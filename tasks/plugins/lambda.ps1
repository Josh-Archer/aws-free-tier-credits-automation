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

    # Wait for role to propagate
    Start-Sleep -Seconds 10

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

    Write-Host "Created Lambda: $funcName" -ForegroundColor Green
    return @{ LambdaRoleName = $roleName; LambdaName = $funcName }
}

function Invoke-TaskLambdaCleanup {
    param([hashtable]$State)
    if ($State.LambdaName) {
        Write-Host "Deleting Lambda Function: $($State.LambdaName)..."
        aws lambda delete-function --function-name $State.LambdaName | Out-Null
        if ($State.LambdaRoleName) {
            aws iam delete-role --role-name $State.LambdaRoleName | Out-Null
        }
        Write-Host "Destroyed Lambda." -ForegroundColor Green
    }
    Remove-Item -ErrorAction SilentlyContinue trust-policy.json, main.py, lambda.zip
}
