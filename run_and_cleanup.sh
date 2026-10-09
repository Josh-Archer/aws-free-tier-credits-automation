#!/bin/bash
# Orchestrates modular free-tier task plugins from tasks/catalog.json + tasks/plugins/*.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_PATH="${SCRIPT_DIR}/tasks/catalog.json"
PLUGINS_DIR="${SCRIPT_DIR}/tasks/plugins"

# --- UTILS ---
log_info() { echo -e "\033[0;36m$1\033[0m"; }
log_success() { echo -e "\033[0;32m$1\033[0m"; }
log_warn() { echo -e "\033[0;33m$1\033[0m"; }
log_error() { echo -e "\033[0;31m$1\033[0m"; }

# --- CATALOG / TASK DISCOVERY ---
if [ ! -f "$CATALOG_PATH" ]; then
    log_error "Task catalog not found: $CATALOG_PATH"
    exit 1
fi

# Requires python3 or jq for JSON; prefer python3 for portability of list parsing
read_catalog_field() {
    local field=$1
    if command -v jq >/dev/null 2>&1; then
        jq -r ".$field" "$CATALOG_PATH"
    else
        python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('$field',''))" "$CATALOG_PATH"
    fi
}

list_task_ids() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.tasks[].id' "$CATALOG_PATH"
    else
        python3 -c "import json,sys; [print(t['id']) for t in json.load(open(sys.argv[1]))['tasks']]" "$CATALOG_PATH"
    fi
}

task_default_enabled() {
    local id=$1
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg id "$id" '.tasks[] | select(.id==$id) | .default_enabled' "$CATALOG_PATH"
    else
        python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(next(t['default_enabled'] for t in c['tasks'] if t['id']==sys.argv[2]))" "$CATALOG_PATH" "$id"
    fi
}

task_meta() {
    local id=$1
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg id "$id" '.tasks[] | select(.id==$id) | "\(.name)\t\(.credit_usd)\t\(.description)"' "$CATALOG_PATH"
    else
        python3 -c "
import json,sys
c=json.load(open(sys.argv[1]))
t=next(x for x in c['tasks'] if x['id']==sys.argv[2])
print(f\"{t['name']}\t{t['credit_usd']}\t{t['description']}\")
" "$CATALOG_PATH" "$id"
    fi
}

mapfile -t ALL_TASK_IDS < <(list_task_ids)

# Build default enable map
declare -A ENABLE
for id in "${ALL_TASK_IDS[@]}"; do
    def=$(task_default_enabled "$id")
    if [ "$def" = "true" ] || [ "$def" = "True" ]; then
        ENABLE[$id]=true
    else
        ENABLE[$id]=false
    fi
done

ONLY_SET=false
AUTO_CHECK=false
LIST_TASKS=false

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Modular free-tier task runner. Tasks are defined in tasks/catalog.json"
    echo "and implemented as plugins under tasks/plugins/."
    echo ""
    echo "Options:"
    for id in "${ALL_TASK_IDS[@]}"; do
        printf "  --skip-%-8s Skip task: %s\n" "$id" "$id"
    done
    echo "  --only IDS      Comma-separated task ids to run exclusively (e.g. ec2,lambda)"
    echo "  --list-tasks    List catalog tasks (id, credit, description) and exit"
    echo "  --auto-check    Display info about AWS credit checking limitations"
    echo "  --help          Display this help message"
    exit 1
}

list_tasks() {
    local last_verified
    last_verified=$(read_catalog_field last_verified)
    local program
    program=$(read_catalog_field program)
    echo "Program: $program"
    echo "Last verified: $last_verified"
    echo ""
    printf "%-12s %-8s %-10s %s\n" "ID" "DEFAULT" "CREDIT" "DESCRIPTION"
    printf "%-12s %-8s %-10s %s\n" "------------" "--------" "----------" "-----------"
    for id in "${ALL_TASK_IDS[@]}"; do
        local meta name credit desc def
        meta=$(task_meta "$id")
        name=$(echo "$meta" | cut -f1)
        credit=$(echo "$meta" | cut -f2)
        desc=$(echo "$meta" | cut -f3)
        def=$(task_default_enabled "$id")
        printf "%-12s %-8s \$%-9s %s\n" "$id" "$def" "$credit" "$desc"
    done
    echo ""
    echo "Enable/skip: --skip-<id> or --only id1,id2"
}

