<#
.SYNOPSIS
Provisions resources required to claim the AWS new account free tier credits natively via AWS CLI, waits, and then destroys them.

.DESCRIPTION
AWS updated its new account Free Tier (as of mid-2025) to provide up to $100 in earned credits.
This script uses the AWS CLI directly to spin up resources, pauses, and then cleans them up.

Progress is recorded in a local state file so re-runs skip tasks already completed and can resume
cleanup of resources left from an interrupted run.

.PARAMETER EnableEC2
Set to $false to skip launching an EC2 instance. Default is $true.

.PARAMETER EnableRDS
Set to $false to skip creating an RDS database. Default is $true.

.PARAMETER EnableLambda
Set to $false to skip building a Lambda function. Default is $true.

.PARAMETER EnableBudget
Set to $false to skip setting an AWS Cost Budget. Default is $true.

.PARAMETER AutoCheck
Throws a warning that AWS API does not support programmatic checking of promotional credits.

.PARAMETER StateFile
Path to the JSON state file used for idempotent re-runs. Default: .aws-freetier-state.json next to this script.

.PARAMETER ResetState
Delete the state file and start with a clean slate (all tasks treated as incomplete).

.PARAMETER Force
Re-run tasks even if the state file marks them completed. Does not delete the state file.
#>

[CmdletBinding()]
param (
    [bool]$EnableEC2 = $true,
    [bool]$EnableRDS = $true,
    [bool]$EnableLambda = $true,
    [bool]$EnableBudget = $true,
    [switch]$AutoCheck,
    [string]$StateFile = "",
    [switch]$ResetState,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if ($AutoCheck) {
    Write-Host "=======================================================" -ForegroundColor Yellow
    Write-Host "AUTO-CHECK LIMITATION" -ForegroundColor Yellow
    Write-Host "=======================================================" -ForegroundColor Yellow
    Write-Host "AWS does not provide a public API or CLI command to retrieve your Promotional Credit balance."
    Write-Host "Please use the AWS Billing Console to verify your credits and use the Enable* flags to skip the ones you already have."
    Write-Host "=======================================================" -ForegroundColor Yellow
    exit
}

# --- STATE FILE HELPERS ---
if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $StateFile = Join-Path $PSScriptRoot ".aws-freetier-state.json"
}

function New-EmptyState {
    return [pscustomobject]@{
        version   = 1
        accountId = $null
        updatedAt = $null
        tasks     = [pscustomobject]@{
            ec2    = [pscustomobject]@{ status = "pending"; instanceId = $null; completedAt = $null }
            rds    = [pscustomobject]@{ status = "pending"; dbInstanceId = $null; completedAt = $null }
            lambda = [pscustomobject]@{ status = "pending"; functionName = $null; roleName = $null; completedAt = $null }
            budget = [pscustomobject]@{ status = "pending"; budgetName = $null; completedAt = $null }
        }
    }
}

function Get-TaskStatus {
    param($State, [string]$Task)
    $taskObj = $State.tasks.$Task
    if (-not $taskObj) { return "pending" }
    if ([string]::IsNullOrWhiteSpace([string]$taskObj.status)) { return "pending" }
    return [string]$taskObj.status
}

function Save-State {
    param($State)
    $State.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    $json = $State | ConvertTo-Json -Depth 6
    $dir = Split-Path -Parent $StateFile
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # UTF8 without BOM for cross-platform friendliness
    [System.IO.File]::WriteAllText($StateFile, $json)
}

