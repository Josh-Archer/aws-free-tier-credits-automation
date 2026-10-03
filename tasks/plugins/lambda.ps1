# Task plugin: Lambda — create IAM role + Python function, then delete both.
# Requires: $script:TaskAccountId (set by runner)

function Invoke-TaskLambdaCheck {
    aws lambda list-functions --max-items 1 --output json | Out-Null
}

function Invoke-TaskLambdaProvision {
    Write-Host "Creating Lambda Role and Function..."
    $roleName = "freetier-role-$(Get-Random)"
    $funcName = "freetier-func-$(Get-Random)"

    $trustPolicy = '{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    $trustPolicy | Out-File -FilePath trust-policy.json -Encoding ascii
    aws iam create-role --role-name $roleName --assume-role-policy-document file://trust-policy.json | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -ErrorAction SilentlyContinue trust-policy.json
        throw "Failed to create IAM role: $roleName"
    }

    # Wait for role to propagate
    $roleWait = if ($env:LAMBDA_ROLE_WAIT) { [int]$env:LAMBDA_ROLE_WAIT } else { 10 }
    Start-Sleep -Seconds $roleWait

    $lambdaCode = "def lambda_handler(event, context): return 'Hello Free Tier'"
    $lambdaCode | Out-File -FilePath main.py -Encoding ascii
    Compress-Archive -Path main.py -DestinationPath lambda.zip -Force

    $account = $script:TaskAccountId
    aws lambda create-function `
        --function-name $funcName `
        --runtime python3.12 `
        --role "arn:aws:iam::${account}:role/$roleName" `
        --handler main.lambda_handler `
        --zip-file fileb://lambda.zip | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create Lambda function: $funcName" -ForegroundColor Red
        Invoke-TaskLambdaCleanup -State @{ LambdaRoleName = $roleName }
        throw "Failed to create Lambda function: $funcName"
    }

    Write-Host "Created Lambda: $funcName" -ForegroundColor Green
    return @{ LambdaRoleName = $roleName; LambdaName = $funcName }
}

function Invoke-TaskLambdaCleanup {
    param([hashtable]$State)
    $cleaned = $false
    if ($State -and $State.LambdaName) {
        Write-Host "Deleting Lambda Function: $($State.LambdaName)..."
        aws lambda delete-function --function-name $State.LambdaName | Out-Null
        $cleaned = $true
    }
    if ($State -and $State.LambdaRoleName) {
        Write-Host "Deleting IAM Role: $($State.LambdaRoleName)..."
        aws iam delete-role --role-name $State.LambdaRoleName | Out-Null
        $cleaned = $true
    }
    if ($cleaned) {
        Write-Host "Destroyed Lambda." -ForegroundColor Green
    }
    Remove-Item -ErrorAction SilentlyContinue trust-policy.json, main.py, lambda.zip
}
