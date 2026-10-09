# Task plugin: AWS Budgets — create a small monthly cost budget, then delete it.
# Requires: $script:TaskAccountId (set by runner)

function Invoke-TaskBudgetCheck {
    aws budgets describe-budgets --account-id $script:TaskAccountId --max-items 1 --output json | Out-Null
}

function Invoke-TaskBudgetProvision {
    Write-Host "Creating AWS Budget..."
    $budgetName = "freetier-budget-$(Get-Random)"
    if ($null -ne $script:CurrentTaskState) {
        $script:CurrentTaskState["BudgetName"] = $budgetName
    }
    $account = $script:TaskAccountId
    $budgetDef = '{"BudgetName":"' + $budgetName + '","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'
    aws budgets create-budget --account-id $account --budget $budgetDef --notifications-with-subscribers "[]" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create Budget: $budgetName" -ForegroundColor Red
        if ($null -ne $script:CurrentTaskState) {
            $script:CurrentTaskState.Remove("BudgetName")
        }
        throw "Failed to create Budget: $budgetName"
    }
    Write-Host "Created Budget: $budgetName" -ForegroundColor Green
    return @{ BudgetName = $budgetName }
}

function Invoke-TaskBudgetCleanup {
    param([hashtable]$State)
    if ($State -and $State.BudgetName) {
        Write-Host "Deleting Budget: $($State.BudgetName)..."
        $account = $script:TaskAccountId
        aws budgets delete-budget --account-id $account --budget-name $State.BudgetName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to delete Budget: $($State.BudgetName)" -ForegroundColor Red
            throw "Failed to delete Budget: $($State.BudgetName)"
        }
        Write-Host "Destroyed Budget." -ForegroundColor Green
    }
}