function Read-State {
    if (-not (Test-Path $StateFile)) {
        return New-EmptyState
    }
    try {
        $raw = Get-Content -Path $StateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return New-EmptyState
        }
        $parsed = $raw | ConvertFrom-Json
        # Ensure tasks node exists
        if (-not $parsed.tasks) {
            $empty = New-EmptyState
            $parsed | Add-Member -NotePropertyName tasks -NotePropertyValue $empty.tasks -Force
        }
        foreach ($name in @("ec2", "rds", "lambda", "budget")) {
            if (-not $parsed.tasks.$name) {
                $emptyTask = (New-EmptyState).tasks.$name
                $parsed.tasks | Add-Member -NotePropertyName $name -NotePropertyValue $emptyTask -Force
            }
        }
        return $parsed
    } catch {
        Write-Host "Warning: Could not parse state file at $StateFile. Starting fresh." -ForegroundColor Yellow
        return New-EmptyState
    }
}

function Test-TaskShouldRun {
    param(
        [bool]$Enabled,
        $State,
        [string]$Task
    )
    if (-not $Enabled) { return $false }
    $status = Get-TaskStatus -State $State -Task $Task
    if ($Force) { return $true }
    if ($status -eq "completed") { return $false }
    return $true
}

if ($ResetState) {
    if (Test-Path $StateFile) {
        Remove-Item -Path $StateFile -Force
        Write-Host "State file reset: $StateFile" -ForegroundColor Yellow
    } else {
        Write-Host "No state file to reset at: $StateFile" -ForegroundColor Yellow
    }
}

$state = Read-State
Write-Host "State file: $StateFile" -ForegroundColor DarkGray

# --- IDENTITY CHECK ---
Write-Host "Verifying AWS CLI Identity..." -ForegroundColor Cyan
try {
    $identity = aws sts get-caller-identity --query "{Account:Account, Arn:Arn}" --output json | ConvertFrom-Json
    Write-Host "Account: $($identity.Account)"
    Write-Host "User Arn: $($identity.Arn)"
} catch {
    Write-Host "Error: Unable to verify AWS identity. Please run 'aws configure' first." -ForegroundColor Red
    exit 1
}

if ($state.accountId -and $state.accountId -ne $identity.Account) {
    Write-Host "Warning: State file belongs to account $($state.accountId), but active identity is $($identity.Account)." -ForegroundColor Yellow
    Write-Host "Starting a new state for the current account. Use -ResetState to clear the old file explicitly." -ForegroundColor Yellow
    $state = New-EmptyState
}
$state.accountId = $identity.Account
Save-State $state

# Effective enable flags after state + force
$runEC2 = Test-TaskShouldRun -Enabled $EnableEC2 -State $state -Task "ec2"
$runRDS = Test-TaskShouldRun -Enabled $EnableRDS -State $state -Task "rds"
$runLambda = Test-TaskShouldRun -Enabled $EnableLambda -State $state -Task "lambda"
$runBudget = Test-TaskShouldRun -Enabled $EnableBudget -State $state -Task "budget"

function Write-SkipMessage {
    param([string]$Task, [bool]$Enabled, $State)
    if (-not $Enabled) {
        Write-Host "  Skipping $Task (disabled by flag)." -ForegroundColor DarkGray
        return
    }
    $status = Get-TaskStatus -State $State -Task $Task
    if ($status -eq "completed" -and -not $Force) {
        Write-Host "  Skipping $Task (already completed in state file). Use -Force to re-run." -ForegroundColor DarkGray
    }
}

# --- PRE-FLIGHT PERMISSION CHECK ---
Write-Host "`nRunning Pre-flight Permission Checks..." -ForegroundColor Cyan
$failedChecks = 0

