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
- `-WaitMinutes <int>` (Default: `10`) — billing registration wait before cleanup
- `-PollReady` — optionally poll EC2/RDS readiness with exponential backoff before the wait
- `-MaxPollMinutes <int>` (Default: `20`) — ceiling for readiness polling (avoids infinite hang)

Available Flags (Bash):
- `--skip-ec2`
- `--skip-rds`
- `--skip-lambda`
- `--skip-budget`
- `--wait-minutes N` (Default: `10`)
- `--poll-ready`
- `--max-poll-minutes N` (Default: `20`)

### Wait duration and billing registration

A short fixed wait (for example 3 minutes) is often **not enough** for AWS billing systems to register resource activity before cleanup. Defaults are therefore longer and configurable.

| Setting | Recommended | Notes |
|--------|-------------|--------|
| Billing wait (`WaitMinutes` / `--wait-minutes`) | **10–15 minutes** | Default is **10**. Raise if runs still fail to earn credits. |
| Readiness poll (`PollReady` / `--poll-ready`) | Optional, useful with RDS | Polls EC2 → `running` and RDS → `available` with backoff. |
| Poll ceiling (`MaxPollMinutes` / `--max-poll-minutes`) | **15–20 minutes** | Caps polling so the script never hangs forever. |

**Examples:**

```powershell
# Longer billing wait only
.\run_and_cleanup.ps1 -WaitMinutes 15

# Wait for EC2/RDS to become ready, then 12 minutes for billing
.\run_and_cleanup.ps1 -PollReady -WaitMinutes 12 -MaxPollMinutes 20
```

```bash
# Longer billing wait only
./run_and_cleanup.sh --wait-minutes 15

# Wait for EC2/RDS to become ready, then 12 minutes for billing
./run_and_cleanup.sh --poll-ready --wait-minutes 12 --max-poll-minutes 20
```

> **Credit lag:** Allow **24–48 hours** for promotional credits to appear in the AWS Billing Dashboard after a successful run. Re-running too soon can create duplicate resources or confuse which tasks already counted—check Billing first and use skip flags for credits you already earned.

## How it Works
1. **Pre-flight Check**: Verifies your active `aws sts get-caller-identity` and performs dry-run permission checks.
2. **Provisioning**: Creates the enabled resources natively via the `aws` CLI.
3. **Optional readiness poll**: If enabled, polls EC2/RDS with exponential backoff until ready or until `MaxPollMinutes` is reached (no infinite hang).
4. **Tracking delay**: Sleeps for a configurable number of minutes (default 10) so billing can detect the activity.
5. **Cleanup**: Automatically destroys all provisioned resources to prevent accidental recurring charges.

### Security & Privacy
These scripts run locally on your machine and communicate directly with the AWS API. No private information, AWS account IDs, or region specifics are hardcoded. They dynamically fetch your caller identity and region context from your local `aws configure` session.
