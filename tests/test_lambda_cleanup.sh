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
                if [ "${FAIL_IAM_ROLE_DELETE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling the DeleteRole operation" >&2
                    exit 1
                fi
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
                if [ "${FAIL_LAMBDA_DELETE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDeniedException) when calling the DeleteFunction operation" >&2
                    exit 1
                fi
                if [ "${RESOURCE_NOT_FOUND_LAMBDA_DELETE:-0}" = "1" ]; then
                    echo "An error occurred (ResourceNotFoundException) when calling the DeleteFunction operation: Function not found" >&2
                    exit 1
                fi
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

# Test 6: Bash runner - delete-function returning non-not-found error -> non-zero exit + failure summary
echo "=== Test 6: Bash runner - delete-function returning non-not-found error ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_lambda_del_fail.log"

set +e
FAIL_LAMBDA_DELETE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only lambda > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "FAIL: Expected non-zero exit code when lambda delete-function failed, got 0"
    cat "$LOG_OUT"
    exit 1
fi

if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
    echo "FAIL: Found success message despite delete-function failure"
    cat "$LOG_OUT"
    exit 1
fi

grep -q "Cleanup failed for task(s) (resources may still exist): lambda" "$LOG_OUT" || {
    echo "FAIL: Expected cleanup failure message for lambda in output"
    cat "$LOG_OUT"
    exit 1
}

created_func=$(grep "lambda create-function --function-name" "$AWS_LOG" | sed -n 's/.*--function-name \([^ ]*\).*/\1/p' | head -n1)
grep -q -- "- Lambda (Function: ${created_func})" "$LOG_OUT" || {
    echo "FAIL: Expected failure summary to list leftover function $created_func"
    cat "$LOG_OUT"
    exit 1
}

grep -q "iam delete-role --role-name" "$AWS_LOG" || {
    echo "FAIL: Expected IAM delete-role to still be called despite delete-function failure"
    cat "$AWS_LOG"
    exit 1
}

for f in trust-policy.json main.py lambda.zip; do
    if [ -f "${REPO_DIR}/$f" ]; then
        echo "FAIL: Residual file left behind: $f"
        exit 1
    fi
done

echo "PASS: Bash runner delete-function non-not-found failure returned non-zero with failure summary."

# Test 7: Bash runner - delete-function returning ResourceNotFoundException during cleanup -> tolerated
echo "=== Test 7: Bash runner - delete-function returning ResourceNotFoundException ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_lambda_not_found.log"

set +e
RESOURCE_NOT_FOUND_LAMBDA_DELETE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only lambda > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "FAIL: Expected exit code 0 when ResourceNotFoundException is returned, got $EXIT_CODE"
    cat "$LOG_OUT"
    exit 1
fi

if ! grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
    echo "FAIL: Expected success message when ResourceNotFoundException is tolerated"
    cat "$LOG_OUT"
    exit 1
fi

if grep -q "Cleanup failed" "$LOG_OUT"; then
    echo "FAIL: Found unexpected cleanup failure message in output"
    cat "$LOG_OUT"
    exit 1
fi

grep -q "lambda delete-function --function-name" "$AWS_LOG" || {
    echo "FAIL: Expected delete-function to be called"
    cat "$AWS_LOG"
    exit 1
}

grep -q "iam delete-role --role-name" "$AWS_LOG" || {
    echo "FAIL: Expected delete-role to be called"
    cat "$AWS_LOG"
    exit 1
}

for f in trust-policy.json main.py lambda.zip; do
    if [ -f "${REPO_DIR}/$f" ]; then
        echo "FAIL: Residual file left behind: $f"
        exit 1
    fi
done

echo "PASS: Bash runner delete-function ResourceNotFoundException was tolerated."

# Test 8: Bash runner - IAM delete-role failing after a create-function failure -> listed as leftover + non-zero exit
echo "=== Test 8: Bash runner - IAM delete-role failing after create-function failure ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_role_fail_after_create_fail.log"

set +e
FAIL_LAMBDA_CREATE=1 FAIL_IAM_ROLE_DELETE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only lambda > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "FAIL: Expected non-zero exit code when IAM delete-role failed after create failure, got 0"
    cat "$LOG_OUT"
    exit 1
fi

if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
    echo "FAIL: Found success message despite cleanup failure"
    cat "$LOG_OUT"
    exit 1
fi

grep -q "Provisioning failed for task(s): lambda" "$LOG_OUT" || {
    echo "FAIL: Expected provisioning failure message in output"
    cat "$LOG_OUT"
    exit 1
}

grep -q "Cleanup failed for task(s) (resources may still exist): lambda" "$LOG_OUT" || {
    echo "FAIL: Expected cleanup failure message for lambda in output"
    cat "$LOG_OUT"
    exit 1
}

created_role=$(grep "iam create-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
grep -q -- "- Lambda (Role: ${created_role})" "$LOG_OUT" || {
    echo "FAIL: Expected failure summary to list leftover role $created_role"
    cat "$LOG_OUT"
    exit 1
}

for f in trust-policy.json main.py lambda.zip; do
    if [ -f "${REPO_DIR}/$f" ]; then
        echo "FAIL: Residual file left behind: $f"
        exit 1
    fi
done

echo "PASS: Bash runner IAM delete-role failure after create failure was listed as leftover."

# PowerShell runner tests (Tests 9, 10, 11)
if command -v pwsh >/dev/null 2>&1; then
    # Test 9: PowerShell runner - delete-function non-not-found error -> non-zero exit + failure summary
    echo "=== Test 9: PowerShell runner - delete-function returning non-not-found error ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_lambda_del_fail.log"

    set +e
    FAIL_LAMBDA_DELETE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only lambda > "$LOG_OUT" 2>&1
    EXIT_CODE=$?
    set -e

    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "FAIL: Expected non-zero exit code in pwsh when lambda delete-function failed, got 0"
        cat "$LOG_OUT"
        exit 1
    fi

    if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
        echo "FAIL: Found success message in pwsh despite delete-function failure"
        cat "$LOG_OUT"
        exit 1
    fi

    grep -q "Cleanup failed for: lambda" "$LOG_OUT" || {
        echo "FAIL: Expected cleanup failure message for lambda in pwsh output"
        cat "$LOG_OUT"
        exit 1
    }

    created_func=$(grep "lambda create-function --function-name" "$AWS_LOG" | sed -n 's/.*--function-name \([^ ]*\).*/\1/p' | head -n1)
    grep -q -- "LambdaName: ${created_func}" "$LOG_OUT" || {
        echo "FAIL: Expected pwsh failure summary to list leftover function $created_func"
        cat "$LOG_OUT"
        exit 1
    }

    grep -q "iam delete-role --role-name" "$AWS_LOG" || {
        echo "FAIL: Expected IAM delete-role to still be called in pwsh despite delete-function failure"
        cat "$AWS_LOG"
        exit 1
    }

    for f in trust-policy.json main.py lambda.zip; do
        if [ -f "${REPO_DIR}/$f" ]; then
            echo "FAIL: Residual file left behind: $f"
            exit 1
        fi
    done

    echo "PASS: PowerShell runner delete-function non-not-found failure returned non-zero with failure summary."

    # Test 10: PowerShell runner - delete-function returning ResourceNotFoundException during cleanup -> tolerated
    echo "=== Test 10: PowerShell runner - delete-function returning ResourceNotFoundException ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_lambda_not_found.log"

    set +e
    RESOURCE_NOT_FOUND_LAMBDA_DELETE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only lambda > "$LOG_OUT" 2>&1
    EXIT_CODE=$?
    set -e

    if [ "$EXIT_CODE" -ne 0 ]; then
        echo "FAIL: Expected exit code 0 in pwsh when ResourceNotFoundException is returned, got $EXIT_CODE"
        cat "$LOG_OUT"
        exit 1
    fi

    if ! grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
        echo "FAIL: Expected success message in pwsh when ResourceNotFoundException is tolerated"
        cat "$LOG_OUT"
        exit 1
    fi

    if grep -q "Cleanup failed" "$LOG_OUT"; then
        echo "FAIL: Found unexpected cleanup failure message in pwsh output"
        cat "$LOG_OUT"
        exit 1
    fi

    grep -q "lambda delete-function --function-name" "$AWS_LOG" || {
        echo "FAIL: Expected delete-function to be called in pwsh"
        cat "$AWS_LOG"
        exit 1
    }

    grep -q "iam delete-role --role-name" "$AWS_LOG" || {
        echo "FAIL: Expected delete-role to be called in pwsh"
        cat "$AWS_LOG"
        exit 1
    }

    for f in trust-policy.json main.py lambda.zip; do
        if [ -f "${REPO_DIR}/$f" ]; then
            echo "FAIL: Residual file left behind: $f"
            exit 1
        fi
    done

    echo "PASS: PowerShell runner delete-function ResourceNotFoundException was tolerated."

    # Test 11: PowerShell runner - IAM delete-role failing after a create-function failure -> listed as leftover + non-zero exit
    echo "=== Test 11: PowerShell runner - IAM delete-role failing after create-function failure ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_role_fail_after_create_fail.log"

    set +e
    FAIL_LAMBDA_CREATE=1 FAIL_IAM_ROLE_DELETE=1 LAMBDA_ROLE_WAIT=0 WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only lambda > "$LOG_OUT" 2>&1
    EXIT_CODE=$?
    set -e

    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "FAIL: Expected non-zero exit code in pwsh when IAM delete-role failed after create failure, got 0"
        cat "$LOG_OUT"
        exit 1
    fi

    if grep -q "Automation Finished Successfully!" "$LOG_OUT"; then
        echo "FAIL: Found success message in pwsh despite cleanup failure"
        cat "$LOG_OUT"
        exit 1
    fi

    grep -q "Provisioning failed for: lambda" "$LOG_OUT" || {
        echo "FAIL: Expected provisioning failure message in pwsh output"
        cat "$LOG_OUT"
        exit 1
    }

    grep -q "Cleanup failed for: lambda" "$LOG_OUT" || {
        echo "FAIL: Expected cleanup failure message for lambda in pwsh output"
        cat "$LOG_OUT"
        exit 1
    }

    created_role=$(grep "iam create-role --role-name" "$AWS_LOG" | sed -n 's/.*--role-name \([^ ]*\).*/\1/p' | head -n1)
    grep -q -- "LambdaRoleName: ${created_role}" "$LOG_OUT" || {
        echo "FAIL: Expected pwsh failure summary to list leftover role $created_role"
        cat "$LOG_OUT"
        exit 1
    }

    for f in trust-policy.json main.py lambda.zip; do
        if [ -f "${REPO_DIR}/$f" ]; then
            echo "FAIL: Residual file left behind: $f"
            exit 1
        fi
    done

    echo "PASS: PowerShell runner IAM delete-role failure after create failure was listed as leftover."
fi

echo "All lambda cleanup tests passed successfully!"
