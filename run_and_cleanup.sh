#!/bin/bash

# --- DEFAULTS ---
ENABLE_EC2=true
ENABLE_RDS=true
ENABLE_LAMBDA=true
ENABLE_BUDGET=true
AUTO_CHECK=false
WAIT_MINUTES=10
POLL_READY=false
MAX_POLL_MINUTES=20

# --- USAGE ---
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --skip-ec2              Skip EC2 instance creation"
    echo "  --skip-rds              Skip RDS database creation"
    echo "  --skip-lambda           Skip Lambda function creation"
    echo "  --skip-budget           Skip Budget creation"
    echo "  --wait-minutes N        Minutes to wait for billing registration before cleanup (default: 10)"
    echo "  --poll-ready            Poll EC2/RDS until ready (bounded backoff) before the billing wait"
    echo "  --max-poll-minutes N    Max minutes for readiness polling when --poll-ready is set (default: 20)"
    echo "  --auto-check            Display info about AWS credit checking limitations"
    echo "  --help                  Display this help message"
    echo ""
    echo "Recommended: wait 10–15 minutes after provisioning. Credits can take 24–48 hours to appear."
    exit 1
}

# --- ARGUMENT PARSING ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-ec2) ENABLE_EC2=false ;;
        --skip-rds) ENABLE_RDS=false ;;
        --skip-lambda) ENABLE_LAMBDA=false ;;
        --skip-budget) ENABLE_BUDGET=false ;;
        --wait-minutes)
            WAIT_MINUTES="$2"
            shift
            ;;
        --poll-ready) POLL_READY=true ;;
        --max-poll-minutes)
            MAX_POLL_MINUTES="$2"
            shift
            ;;
        --auto-check) AUTO_CHECK=true ;;
        --help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate numeric options
if ! [[ "$WAIT_MINUTES" =~ ^[0-9]+$ ]] || [ "$WAIT_MINUTES" -lt 1 ] || [ "$WAIT_MINUTES" -gt 180 ]; then
    echo "Error: --wait-minutes must be an integer between 1 and 180."
    exit 1
fi
if ! [[ "$MAX_POLL_MINUTES" =~ ^[0-9]+$ ]] || [ "$MAX_POLL_MINUTES" -lt 1 ] || [ "$MAX_POLL_MINUTES" -gt 120 ]; then
    echo "Error: --max-poll-minutes must be an integer between 1 and 120."
    exit 1
fi

# --- UTILS ---
log_info() { echo -e "\033[0;36m$1\033[0m"; }
log_success() { echo -e "\033[0;32m$1\033[0m"; }
log_warn() { echo -e "\033[0;33m$1\033[0m"; }
log_error() { echo -e "\033[0;31m$1\033[0m"; }

if [ "$AUTO_CHECK" = true ]; then
    echo "======================================================="
    log_warn "AUTO-CHECK LIMITATION"
    echo "======================================================="
    echo "AWS does not provide a public API or CLI command to retrieve your Promotional Credit balance."
    echo "Please use the AWS Billing Console to verify your credits and use the --skip flags to skip the ones you already have."
    echo "======================================================="
    exit 0
fi

# --- IDENTITY CHECK ---
log_info "Verifying AWS CLI Identity..."
IDENTITY=$(aws sts get-caller-identity --query "{Account:Account, Arn:Arn}" --output json 2>/dev/null)
if [ $? -ne 0 ]; then
    log_error "Error: Unable to verify AWS identity. Please run 'aws configure' first."
    exit 1
fi

ACCOUNT_ID=$(echo $IDENTITY | grep -oP '(?<="Account": ")[^"]*')
USER_ARN=$(echo $IDENTITY | grep -oP '(?<="Arn": ")[^"]*')

echo "Account: $ACCOUNT_ID"
echo "User Arn: $USER_ARN"

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
        ((FAILED_CHECKS++))
    fi
}

