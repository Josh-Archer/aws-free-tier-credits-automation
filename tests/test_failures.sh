#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_TMP="$(mktemp -d /tmp/aws-free-tier-failures-test.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

FAKE_BIN_DIR="${TEST_TMP}/bin"
mkdir -p "$FAKE_BIN_DIR"
AWS_LOG="${TEST_TMP}/aws_calls.log"
touch "$AWS_LOG"

cat << 'EOF' > "${FAKE_BIN_DIR}/aws"
#!/bin/bash
echo "$*" >> "${AWS_LOG}"

cmd="$1"
sub="${2:-}"

case "$cmd" in
    sts)
        if [ "$sub" = "get-caller-identity" ]; then
            echo '{"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/REDACTED_TEST_USER"}'
            exit 0
        fi
        ;;
    ec2)
        case "$sub" in
            describe-regions)
                echo '{"Regions": []}'
                exit 0
                ;;
            describe-images)
                if [ "${EC2_DESCRIBE_IMAGES_FAIL:-0}" = "1" ]; then
                    echo "An error occurred (AuthFailure) when calling DescribeImages" >&2
                    exit 1
                fi
                if [ "${EC2_AMI_NONE:-0}" = "1" ]; then
                    echo "None"
                    exit 0
                fi
                if [ "${EC2_AMI_EMPTY:-0}" = "1" ]; then
                    echo ""
                    exit 0
                fi
                echo "ami-REDACTED_TEST_AMI"
                exit 0
                ;;
            run-instances)
                if [ "${EC2_RUN_INSTANCES_FAIL:-0}" = "1" ]; then
                    echo "An error occurred (InstanceLimitExceeded)" >&2
                    exit 1
                fi
                echo "i-REDACTED_TEST_EC2"
                exit 0
                ;;
            terminate-instances)
                if [ "${EC2_TERMINATE_FAIL:-0}" = "1" ]; then
                    echo "An error occurred (UnauthorizedOperation) when terminating" >&2
                    exit 1
                fi
                echo '{"TerminatingInstances": []}'
                exit 0
                ;;
        esac
        ;;
    rds)
        case "$sub" in
            describe-db-instances)
                echo '{"DBInstances": []}'
                exit 0
                ;;
            create-db-instance)
                exit 0
                ;;
            delete-db-instance)
                exit 0
                ;;
        esac
        ;;
    budgets)
        case "$sub" in
            describe-budgets)
                echo '{"Budgets": []}'
                exit 0
                ;;
            create-budget)
                exit 0
                ;;
            delete-budget)
                exit 0
                ;;
        esac
        ;;
    iam)
        case "$sub" in
            create-role)
                exit 0
                ;;
            delete-role)
                exit 0
                ;;
        esac
        ;;
    lambda)
        case "$sub" in
            list-functions)
                echo '{"Functions": []}'
                exit 0
                ;;
            create-function)
                exit 0
                ;;
            delete-function)
                exit 0
                ;;
        esac
        ;;
esac

exit 0
EOF
chmod +x "${FAKE_BIN_DIR}/aws"

export PATH="${FAKE_BIN_DIR}:${PATH}"
export AWS_LOG

# Test 1: Bash runner - AMI None -> no run-instances, non-zero exit, no success message
echo "=== Test 1: Bash runner - AMI None ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_ami_none.log"

set +e
EC2_AMI_NONE=1 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only ec2 > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "FAIL: Expected non-zero exit code when AMI is None, got 0"
    cat "$LOG_OUT"
    exit 1
fi

if grep -q "ec2 run-instances" "$AWS_LOG"; then
    echo "FAIL: run-instances was called despite AMI being None"
    cat "$AWS_LOG"
    exit 1
fi

if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
    echo "FAIL: Found success message despite AMI being None"
    cat "$LOG_OUT"
    exit 1
fi

echo "PASS: Bash runner AMI None returned non-zero, did not call run-instances, and printed no success message."

# Test 2: Bash runner - Cleanup failure -> non-zero exit, no success message
echo "=== Test 2: Bash runner - Cleanup failure ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_cleanup_fail.log"

set +e
EC2_TERMINATE_FAIL=1 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only ec2 > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "FAIL: Expected non-zero exit code when cleanup failed, got 0"
    cat "$LOG_OUT"
    exit 1
fi

if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
    echo "FAIL: Found success message despite cleanup failure"
    cat "$LOG_OUT"
    exit 1
fi

grep -q "i-REDACTED_TEST_EC2" "$LOG_OUT" || {
    echo "FAIL: Expected failure summary to list EC2 instance id i-REDACTED_TEST_EC2"
    cat "$LOG_OUT"
    exit 1
}

echo "PASS: Bash runner cleanup failure returned non-zero and printed no success message."

# Test 3: PowerShell runner - AMI None -> no run-instances, non-zero exit, no success message
if command -v pwsh >/dev/null 2>&1; then
    echo "=== Test 3: PowerShell runner - AMI None ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_ami_none.log"

    set +e
    EC2_AMI_NONE=1 WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only ec2 > "$LOG_OUT" 2>&1
    EXIT_CODE=$?
    set -e

    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "FAIL: Expected non-zero exit code in pwsh when AMI is None, got 0"
        cat "$LOG_OUT"
        exit 1
    fi

    if grep -q "ec2 run-instances" "$AWS_LOG"; then
        echo "FAIL: run-instances was called in pwsh despite AMI being None"
        cat "$AWS_LOG"
        exit 1
    fi

    if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
        echo "FAIL: Found success message in pwsh despite AMI being None"
        cat "$LOG_OUT"
        exit 1
    fi

    echo "PASS: PowerShell runner AMI None returned non-zero, did not call run-instances, and printed no success message."

    # Test 4: PowerShell runner - Cleanup failure -> non-zero exit, no success message
    echo "=== Test 4: PowerShell runner - Cleanup failure ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_cleanup_fail.log"

    set +e
    EC2_TERMINATE_FAIL=1 WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only ec2 > "$LOG_OUT" 2>&1
    EXIT_CODE=$?
    set -e

    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "FAIL: Expected non-zero exit code in pwsh when cleanup failed, got 0"
        cat "$LOG_OUT"
        exit 1
    fi

    if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
        echo "FAIL: Found success message in pwsh despite cleanup failure"
        cat "$LOG_OUT"
        exit 1
    fi

    grep -q "i-REDACTED_TEST_EC2" "$LOG_OUT" || {
        echo "FAIL: Expected failure summary in pwsh to list EC2 instance id i-REDACTED_TEST_EC2"
        cat "$LOG_OUT"
        exit 1
    }

    echo "PASS: PowerShell runner cleanup failure returned non-zero and printed no success message."
fi

echo "All failure tests passed successfully!"