if ($runEC2) {
    try { aws ec2 describe-regions --max-items 1 --output json | Out-Null; Write-Host "  [OK] EC2 Read Permissions" -ForegroundColor Green }
    catch { Write-Host "  [FAIL] EC2 Read Permissions" -ForegroundColor Red; $failedChecks++ }
}
if ($runRDS) {
    try { aws rds describe-db-instances --max-items 1 --output json | Out-Null; Write-Host "  [OK] RDS Read Permissions" -ForegroundColor Green }
    catch { Write-Host "  [FAIL] RDS Read Permissions" -ForegroundColor Red; $failedChecks++ }
}
if ($runLambda) {
    try { aws lambda list-functions --max-items 1 --output json | Out-Null; Write-Host "  [OK] Lambda Read Permissions" -ForegroundColor Green }
    catch { Write-Host "  [FAIL] Lambda Read Permissions" -ForegroundColor Red; $failedChecks++ }
}
if ($runBudget) {
    try {
        $acc = $identity.Account
        aws budgets describe-budgets --account-id $acc --max-items 1 --output json | Out-Null; Write-Host "  [OK] Budget Read Permissions" -ForegroundColor Green
    }
    catch { Write-Host "  [FAIL] Budget Read Permissions" -ForegroundColor Red; $failedChecks++ }
}

if ($failedChecks -gt 0) {
    Write-Host "`nWarning: $failedChecks permission check(s) failed. If you proceed, the script will likely fail to create resources." -ForegroundColor Yellow
}

Write-Host "`nStarting AWS Free Tier Credit Automation..." -ForegroundColor Cyan
Write-Host "Enabled Flags: EC2=$EnableEC2, RDS=$EnableRDS, Lambda=$EnableLambda, Budget=$EnableBudget"
Write-Host "Will run this session: EC2=$runEC2, RDS=$runRDS, Lambda=$runLambda, Budget=$runBudget"
Write-SkipMessage -Task "EC2" -Enabled $EnableEC2 -State $state
Write-SkipMessage -Task "RDS" -Enabled $EnableRDS -State $state
Write-SkipMessage -Task "Lambda" -Enabled $EnableLambda -State $state
Write-SkipMessage -Task "Budget" -Enabled $EnableBudget -State $state

$createdResources = @{
    InstanceId     = $null
    RDSId          = $null
    LambdaRoleName = $null
    LambdaName     = $null
    BudgetName     = $null
}

$provisionedThisRun = $false

# Resume IDs from prior interrupted run (status = provisioned)
if ($runEC2 -and (Get-TaskStatus -State $state -Task "ec2") -eq "provisioned" -and $state.tasks.ec2.instanceId) {
    $createdResources.InstanceId = [string]$state.tasks.ec2.instanceId
    Write-Host "Resuming EC2 cleanup from state: $($createdResources.InstanceId)" -ForegroundColor Yellow
}
if ($runRDS -and (Get-TaskStatus -State $state -Task "rds") -eq "provisioned" -and $state.tasks.rds.dbInstanceId) {
    $createdResources.RDSId = [string]$state.tasks.rds.dbInstanceId
    Write-Host "Resuming RDS cleanup from state: $($createdResources.RDSId)" -ForegroundColor Yellow
}
if ($runLambda -and (Get-TaskStatus -State $state -Task "lambda") -eq "provisioned") {
    if ($state.tasks.lambda.functionName) {
        $createdResources.LambdaName = [string]$state.tasks.lambda.functionName
        $createdResources.LambdaRoleName = [string]$state.tasks.lambda.roleName
        Write-Host "Resuming Lambda cleanup from state: $($createdResources.LambdaName)" -ForegroundColor Yellow
    }
}
if ($runBudget -and (Get-TaskStatus -State $state -Task "budget") -eq "provisioned" -and $state.tasks.budget.budgetName) {
    $createdResources.BudgetName = [string]$state.tasks.budget.budgetName
    Write-Host "Resuming Budget cleanup from state: $($createdResources.BudgetName)" -ForegroundColor Yellow
}

# --- PROVISIONING ---
Write-Host "`n=== PROVISIONING RESOURCES ===" -ForegroundColor Cyan