# --- ARGUMENT PARSING ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help) usage ;;
        --auto-check) AUTO_CHECK=true ;;
        --list-tasks) LIST_TASKS=true ;;
        --only)
            shift
            if [[ $# -eq 0 ]]; then
                log_error "--only requires a comma-separated list of task ids"
                exit 1
            fi
            ONLY_SET=true
            for id in "${ALL_TASK_IDS[@]}"; do ENABLE[$id]=false; done
            IFS=',' read -ra ONLY_IDS <<< "$1"
            for oid in "${ONLY_IDS[@]}"; do
                oid=$(echo "$oid" | xargs)
                if [[ -z "${ENABLE[$oid]+x}" ]]; then
                    log_error "Unknown task id in --only: $oid"
                    echo "Known tasks: ${ALL_TASK_IDS[*]}"
                    exit 1
                fi
                ENABLE[$oid]=true
            done
            ;;
        --only=*)
            ONLY_SET=true
            for id in "${ALL_TASK_IDS[@]}"; do ENABLE[$id]=false; done
            IFS=',' read -ra ONLY_IDS <<< "${1#*=}"
            for oid in "${ONLY_IDS[@]}"; do
                oid=$(echo "$oid" | xargs)
                if [[ -z "${ENABLE[$oid]+x}" ]]; then
                    log_error "Unknown task id in --only: $oid"
                    exit 1
                fi
                ENABLE[$oid]=true
            done
            ;;
        --skip-*)
            sid="${1#--skip-}"
            if [[ -z "${ENABLE[$sid]+x}" ]]; then
                log_error "Unknown task to skip: $sid"
                echo "Known tasks: ${ALL_TASK_IDS[*]}"
                exit 1
            fi
            ENABLE[$sid]=false
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
    shift
done

if [ "$LIST_TASKS" = true ]; then
    list_tasks
    exit 0
fi

if [ "$AUTO_CHECK" = true ]; then
    echo "======================================================="
    log_warn "AUTO-CHECK LIMITATION"
    echo "======================================================="
    echo "AWS does not provide a public API or CLI command to retrieve your Promotional Credit balance."
    echo "Please use the AWS Billing Console to verify your credits and use --skip-<id> or --only to control tasks."
    echo "Catalog last verified: $(read_catalog_field last_verified)"
    echo "======================================================="
    exit 0
fi

# --- LOAD PLUGINS ---
for id in "${ALL_TASK_IDS[@]}"; do
    plugin_file="${PLUGINS_DIR}/${id}.sh"
    if [ ! -f "$plugin_file" ]; then
        log_error "Missing plugin for task '$id': $plugin_file"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$plugin_file"
done

# --- IDENTITY CHECK ---
log_info "Verifying AWS CLI Identity..."
IDENTITY=$(aws sts get-caller-identity --query "{Account:Account, Arn:Arn}" --output json 2>/dev/null) || {
    log_error "Error: Unable to verify AWS identity. Please run 'aws configure' first."
    exit 1
}

if command -v jq >/dev/null 2>&1; then
    ACCOUNT_ID=$(echo "$IDENTITY" | jq -r .Account)
    USER_ARN=$(echo "$IDENTITY" | jq -r .Arn)
else
    ACCOUNT_ID=$(echo "$IDENTITY" | python3 -c "import json,sys; print(json.load(sys.stdin)['Account'])")
    USER_ARN=$(echo "$IDENTITY" | python3 -c "import json,sys; print(json.load(sys.stdin)['Arn'])")
fi

echo "Account: $ACCOUNT_ID"
echo "User Arn: $USER_ARN"
echo "Catalog last verified: $(read_catalog_field last_verified)"

# --- PRE-FLIGHT PERMISSION CHECK ---
log_info "\nRunning Pre-flight Permission Checks..."
FAILED_CHECKS=0

for id in "${ALL_TASK_IDS[@]}"; do
    if [ "${ENABLE[$id]}" = true ]; then
        check_fn="task_${id}_check_perm"
        if declare -f "$check_fn" >/dev/null; then
            if "$check_fn"; then
                log_success "  [OK] $id Read Permissions"
            else
                log_error "  [FAIL] $id Read Permissions"
                FAILED_CHECKS=$((FAILED_CHECKS + 1))
            fi
        else
            log_warn "  [SKIP] $id has no check_perm hook"
        fi
    fi
done

if [ "$FAILED_CHECKS" -gt 0 ]; then
    log_warn "\nWarning: $FAILED_CHECKS permission check(s) failed. If you proceed, the script will likely fail to create resources."
fi

ENABLED_LIST=""
for id in "${ALL_TASK_IDS[@]}"; do
    ENABLED_LIST+="${id}=${ENABLE[$id]} "
done
log_info "\nStarting AWS Free Tier Credit Automation..."
echo "Enabled Tasks: $ENABLED_LIST"

# --- PROVISIONING & CLEANUP STATE ---
PROVISIONED_IDS=()
FAILED_PROVISIONS=()
FAILED_CLEANUPS=()
CURRENT_TASK=""
RUNNER_PHASE="provisioning"
SLEEP_PID=""

add_failed_cleanup() {
    local task_id=$1
    for f in "${FAILED_CLEANUPS[@]:-}"; do
        [ "$f" = "$task_id" ] && return 0
    done
    FAILED_CLEANUPS+=("$task_id")
}