[ "$ENABLE_EC2" = true ] && check_perm "EC2" "aws ec2 describe-regions --max-items 1"
[ "$ENABLE_RDS" = true ] && check_perm "RDS" "aws rds describe-db-instances --max-items 1"
[ "$ENABLE_LAMBDA" = true ] && check_perm "Lambda" "aws lambda list-functions --max-items 1"
[ "$ENABLE_BUDGET" = true ] && check_perm "Budget" "aws budgets describe-budgets --account-id $ACCOUNT_ID --max-items 1"

if [ $FAILED_CHECKS -gt 0 ]; then
    log_warn "\nWarning: $FAILED_CHECKS permission check(s) failed. If you proceed, the script will likely fail to create resources."
fi

log_info "\nStarting AWS Free Tier Credit Automation..."
echo "Enabled Tasks: EC2=$ENABLE_EC2, RDS=$ENABLE_RDS, Lambda=$ENABLE_LAMBDA, Budget=$ENABLE_BUDGET"
echo "Wait: ${WAIT_MINUTES}m | PollReady=$POLL_READY | MaxPollMinutes=$MAX_POLL_MINUTES"

INSTANCE_ID=""
RDS_ID=""
LAMBDA_ROLE=""
LAMBDA_NAME=""
BUDGET_NAME=""

# --- PROVISIONING ---
log_info "\n=== PROVISIONING RESOURCES ==="

if [ "$ENABLE_EC2" = true ]; then
    log_info "Fetching latest Amazon Linux 2 AMI..."
    AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
    log_info "Launching EC2 instance (t2.micro) with AMI $AMI..."
    INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI --instance-type t2.micro --query "Instances[0].InstanceId" --output text)
    log_success "Created EC2 Instance: $INSTANCE_ID"
fi

if [ "$ENABLE_RDS" = true ]; then
    log_info "Creating RDS Database (db.t3.micro MySQL)..."
    RDS_ID="freetier-db-$RANDOM"
    aws rds create-db-instance --db-instance-identifier $RDS_ID --allocated-storage 20 --engine mysql --engine-version 8.0 --instance-class db.t3.micro --master-username admin --master-user-password "FreeTierPassword123!" --no-publicly-accessible --skip-final-snapshot >/dev/null
    log_success "Created RDS Database: $RDS_ID"
fi

if [ "$ENABLE_LAMBDA" = true ]; then
    log_info "Creating Lambda Role and Function..."
    ROLE_NAME="freetier-role-$RANDOM"
    LAMBDA_NAME="freetier-func-$RANDOM"
    
    TRUST_POLICY='{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    echo "$TRUST_POLICY" > trust-policy.json
    aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json >/dev/null
    
    # Wait for role to propagate
    sleep 10
    
    echo "def lambda_handler(event, context): return 'Hello Free Tier'" > main.py
    zip -q lambda.zip main.py
    
    aws lambda create-function --function-name $LAMBDA_NAME --runtime python3.12 --role arn:aws:iam::${ACCOUNT_ID}:role/$ROLE_NAME --handler main.lambda_handler --zip-file fileb://lambda.zip >/dev/null
    
    LAMBDA_ROLE=$ROLE_NAME
    log_success "Created Lambda: $LAMBDA_NAME"
fi

if [ "$ENABLE_BUDGET" = true ]; then
    log_info "Creating AWS Budget..."
    BUDGET_NAME="freetier-budget-$RANDOM"
    BUDGET_DEF="{\"BudgetName\":\"$BUDGET_NAME\",\"BudgetLimit\":{\"Amount\":\"10\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}"
    aws budgets create-budget --account-id $ACCOUNT_ID --budget "$BUDGET_DEF" --notifications-with-subscribers "[]" >/dev/null
    log_success "Created Budget: $BUDGET_NAME"
fi

