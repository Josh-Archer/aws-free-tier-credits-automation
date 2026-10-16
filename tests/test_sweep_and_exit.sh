#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_TMP="$(mktemp -d /tmp/aws-free-tier-sweep-test.XXXXXX)"
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
                echo "ami-REDACTED_TEST_AMI"
                exit 0
                ;;
            run-instances)
                echo "i-REDACTED_TEST_EC2"
                exit 0
                ;;
            describe-instances)
                if [ "${EC2_HAS_LEFTOVERS:-0}" = "1" ]; then
                    cat << 'JSON'
{
    "Reservations": [
        {
            "Instances": [
                {
                    "InstanceId": "i-LEFTOVER_EC2",
                    "State": {"Name": "running"},
                    "Tags": [{"Key": "Name", "Value": "freetier-ec2-1234"}]
                },
                {
                    "InstanceId": "i-PROD_SERVER",
                    "State": {"Name": "running"},
                    "Tags": [{"Key": "Name", "Value": "production-web-server"}]
                }
            ]
        }
    ]
}
JSON
                    exit 0
                fi
                echo '{"Reservations": []}'
                exit 0
                ;;
            terminate-instances)
                echo '{"TerminatingInstances": []}'
                exit 0
                ;;
        esac
        ;;
    rds)
        case "$sub" in
            describe-db-instances)
                if [ "${RDS_HAS_LEFTOVERS:-0}" = "1" ]; then
                    cat << 'JSON'
{
    "DBInstances": [
        {
            "DBInstanceIdentifier": "freetier-db-9999",
            "DBInstanceStatus": "available"
        },
        {
            "DBInstanceIdentifier": "prod-customer-db",
            "DBInstanceStatus": "available"
        }
    ]
}
JSON
                    exit 0
                fi
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
                if [ "${BUDGETS_HAS_LEFTOVERS:-0}" = "1" ]; then
                    cat << 'JSON'
{
    "Budgets": [
        {
            "BudgetName": "freetier-budget-7777"
        },
        {
            "BudgetName": "prod-monthly-cap"
        }
    ]
}
JSON
                    exit 0
                fi
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
            list-roles)
                if [ "${IAM_HAS_LEFTOVERS:-0}" = "1" ]; then
                    cat << 'JSON'
{
    "Roles": [
        {
            "RoleName": "freetier-role-5555"
        },
        {
            "RoleName": "prod-service-role"
        }
    ]
}
JSON
                    exit 0
                fi
                echo '{"Roles": []}'
                exit 0
                ;;
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
                if [ "${LAMBDA_HAS_LEFTOVERS:-0}" = "1" ]; then
                    cat << 'JSON'
{
    "Functions": [
        {
            "FunctionName": "freetier-func-3333"
        },
        {
            "FunctionName": "prod-api-handler"
        }
    ]
}
JSON
                    exit 0
                fi
                echo '{"Functions": []}'
                exit 0
                ;;
            create-function)
                if [ "${FAIL_LAMBDA_CREATE:-0}" = "1" ]; then
                    echo "An error occurred (InvalidParameterValueException) when calling CreateFunction" >&2
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

# Test 1: Standalone --sweep terminates leftover freetier resources and ignores non-freetier resources
echo "=== Test 1: Standalone --sweep sweeps all leftover freetier resources ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/sweep_standalone.log"

EC2_HAS_LEFTOVERS=1 \
RDS_HAS_LEFTOVERS=1 \
LAMBDA_HAS_LEFTOVERS=1 \
IAM_HAS_LEFTOVERS=1 \
BUDGETS_HAS_LEFTOVERS=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --sweep > "$LOG_OUT" 2>&1

grep -q "Leftover sweep completed successfully!" "$LOG_OUT" || {
    echo "FAIL: Expected successful sweep completion message"
    cat "$LOG_OUT"
    exit 1
}

# Verify EC2 sweep: terminates freetier instance, ignores prod server
grep -q "ec2 terminate-instances --instance-ids i-LEFTOVER_EC2" "$AWS_LOG" || {
    echo "FAIL: Expected ec2 terminate-instances for i-LEFTOVER_EC2"
    cat "$AWS_LOG"
    exit 1
}
if grep -q "i-PROD_SERVER" "$AWS_LOG"; then
    echo "FAIL: Non-freetier EC2 instance i-PROD_SERVER was targeted by sweep"
    cat "$AWS_LOG"
    exit 1
fi

# Verify RDS sweep: deletes freetier-db, ignores prod db
grep -q "rds delete-db-instance --db-instance-identifier freetier-db-9999" "$AWS_LOG" || {
    echo "FAIL: Expected rds delete-db-instance for freetier-db-9999"
    cat "$AWS_LOG"
    exit 1
}
if grep -q "prod-customer-db" "$AWS_LOG"; then
    echo "FAIL: Non-freetier RDS database was targeted by sweep"
    cat "$AWS_LOG"
    exit 1
fi

# Verify Lambda sweep: deletes freetier-func, ignores prod func
grep -q "lambda delete-function --function-name freetier-func-3333" "$AWS_LOG" || {
    echo "FAIL: Expected lambda delete-function for freetier-func-3333"
    cat "$AWS_LOG"
    exit 1
}
if grep -q "prod-api-handler" "$AWS_LOG"; then
    echo "FAIL: Non-freetier Lambda function was targeted by sweep"
    cat "$AWS_LOG"
    exit 1
fi

