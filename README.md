# AWS Free Tier Credits Automation

This repository contains scripts designed to automate the process of claiming AWS "Earned" Free Tier credits available to new accounts (as of mid-2025).

AWS currently offers up to $100 in earned credits for users who complete specific exploration tasks. These scripts provision the required minimal resources using the AWS CLI, wait for the billing system to register the activity, and safely destroy the resources.

## Covered Tasks

**Last verified: 2026-07-28** (see [`tasks/catalog.json`](tasks/catalog.json) — update this date when you re-check the AWS Free Tier program).

| ID | Task | Credit | Default |
|----|------|--------|---------|
| `ec2` | Launch Amazon Linux 2 `t2.micro` | $20.00 | enabled |
| `rds` | Create MySQL `db.t3.micro` | $20.00 | enabled |
| `lambda` | Deploy a Python Lambda function | $20.00 | enabled |
| `budget` | Create a $10 monthly cost budget | $20.00 | enabled |

Task definitions live in a **modular plugin catalog** so coverage can expand when AWS changes the program:

- Catalog: [`tasks/catalog.json`](tasks/catalog.json)
- Plugins: [`tasks/plugins/`](tasks/plugins/) (`<id>.sh` / `<id>.ps1`)
- How to add a task: [`tasks/README.md`](tasks/README.md)

List the catalog from the CLI:

```bash
./run_and_cleanup.sh --list-tasks
```

```powershell
.\run_and_cleanup.ps1 -ListTasks
```

## Prerequisites
- **AWS CLI Version 2** installed.
- **Configured AWS Credentials** (`aws configure`) with AdministratorAccess or specific permissions to manage EC2, RDS, IAM, Lambda, and Budgets.
- **PowerShell** or **Bash** environment (Windows, macOS, or Linux).
- **Bash runner:** `jq` or `python3` to parse `tasks/catalog.json`.

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

### Customizing Tasks (enable / skip)

Because AWS does not provide an API to check your Promotional Credit balance programmatically, check the AWS Billing Console for which tasks you still need, then enable or skip tasks as needed.

**Skip individual tasks**

```powershell
# Legacy flags (still supported)
.\run_and_cleanup.ps1 -EnableEC2 $false -EnableRDS $false

# Preferred: -Skip by catalog id
.\run_and_cleanup.ps1 -Skip ec2,rds
```

```bash
./run_and_cleanup.sh --skip-ec2 --skip-rds
```

**Run only a subset**

```powershell
.\run_and_cleanup.ps1 -Only lambda,budget
```

```bash
./run_and_cleanup.sh --only lambda,budget
```

**Flags summary**

| PowerShell | Bash | Meaning |
|------------|------|---------|
| `-EnableEC2 / -EnableRDS / -EnableLambda / -EnableBudget` | `--skip-<id>` | Legacy per-task enable (PS) or skip (bash) |
| `-Skip id1,id2` | `--skip-id` (repeatable) | Skip listed catalog ids |
| `-Only id1,id2` | `--only id1,id2` | Run only these ids |
| `-ListTasks` | `--list-tasks` | Print catalog and exit |
| `-AutoCheck` | `--auto-check` | Explain credit API limitation |

## How it Works
1. **Catalog load**: Reads `tasks/catalog.json` and sources matching plugins.
2. **Pre-flight Check**: Verifies `aws sts get-caller-identity` and permission checks for enabled tasks.
3. **Provisioning**: Each enabled plugin creates its minimal resources via the `aws` CLI.
4. **Tracking Delay**: Sleeps for 3 minutes so billing systems can detect activity.
5. **Cleanup**: Plugins destroy resources they created (reverse order).

### Expanding coverage when AWS changes the program
1. Confirm new earned-credit tasks in the AWS Free Tier / Billing console.
2. Add a row to `tasks/catalog.json` and set `last_verified`.
3. Implement `tasks/plugins/<id>.sh` and `tasks/plugins/<id>.ps1` (see [`tasks/README.md`](tasks/README.md)).
4. Register the PowerShell plugin in `run_and_cleanup.ps1` (`TaskPluginMap`).
5. Update the table above in this README.

### Security & Privacy
These scripts run locally on your machine and communicate directly with the AWS API. No private information, AWS account IDs, or region specifics are hardcoded. They dynamically fetch your caller identity and region context from your local `aws configure` session.

> **Note**: Allow 24-48 hours for the promotional credits to appear in your Billing Dashboard after a successful run.
