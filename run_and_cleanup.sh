#!/bin/bash
set -euo pipefail

# --- DEFAULTS ---
ENABLE_EC2=true
ENABLE_RDS=true
ENABLE_LAMBDA=true
ENABLE_BUDGET=true
AUTO_CHECK=false
RESET_STATE=false
FORCE=false
STATE_FILE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- USAGE ---
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --skip-ec2       Skip EC2 instance creation"
    echo "  --skip-rds       Skip RDS database creation"
    echo "  --skip-lambda    Skip Lambda function creation"
    echo "  --skip-budget    Skip Budget creation"
    echo "  --auto-check     Display info about AWS credit checking limitations"
    echo "  --state-file PATH  Path to JSON state file (default: .aws-freetier-state.json next to this script)"
    echo "  --reset-state    Delete the state file and start clean"
    echo "  --force          Re-run tasks even if marked completed in the state file"
    echo "  --help           Display this help message"
    exit 1
}

# --- ARGUMENT PARSING ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-ec2) ENABLE_EC2=false ;;
        --skip-rds) ENABLE_RDS=false ;;
        --skip-lambda) ENABLE_LAMBDA=false ;;
        --skip-budget) ENABLE_BUDGET=false ;;
        --auto-check) AUTO_CHECK=true ;;
        --state-file)
            STATE_FILE="${2:-}"
            if [ -z "$STATE_FILE" ]; then echo "Error: --state-file requires a path"; usage; fi
            shift
            ;;
        --reset-state) RESET_STATE=true ;;
        --force) FORCE=true ;;
        --help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# --- UTILS ---
log_info() { echo -e "\033[0;36m$1\033[0m"; }
log_success() { echo -e "\033[0;32m$1\033[0m"; }
log_warn() { echo -e "\033[0;33m$1\033[0m"; }
log_error() { echo -e "\033[0;31m$1\033[0m"; }
log_dim() { echo -e "\033[0;90m$1\033[0m"; }

if [ "$AUTO_CHECK" = true ]; then
    echo "======================================================="
    log_warn "AUTO-CHECK LIMITATION"
    echo "======================================================="
    echo "AWS does not provide a public API or CLI command to retrieve your Promotional Credit balance."
    echo "Please use the AWS Billing Console to verify your credits and use the --skip flags to skip the ones you already have."
    echo "======================================================="
    exit 0
fi

if [ -z "$STATE_FILE" ]; then
    STATE_FILE="$SCRIPT_DIR/.aws-freetier-state.json"
fi

# In-memory task fields (loaded/saved via state file)
STATE_ACCOUNT_ID=""
EC2_STATUS="pending"
EC2_INSTANCE_ID=""
EC2_COMPLETED_AT=""
RDS_STATUS="pending"
RDS_DB_ID=""
RDS_COMPLETED_AT=""
LAMBDA_STATUS="pending"
LAMBDA_NAME=""
LAMBDA_ROLE=""
LAMBDA_COMPLETED_AT=""
BUDGET_STATUS="pending"
BUDGET_NAME=""
BUDGET_COMPLETED_AT=""

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Extract a nested string value from our fixed-schema JSON state file (no jq required).
# Usage: json_get_task_field <task> <field>   e.g. json_get_task_field ec2 status
json_get_top() {
    local key="$1"
    local default="${2:-}"
    if [ ! -f "$STATE_FILE" ]; then
        echo "$default"
        return
    fi
    # Match "key": "value" or "key": null
    local line
    line=$(grep -E "\"$key\"[[:space:]]*:" "$STATE_FILE" | head -1 || true)
    if [ -z "$line" ]; then
        echo "$default"
        return
    fi
    if echo "$line" | grep -q 'null'; then
        echo "$default"
        return
    fi
    echo "$line" | sed -E 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}

