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
            if [ "${FAIL_STS_IDENTITY:-0}" = "1" ]; then
                echo "Unable to locate credentials" >&2
                exit 99
            fi
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
                if [ "${FAIL_EC2_DESCRIBE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling DescribeInstances" >&2
                    exit 1
                fi
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
                if [ "${FAIL_EC2_TERMINATE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling TerminateInstances" >&2
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
                if [ "${FAIL_RDS_DELETE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling DeleteDBInstance" >&2
                    exit 1
                fi
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
                if [ "${FAIL_BUDGETS_DELETE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling DeleteBudget" >&2
                    exit 1
                fi
                exit 0
                ;;
            list-tags-for-resource)
                echo '{"ResourceTags": []}'
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
            list-attached-role-policies)
                echo '{"AttachedPolicies": []}'
                exit 0
                ;;
            detach-role-policy)
                exit 0
                ;;
            list-role-policies)
                echo '{"PolicyNames": []}'
                exit 0
                ;;
            delete-role-policy)
                exit 0
                ;;
            delete-role)
                if [ "${FAIL_IAM_DELETE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling DeleteRole" >&2
                    exit 1
                fi
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
            list-tags)
                echo '{"Tags": {}}'
                exit 0
                ;;
            delete-function)
                if [ "${FAIL_LAMBDA_DELETE:-0}" = "1" ]; then
                    echo "An error occurred (AccessDenied) when calling DeleteFunction" >&2
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

# Test 1: Standalone --sweep defaults to dry run (list only, no deletes)
echo "=== Test 1: Standalone --sweep defaults to dry run ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/sweep_dry_run.log"

EC2_HAS_LEFTOVERS=1 \
RDS_HAS_LEFTOVERS=1 \
LAMBDA_HAS_LEFTOVERS=1 \
IAM_HAS_LEFTOVERS=1 \
BUDGETS_HAS_LEFTOVERS=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --sweep > "$LOG_OUT" 2>&1

grep -q "\[DRY RUN\] Found leftover EC2 Instance: i-LEFTOVER_EC2" "$LOG_OUT" || {
    echo "FAIL: Expected dry run EC2 listing"
    cat "$LOG_OUT"
    exit 1
}
grep -q "\[DRY RUN\] Found leftover RDS Database: freetier-db-9999" "$LOG_OUT" || {
    echo "FAIL: Expected dry run RDS listing"
    cat "$LOG_OUT"
    exit 1
}
grep -q "\[DRY RUN\] Found leftover Lambda Function: freetier-func-3333" "$LOG_OUT" || {
    echo "FAIL: Expected dry run Lambda listing"
    cat "$LOG_OUT"
    exit 1
}
grep -q "\[DRY RUN\] Found leftover IAM Role: freetier-role-5555" "$LOG_OUT" || {
    echo "FAIL: Expected dry run IAM role listing"
    cat "$LOG_OUT"
    exit 1
}
grep -q "\[DRY RUN\] Found leftover Budget: freetier-budget-7777" "$LOG_OUT" || {
    echo "FAIL: Expected dry run Budget listing"
    cat "$LOG_OUT"
    exit 1
}
grep -q "To delete these resources, re-run with --confirm or --yes" "$LOG_OUT" || {
    echo "FAIL: Expected dry run confirmation instruction"
    cat "$LOG_OUT"
    exit 1
}

# Ensure NO delete commands were executed in dry run
if grep -q "terminate-instances" "$AWS_LOG"; then
    echo "FAIL: terminate-instances was executed during dry run"
    cat "$AWS_LOG"
    exit 1
fi
if grep -q "delete-db-instance" "$AWS_LOG"; then
    echo "FAIL: delete-db-instance was executed during dry run"
    cat "$AWS_LOG"
    exit 1
fi
if grep -q "delete-function" "$AWS_LOG"; then
    echo "FAIL: delete-function was executed during dry run"
    cat "$AWS_LOG"
    exit 1
fi
if grep -q "delete-role" "$AWS_LOG"; then
    echo "FAIL: delete-role was executed during dry run"
    cat "$AWS_LOG"
    exit 1
fi
if grep -q "delete-budget" "$AWS_LOG"; then
    echo "FAIL: delete-budget was executed during dry run"
    cat "$AWS_LOG"
    exit 1
fi

echo "PASS: Standalone --sweep defaulted to dry-run listing without deleting any resources."

# Test 2: Standalone --sweep --confirm deletes all leftover freetier resources (with snapshot by default)
echo "=== Test 2: Standalone --sweep --confirm sweeps freetier resources with RDS snapshot ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/sweep_confirmed.log"