if ($runEC2 -and -not $createdResources.InstanceId) {
    try {
        Write-Host "Fetching latest Amazon Linux 2 AMI..."
        $ami = aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text
        Write-Host "Launching EC2 instance (t2.micro) with AMI $ami..."
        $instanceId = aws ec2 run-instances --image-id $ami --instance-type t2.micro --query "Instances[0].InstanceId" --output text
        $createdResources.InstanceId = $instanceId
        $state.tasks.ec2.status = "provisioned"
        $state.tasks.ec2.instanceId = $instanceId
        $state.tasks.ec2.completedAt = $null
        Save-State $state
        $provisionedThisRun = $true
        Write-Host "Created EC2 Instance: $instanceId" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create EC2 instance: $($_.Exception.Message)" -ForegroundColor Red
    }
} elseif ($runEC2 -and $createdResources.InstanceId) {
    $provisionedThisRun = $true
}

if ($runRDS -and -not $createdResources.RDSId) {
    try {
        Write-Host "Creating RDS Database (db.t3.micro MySQL)..."
        $dbName = "freetier-db-$(Get-Random)"
        aws rds create-db-instance --db-instance-identifier $dbName --allocated-storage 20 --engine mysql --engine-version 8.0 --instance-class db.t3.micro --master-username admin --master-user-password "FreeTierPassword123!" --no-publicly-accessible --skip-final-snapshot | Out-Null
        $createdResources.RDSId = $dbName
        $state.tasks.rds.status = "provisioned"
        $state.tasks.rds.dbInstanceId = $dbName
        $state.tasks.rds.completedAt = $null
        Save-State $state
        $provisionedThisRun = $true
        Write-Host "Created RDS Database: $dbName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create RDS database: $($_.Exception.Message)" -ForegroundColor Red
    }
} elseif ($runRDS -and $createdResources.RDSId) {
    $provisionedThisRun = $true
}

if ($runLambda -and -not $createdResources.LambdaName) {
    try {
        Write-Host "Creating Lambda Role and Function..."
        $roleName = "freetier-role-$(Get-Random)"
        $funcName = "freetier-func-$(Get-Random)"

        $trustPolicy = '{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
        $trustPolicy | Out-File -FilePath trust-policy.json -Encoding ascii
        aws iam create-role --role-name $roleName --assume-role-policy-document file://trust-policy.json | Out-Null

        # Wait for role to propagate
        Start-Sleep -Seconds 10

        $lambdaCode = "def lambda_handler(event, context): return 'Hello Free Tier'"
        $lambdaCode | Out-File -FilePath main.py -Encoding ascii
        Compress-Archive -Path main.py -DestinationPath lambda.zip -Force

        $account = $identity.Account
        aws lambda create-function --function-name $funcName --runtime python3.12 --role arn:aws:iam::${account}:role/$roleName --handler main.lambda_handler --zip-file fileb://lambda.zip | Out-Null

        $createdResources.LambdaRoleName = $roleName
        $createdResources.LambdaName = $funcName
        $state.tasks.lambda.status = "provisioned"
        $state.tasks.lambda.functionName = $funcName
        $state.tasks.lambda.roleName = $roleName
        $state.tasks.lambda.completedAt = $null
        Save-State $state
        $provisionedThisRun = $true
        Write-Host "Created Lambda: $funcName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create Lambda: $($_.Exception.Message)" -ForegroundColor Red
    }
} elseif ($runLambda -and $createdResources.LambdaName) {
    $provisionedThisRun = $true
}

if ($runBudget -and -not $createdResources.BudgetName) {
    try {
        Write-Host "Creating AWS Budget..."
        $budgetName = "freetier-budget-$(Get-Random)"
        $account = $identity.Account
        $budgetDef = '{"BudgetName":"' + $budgetName + '","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'
        aws budgets create-budget --account-id $account --budget $budgetDef --notifications-with-subscribers "[]" | Out-Null
        $createdResources.BudgetName = $budgetName
        $state.tasks.budget.status = "provisioned"
        $state.tasks.budget.budgetName = $budgetName
        $state.tasks.budget.completedAt = $null
        Save-State $state
        $provisionedThisRun = $true
        Write-Host "Created Budget: $budgetName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create Budget: $($_.Exception.Message)" -ForegroundColor Red
    }
} elseif ($runBudget -and $createdResources.BudgetName) {
    $provisionedThisRun = $true
}