# Verify IAM role sweep: deletes freetier-role, ignores prod role
grep -q "iam delete-role --role-name freetier-role-5555" "$AWS_LOG" || {
    echo "FAIL: Expected iam delete-role for freetier-role-5555"
    cat "$AWS_LOG"
    exit 1
}
if grep -q "prod-service-role" "$AWS_LOG"; then
    echo "FAIL: Non-freetier IAM role was targeted by sweep"
    cat "$AWS_LOG"
    exit 1
fi

# Verify Budget sweep: deletes freetier-budget, ignores prod budget
grep -q "budgets delete-budget --account-id 123456789012 --budget-name freetier-budget-7777" "$AWS_LOG" || {
    echo "FAIL: Expected budgets delete-budget for freetier-budget-7777"
    cat "$AWS_LOG"
    exit 1
}
if grep -q "prod-monthly-cap" "$AWS_LOG"; then
    echo "FAIL: Non-freetier Budget was targeted by sweep"
    cat "$AWS_LOG"
    exit 1
fi

echo "PASS: Standalone --sweep successfully cleaned up all leftover freetier resources without touching non-freetier resources."

# Test 2: Failed run sweeps leftover resources on runner exit
echo "=== Test 2: Failed run sweeps leftover resources upon exit ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/sweep_failed_run.log"

set +e
FAIL_LAMBDA_CREATE=1 \
EC2_HAS_LEFTOVERS=1 \
RDS_HAS_LEFTOVERS=1 \
BUDGETS_HAS_LEFTOVERS=1 \
LAMBDA_ROLE_WAIT=0 \
WAIT_SECONDS=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --only lambda > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "FAIL: Expected non-zero exit code when Lambda provision fails"
    cat "$LOG_OUT"
    exit 1
fi

# The failed run should have invoked the shared cleanup path, sweeping leftovers
grep -q "ec2 terminate-instances --instance-ids i-LEFTOVER_EC2" "$AWS_LOG" || {
    echo "FAIL: Expected leftover EC2 instance to be swept after failed run"
    cat "$AWS_LOG"
    exit 1
}
grep -q "rds delete-db-instance --db-instance-identifier freetier-db-9999" "$AWS_LOG" || {
    echo "FAIL: Expected leftover RDS database to be swept after failed run"
    cat "$AWS_LOG"
    exit 1
}
grep -q "budgets delete-budget --account-id 123456789012 --budget-name freetier-budget-7777" "$AWS_LOG" || {
    echo "FAIL: Expected leftover Budget to be swept after failed run"
    cat "$AWS_LOG"
    exit 1
}
echo "PASS: Failed run swept leftover freetier resources upon exit."

# Test 3: EXIT trap during wait cleans up provisioned resources
echo "=== Test 3: Runner exit during wait triggers EXIT trap cleanup ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/exit_trap_wait.log"

python3 -c "
import subprocess, time, signal, os, sys

proc = subprocess.Popen(
    ['bash', '${REPO_DIR}/run_and_cleanup.sh', '--only', 'ec2,budget'],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
    cwd='${REPO_DIR}'
)

start = time.time()
interrupted = False
while time.time() - start < 10:
    line = proc.stdout.readline()
    if not line:
        break
    if 'Waiting 3 minutes' in line:
        # Send SIGTERM instead of SIGINT to test general termination handling
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        interrupted = True
        break

rest, _ = proc.communicate(timeout=10)
with open('${LOG_OUT}', 'w') as f:
    f.write(rest)

if not interrupted:
    print('Failed to reach wait before timeout', file=sys.stderr)
    sys.exit(1)
"

grep -q "ec2 terminate-instances --instance-ids i-REDACTED_TEST_EC2" "$AWS_LOG" || {
    echo "FAIL: Expected ec2 terminate-instances after exit during wait"
    cat "$AWS_LOG"
    exit 1
}
grep -q "budgets delete-budget" "$AWS_LOG" || {
    echo "FAIL: Expected budgets delete-budget after exit during wait"
    cat "$AWS_LOG"
    exit 1
}
echo "PASS: Runner exit during wait triggered EXIT trap cleanup."

# Test 4: PowerShell runner tests (if pwsh available)
if command -v pwsh >/dev/null 2>&1; then
    echo "=== Test 4: PowerShell runner - -Sweep flag ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_sweep.log"

    EC2_HAS_LEFTOVERS=1 \
    RDS_HAS_LEFTOVERS=1 \
    LAMBDA_HAS_LEFTOVERS=1 \
    IAM_HAS_LEFTOVERS=1 \
    BUDGETS_HAS_LEFTOVERS=1 \
    pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Sweep > "$LOG_OUT" 2>&1

    grep -q "Leftover sweep completed successfully!" "$LOG_OUT" || {
        echo "FAIL: Expected pwsh sweep completion message"
        cat "$LOG_OUT"
        exit 1
    }
    grep -q "ec2 terminate-instances --instance-ids i-LEFTOVER_EC2" "$AWS_LOG" || {
        echo "FAIL: Expected pwsh ec2 terminate-instances for i-LEFTOVER_EC2"
        cat "$AWS_LOG"
        exit 1
    }
    grep -q "rds delete-db-instance --db-instance-identifier freetier-db-9999" "$AWS_LOG" || {
        echo "FAIL: Expected pwsh rds delete-db-instance for freetier-db-9999"
        cat "$AWS_LOG"
        exit 1
    }
    echo "PASS: PowerShell runner -Sweep flag passed."
fi

echo "All sweep and exit cleanup tests passed successfully!"
