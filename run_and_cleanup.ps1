<#
.SYNOPSIS
Provisions resources required to claim the AWS new account free tier credits natively via AWS CLI, waits, and then destroys them.

.DESCRIPTION
AWS updated its new account Free Tier (as of mid-2025) to provide up to $100 in earned credits.
This script uses the AWS CLI directly to spin up resources, pauses, and then cleans them up.

Cleanup always runs via try/finally so mid-run failures or early exit still attempt destruction.
Created resources are tracked as soon as each create succeeds. Failed cleanup prints remaining
resource IDs for manual deletion.

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
#>

[CmdletBinding()]
param (
    [bool]$EnableEC2 = $true,
    [bool]$EnableRDS = $true,
    [bool]$EnableLambda = $true,
    [bool]$EnableBudget = $true,
    [switch]$AutoCheck
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

# --- PRE-FLIGHT PERMISSION CHECK ---
Write-Host "`nRunning Pre-flight Permission Checks..." -ForegroundColor Cyan
$failedChecks = 0

if ($EnableEC2) {
    try { aws ec2 describe-regions --max-items 1 --output json | Out-Null; Write-Host "  [OK] EC2 Read Permissions" -ForegroundColor Green }
    catch { Write-Host "  [FAIL] EC2 Read Permissions" -ForegroundColor Red; $failedChecks++ }
}
if ($EnableRDS) {
    try { aws rds describe-db-instances --max-items 1 --output json | Out-Null; Write-Host "  [OK] RDS Read Permissions" -ForegroundColor Green }
    catch { Write-Host "  [FAIL] RDS Read Permissions" -ForegroundColor Red; $failedChecks++ }
}
if ($EnableLambda) {
    try { aws lambda list-functions --max-items 1 --output json | Out-Null; Write-Host "  [OK] Lambda Read Permissions" -ForegroundColor Green }
    catch { Write-Host "  [FAIL] Lambda Read Permissions" -ForegroundColor Red; $failedChecks++ }
}
if ($EnableBudget) {
    try {
        $acc = aws sts get-caller-identity --query "Account" --output text
        aws budgets describe-budgets --account-id $acc --max-items 1 --output json | Out-Null; Write-Host "  [OK] Budget Read Permissions" -ForegroundColor Green
    }
    catch { Write-Host "  [FAIL] Budget Read Permissions" -ForegroundColor Red; $failedChecks++ }
}

if ($failedChecks -gt 0) {
    Write-Host "`nWarning: $failedChecks permission check(s) failed. If you proceed, the script will likely fail to create resources." -ForegroundColor Yellow
}

Write-Host "`nStarting AWS Free Tier Credit Automation..." -ForegroundColor Cyan
Write-Host "Enabled Tasks: EC2=$EnableEC2, RDS=$EnableRDS, Lambda=$EnableLambda, Budget=$EnableBudget"

# Track each resource as soon as create succeeds so partial runs still clean up.
$createdResources = @{
    InstanceId     = $null
    RDSId          = $null
    LambdaRoleName = $null
    LambdaName     = $null
    BudgetName     = $null
}

$scriptFailed = $false
$cleanupFailed = $false

function Get-RemainingResources {
    $remaining = @()
    if ($createdResources.InstanceId)     { $remaining += "EC2 InstanceId: $($createdResources.InstanceId)" }
    if ($createdResources.RDSId)          { $remaining += "RDS DB Identifier: $($createdResources.RDSId)" }
    if ($createdResources.LambdaName)     { $remaining += "Lambda Function: $($createdResources.LambdaName)" }
    if ($createdResources.LambdaRoleName) { $remaining += "IAM Role: $($createdResources.LambdaRoleName)" }
    if ($createdResources.BudgetName)     { $remaining += "Budget Name: $($createdResources.BudgetName)" }
    return $remaining
}

function Invoke-Cleanup {
    Write-Host "`n=== CLEANING UP RESOURCES ===" -ForegroundColor Cyan
    $localCleanupFailed = $false
    $account = $identity.Account

    if ($createdResources.InstanceId) {
        Write-Host "Terminating EC2 Instance: $($createdResources.InstanceId)..."
        try {
            aws ec2 terminate-instances --instance-ids $createdResources.InstanceId | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "aws exit code $LASTEXITCODE" }
            Write-Host "Destroyed EC2." -ForegroundColor Green
            $createdResources.InstanceId = $null
        } catch {
            Write-Host "Failed to terminate EC2 $($createdResources.InstanceId): $($_.Exception.Message)" -ForegroundColor Red
            $localCleanupFailed = $true
        }
    }

    if ($createdResources.RDSId) {
        Write-Host "Deleting RDS Database: $($createdResources.RDSId)..."
        try {
            aws rds delete-db-instance --db-instance-identifier $createdResources.RDSId --skip-final-snapshot | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "aws exit code $LASTEXITCODE" }
            Write-Host "Destroyed RDS." -ForegroundColor Green
            $createdResources.RDSId = $null
        } catch {
            Write-Host "Failed to delete RDS $($createdResources.RDSId): $($_.Exception.Message)" -ForegroundColor Red
            $localCleanupFailed = $true
        }
    }

    if ($createdResources.LambdaName) {
        Write-Host "Deleting Lambda Function: $($createdResources.LambdaName)..."
        try {
            aws lambda delete-function --function-name $createdResources.LambdaName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "aws exit code $LASTEXITCODE" }
            Write-Host "Destroyed Lambda function." -ForegroundColor Green
            $createdResources.LambdaName = $null
        } catch {
            Write-Host "Failed to delete Lambda $($createdResources.LambdaName): $($_.Exception.Message)" -ForegroundColor Red
            $localCleanupFailed = $true
        }
    }

    if ($createdResources.LambdaRoleName) {
        Write-Host "Deleting IAM Role: $($createdResources.LambdaRoleName)..."
        try {
            aws iam delete-role --role-name $createdResources.LambdaRoleName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "aws exit code $LASTEXITCODE" }
            Write-Host "Destroyed IAM role." -ForegroundColor Green
            $createdResources.LambdaRoleName = $null
        } catch {
            Write-Host "Failed to delete IAM role $($createdResources.LambdaRoleName): $($_.Exception.Message)" -ForegroundColor Red
            $localCleanupFailed = $true
        }
    }

    if ($createdResources.BudgetName) {
        Write-Host "Deleting Budget: $($createdResources.BudgetName)..."
        try {
            aws budgets delete-budget --account-id $account --budget-name $createdResources.BudgetName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "aws exit code $LASTEXITCODE" }
            Write-Host "Destroyed Budget." -ForegroundColor Green
            $createdResources.BudgetName = $null
        } catch {
            Write-Host "Failed to delete Budget $($createdResources.BudgetName): $($_.Exception.Message)" -ForegroundColor Red
            $localCleanupFailed = $true
        }
    }

    # Always remove local temp artifacts
    Remove-Item -ErrorAction SilentlyContinue -Force trust-policy.json, main.py, lambda.zip, config.txt, profiles.txt

    $remaining = Get-RemainingResources
    if ($remaining.Count -gt 0) {
        Write-Host "`n=======================================================" -ForegroundColor Red
        Write-Host "CLEANUP INCOMPLETE - manually delete remaining resources:" -ForegroundColor Red
        Write-Host "=======================================================" -ForegroundColor Red
        foreach ($item in $remaining) {
            Write-Host "  - $item" -ForegroundColor Red
        }
        Write-Host "=======================================================" -ForegroundColor Red
        return $true
    }

    if ($localCleanupFailed) {
        return $true
    }

    Write-Host "Cleanup completed; no tracked resources remain." -ForegroundColor Green
    return $false
}