$hasResourcesToClean = $createdResources.InstanceId -or $createdResources.RDSId -or $createdResources.LambdaName -or $createdResources.BudgetName

if (-not $hasResourcesToClean) {
    Write-Host "`nNo resources to provision or clean up. All requested tasks are complete or disabled." -ForegroundColor Green
    Write-Host "State file: $StateFile" -ForegroundColor DarkGray
    Write-Host "`nAutomation Finished Successfully!" -ForegroundColor Green
    exit 0
}

# --- WAITING ---
Write-Host "`n=======================================================" -ForegroundColor Yellow
Write-Host "Provisioning phase complete!"
Write-Host "Waiting 3 minutes for AWS to register the activity..." -ForegroundColor Yellow
Start-Sleep -Seconds 180
Write-Host "=======================================================" -ForegroundColor Yellow

# --- CLEANUP ---
Write-Host "`n=== CLEANING UP RESOURCES ===" -ForegroundColor Cyan

if ($createdResources.InstanceId) {
    Write-Host "Terminating EC2 Instance: $($createdResources.InstanceId)..."
    try {
        aws ec2 terminate-instances --instance-ids $($createdResources.InstanceId) | Out-Null
        Write-Host "Destroyed EC2." -ForegroundColor Green
        $state.tasks.ec2.status = "completed"
        $state.tasks.ec2.completedAt = (Get-Date).ToUniversalTime().ToString("o")
        Save-State $state
    } catch {
        Write-Host "Failed to terminate EC2: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($createdResources.RDSId) {
    Write-Host "Deleting RDS Database: $($createdResources.RDSId)..."
    try {
        aws rds delete-db-instance --db-instance-identifier $($createdResources.RDSId) --skip-final-snapshot | Out-Null
        Write-Host "Destroyed RDS." -ForegroundColor Green
        $state.tasks.rds.status = "completed"
        $state.tasks.rds.completedAt = (Get-Date).ToUniversalTime().ToString("o")
        Save-State $state
    } catch {
        Write-Host "Failed to delete RDS: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($createdResources.LambdaName) {
    Write-Host "Deleting Lambda Function: $($createdResources.LambdaName)..."
    try {
        aws lambda delete-function --function-name $($createdResources.LambdaName) | Out-Null
        if ($createdResources.LambdaRoleName) {
            aws iam delete-role --role-name $($createdResources.LambdaRoleName) | Out-Null
        }
        Write-Host "Destroyed Lambda." -ForegroundColor Green
        $state.tasks.lambda.status = "completed"
        $state.tasks.lambda.completedAt = (Get-Date).ToUniversalTime().ToString("o")
        Save-State $state
    } catch {
        Write-Host "Failed to delete Lambda: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($createdResources.BudgetName) {
    Write-Host "Deleting Budget: $($createdResources.BudgetName)..."
    try {
        $account = $identity.Account
        aws budgets delete-budget --account-id $account --budget-name $($createdResources.BudgetName) | Out-Null
        Write-Host "Destroyed Budget." -ForegroundColor Green
        $state.tasks.budget.status = "completed"
        $state.tasks.budget.completedAt = (Get-Date).ToUniversalTime().ToString("o")
        Save-State $state
    } catch {
        Write-Host "Failed to delete Budget: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Cleanup temp files
Remove-Item -ErrorAction SilentlyContinue trust-policy.json, main.py, lambda.zip

Write-Host "`nState saved to: $StateFile" -ForegroundColor DarkGray
Write-Host "Completed tasks will be skipped on the next run. Use -ResetState or -Force to re-run." -ForegroundColor DarkGray
Write-Host "`nAutomation Finished Successfully!" -ForegroundColor Green
