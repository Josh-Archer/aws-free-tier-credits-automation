# AWS Free Tier Credits Automation

This repository contains scripts designed to automate the process of claiming AWS "Earned" Free Tier credits available to new accounts (as of mid-2025). 

AWS currently offers up to $100 in earned credits for users who complete specific exploration tasks. These scripts provision the required minimal resources using the AWS CLI, wait for the billing system to register the activity, and safely destroy the resources.

## Covered Tasks
The scripts can automate:
1. **EC2:** Launching an Amazon Linux 2 `t2.micro` instance. ($20.00 credit)
2. **RDS:** Creating a MySQL `db.t3.micro` database. ($20.00 credit)
3. **Lambda:** Building and deploying a Serverless Python function. ($20.00 credit)
4. **AWS Budgets:** Setting up a $10.00 monthly cost budget. ($20.00 credit)

## Prerequisites
- **AWS CLI Version 2** installed.
- **Configured AWS Credentials** (`aws configure`) with AdministratorAccess or specific permissions to manage EC2, RDS, IAM, Lambda, and Budgets.
- **PowerShell** or **Bash** environment (Windows, macOS, or Linux).

## Usage

### PowerShell (Windows/Cross-platform)
```powershell
.\run_and_cleanup.ps1
```

### Bash (Linux/macOS)
```bash
chmod +x run_and_cleanup.sh
./run_and_cleanup.sh
```

### Customizing Tasks (Skipping Completed Credits)
Because AWS does not provide an API to check your Promotional Credit balance programmatically, you must manually check your AWS Billing Console to see which tasks you've already completed.

To skip tasks you've already earned credits for, pass the corresponding flags:

**PowerShell:**
```powershell
.\run_and_cleanup.ps1 -EnableEC2 $false -EnableRDS $false
```

**Bash:**
```bash
./run_and_cleanup.sh --skip-ec2 --skip-rds
```

Available Flags (PowerShell):
- `-EnableEC2` (Default: `$true`)
- `-EnableRDS` (Default: `$true`)
- `-EnableLambda` (Default: `$true`)
- `-EnableBudget` (Default: `$true`)
- `-StateFile` (optional path; see [State file](#state-file-idempotent-re-runs))
- `-ResetState` (delete state and start clean)
- `-Force` (re-run tasks even if marked completed)

Available Flags (Bash):
- `--skip-ec2`
- `--skip-rds`
- `--skip-lambda`
- `--skip-budget`
- `--state-file PATH`
- `--reset-state`
- `--force`

## State file (idempotent re-runs)

The scripts persist progress in a local JSON **state file** so re-runs are safe by default:

- Resource IDs (EC2 instance, RDS identifier, Lambda function/role, Budget name) are written as soon as resources are created.
- Each task is marked `completed` after successful cleanup.
- On the next run, **completed tasks are skipped** unless you force or reset.
- If a previous run was interrupted after provisioning, the next run **resumes cleanup** using the saved IDs instead of creating duplicates.

### Default path

| Platform   | Default state file path |
|-----------|--------------------------|
| Either    | `.aws-freetier-state.json` in the same directory as the script |

Override with:

```powershell
.\run_and_cleanup.ps1 -StateFile "C:\path\to\my-state.json"
```

```bash
./run_and_cleanup.sh --state-file /path/to/my-state.json
```

### State schema (overview)

```json
{
  "version": 1,
  "accountId": "123456789012",
  "updatedAt": "2026-07-28T12:00:00Z",
  "tasks": {
    "ec2": { "status": "completed", "instanceId": "i-...", "completedAt": "..." },
    "rds": { "status": "completed", "dbInstanceId": "freetier-db-...", "completedAt": "..." },
    "lambda": { "status": "completed", "functionName": "...", "roleName": "...", "completedAt": "..." },
    "budget": { "status": "completed", "budgetName": "...", "completedAt": "..." }
  }
}
```

Task `status` values: `pending` → `provisioned` → `completed`.

### Resetting state

To clear all recorded progress and treat every task as incomplete again:

```powershell
.\run_and_cleanup.ps1 -ResetState
```

```bash
./run_and_cleanup.sh --reset-state
```

To re-run tasks that are already marked completed **without** deleting the file:

```powershell
.\run_and_cleanup.ps1 -Force
```

```bash
./run_and_cleanup.sh --force
```

You can also delete the state file manually:

```powershell
Remove-Item .\.aws-freetier-state.json   # path next to the script
```

```bash
rm .aws-freetier-state.json
```

> The state file is local and may contain AWS resource identifiers for your account. Do not commit it to version control.

## How it Works
1. **Pre-flight Check**: Verifies your active `aws sts get-caller-identity` and performs dry-run permission checks.
2. **Load state**: Reads `.aws-freetier-state.json` (or your custom path) and skips completed tasks.
3. **Provisioning**: Creates only the remaining enabled resources natively via the `aws` CLI; IDs are saved immediately.
4. **Tracking Delay**: Sleeps for 3 minutes to ensure the AWS billing systems detect the activity.
5. **Cleanup**: Automatically destroys provisioned resources and marks those tasks completed in the state file.

### Security & Privacy
These scripts run locally on your machine and communicate directly with the AWS API. No private information, AWS account IDs, or region specifics are hardcoded. They dynamically fetch your caller identity and region context from your local `aws configure` session.

> **Note**: Allow 24-48 hours for the promotional credits to appear in your Billing Dashboard after a successful run.