try {
    # --- PROVISIONING ---
    Write-Host "`n=== PROVISIONING RESOURCES ===" -ForegroundColor Cyan

    if ($EnableEC2) {
        try {
            Write-Host "Fetching latest Amazon Linux 2 AMI..."
            $ami = aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text
            if ($LASTEXITCODE -ne 0) { throw "Failed to describe images (aws exit $LASTEXITCODE)" }
            Write-Host "Launching EC2 instance (t2.micro) with AMI $ami..."
            $instanceId = aws ec2 run-instances --image-id $ami --instance-type t2.micro --query "Instances[0].InstanceId" --output text
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($instanceId) -or $instanceId -eq "None") {
                throw "Failed to launch instance (aws exit $LASTEXITCODE)"
            }
            # Track immediately so cleanup runs even if later steps fail.
            $createdResources.InstanceId = $instanceId
            Write-Host "Created EC2 Instance: $instanceId" -ForegroundColor Green
        } catch {
            Write-Host "Failed to create EC2 instance: $($_.Exception.Message)" -ForegroundColor Red
            $scriptFailed = $true
        }
    }

    if ($EnableRDS) {
        try {
            Write-Host "Creating RDS Database (db.t3.micro MySQL)..."
            $dbName = "freetier-db-$(Get-Random)"
            aws rds create-db-instance --db-instance-identifier $dbName --allocated-storage 20 --engine mysql --engine-version 8.0 --instance-class db.t3.micro --master-username admin --master-user-password "FreeTierPassword123!" --no-publicly-accessible --skip-final-snapshot | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "aws exit code $LASTEXITCODE" }
            $createdResources.RDSId = $dbName
            Write-Host "Created RDS Database: $dbName" -ForegroundColor Green
        } catch {
            Write-Host "Failed to create RDS database: $($_.Exception.Message)" -ForegroundColor Red
            $scriptFailed = $true
        }
    }

    if ($EnableLambda) {
        try {
            Write-Host "Creating Lambda Role and Function..."
            $roleName = "freetier-role-$(Get-Random)"
            $funcName = "freetier-func-$(Get-Random)"

            $trustPolicy = '{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
            $trustPolicy | Out-File -FilePath trust-policy.json -Encoding ascii
            aws iam create-role --role-name $roleName --assume-role-policy-document file://trust-policy.json | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to create IAM role (aws exit $LASTEXITCODE)" }
            # Track role immediately (function create can still fail).
            $createdResources.LambdaRoleName = $roleName
            Write-Host "Created IAM Role: $roleName" -ForegroundColor Green

            # Wait for role to propagate
            Start-Sleep -Seconds 10

            $lambdaCode = "def lambda_handler(event, context): return 'Hello Free Tier'"
            $lambdaCode | Out-File -FilePath main.py -Encoding ascii
            Compress-Archive -Path main.py -DestinationPath lambda.zip -Force

            $account = $identity.Account
            aws lambda create-function --function-name $funcName --runtime python3.12 --role arn:aws:iam::${account}:role/$roleName --handler main.lambda_handler --zip-file fileb://lambda.zip | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to create Lambda function (aws exit $LASTEXITCODE)" }
            $createdResources.LambdaName = $funcName
            Write-Host "Created Lambda: $funcName" -ForegroundColor Green
        } catch {
            Write-Host "Failed to create Lambda: $($_.Exception.Message)" -ForegroundColor Red
            $scriptFailed = $true
        }
    }

    if ($EnableBudget) {
        try {
            Write-Host "Creating AWS Budget..."
            $budgetName = "freetier-budget-$(Get-Random)"
            $account = $identity.Account
            $budgetDef = '{"BudgetName":"' + $budgetName + '","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'
            aws budgets create-budget --account-id $account --budget $budgetDef --notifications-with-subscribers "[]" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "aws exit code $LASTEXITCODE" }
            $createdResources.BudgetName = $budgetName
            Write-Host "Created Budget: $budgetName" -ForegroundColor Green
        } catch {
            Write-Host "Failed to create Budget: $($_.Exception.Message)" -ForegroundColor Red
            $scriptFailed = $true
        }
    }

    # --- WAITING ---
    Write-Host "`n=======================================================" -ForegroundColor Yellow
    Write-Host "Provisioning phase complete!"
    Write-Host "Waiting 3 minutes for AWS to register the activity..." -ForegroundColor Yellow
    Start-Sleep -Seconds 180
    Write-Host "=======================================================" -ForegroundColor Yellow
} catch {
    Write-Host "Unexpected error during provisioning/wait: $($_.Exception.Message)" -ForegroundColor Red
    $scriptFailed = $true
} finally {
    # Always attempt cleanup, including after partial creates or mid-run errors.
    $cleanupFailed = Invoke-Cleanup
}

if ($cleanupFailed) {
    Write-Host "`nAutomation finished with CLEANUP FAILURES. Review remaining resources above." -ForegroundColor Red
    exit 2
}

if ($scriptFailed) {
    Write-Host "`nAutomation finished with provisioning errors, but cleanup reported no remaining tracked resources." -ForegroundColor Yellow
    exit 1
}

Write-Host "`nAutomation Finished Successfully!" -ForegroundColor Green
exit 0
