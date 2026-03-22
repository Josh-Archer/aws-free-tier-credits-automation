<#
.SYNOPSIS
Provisions resources required to claim the AWS new account free tier credits natively via AWS CLI, waits, and then destroys them.

.DESCRIPTION
AWS updated its new account Free Tier (as of mid-2025) to provide up to $100 in earned credits.
This script uses the AWS CLI directly to spin up resources, pauses, and then cleans them up.

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

$createdResources = @{
    InstanceId = $null
    RDSId = $null
    LambdaRoleName = $null
    LambdaName = $null
    BudgetName = $null
}

# --- PROVISIONING ---
Write-Host "`n=== PROVISIONING RESOURCES ===" -ForegroundColor Cyan

if ($EnableEC2) {
    try {
        Write-Host "Fetching latest Amazon Linux 2 AMI..."
        $ami = aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text
        Write-Host "Launching EC2 instance (t2.micro) with AMI $ami..."
        $instanceId = aws ec2 run-instances --image-id $ami --instance-type t2.micro --query "Instances[0].InstanceId" --output text
        $createdResources.InstanceId = $instanceId
        Write-Host "Created EC2 Instance: $instanceId" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create EC2 instance: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($EnableRDS) {
    try {
        Write-Host "Creating RDS Database (db.t3.micro MySQL)..."
        $dbName = "freetier-db-$(Get-Random)"
        aws rds create-db-instance --db-instance-identifier $dbName --allocated-storage 20 --engine mysql --engine-version 8.0 --instance-class db.t3.micro --master-username admin --master-user-password "FreeTierPassword123!" --no-publicly-accessible --skip-final-snapshot | Out-Null
        $createdResources.RDSId = $dbName
        Write-Host "Created RDS Database: $dbName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create RDS database: $($_.Exception.Message)" -ForegroundColor Red
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
        
        # Wait for role to propagate
        Start-Sleep -Seconds 10
        
        $lambdaCode = "def lambda_handler(event, context): return 'Hello Free Tier'"
        $lambdaCode | Out-File -FilePath main.py -Encoding ascii
        Compress-Archive -Path main.py -DestinationPath lambda.zip -Force
        
        $account = $identity.Account
        aws lambda create-function --function-name $funcName --runtime python3.12 --role arn:aws:iam::${account}:role/$roleName --handler main.lambda_handler --zip-file fileb://lambda.zip | Out-Null
        
        $createdResources.LambdaRoleName = $roleName
        $createdResources.LambdaName = $funcName
        Write-Host "Created Lambda: $funcName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create Lambda: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($EnableBudget) {
    try {
        Write-Host "Creating AWS Budget..."
        $budgetName = "freetier-budget-$(Get-Random)"
        $account = $identity.Account
        $budgetDef = '{"BudgetName":"' + $budgetName + '","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'
        aws budgets create-budget --account-id $account --budget $budgetDef --notifications-with-subscribers "[]" | Out-Null
        $createdResources.BudgetName = $budgetName
        Write-Host "Created Budget: $budgetName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create Budget: $($_.Exception.Message)" -ForegroundColor Red
    }
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
    aws ec2 terminate-instances --instance-ids $($createdResources.InstanceId) | Out-Null
    Write-Host "Destroyed EC2." -ForegroundColor Green
}

if ($createdResources.RDSId) {
    Write-Host "Deleting RDS Database: $($createdResources.RDSId)..."
    aws rds delete-db-instance --db-instance-identifier $($createdResources.RDSId) --skip-final-snapshot | Out-Null
    Write-Host "Destroyed RDS." -ForegroundColor Green
}

if ($createdResources.LambdaName) {
    Write-Host "Deleting Lambda Function: $($createdResources.LambdaName)..."
    aws lambda delete-function --function-name $($createdResources.LambdaName) | Out-Null
    aws iam delete-role --role-name $($createdResources.LambdaRoleName) | Out-Null
    Write-Host "Destroyed Lambda." -ForegroundColor Green
}

if ($createdResources.BudgetName) {
    Write-Host "Deleting Budget: $($createdResources.BudgetName)..."
    $account = $identity.Account
    aws budgets delete-budget --account-id $account --budget-name $($createdResources.BudgetName) | Out-Null
    Write-Host "Destroyed Budget." -ForegroundColor Green
}

Write-Host "`nAutomation Finished Successfully!" -ForegroundColor Green
