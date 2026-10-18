# Task plugin: Lambda — create IAM role + Python function, then delete both.
# Namespace: task_lambda_*
# Requires: ACCOUNT_ID (set by runner)

task_lambda_check_perm() {
    aws lambda list-functions --max-items 1 >/dev/null 2>&1
}

task_lambda_provision() {
    log_info "Creating Lambda Role and Function..."
    local run_id="${RUN_ID:-run-$RANDOM}"
    TASK_LAMBDA_ROLE="freetier-role-$RANDOM"
    local func_name="freetier-func-$RANDOM"

    TASK_LAMBDA_TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'lambda')"

    local trust_policy='{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    echo "$trust_policy" > "${TASK_LAMBDA_TMP_DIR}/trust-policy.json"
    if ! aws iam create-role --role-name "$TASK_LAMBDA_ROLE" --assume-role-policy-document "file://${TASK_LAMBDA_TMP_DIR}/trust-policy.json" --tags "Key=freetier-run-id,Value=$run_id" >/dev/null; then
        log_error "Failed to create IAM role: $TASK_LAMBDA_ROLE"
        TASK_LAMBDA_ROLE=""
        rm -rf "$TASK_LAMBDA_TMP_DIR"
        TASK_LAMBDA_TMP_DIR=""
        return 1
    fi

    # Wait for role to propagate
    sleep "${LAMBDA_ROLE_WAIT:-10}"

    echo "def lambda_handler(event, context): return 'Hello Free Tier'" > "${TASK_LAMBDA_TMP_DIR}/main.py"
    local zipped=false
    if command -v zip >/dev/null 2>&1; then
        if (cd "$TASK_LAMBDA_TMP_DIR" && zip -q lambda.zip main.py); then
            zipped=true
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if (cd "$TASK_LAMBDA_TMP_DIR" && python3 -c "import zipfile; z=zipfile.ZipFile('lambda.zip','w'); z.write('main.py'); z.close()" >/dev/null 2>&1); then
            zipped=true
        fi
    fi
    if [ "$zipped" != true ]; then
        log_error "Failed to package lambda code."
        TASK_LAMBDA_NAME=""
        task_lambda_cleanup
        return 1
    fi

    TASK_LAMBDA_NAME="$func_name"
    if ! aws lambda create-function \
        --function-name "$func_name" \
        --runtime python3.12 \
        --role "arn:aws:iam::${ACCOUNT_ID}:role/${TASK_LAMBDA_ROLE}" \
        --handler main.lambda_handler \
        --tags "freetier-run-id=$run_id" \
        --zip-file "fileb://${TASK_LAMBDA_TMP_DIR}/lambda.zip" >/dev/null; then
        TASK_LAMBDA_NAME=""
        log_error "Failed to create Lambda function: $func_name"
        task_lambda_cleanup
        return 1
    fi

    log_success "Created Lambda: $TASK_LAMBDA_NAME"
}

delete_iam_role() {
    local role_name="$1"
    [ -z "$role_name" ] && return 0

    # 1. Detach attached policies
    local attached_raw
    if attached_raw=$(aws iam list-attached-role-policies --role-name "$role_name" --output json 2>/dev/null); then
        if [ -n "$attached_raw" ]; then
            local policy_arns=()
            if command -v jq >/dev/null 2>&1; then
                mapfile -t policy_arns < <(echo "$attached_raw" | jq -r '.AttachedPolicies[]?.PolicyArn // empty' 2>/dev/null)
            elif command -v python3 >/dev/null 2>&1; then
                mapfile -t policy_arns < <(python3 -c "
import sys, json
raw = sys.argv[1].strip()
if raw:
    try:
        d = json.loads(raw)
        for p in d.get('AttachedPolicies', []):
            arn = p.get('PolicyArn')
            if arn: print(arn)
    except Exception:
        pass
" "$attached_raw" 2>/dev/null)
            fi
            for arn in "${policy_arns[@]}"; do
                [ -z "$arn" ] && continue
                log_info "Detaching policy $arn from role $role_name..."
                aws iam detach-role-policy --role-name "$role_name" --policy-arn "$arn" >/dev/null 2>&1 || true
            done
        fi
    fi

    # 2. Delete inline policies
    local inline_raw
    if inline_raw=$(aws iam list-role-policies --role-name "$role_name" --output json 2>/dev/null); then
        if [ -n "$inline_raw" ]; then
            local inline_names=()
            if command -v jq >/dev/null 2>&1; then
                mapfile -t inline_names < <(echo "$inline_raw" | jq -r '.PolicyNames[]? // empty' 2>/dev/null)
            elif command -v python3 >/dev/null 2>&1; then
                mapfile -t inline_names < <(python3 -c "
import sys, json
raw = sys.argv[1].strip()
if raw:
    try:
        d = json.loads(raw)
        for name in d.get('PolicyNames', []):
            if name: print(name)
    except Exception:
        pass
" "$inline_raw" 2>/dev/null)
            fi
            for pname in "${inline_names[@]}"; do
                [ -z "$pname" ] && continue
                log_info "Deleting inline policy $pname from role $role_name..."
                aws iam delete-role-policy --role-name "$role_name" --policy-name "$pname" >/dev/null 2>&1 || true
            done
        fi
    fi

    # 3. Delete role
    aws iam delete-role --role-name "$role_name"
}

task_lambda_cleanup() {
    local cleaned=false
    local failed=false
    if [ -n "${TASK_LAMBDA_NAME:-}" ]; then
        log_info "Deleting Lambda Function: $TASK_LAMBDA_NAME..."
        local del_err
        if ! del_err=$(aws lambda delete-function --function-name "$TASK_LAMBDA_NAME" 2>&1); then
            if [[ "$del_err" =~ ResourceNotFoundException ]]; then
                TASK_LAMBDA_NAME=""
                cleaned=true
            else
                log_error "Failed to delete Lambda function: $TASK_LAMBDA_NAME"
                failed=true
            fi
        else
            TASK_LAMBDA_NAME=""
            cleaned=true
        fi
    fi
    if [ -n "${TASK_LAMBDA_ROLE:-}" ]; then
        log_info "Deleting IAM Role: $TASK_LAMBDA_ROLE..."
        if ! delete_iam_role "$TASK_LAMBDA_ROLE" >/dev/null 2>&1; then
            log_error "Failed to delete IAM role: $TASK_LAMBDA_ROLE"
            failed=true
        else
            TASK_LAMBDA_ROLE=""
            cleaned=true
        fi
    fi
    if [ -n "${TASK_LAMBDA_TMP_DIR:-}" ] && [ -d "$TASK_LAMBDA_TMP_DIR" ]; then
        rm -rf "$TASK_LAMBDA_TMP_DIR"
        TASK_LAMBDA_TMP_DIR=""
    fi
    rm -f trust-policy.json main.py lambda.zip
    if [ "$failed" = true ]; then
        return 1
    fi
    if [ "$cleaned" = true ]; then
        log_success "Destroyed Lambda."
    fi
}