# --- OPTIONAL READINESS POLL (bounded exponential backoff) ---
wait_with_backoff() {
    local label=$1
    local check_cmd=$2
    local max_seconds=$3
    local delay=15
    local elapsed=0
    local max_delay=120

    log_info "  Polling $label (max ${max_seconds}s, backoff ${delay}s..${max_delay}s)..."
    while [ "$elapsed" -lt "$max_seconds" ]; do
        if eval "$check_cmd" >/dev/null 2>&1; then
            log_success "  [OK] $label ready after ~${elapsed}s"
            return 0
        fi
        local sleep_for=$delay
        local remaining=$((max_seconds - elapsed))
        if [ "$sleep_for" -gt "$remaining" ]; then
            sleep_for=$remaining
        fi
        if [ "$sleep_for" -le 0 ]; then
            break
        fi
        log_warn "    $label not ready yet; sleeping ${sleep_for}s (elapsed ${elapsed}s)..."
        sleep "$sleep_for"
        elapsed=$((elapsed + sleep_for))
        delay=$((delay * 2))
        if [ "$delay" -gt "$max_delay" ]; then
            delay=$max_delay
        fi
    done
    log_warn "  [WARN] $label not ready within ${max_seconds}s; continuing to billing wait/cleanup."
    return 1
}

if [ "$POLL_READY" = true ]; then
    log_info "\n=== POLLING RESOURCE READINESS ==="
    MAX_POLL_SECONDS=$((MAX_POLL_MINUTES * 60))

    if [ -n "$INSTANCE_ID" ]; then
        wait_with_backoff "EC2 $INSTANCE_ID" \
            "[ \"\$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)\" = \"running\" ]" \
            "$MAX_POLL_SECONDS" || true
    fi

    if [ -n "$RDS_ID" ]; then
        wait_with_backoff "RDS $RDS_ID" \
            "[ \"\$(aws rds describe-db-instances --db-instance-identifier $RDS_ID --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)\" = \"available\" ]" \
            "$MAX_POLL_SECONDS" || true
    fi

    if [ -z "$INSTANCE_ID" ] && [ -z "$RDS_ID" ]; then
        log_warn "  No EC2/RDS resources to poll; skipping readiness wait."
    fi
fi

# --- BILLING REGISTRATION WAIT ---
WAIT_SECONDS=$((WAIT_MINUTES * 60))
echo -e "\n======================================================="
log_warn "Provisioning phase complete!"
log_warn "Waiting $WAIT_MINUTES minute(s) for AWS billing to register activity..."
log_warn "Note: Promotional credits can take 24-48 hours to appear in Billing."
echo "======================================================="
sleep "$WAIT_SECONDS"
log_warn "Billing registration wait finished."

# --- CLEANUP ---
log_info "\n=== CLEANING UP RESOURCES ==="

if [ -n "$INSTANCE_ID" ]; then
    log_info "Terminating EC2 Instance: $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID >/dev/null
    log_success "Destroyed EC2."
fi

if [ -n "$RDS_ID" ]; then
    log_info "Deleting RDS Database: $RDS_ID..."
    aws rds delete-db-instance --db-instance-identifier $RDS_ID --skip-final-snapshot >/dev/null
    log_success "Destroyed RDS."
fi

if [ -n "$LAMBDA_NAME" ]; then
    log_info "Deleting Lambda Function: $LAMBDA_NAME..."
    aws lambda delete-function --function-name $LAMBDA_NAME >/dev/null
    aws iam delete-role --role-name $LAMBDA_ROLE >/dev/null
    log_success "Destroyed Lambda."
fi

if [ -n "$BUDGET_NAME" ]; then
    log_info "Deleting Budget: $BUDGET_NAME..."
    aws budgets delete-budget --account-id $ACCOUNT_ID --budget-name $BUDGET_NAME >/dev/null
    log_success "Destroyed Budget."
fi

# Cleanup temp files
rm -f trust-policy.json main.py lambda.zip config.txt profiles.txt

log_success "\nAutomation Finished Successfully!"
log_warn "Remember: credits may take 24-48 hours to show in the Billing Dashboard."
