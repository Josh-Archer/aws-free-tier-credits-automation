# Task plugin: Lambda — create IAM role + Python function, then delete both.
# Namespace: task_lambda_*
# Requires: ACCOUNT_ID (set by runner)

task_lambda_check_perm() {
    aws lambda list-functions --max-items 1 >/dev/null 2>&1
}

task_lambda_provision() {
    log_info "Creating Lambda Role and Function..."
    TASK_LAMBDA_ROLE="freetier-role-$RANDOM"
    TASK_LAMBDA_NAME="freetier-func-$RANDOM"

    local trust_policy='{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    echo "$trust_policy" > trust-policy.json
    aws iam create-role --role-name "$TASK_LAMBDA_ROLE" --assume-role-policy-document file://trust-policy.json >/dev/null

    # Wait for role to propagate
    sleep 10

    echo "def lambda_handler(event, context): return 'Hello Free Tier'" > main.py
    zip -q lambda.zip main.py

    aws lambda create-function \
        --function-name "$TASK_LAMBDA_NAME" \
        --runtime python3.12 \
        --role "arn:aws:iam::${ACCOUNT_ID}:role/${TASK_LAMBDA_ROLE}" \
        --handler main.lambda_handler \
        --zip-file fileb://lambda.zip >/dev/null

    log_success "Created Lambda: $TASK_LAMBDA_NAME"
}

task_lambda_cleanup() {
    if [ -n "${TASK_LAMBDA_NAME:-}" ]; then
        log_info "Deleting Lambda Function: $TASK_LAMBDA_NAME..."
        aws lambda delete-function --function-name "$TASK_LAMBDA_NAME" >/dev/null
        if [ -n "${TASK_LAMBDA_ROLE:-}" ]; then
            aws iam delete-role --role-name "$TASK_LAMBDA_ROLE" >/dev/null
        fi
        log_success "Destroyed Lambda."
    fi
    rm -f trust-policy.json main.py lambda.zip
}