# For nested task fields we rely on unique field names within our schema:
# instanceId, dbInstanceId, functionName, roleName, budgetName, completedAt appear once per task block.
# Status is repeated; use task-block extraction via awk.
json_get_task_status() {
    local task="$1"
    if [ ! -f "$STATE_FILE" ]; then
        echo "pending"
        return
    fi
    # Portable awk (no gawk-only match 3-arg form)
    local val
    val=$(awk -v task="$task" '
        $0 ~ "\"" task "\"" { in_task=1; next }
        in_task && /"status"/ {
            if ($0 ~ /null/) { print ""; exit }
            sub(/.*"status"[[:space:]]*:[[:space:]]*"/, "")
            sub(/".*/, "")
            print
            exit
        }
        in_task && /}/ { in_task=0 }
    ' "$STATE_FILE" 2>/dev/null || true)
    if [ -z "$val" ]; then
        echo "pending"
    else
        echo "$val"
    fi
}

json_get_task_field() {
    local task="$1"
    local field="$2"
    if [ ! -f "$STATE_FILE" ]; then
        echo ""
        return
    fi
    awk -v task="$task" -v field="$field" '
        $0 ~ "\"" task "\"" { in_task=1; next }
        in_task && index($0, "\"" field "\"") {
            if ($0 ~ /null/) { print ""; exit }
            # strip through opening quote after colon
            sub(".*\"" field "\"[[:space:]]*:[[:space:]]*\"", "")
            sub(/".*/, "")
            print
            exit
        }
        in_task && /}/ { in_task=0 }
    ' "$STATE_FILE" 2>/dev/null || true
}

load_state() {
    EC2_STATUS="pending"; EC2_INSTANCE_ID=""; EC2_COMPLETED_AT=""
    RDS_STATUS="pending"; RDS_DB_ID=""; RDS_COMPLETED_AT=""
    LAMBDA_STATUS="pending"; LAMBDA_NAME=""; LAMBDA_ROLE=""; LAMBDA_COMPLETED_AT=""
    BUDGET_STATUS="pending"; BUDGET_NAME=""; BUDGET_COMPLETED_AT=""
    STATE_ACCOUNT_ID=""

    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    STATE_ACCOUNT_ID=$(json_get_top "accountId" "")

    local s
    s=$(json_get_task_status "ec2"); [ -n "$s" ] && EC2_STATUS="$s"
    EC2_INSTANCE_ID=$(json_get_task_field "ec2" "instanceId")
    EC2_COMPLETED_AT=$(json_get_task_field "ec2" "completedAt")

    s=$(json_get_task_status "rds"); [ -n "$s" ] && RDS_STATUS="$s"
    RDS_DB_ID=$(json_get_task_field "rds" "dbInstanceId")
    RDS_COMPLETED_AT=$(json_get_task_field "rds" "completedAt")

    s=$(json_get_task_status "lambda"); [ -n "$s" ] && LAMBDA_STATUS="$s"
    LAMBDA_NAME=$(json_get_task_field "lambda" "functionName")
    LAMBDA_ROLE=$(json_get_task_field "lambda" "roleName")
    LAMBDA_COMPLETED_AT=$(json_get_task_field "lambda" "completedAt")

    s=$(json_get_task_status "budget"); [ -n "$s" ] && BUDGET_STATUS="$s"
    BUDGET_NAME=$(json_get_task_field "budget" "budgetName")
    BUDGET_COMPLETED_AT=$(json_get_task_field "budget" "completedAt")
}

json_or_null() {
    local v="$1"
    if [ -z "$v" ]; then
        echo "null"
    else
        # escape backslashes and quotes
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        echo "\"$v\""
    fi
}

save_state() {
    local updated
    updated=$(utc_now)
    local dir
    dir=$(dirname "$STATE_FILE")
    mkdir -p "$dir"

    cat > "$STATE_FILE" <<EOF
{
  "version": 1,
  "accountId": $(json_or_null "$STATE_ACCOUNT_ID"),
  "updatedAt": $(json_or_null "$updated"),
  "tasks": {
    "ec2": {
      "status": $(json_or_null "$EC2_STATUS"),
      "instanceId": $(json_or_null "$EC2_INSTANCE_ID"),
      "completedAt": $(json_or_null "$EC2_COMPLETED_AT")
    },
    "rds": {
      "status": $(json_or_null "$RDS_STATUS"),
      "dbInstanceId": $(json_or_null "$RDS_DB_ID"),
      "completedAt": $(json_or_null "$RDS_COMPLETED_AT")
    },
    "lambda": {
      "status": $(json_or_null "$LAMBDA_STATUS"),
      "functionName": $(json_or_null "$LAMBDA_NAME"),
      "roleName": $(json_or_null "$LAMBDA_ROLE"),
      "completedAt": $(json_or_null "$LAMBDA_COMPLETED_AT")
    },
    "budget": {
      "status": $(json_or_null "$BUDGET_STATUS"),
      "budgetName": $(json_or_null "$BUDGET_NAME"),
      "completedAt": $(json_or_null "$BUDGET_COMPLETED_AT")
    }
  }
}
EOF
}

task_should_run() {
    local enabled="$1"
    local status="$2"
    if [ "$enabled" != true ]; then
        echo false
        return
    fi
    if [ "$FORCE" = true ]; then
        echo true
        return
    fi
    if [ "$status" = "completed" ]; then
        echo false
        return
    fi
    echo true
}

if [ "$RESET_STATE" = true ]; then
    if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE"
        log_warn "State file reset: $STATE_FILE"
    else
        log_warn "No state file to reset at: $STATE_FILE"
    fi
fi

load_state
log_dim "State file: $STATE_FILE"

# --- IDENTITY CHECK ---
log_info "Verifying AWS CLI Identity..."
if ! IDENTITY=$(aws sts get-caller-identity --query "{Account:Account, Arn:Arn}" --output json 2>/dev/null); then
    log_error "Error: Unable to verify AWS identity. Please run 'aws configure' first."
    exit 1
fi

# Portable JSON field extraction (no grep -P)
ACCOUNT_ID=$(echo "$IDENTITY" | sed -n 's/.*"Account"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
USER_ARN=$(echo "$IDENTITY" | sed -n 's/.*"Arn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

echo "Account: $ACCOUNT_ID"
echo "User Arn: $USER_ARN"

if [ -n "$STATE_ACCOUNT_ID" ] && [ "$STATE_ACCOUNT_ID" != "$ACCOUNT_ID" ]; then
    log_warn "Warning: State file belongs to account $STATE_ACCOUNT_ID, but active identity is $ACCOUNT_ID."
    log_warn "Starting a new state for the current account. Use --reset-state to clear the old file explicitly."
    EC2_STATUS="pending"; EC2_INSTANCE_ID=""; EC2_COMPLETED_AT=""
    RDS_STATUS="pending"; RDS_DB_ID=""; RDS_COMPLETED_AT=""
    LAMBDA_STATUS="pending"; LAMBDA_NAME=""; LAMBDA_ROLE=""; LAMBDA_COMPLETED_AT=""
    BUDGET_STATUS="pending"; BUDGET_NAME=""; BUDGET_COMPLETED_AT=""
fi
STATE_ACCOUNT_ID="$ACCOUNT_ID"
save_state

RUN_EC2=$(task_should_run "$ENABLE_EC2" "$EC2_STATUS")
RUN_RDS=$(task_should_run "$ENABLE_RDS" "$RDS_STATUS")
RUN_LAMBDA=$(task_should_run "$ENABLE_LAMBDA" "$LAMBDA_STATUS")
RUN_BUDGET=$(task_should_run "$ENABLE_BUDGET" "$BUDGET_STATUS")

print_skip() {
    local label="$1" enabled="$2" status="$3"
    if [ "$enabled" != true ]; then
        log_dim "  Skipping $label (disabled by flag)."
        return
    fi
    if [ "$status" = "completed" ] && [ "$FORCE" != true ]; then
        log_dim "  Skipping $label (already completed in state file). Use --force to re-run."
    fi
}

# --- PRE-FLIGHT PERMISSION CHECK ---
log_info "\nRunning Pre-flight Permission Checks..."
FAILED_CHECKS=0

check_perm() {
    local service=$1
    local cmd=$2
    if eval "$cmd" >/dev/null 2>&1; then
        log_success "  [OK] $service Read Permissions"
    else
        log_error "  [FAIL] $service Read Permissions"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

[ "$RUN_EC2" = true ] && check_perm "EC2" "aws ec2 describe-regions --max-items 1"
[ "$RUN_RDS" = true ] && check_perm "RDS" "aws rds describe-db-instances --max-items 1"
[ "$RUN_LAMBDA" = true ] && check_perm "Lambda" "aws lambda list-functions --max-items 1"
[ "$RUN_BUDGET" = true ] && check_perm "Budget" "aws budgets describe-budgets --account-id $ACCOUNT_ID --max-items 1"

if [ "$FAILED_CHECKS" -gt 0 ]; then
    log_warn "\nWarning: $FAILED_CHECKS permission check(s) failed. If you proceed, the script will likely fail to create resources."
fi

log_info "\nStarting AWS Free Tier Credit Automation..."
echo "Enabled Flags: EC2=$ENABLE_EC2, RDS=$ENABLE_RDS, Lambda=$ENABLE_LAMBDA, Budget=$ENABLE_BUDGET"
echo "Will run this session: EC2=$RUN_EC2, RDS=$RUN_RDS, Lambda=$RUN_LAMBDA, Budget=$RUN_BUDGET"
print_skip "EC2" "$ENABLE_EC2" "$EC2_STATUS"
print_skip "RDS" "$ENABLE_RDS" "$RDS_STATUS"
print_skip "Lambda" "$ENABLE_LAMBDA" "$LAMBDA_STATUS"
print_skip "Budget" "$ENABLE_BUDGET" "$BUDGET_STATUS"

INSTANCE_ID=""
RDS_ID=""
LAMBDA_ROLE_NAME=""
LAMBDA_FUNC_NAME=""
BUDGET_NAME_ACTIVE=""

# Resume from provisioned state (interrupted prior run)
if [ "$RUN_EC2" = true ] && [ "$EC2_STATUS" = "provisioned" ] && [ -n "$EC2_INSTANCE_ID" ]; then
    INSTANCE_ID="$EC2_INSTANCE_ID"
    log_warn "Resuming EC2 cleanup from state: $INSTANCE_ID"
fi
if [ "$RUN_RDS" = true ] && [ "$RDS_STATUS" = "provisioned" ] && [ -n "$RDS_DB_ID" ]; then
    RDS_ID="$RDS_DB_ID"
    log_warn "Resuming RDS cleanup from state: $RDS_ID"
fi
if [ "$RUN_LAMBDA" = true ] && [ "$LAMBDA_STATUS" = "provisioned" ] && [ -n "$LAMBDA_NAME" ]; then
    LAMBDA_FUNC_NAME="$LAMBDA_NAME"
    LAMBDA_ROLE_NAME="$LAMBDA_ROLE"
    log_warn "Resuming Lambda cleanup from state: $LAMBDA_FUNC_NAME"
fi
if [ "$RUN_BUDGET" = true ] && [ "$BUDGET_STATUS" = "provisioned" ] && [ -n "$BUDGET_NAME" ]; then
    BUDGET_NAME_ACTIVE="$BUDGET_NAME"
    log_warn "Resuming Budget cleanup from state: $BUDGET_NAME_ACTIVE"
fi

# --- PROVISIONING ---
log_info "\n=== PROVISIONING RESOURCES ==="

if [ "$RUN_EC2" = true ] && [ -z "$INSTANCE_ID" ]; then
    log_info "Fetching latest Amazon Linux 2 AMI..."
    AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
    log_info "Launching EC2 instance (t2.micro) with AMI $AMI..."
    INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t2.micro --query "Instances[0].InstanceId" --output text)
    EC2_STATUS="provisioned"
    EC2_INSTANCE_ID="$INSTANCE_ID"
    EC2_COMPLETED_AT=""
    save_state
    log_success "Created EC2 Instance: $INSTANCE_ID"
fi

if [ "$RUN_RDS" = true ] && [ -z "$RDS_ID" ]; then
    log_info "Creating RDS Database (db.t3.micro MySQL)..."
    RDS_ID="freetier-db-$RANDOM"
    aws rds create-db-instance --db-instance-identifier "$RDS_ID" --allocated-storage 20 --engine mysql --engine-version 8.0 --instance-class db.t3.micro --master-username admin --master-user-password "FreeTierPassword123!" --no-publicly-accessible --skip-final-snapshot >/dev/null
    RDS_STATUS="provisioned"
    RDS_DB_ID="$RDS_ID"
    RDS_COMPLETED_AT=""
    save_state
    log_success "Created RDS Database: $RDS_ID"
fi

if [ "$RUN_LAMBDA" = true ] && [ -z "$LAMBDA_FUNC_NAME" ]; then
    log_info "Creating Lambda Role and Function..."
    ROLE_NAME="freetier-role-$RANDOM"
    FUNC_NAME="freetier-func-$RANDOM"

    TRUST_POLICY='{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    echo "$TRUST_POLICY" > trust-policy.json
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://trust-policy.json >/dev/null

    # Wait for role to propagate
    sleep 10

    echo "def lambda_handler(event, context): return 'Hello Free Tier'" > main.py
    zip -q lambda.zip main.py

    aws lambda create-function --function-name "$FUNC_NAME" --runtime python3.12 --role "arn:aws:iam::${ACCOUNT_ID}:role/$ROLE_NAME" --handler main.lambda_handler --zip-file fileb://lambda.zip >/dev/null

    LAMBDA_FUNC_NAME="$FUNC_NAME"
    LAMBDA_ROLE_NAME="$ROLE_NAME"
    LAMBDA_STATUS="provisioned"
    LAMBDA_NAME="$FUNC_NAME"
    LAMBDA_ROLE="$ROLE_NAME"
    LAMBDA_COMPLETED_AT=""
    save_state
    log_success "Created Lambda: $FUNC_NAME"
fi

if [ "$RUN_BUDGET" = true ] && [ -z "$BUDGET_NAME_ACTIVE" ]; then
    log_info "Creating AWS Budget..."
    BNAME="freetier-budget-$RANDOM"
    BUDGET_DEF="{\"BudgetName\":\"$BNAME\",\"BudgetLimit\":{\"Amount\":\"10\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}"
    aws budgets create-budget --account-id "$ACCOUNT_ID" --budget "$BUDGET_DEF" --notifications-with-subscribers "[]" >/dev/null
    BUDGET_NAME_ACTIVE="$BNAME"
    BUDGET_STATUS="provisioned"
    BUDGET_NAME="$BNAME"
    BUDGET_COMPLETED_AT=""
    save_state
    log_success "Created Budget: $BNAME"
fi

HAS_RESOURCES=false
[ -n "$INSTANCE_ID" ] && HAS_RESOURCES=true
[ -n "$RDS_ID" ] && HAS_RESOURCES=true
[ -n "$LAMBDA_FUNC_NAME" ] && HAS_RESOURCES=true
[ -n "$BUDGET_NAME_ACTIVE" ] && HAS_RESOURCES=true

if [ "$HAS_RESOURCES" != true ]; then
    log_success "\nNo resources to provision or clean up. All requested tasks are complete or disabled."
    log_dim "State file: $STATE_FILE"
    log_success "\nAutomation Finished Successfully!"
    exit 0
fi

# --- WAITING ---
echo -e "\n======================================================="
log_warn "Provisioning phase complete!"
log_warn "Waiting 3 minutes for AWS to register the activity..."
sleep 180
echo "======================================================="

# --- CLEANUP ---
log_info "\n=== CLEANING UP RESOURCES ==="

if [ -n "$INSTANCE_ID" ]; then
    log_info "Terminating EC2 Instance: $INSTANCE_ID..."
    if aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null; then
        log_success "Destroyed EC2."
        EC2_STATUS="completed"
        EC2_COMPLETED_AT=$(utc_now)
        save_state
    else
        log_error "Failed to terminate EC2."
    fi
fi

if [ -n "$RDS_ID" ]; then
    log_info "Deleting RDS Database: $RDS_ID..."
    if aws rds delete-db-instance --db-instance-identifier "$RDS_ID" --skip-final-snapshot >/dev/null; then
        log_success "Destroyed RDS."
        RDS_STATUS="completed"
        RDS_COMPLETED_AT=$(utc_now)
        save_state
    else
        log_error "Failed to delete RDS."
    fi
fi

if [ -n "$LAMBDA_FUNC_NAME" ]; then
    log_info "Deleting Lambda Function: $LAMBDA_FUNC_NAME..."
    if aws lambda delete-function --function-name "$LAMBDA_FUNC_NAME" >/dev/null; then
        if [ -n "$LAMBDA_ROLE_NAME" ]; then
            aws iam delete-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null || true
        fi
        log_success "Destroyed Lambda."
        LAMBDA_STATUS="completed"
        LAMBDA_COMPLETED_AT=$(utc_now)
        save_state
    else
        log_error "Failed to delete Lambda."
    fi
fi

if [ -n "$BUDGET_NAME_ACTIVE" ]; then
    log_info "Deleting Budget: $BUDGET_NAME_ACTIVE..."
    if aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME_ACTIVE" >/dev/null; then
        log_success "Destroyed Budget."
        BUDGET_STATUS="completed"
        BUDGET_COMPLETED_AT=$(utc_now)
        save_state
    else
        log_error "Failed to delete Budget."
    fi
fi

# Cleanup temp files
rm -f trust-policy.json main.py lambda.zip config.txt profiles.txt

log_dim "State saved to: $STATE_FILE"
log_dim "Completed tasks will be skipped on the next run. Use --reset-state or --force to re-run."
log_success "\nAutomation Finished Successfully!"
