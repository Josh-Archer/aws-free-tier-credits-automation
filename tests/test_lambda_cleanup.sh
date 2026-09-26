#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_TMP="$(mktemp -d /tmp/aws-free-tier-test.XXXXXX)"
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
    iam)
        case "$sub" in
            create-role)
                if [ "${FAIL_IAM_ROLE_CREATE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling the CreateRole operation" >&2
                    exit 1
                fi
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
                if [ "${FAIL_LAMBDA_CREATE:-0}" = "1" ]; then
                    echo "An error occurred (InvalidParameterValueException) when calling the CreateFunction operation" >&2
                    exit 1
                fi
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

# Test 1: Bash runner - Lambda create-function failure cleans up IAM role
echo "=== Test 1: Bash runner - Lambda create-function failure cleans up IAM role ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_lambda_fail.log"

FAIL_LAMBDA_CREATE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only lambda > "$LOG_OUT" 2>&1 || true

created_role=$(grep "iam create-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
if [ -z "$created_role" ]; then
    echo "FAIL: Expected iam create-role call in aws log"
    cat "$AWS_LOG"
    exit 1
fi

deleted_role=$(grep "iam delete-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
if [ -z "$deleted_role" ]; then
    echo "FAIL: Expected iam delete-role call in aws log after lambda create failure"
    cat "$AWS_LOG"
    exit 1
fi

if [ "$created_role" != "$deleted_role" ]; then
    echo "FAIL: Deleted role ($deleted_role) does not match created role ($created_role)"
    exit 1
fi

if grep -q "lambda delete-function" "$AWS_LOG"; then
    echo "FAIL: Unexpected lambda delete-function call for uncreated function"
    cat "$AWS_LOG"
    exit 1
fi

for f in trust-policy.json main.py lambda.zip; do
    if [ -f "${REPO_DIR}/$f" ]; then
        echo "FAIL: Residual file left behind: $f"
        exit 1
    fi
done

grep -q "Provisioning failed for task: lambda" "$LOG_OUT" || {
    echo "FAIL: Expected provisioning failure message in output"
    cat "$LOG_OUT"
    exit 1
}

echo "PASS: Bash runner cleaned up IAM role when create-function failed."

# Test 2: Bash runner - Lambda normal execution provisions and cleans up both
echo "=== Test 2: Bash runner - Lambda normal execution provisions and cleans up both ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_lambda_success.log"

FAIL_LAMBDA_CREATE=0 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only lambda > "$LOG_OUT" 2>&1

created_role=$(grep "iam create-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
created_func=$(grep "lambda create-function --function-name" "$AWS_LOG" | sed -n 's/.*--function-name \([^ ]*\).*/\1/p' | head -n1)
deleted_func=$(grep "lambda delete-function --function-name" "$AWS_LOG" | sed -n 's/.*--function-name \([^ ]*\).*/\1/p' | head -n1)
deleted_role=$(grep "iam delete-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)

if [ -z "$created_role" ] || [ -z "$created_func" ]; then
    echo "FAIL: Expected create-role and create-function in aws log"
    cat "$AWS_LOG"
    exit 1
fi

if [ "$created_func" != "$deleted_func" ]; then
    echo "FAIL: Deleted func ($deleted_func) does not match created func ($created_func)"
    exit 1
fi

if [ "$created_role" != "$deleted_role" ]; then
    echo "FAIL: Deleted role ($deleted_role) does not match created role ($created_role)"
    exit 1
fi

for f in trust-policy.json main.py lambda.zip; do
    if [ -f "${REPO_DIR}/$f" ]; then
        echo "FAIL: Residual file left behind: $f"
        exit 1
    fi
done

grep -q "Automation Finished Successfully!" "$LOG_OUT" || {
    echo "FAIL: Expected success message in output"
    cat "$LOG_OUT"
    exit 1
}

echo "PASS: Bash runner successfully provisioned and cleaned up Lambda function and IAM role."

# Test 3: PowerShell runner - Lambda create-function failure cleans up IAM role
if command -v pwsh >/dev/null 2>&1; then
    echo "=== Test 3: PowerShell runner - Lambda create-function failure cleans up IAM role ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_lambda_fail.log"

    FAIL_LAMBDA_CREATE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only lambda > "$LOG_OUT" 2>&1 || true

    created_role=$(grep "iam create-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
    if [ -z "$created_role" ]; then
        echo "FAIL: Expected iam create-role call in pwsh aws log"
        cat "$AWS_LOG"
        exit 1
    fi

    deleted_role=$(grep "iam delete-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
    if [ -z "$deleted_role" ]; then
        echo "FAIL: Expected iam delete-role call in pwsh aws log after lambda create failure"
        cat "$AWS_LOG"
        exit 1
    fi

    if [ "$created_role" != "$deleted_role" ]; then
        echo "FAIL: Deleted role ($deleted_role) does not match created role ($created_role)"
        exit 1
    fi

    if grep -q "lambda delete-function" "$AWS_LOG"; then
        echo "FAIL: Unexpected lambda delete-function call for uncreated function in pwsh"
        cat "$AWS_LOG"
        exit 1
    fi

    for f in trust-policy.json main.py lambda.zip; do
        if [ -f "${REPO_DIR}/$f" ]; then
            echo "FAIL: Residual file left behind: $f"
            exit 1
        fi
    done

    echo "PASS: PowerShell runner cleaned up IAM role when create-function failed."

    # Test 4: PowerShell runner - Lambda normal execution provisions and cleans up both
    echo "=== Test 4: PowerShell runner - Lambda normal execution provisions and cleans up both ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_lambda_success.log"

    FAIL_LAMBDA_CREATE=0 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only lambda > "$LOG_OUT" 2>&1

    created_role=$(grep "iam create-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
    created_func=$(grep "lambda create-function --function-name" "$AWS_LOG" | sed -n 's/.*--function-name \([^ ]*\).*/\1/p' | head -n1)
    deleted_func=$(grep "lambda delete-function --function-name" "$AWS_LOG" | sed -n 's/.*--function-name \([^ ]*\).*/\1/p' | head -n1)
    deleted_role=$(grep "iam delete-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)

    if [ -z "$created_role" ] || [ -z "$created_func" ]; then
        echo "FAIL: Expected create-role and create-function in pwsh aws log"
        cat "$AWS_LOG"
        exit 1
    fi

    if [ "$created_func" != "$deleted_func" ]; then
        echo "FAIL: Deleted func ($deleted_func) does not match created func ($created_func)"
        exit 1
    fi

    if [ "$created_role" != "$deleted_role" ]; then
        echo "FAIL: Deleted role ($deleted_role) does not match created role ($created_role)"
        exit 1
    fi

    for f in trust-policy.json main.py lambda.zip; do
        if [ -f "${REPO_DIR}/$f" ]; then
            echo "FAIL: Residual file left behind: $f"
            exit 1
        fi
    done

    grep -q "Automation Finished Successfully!" "$LOG_OUT" || {
        echo "FAIL: Expected success message in pwsh output"
        cat "$LOG_OUT"
        exit 1
    }

    echo "PASS: PowerShell runner successfully provisioned and cleaned up Lambda function and IAM role."
fi

# Test 5: Bash runner - Lambda IAM role creation failure
echo "=== Test 5: Bash runner - Lambda IAM role creation failure ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_iam_fail.log"

FAIL_IAM_ROLE_CREATE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only lambda > "$LOG_OUT" 2>&1 || true

if grep -q "lambda create-function" "$AWS_LOG"; then
    echo "FAIL: Unexpected lambda create-function after iam create-role failed"
    cat "$AWS_LOG"
    exit 1
fi

if grep -q "iam delete-role" "$AWS_LOG"; then
    echo "FAIL: Unexpected iam delete-role after iam create-role failed"
    cat "$AWS_LOG"
    exit 1
fi

for f in trust-policy.json main.py lambda.zip; do
    if [ -f "${REPO_DIR}/$f" ]; then
        echo "FAIL: Residual file left behind: $f"
        exit 1
    fi
done

echo "PASS: Bash runner handled failed IAM role create without leaking resources."

echo "All lambda cleanup tests passed successfully!"
