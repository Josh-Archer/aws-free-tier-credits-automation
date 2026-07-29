#!/bin/bash

# --- DEFAULTS ---
ENABLE_EC2=true
ENABLE_RDS=true
ENABLE_LAMBDA=true
ENABLE_BUDGET=true
AUTO_CHECK=false

# Track each resource as soon as create succeeds so partial runs still clean up.
INSTANCE_ID=""
RDS_ID=""
LAMBDA_ROLE=""
LAMBDA_NAME=""
BUDGET_NAME=""
ACCOUNT_ID=""
SCRIPT_FAILED=0
CLEANUP_RAN=0

# --- USAGE ---
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --skip-ec2      Skip EC2 instance creation"
    echo "  --skip-rds      Skip RDS database creation"
    echo "  --skip-lambda   Skip Lambda function creation"
    echo "  --skip-budget   Skip Budget creation"
    echo "  --auto-check    Display info about AWS credit checking limitations"
    echo "  --help          Display this help message"
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

if [ "$AUTO_CHECK" = true ]; then
    echo "======================================================="
    log_warn "AUTO-CHECK LIMITATION"
    echo "======================================================="
    echo "AWS does not provide a public API or CLI command to retrieve your Promotional Credit balance."
    echo "Please use the AWS Billing Console to verify your credits and use the --skip flags to skip the ones you already have."
    echo "======================================================="
    exit 0
fi

print_remaining_resources() {
    local remaining=0
    if [ -n "$INSTANCE_ID" ]; then
        log_error "  - EC2 InstanceId: $INSTANCE_ID"
        remaining=1
    fi
    if [ -n "$RDS_ID" ]; then
        log_error "  - RDS DB Identifier: $RDS_ID"
        remaining=1
    fi
    if [ -n "$LAMBDA_NAME" ]; then
        log_error "  - Lambda Function: $LAMBDA_NAME"
        remaining=1
    fi
    if [ -n "$LAMBDA_ROLE" ]; then
        log_error "  - IAM Role: $LAMBDA_ROLE"
        remaining=1
    fi
    if [ -n "$BUDGET_NAME" ]; then
        log_error "  - Budget Name: $BUDGET_NAME"
        remaining=1
    fi
    return $remaining
}

cleanup() {
    # Prevent double-run if EXIT fires after explicit call
    if [ "$CLEANUP_RAN" -eq 1 ]; then
        return 0
    fi
    CLEANUP_RAN=1

    log_info "\n=== CLEANING UP RESOURCES ==="
    local cleanup_failed=0

    if [ -n "$INSTANCE_ID" ]; then
        log_info "Terminating EC2 Instance: $INSTANCE_ID..."
        if aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null; then
            log_success "Destroyed EC2."
            INSTANCE_ID=""
        else
            log_error "Failed to terminate EC2: $INSTANCE_ID"
            cleanup_failed=1
        fi
    fi

    if [ -n "$RDS_ID" ]; then
        log_info "Deleting RDS Database: $RDS_ID..."
        if aws rds delete-db-instance --db-instance-identifier "$RDS_ID" --skip-final-snapshot >/dev/null; then
            log_success "Destroyed RDS."
            RDS_ID=""
        else
            log_error "Failed to delete RDS: $RDS_ID"
            cleanup_failed=1
        fi
    fi

    if [ -n "$LAMBDA_NAME" ]; then
        log_info "Deleting Lambda Function: $LAMBDA_NAME..."
        if aws lambda delete-function --function-name "$LAMBDA_NAME" >/dev/null; then
            log_success "Destroyed Lambda function."
            LAMBDA_NAME=""
        else
            log_error "Failed to delete Lambda: $LAMBDA_NAME"
            cleanup_failed=1
        fi
    fi

    if [ -n "$LAMBDA_ROLE" ]; then
        log_info "Deleting IAM Role: $LAMBDA_ROLE..."
        if aws iam delete-role --role-name "$LAMBDA_ROLE" >/dev/null; then
            log_success "Destroyed IAM role."
            LAMBDA_ROLE=""
        else
            log_error "Failed to delete IAM role: $LAMBDA_ROLE"
            cleanup_failed=1
        fi
    fi

    if [ -n "$BUDGET_NAME" ]; then
        log_info "Deleting Budget: $BUDGET_NAME..."
        if aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" >/dev/null; then
            log_success "Destroyed Budget."
            BUDGET_NAME=""
        else
            log_error "Failed to delete Budget: $BUDGET_NAME"
            cleanup_failed=1
        fi
    fi

    # Cleanup temp files
    rm -f trust-policy.json main.py lambda.zip config.txt profiles.txt

    local has_remaining=0
    if [ -n "$INSTANCE_ID" ] || [ -n "$RDS_ID" ] || [ -n "$LAMBDA_NAME" ] || [ -n "$LAMBDA_ROLE" ] || [ -n "$BUDGET_NAME" ]; then
        has_remaining=1
        echo ""
        log_error "======================================================="
        log_error "CLEANUP INCOMPLETE - manually delete remaining resources:"
        log_error "======================================================="
        print_remaining_resources
        log_error "======================================================="
    fi

    if [ "$has_remaining" -eq 1 ] || [ "$cleanup_failed" -eq 1 ]; then
        return 2
    fi

    log_success "Cleanup completed; no tracked resources remain."
    return 0
}