cleanup_resources() {
    log_info "\n=== CLEANING UP RESOURCES ==="

    if [ -n "${CURRENT_TASK:-}" ]; then
        local in_prog="$CURRENT_TASK"
        CURRENT_TASK=""
        local cleanup_fn="task_${in_prog}_cleanup"
        if declare -f "$cleanup_fn" >/dev/null; then
            if ! "$cleanup_fn"; then
                log_warn "Cleanup reported an error for task: $in_prog"
                add_failed_cleanup "$in_prog"
            fi
        fi
    fi

    # Cleanup in reverse order of provision
    for ((i=${#PROVISIONED_IDS[@]}-1; i>=0; i--)); do
        local id="${PROVISIONED_IDS[$i]}"
        local cleanup_fn="task_${id}_cleanup"
        if declare -f "$cleanup_fn" >/dev/null; then
            if ! "$cleanup_fn"; then
                log_warn "Cleanup reported an error for task: $id"
                add_failed_cleanup "$id"
            fi
        fi
    done

    # Residual temp files from plugins
    rm -f trust-policy.json main.py lambda.zip config.txt profiles.txt
}

handle_interrupt() {
    trap - INT TERM
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
    echo ""
    if [ "$RUNNER_PHASE" = "wait" ]; then
        log_warn "Interrupted during wait. Cleaning up provisioned resources..."
    else
        log_warn "Interrupted during provisioning. Cleaning up provisioned resources..."
    fi
    cleanup_resources
    exit 130
}

# Arm interrupt handler during provisioning phase
trap handle_interrupt INT TERM

# --- PROVISIONING ---
log_info "\n=== PROVISIONING RESOURCES ==="

for id in "${ALL_TASK_IDS[@]}"; do
    if [ "${ENABLE[$id]}" = true ]; then
        provision_fn="task_${id}_provision"
        if declare -f "$provision_fn" >/dev/null; then
            CURRENT_TASK="$id"
            if "$provision_fn"; then
                PROVISIONED_IDS+=("$id")
            else
                log_error "Provisioning failed for task: $id"
                FAILED_PROVISIONS+=("$id")
                cleanup_fn="task_${id}_cleanup"
                if declare -f "$cleanup_fn" >/dev/null; then
                    if ! "$cleanup_fn"; then
                        log_warn "Cleanup reported an error for task: $id"
                        add_failed_cleanup "$id"
                    fi
                fi
            fi
            CURRENT_TASK=""
        else
            log_error "Plugin missing provision function: $provision_fn"
            FAILED_PROVISIONS+=("$id")
        fi
    fi
done

# --- WAITING ---
RUNNER_PHASE="wait"
echo -e "\n======================================================="
log_warn "Provisioning phase complete!"
log_warn "Waiting 3 minutes for AWS to register the activity..."
sleep "${WAIT_SECONDS:-180}" &
SLEEP_PID=$!
wait "$SLEEP_PID" 2>/dev/null || true
SLEEP_PID=""
echo "======================================================="

# --- CLEANUP ---
RUNNER_PHASE="cleanup"
cleanup_resources

trap - INT TERM

if [ ${#FAILED_PROVISIONS[@]} -gt 0 ] || [ ${#FAILED_CLEANUPS[@]} -gt 0 ]; then
    log_error "\n=== AUTOMATION SUMMARY: FAILURE ==="
    if [ ${#FAILED_PROVISIONS[@]} -gt 0 ]; then
        log_error "Provisioning failed for task(s): ${FAILED_PROVISIONS[*]}"
    fi
    if [ ${#FAILED_CLEANUPS[@]} -gt 0 ]; then
        log_error "Cleanup failed for task(s) (resources may still exist): ${FAILED_CLEANUPS[*]}"
        log_error "The following resources may still exist in your account:"
        for id in "${FAILED_CLEANUPS[@]}"; do
            case "$id" in
                ec2)
                    if [ -n "${TASK_EC2_INSTANCE_ID:-}" ]; then
                        log_error "  - EC2 Instance: $TASK_EC2_INSTANCE_ID"
                    else
                        log_error "  - EC2 resources for task: $id"
                    fi
                    ;;
                rds)
                    if [ -n "${TASK_RDS_ID:-}" ]; then
                        log_error "  - RDS Instance: $TASK_RDS_ID"
                    else
                        log_error "  - RDS resources for task: $id"
                    fi
                    ;;
                lambda)
                    res=""
                    [ -n "${TASK_LAMBDA_NAME:-}" ] && res+="Function: $TASK_LAMBDA_NAME"
                    if [ -n "${TASK_LAMBDA_ROLE:-}" ]; then
                        [ -n "$res" ] && res+=" "
                        res+="Role: $TASK_LAMBDA_ROLE"
                    fi
                    if [ -n "$res" ]; then
                        log_error "  - Lambda ($res)"
                    else
                        log_error "  - Lambda resources for task: $id"
                    fi
                    ;;
                budget)
                    if [ -n "${TASK_BUDGET_NAME:-}" ]; then
                        log_error "  - Budget: $TASK_BUDGET_NAME"
                    else
                        log_error "  - Budget resources for task: $id"
                    fi
                    ;;
                *)
                    log_error "  - Task: $id"
                    ;;
            esac
        done
    fi
    exit 1
fi

log_success "\nAutomation Finished Successfully!"

