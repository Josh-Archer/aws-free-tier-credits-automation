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

cat << EOF > "${FAKE_BIN_DIR}/aws"
#!/bin/bash
echo "\$*" >> "${AWS_LOG}"

cmd="\$1"
sub="\${2:-}"

case "\$cmd" in
    sts)
        if [ "\$sub" = "get-caller-identity" ]; then
            echo '{"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/REDACTED_TEST_USER"}'
            exit 0
        fi
        ;;
    ec2)
        case "\$sub" in
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
            terminate-instances)
                echo '{"TerminatingInstances": []}'
                exit 0
                ;;
        esac
        ;;
    rds)
        case "\$sub" in
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
        case "\$sub" in
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
        case "\$sub" in
            create-role)
                exit 0
                ;;
            delete-role)
                exit 0
                ;;
        esac
        ;;
    lambda)
        case "\$sub" in
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

# Test 1: Bash runner interrupted during wait
echo "=== Test 1: Bash runner interrupted during wait ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_interrupt.log"

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

# Wait until 'Waiting 3 minutes' appears in output
output = []
interrupted = False
start_time = time.time()
while time.time() - start_time < 10:
    line = proc.stdout.readline()
    if not line:
        break
    output.append(line)
    if 'Waiting 3 minutes' in line:
        os.killpg(os.getpgid(proc.pid), signal.SIGINT)
        interrupted = True
        break

rest_out, _ = proc.communicate(timeout=10)
output.append(rest_out)
full_output = ''.join(output)
with open('${LOG_OUT}', 'w') as f:
    f.write(full_output)

if not interrupted:
    print('Error: Failed to reach waiting state before interrupt', file=sys.stderr)
    sys.exit(1)

if proc.returncode != 130:
    print(f'Error: Expected exit code 130, got {proc.returncode}', file=sys.stderr)
    sys.exit(1)
"

# Assert bash output and cleanup calls
grep -q "Interrupted during wait. Cleaning up provisioned resources..." "$LOG_OUT" || {
    echo "FAIL: Expected interrupt warning message in output"
    cat "$LOG_OUT"
    exit 1
}
grep -q "ec2 terminate-instances --instance-ids i-REDACTED_TEST_EC2" "$AWS_LOG" || {
    echo "FAIL: Expected ec2 terminate-instances call in aws log"
    cat "$AWS_LOG"
    exit 1
}
grep -q "budgets delete-budget" "$AWS_LOG" || {
    echo "FAIL: Expected budgets delete-budget call in aws log"
    cat "$AWS_LOG"
    exit 1
}
echo "PASS: Bash runner interrupted during wait cleaned up resources and exited 130."

# Test 2: Bash runner normal completion (WAIT_SECONDS=1)
echo "=== Test 2: Bash runner normal completion ==="
: > "$AWS_LOG"
LOG_OUT="${TEST_TMP}/bash_normal.log"
WAIT_SECONDS=1 bash "${REPO_DIR}/run_and_cleanup.sh" --only ec2,budget > "$LOG_OUT" 2>&1
grep -q "Automation Finished Successfully!" "$LOG_OUT" || {
    echo "FAIL: Expected success message in normal bash run"
    cat "$LOG_OUT"
    exit 1
}
grep -q "ec2 terminate-instances --instance-ids i-REDACTED_TEST_EC2" "$AWS_LOG" || {
    echo "FAIL: Expected ec2 terminate-instances call in normal bash run"
    exit 1
}
grep -q "budgets delete-budget" "$AWS_LOG" || {
    echo "FAIL: Expected budgets delete-budget call in normal bash run"
    exit 1
}
echo "PASS: Bash runner normal completion succeeded."

# Test 3: PowerShell runner interrupted during wait (if pwsh is available)
if command -v pwsh >/dev/null 2>&1; then
    echo "=== Test 3: PowerShell runner interrupted during wait ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_interrupt.log"

    python3 -c "
import subprocess, time, signal, os, sys

proc = subprocess.Popen(
    ['pwsh', '-File', '${REPO_DIR}/run_and_cleanup.ps1', '-Only', 'ec2,budget'],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
    cwd='${REPO_DIR}'
)

output = []
interrupted = False
start_time = time.time()
while time.time() - start_time < 10:
    line = proc.stdout.readline()
    if not line:
        break
    output.append(line)
    if 'Waiting 3 minutes' in line:
        os.killpg(os.getpgid(proc.pid), signal.SIGINT)
        interrupted = True
        break

rest_out, _ = proc.communicate(timeout=10)
output.append(rest_out)
full_output = ''.join(output)
with open('${LOG_OUT}', 'w') as f:
    f.write(full_output)

if not interrupted:
    print('Error: Failed to reach waiting state before interrupt', file=sys.stderr)
    sys.exit(1)

if proc.returncode != 130:
    print(f'Error: Expected exit code 130, got {proc.returncode}', file=sys.stderr)
    sys.exit(1)
"

    grep -q "Interrupted during wait. Cleaning up provisioned resources..." "$LOG_OUT" || {
        echo "FAIL: Expected interrupt warning message in pwsh output"
        cat "$LOG_OUT"
        exit 1
    }
    grep -q "ec2 terminate-instances --instance-ids i-REDACTED_TEST_EC2" "$AWS_LOG" || {
        echo "FAIL: Expected ec2 terminate-instances call in aws log for pwsh"
        cat "$AWS_LOG"
        exit 1
    }
    grep -q "budgets delete-budget" "$AWS_LOG" || {
        echo "FAIL: Expected budgets delete-budget call in aws log for pwsh"
        cat "$AWS_LOG"
        exit 1
    }
    echo "PASS: PowerShell runner interrupted during wait cleaned up resources and exited 130."

    # Test 4: PowerShell runner normal completion (WAIT_SECONDS=1)
    echo "=== Test 4: PowerShell runner normal completion ==="
    : > "$AWS_LOG"
    LOG_OUT="${TEST_TMP}/pwsh_normal.log"
    WAIT_SECONDS=1 pwsh -File "${REPO_DIR}/run_and_cleanup.ps1" -Only ec2,budget > "$LOG_OUT" 2>&1
    grep -q "Automation Finished Successfully!" "$LOG_OUT" || {
        echo "FAIL: Expected success message in normal pwsh run"
        cat "$LOG_OUT"
        exit 1
    }
    grep -q "ec2 terminate-instances --instance-ids i-REDACTED_TEST_EC2" "$AWS_LOG" || {
        echo "FAIL: Expected ec2 terminate-instances call in normal pwsh run"
        exit 1
    }
    grep -q "budgets delete-budget" "$AWS_LOG" || {
        echo "FAIL: Expected budgets delete-budget call in normal pwsh run"
        exit 1
    }
    echo "PASS: PowerShell runner normal completion succeeded."
fi

echo "All tests passed successfully!"