EC2_HAS_LEFTOVERS=1 \
RDS_HAS_LEFTOVERS=1 \
LAMBDA_HAS_LEFTOVERS=1 \
IAM_HAS_LEFTOVERS=1 \
BUDGETS_HAS_LEFTOVERS=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --sweep --confirm > "$LOG_OUT" 2>&1

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

# Verify RDS sweep: deletes freetier-db with final snapshot by default, ignores prod db
grep -q "rds delete-db-instance --db-instance-identifier freetier-db-9999 --final-db-snapshot-identifier freetier-db-9999-final-snapshot" "$AWS_LOG" || {
    echo "FAIL: Expected rds delete-db-instance with --final-db-snapshot-identifier for freetier-db-9999"
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

echo "PASS: Standalone --sweep --confirm cleaned up leftover resources with RDS final snapshot."

# Test 3: Standalone --sweep --yes --skip-final-snapshot skips RDS final snapshot
echo "=== Test 3: Standalone --sweep with --skip-final-snapshot skips snapshot ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/sweep_skip_snapshot.log"

RDS_HAS_LEFTOVERS=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --sweep --yes --skip-final-snapshot > "$LOG_OUT" 2>&1

grep -q "rds delete-db-instance --db-instance-identifier freetier-db-9999 --skip-final-snapshot" "$AWS_LOG" || {
    echo "FAIL: Expected rds delete-db-instance with --skip-final-snapshot"
    cat "$AWS_LOG"
    exit 1
}
if grep -q "final-db-snapshot-identifier" "$AWS_LOG"; then
    echo "FAIL: Unexpected --final-db-snapshot-identifier when --skip-final-snapshot was specified"
    cat "$AWS_LOG"
    exit 1
fi

echo "PASS: Standalone sweep skipped RDS snapshot when --skip-final-snapshot was passed."

# Test 4: Standalone sweep exits non-zero when any delete fails
echo "=== Test 4: Standalone sweep exits non-zero when delete fails ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/sweep_fail.log"

set +e
EC2_HAS_LEFTOVERS=1 \
FAIL_EC2_TERMINATE=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --sweep --confirm > "$LOG_OUT" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "FAIL: Expected non-zero exit code when sweep delete fails"
    cat "$LOG_OUT"
    exit 1
fi
grep -q "Leftover sweep encountered errors deleting resources" "$LOG_OUT" || {
    echo "FAIL: Expected sweep failure message in output"
    cat "$LOG_OUT"
    exit 1
}

echo "PASS: Standalone sweep exited non-zero when delete failed."

# Test 5: Normal run cleanup touches only THIS run's resources (scoped by run id tag)
echo "=== Test 5: Normal run cleanup touches only this run's resources ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/normal_run_scoped_cleanup.log"

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

# The failed run must clean up its own IAM role
grep -q "iam delete-role --role-name" "$AWS_LOG" || {
    echo "FAIL: Expected this run's IAM role to be deleted"
    cat "$AWS_LOG"
    exit 1
}

# The failed run must NEVER delete leftover resources from other runs!
if grep -q "terminate-instances" "$AWS_LOG"; then
    echo "FAIL: Normal run terminated other run's EC2 instance!"
    cat "$AWS_LOG"
    exit 1
fi
if grep -q "delete-db-instance" "$AWS_LOG"; then
    echo "FAIL: Normal run deleted other run's RDS database freetier-db-9999!"
    cat "$AWS_LOG"
    exit 1
fi
if grep -q "delete-budget" "$AWS_LOG"; then
    echo "FAIL: Normal run deleted other run's Budget freetier-budget-7777!"
    cat "$AWS_LOG"
    exit 1
fi

echo "PASS: Normal run cleanup touched only this run's resources, never all freetier-* in account."

# Test 6: Normal run RDS deletion takes final snapshot by default and skips with --skip-final-snapshot
echo "=== Test 6: Normal run RDS deletion snapshot behavior ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/normal_rds_default_snap.log"

WAIT_SECONDS=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --only rds > "$LOG_OUT" 2>&1

if grep "rds create-db-instance" "$AWS_LOG" | grep -q -- "--skip-final-snapshot"; then
    echo "FAIL: RDS create-db-instance must not receive --skip-final-snapshot"
    cat "$AWS_LOG"
    exit 1
fi

grep -q "rds delete-db-instance --db-instance-identifier freetier-db-[0-9]* --final-db-snapshot-identifier freetier-db-[0-9]*-final-snapshot" "$AWS_LOG" || {
    echo "FAIL: Expected normal run RDS delete to take final snapshot by default"
    cat "$AWS_LOG"
    exit 1
}

: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/normal_rds_skip_snap.log"

WAIT_SECONDS=1 \
bash "${REPO_DIR}/run_and_cleanup.sh" --only rds --skip-final-snapshot > "$LOG_OUT" 2>&1

grep -q "rds delete-db-instance --db-instance-identifier freetier-db-[0-9]* --skip-final-snapshot" "$AWS_LOG" || {
    echo "FAIL: Expected normal run RDS delete to skip final snapshot when --skip-final-snapshot is passed"
    cat "$AWS_LOG"
    exit 1
}
if grep -q "final-db-snapshot-identifier" "$AWS_LOG"; then
    echo "FAIL: Unexpected final snapshot identifier when --skip-final-snapshot was passed"
    cat "$AWS_LOG"
    exit 1
fi

echo "PASS: Normal run RDS deletion takes final snapshot by default and skips with --skip-final-snapshot."

# Test 7: Runner exit during wait triggers EXIT trap cleanup
echo "=== Test 7: Runner exit during wait triggers EXIT trap cleanup ==="
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

# Test 8: PowerShell runner tests (if pwsh available)
if command -v pwsh >/dev/null 2>&1; then
    echo "=== Test 8: PowerShell runner - -Sweep dry run and confirmed ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_sweep_dry.log"

    EC2_HAS_LEFTOVERS=1 \
    RDS_HAS_LEFTOVERS=1 \
    pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Sweep > "$LOG_OUT" 2>&1

    grep -q "\[DRY RUN\] Found leftover EC2 Instance: i-LEFTOVER_EC2" "$LOG_OUT" || {
        echo "FAIL: Expected pwsh dry run EC2 listing"
        cat "$LOG_OUT"
        exit 1
    }
    if grep -q "terminate-instances" "$AWS_LOG"; then
        echo "FAIL: pwsh executed terminate-instances during dry run"
        cat "$AWS_LOG"
        exit 1
    fi

    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_sweep_confirm.log"
    EC2_HAS_LEFTOVERS=1 \
    RDS_HAS_LEFTOVERS=1 \
    pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Sweep -Confirm > "$LOG_OUT" 2>&1

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
    grep -q "rds delete-db-instance --db-instance-identifier freetier-db-9999 --final-db-snapshot-identifier freetier-db-9999-final-snapshot" "$AWS_LOG" || {
        echo "FAIL: Expected pwsh rds delete-db-instance with snapshot"
        cat "$AWS_LOG"
        exit 1
    }

    # pwsh sweep with failure exits nonzero
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_sweep_fail.log"
    set +e
    EC2_HAS_LEFTOVERS=1 \
    FAIL_EC2_TERMINATE=1 \
    pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Sweep -Confirm > "$LOG_OUT" 2>&1
    PWSH_EC=$?
    set -e
    if [ "$PWSH_EC" -eq 0 ]; then
        echo "FAIL: Expected pwsh -Sweep -Confirm to exit non-zero on delete failure"
        cat "$LOG_OUT"
        exit 1
    fi

    # A standalone confirmed sweep must reject missing AWS identity before listing resources.
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_sweep_no_identity.log"
    set +e
    FAIL_STS_IDENTITY=1 \
    pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Sweep -Confirm > "$LOG_OUT" 2>&1
    PWSH_EC=$?
    set -e
    if [ "$PWSH_EC" -eq 0 ]; then
        echo "FAIL: Expected pwsh -Sweep -Confirm to reject a missing AWS identity"
        cat "$LOG_OUT"
        exit 1
    fi
    if [ "$(wc -l < "$AWS_LOG")" -ne 1 ] || ! grep -q "sts get-caller-identity" "$AWS_LOG"; then
        echo "FAIL: Expected identity verification to stop the sweep before resource API calls"
        cat "$AWS_LOG"
        exit 1
    fi

    # Normal-run cleanup must retain sweep/list failures in its final exit status.
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_normal_sweep_fail.log"
    set +e
    WAIT_SECONDS=0 \
    FAIL_EC2_DESCRIBE=1 \
    pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" > "$LOG_OUT" 2>&1
    PWSH_EC=$?
    set -e
    if [ "$PWSH_EC" -eq 0 ]; then
        echo "FAIL: Expected normal pwsh run to exit non-zero when cleanup sweep listing fails"
        cat "$LOG_OUT"
        exit 1
    fi
    grep -q "Cleanup failed for: sweep" "$LOG_OUT" || {
        echo "FAIL: Expected normal pwsh summary to report cleanup sweep failure"
        cat "$LOG_OUT"
        exit 1
    }

    echo "PASS: PowerShell runner sweep tests passed."
fi

echo "All sweep and exit cleanup tests passed successfully!"
