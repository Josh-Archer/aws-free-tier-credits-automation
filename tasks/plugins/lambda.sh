# Task plugin: Lambda — create IAM role + Python function, then delete both.
# Namespace: task_lambda_*
# Requires: ACCOUNT_ID (set by runner)

task_lambda_check_perm() {
    aws lambda list-functions --max-items 1 >/dev/null 2>&1
}

task_lambda_provision() {
    log_info "Creating Lambda Role and Function..."
    TASK_LAMBDA_ROLE="freetier-role-$RANDOM"
    local func_name="freetier-func-$RANDOM"

    local trust_policy='{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    echo "$trust_policy" > trust-policy.json
    if ! aws iam create-role --role-name "$TASK_LAMBDA_ROLE" --assume-role-policy-document file://trust-policy.json >/dev/null; then
        log_error "Failed to create IAM role: $TASK_LAMBDA_ROLE"
        TASK_LAMBDA_ROLE=""
        rm -f trust-policy.json
        return 1
    fi

    # Wait for role to propagate
    sleep "${LAMBDA_ROLE_WAIT:-10}"

    echo "def lambda_handler(event, context): return 'Hello Free Tier'" > main.py
    if ! zip -q lambda.zip main.py; then
        log_error "Failed to package lambda code."
        TASK_LAMBDA_NAME=""
        task_lambda_cleanup
        return 1
    fi

    if ! aws lambda create-function \
        --function-name "$func_name" \
        --runtime python3.12 \
        --role "arn:aws:iam::${ACCOUNT_ID}:role/${TASK_LAMBDA_ROLE}" \
        --handler main.lambda_handler \
        --zip-file fileb://lambda.zip >/dev/null; then
        log_error "Failed to create Lambda function: $func_name"
        TASK_LAMBDA_NAME=""
        task_lambda_cleanup
        return 1
    fi

    TASK_LAMBDA_NAME="$func_name"
    log_success "Created Lambda: $TASK_LAMBDA_NAME"
}

task_lambda_cleanup() {
    local cleaned=false
    if [ -n "${TASK_LAMBDA_NAME:-}" ]; then
        log_info "Deleting Lambda Function: $TASK_LAMBDA_NAME..."
        aws lambda delete-function --function-name "$TASK_LAMBDA_NAME" >/dev/null 2>&1 || true
        TASK_LAMBDA_NAME=""
        cleaned=true
    fi
    if [ -n "${TASK_LAMBDA_ROLE:-}" ]; then
        log_info "Deleting IAM Role: $TASK_LAMBDA_ROLE..."
        aws iam delete-role --role-name "$TASK_LAMBDA_ROLE" >/dev/null 2>&1 || true
        TASK_LAMBDA_ROLE=""
        cleaned=true
    fi
    if [ "$cleaned" = true ]; then
        log_success "Destroyed Lambda."
    fi
    rm -f trust-policy.json main.py lambda.zip
}
