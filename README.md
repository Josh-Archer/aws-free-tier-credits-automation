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

Available Flags (Bash):
- `--skip-ec2`
- `--skip-rds`
- `--skip-lambda`
- `--skip-budget`

## How it Works
1. **Pre-flight Check**: Verifies your active `aws sts get-caller-identity` and performs dry-run permission checks.
2. **Provisioning**: Creates the enabled resources natively via the `aws` CLI.
3. **Tracking Delay**: Sleeps for 3 minutes to ensure the AWS billing systems detect the activity.
4. **Cleanup**: Automatically destroys all provisioned resources to prevent accidental recurring charges.

### Security & Privacy
These scripts run locally on your machine and communicate directly with the AWS API. No private information, AWS account IDs, or region specifics are hardcoded. They dynamically fetch your caller identity and region context from your local `aws configure` session.

> **Note**: Allow 24-48 hours for the promotional credits to appear in your Billing Dashboard after a successful run.
