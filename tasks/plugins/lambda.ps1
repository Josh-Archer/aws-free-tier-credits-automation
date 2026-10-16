# Task plugin: Lambda — create IAM role + Python function, then delete both.
# Requires: $script:TaskAccountId (set by runner)

function Invoke-TaskLambdaCheck {
    aws lambda list-functions --max-items 1 --output json | Out-Null
}

function Invoke-TaskLambdaProvision {
    Write-Host "Creating Lambda Role and Function..."
    $roleName = "freetier-role-$(Get-Random)"
    $funcName = "freetier-func-$(Get-Random)"
    $runId = if ($script:RunId) { $script:RunId } elseif ($env:RUN_ID) { $env:RUN_ID } else { "run-$(Get-Random)" }

    if ($null -ne $script:CurrentTaskState) {
        $script:CurrentTaskState["LambdaRoleName"] = $roleName
    }

    $trustPolicy = '{"Version": "2012-10-17","Statement": [{"Action": "sts:AssumeRole","Principal": {"Service": "lambda.amazonaws.com"},"Effect": "Allow"}]}'
    $trustPolicy | Out-File -FilePath trust-policy.json -Encoding ascii
    aws iam create-role --role-name $roleName --assume-role-policy-document file://trust-policy.json --tags "Key=freetier-run-id,Value=$runId" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -ErrorAction SilentlyContinue trust-policy.json
        if ($null -ne $script:CurrentTaskState) {
            $script:CurrentTaskState.Remove("LambdaRoleName")
        }
        throw "Failed to create IAM role: $roleName"
    }

    # Wait for role to propagate
    $roleWait = if ($env:LAMBDA_ROLE_WAIT) { [int]$env:LAMBDA_ROLE_WAIT } else { 10 }
    Start-Sleep -Seconds $roleWait

    $lambdaCode = "def lambda_handler(event, context): return 'Hello Free Tier'"
    $lambdaCode | Out-File -FilePath main.py -Encoding ascii
    Compress-Archive -Path main.py -DestinationPath lambda.zip -Force

    $account = $script:TaskAccountId
    if ($null -ne $script:CurrentTaskState) {
        $script:CurrentTaskState["LambdaName"] = $funcName
    }

    aws lambda create-function `
        --function-name $funcName `
        --runtime python3.12 `
        --role "arn:aws:iam::${account}:role/$roleName" `
        --handler main.lambda_handler `
        --tags "freetier-run-id=$runId" `
        --zip-file fileb://lambda.zip | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create Lambda function: $funcName" -ForegroundColor Red
        if ($null -ne $script:CurrentTaskState) {
            $script:CurrentTaskState.Remove("LambdaName")
        }
        try {
            Invoke-TaskLambdaCleanup -State $script:CurrentTaskState
        } catch {
        }
        throw "Failed to create Lambda function: $funcName"
    }

    Write-Host "Created Lambda: $funcName" -ForegroundColor Green
    return @{ LambdaRoleName = $roleName; LambdaName = $funcName }
}

function Remove-TaskIamRole {
    param([string]$RoleName)
    if (-not $RoleName) { return }

    # 1. Detach attached policies
    try {
        $attachedRaw = aws iam list-attached-role-policies --role-name $RoleName --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $attachedRaw) {
            $attachedData = $attachedRaw | ConvertFrom-Json
            if ($attachedData -and $attachedData.AttachedPolicies) {
                foreach ($pol in $attachedData.AttachedPolicies) {
                    if ($pol.PolicyArn) {
                        Write-Host "Detaching policy $($pol.PolicyArn) from role $RoleName..." -ForegroundColor Cyan
                        aws iam detach-role-policy --role-name $RoleName --policy-arn $pol.PolicyArn 2>$null | Out-Null
                    }
                }
            }
        }
    } catch {
    }

    # 2. Delete inline policies
    try {
        $inlineRaw = aws iam list-role-policies --role-name $RoleName --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $inlineRaw) {
            $inlineData = $inlineRaw | ConvertFrom-Json
            if ($inlineData -and $inlineData.PolicyNames) {
                foreach ($pName in $inlineData.PolicyNames) {
                    if ($pName) {
                        Write-Host "Deleting inline policy $pName from role $RoleName..." -ForegroundColor Cyan
                        aws iam delete-role-policy --role-name $RoleName --policy-name $pName 2>$null | Out-Null
                    }
                }
            }
        }
    } catch {
    }

    # 3. Delete role
    aws iam delete-role --role-name $RoleName 2>$null | Out-Null
}

function Invoke-TaskLambdaCleanup {
    param([hashtable]$State)
    $cleaned = $false
    $failed = $false
    $errors = New-Object System.Collections.Generic.List[string]

    if ($State -and $State.LambdaName) {
        Write-Host "Deleting Lambda Function: $($State.LambdaName)..."
        $delOut = aws lambda delete-function --function-name $State.LambdaName 2>&1
        $ec = $LASTEXITCODE
        if ($ec -ne 0) {
            $delStr = ($delOut | Out-String)
            if ($delStr -match "ResourceNotFoundException") {
                $State.Remove("LambdaName")
                $cleaned = $true
            } else {
                Write-Host "Failed to delete Lambda function: $($State.LambdaName)" -ForegroundColor Red
                $failed = $true
                $errors.Add("Failed to delete Lambda function: $($State.LambdaName)") | Out-Null
            }
        } else {
            $State.Remove("LambdaName")
            $cleaned = $true
        }
    }
    if ($State -and $State.LambdaRoleName) {
        Write-Host "Deleting IAM Role: $($State.LambdaRoleName)..."
        Remove-TaskIamRole -RoleName $State.LambdaRoleName
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to delete IAM role: $($State.LambdaRoleName)" -ForegroundColor Red
            $failed = $true
            $errors.Add("Failed to delete IAM role: $($State.LambdaRoleName)") | Out-Null
        } else {
            $State.Remove("LambdaRoleName")
            $cleaned = $true
        }
    }
    Remove-Item -ErrorAction SilentlyContinue trust-policy.json, main.py, lambda.zip
    if ($failed) {
        $msg = if ($errors.Count -gt 0) { $errors -join "; " } else { "Failed to clean up Lambda resources" }
        throw $msg
    }
    if ($cleaned) {
        Write-Host "Destroyed Lambda." -ForegroundColor Green
    }
}