on_exit() {
    local exit_code=$?
    # Always attempt cleanup on any exit path (error, interrupt, or normal).
    cleanup
    local cleanup_rc=$?

    if [ "$cleanup_rc" -ne 0 ]; then
        log_error "\nAutomation finished with CLEANUP FAILURES. Review remaining resources above."
        # Prefer cleanup failure code if cleanup failed
        exit 2
    fi

    if [ "$SCRIPT_FAILED" -ne 0 ] || [ "$exit_code" -ne 0 ]; then
        log_warn "\nAutomation finished with provisioning errors, but cleanup reported no remaining tracked resources."
        if [ "$exit_code" -ne 0 ]; then
            exit "$exit_code"
        fi
        exit 1
    fi

    log_success "\nAutomation Finished Successfully!"
    exit 0
}

# Always attempt cleanup (normal exit, error, Ctrl+C, kill).
trap on_exit EXIT
trap 'SCRIPT_FAILED=1; exit 130' INT
trap 'SCRIPT_FAILED=1; exit 143' TERM

# --- IDENTITY CHECK ---
log_info "Verifying AWS CLI Identity..."
IDENTITY=$(aws sts get-caller-identity --query "{Account:Account, Arn:Arn}" --output json 2>/dev/null)
if [ $? -ne 0 ]; then
    log_error "Error: Unable to verify AWS identity. Please run 'aws configure' first."
    # Disable trap cleanup when nothing was created; exit before trap would claim success falsely
    trap - EXIT INT TERM
    exit 1
fi

ACCOUNT_ID=$(echo "$IDENTITY" | grep -oP '(?<="Account": ")[^"]*')
USER_ARN=$(echo "$IDENTITY" | grep -oP '(?<="Arn": ")[^"]*')

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

# --- PROVISIONING ---
log_info "\n=== PROVISIONING RESOURCES ==="

if [ "$ENABLE_EC2" = true ]; then
    log_info "Fetching latest Amazon Linux 2 AMI..."
    AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
    if [ $? -ne 0 ] || [ -z "$AMI" ] || [ "$AMI" = "None" ]; then
        log_error "Failed to resolve Amazon Linux 2 AMI."
        SCRIPT_FAILED=1
    else
        log_info "Launching EC2 instance (t2.micro) with AMI $AMI..."
        INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t2.micro --query "Instances[0].InstanceId" --output text)
        if [ $? -ne 0 ] || [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
            log_error "Failed to create EC2 instance."
            INSTANCE_ID=""
            SCRIPT_FAILED=1
        else
            # Tracked immediately for trap-based cleanup.
            log_success "Created EC2 Instance: $INSTANCE_ID"
        fi
    fi
fi

if [ "$ENABLE_RDS" = true ]; then
    log_info "Creating RDS Database (db.t3.micro MySQL)..."
    RDS_ID="freetier-db-$RANDOM"
    if aws rds create-db-instance --db-instance-identifier "$RDS_ID" --allocated-storage 20 --engine mysql --engine-version 8.0 --instance-class db.t3.micro --master-username admin --master-user-password "FreeTierPassword123!" --no-publicly-accessible --skip-final-snapshot >/dev/null; then
        log_success "Created RDS Database: $RDS_ID"
    else
        log_error "Failed to create RDS database: $RDS_ID"
        RDS_ID=""
        SCRIPT_FAILED=1
    fi
fi

if [ "$ENABLE_LAMBDA" = true ]; then
    log_info "Creating Lambda Role and Function..."
    ROLE_NAME="freetier-role-$RANDOM"
    FUNC_NAME="freetier-func-$RANDOM"

    TRUST_POLICY='{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    echo "$TRUST_POLICY" > trust-policy.json

    if aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://trust-policy.json >/dev/null; then
        # Track role immediately (function create can still fail).
        LAMBDA_ROLE=$ROLE_NAME
        log_success "Created IAM Role: $LAMBDA_ROLE"

        # Wait for role to propagate
        sleep 10

        echo "def lambda_handler(event, context): return 'Hello Free Tier'" > main.py
        zip -q lambda.zip main.py

        if aws lambda create-function --function-name "$FUNC_NAME" --runtime python3.12 --role "arn:aws:iam::${ACCOUNT_ID}:role/$ROLE_NAME" --handler main.lambda_handler --zip-file fileb://lambda.zip >/dev/null; then
            LAMBDA_NAME=$FUNC_NAME
            log_success "Created Lambda: $LAMBDA_NAME"
        else
            log_error "Failed to create Lambda function: $FUNC_NAME"
            SCRIPT_FAILED=1
        fi
    else
        log_error "Failed to create IAM role: $ROLE_NAME"
        SCRIPT_FAILED=1
    fi
fi

if [ "$ENABLE_BUDGET" = true ]; then
    log_info "Creating AWS Budget..."
    BUDGET_NAME="freetier-budget-$RANDOM"
    BUDGET_DEF="{\"BudgetName\":\"$BUDGET_NAME\",\"BudgetLimit\":{\"Amount\":\"10\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}"
    if aws budgets create-budget --account-id "$ACCOUNT_ID" --budget "$BUDGET_DEF" --notifications-with-subscribers "[]" >/dev/null; then
        log_success "Created Budget: $BUDGET_NAME"
    else
        log_error "Failed to create Budget: $BUDGET_NAME"
        BUDGET_NAME=""
        SCRIPT_FAILED=1
    fi
fi

# --- WAITING ---
echo -e "\n======================================================="
log_warn "Provisioning phase complete!"
log_warn "Waiting 3 minutes for AWS to register the activity..."
sleep 180
echo "======================================================="

# Normal path: EXIT trap runs cleanup and sets final exit code.
exit 0
