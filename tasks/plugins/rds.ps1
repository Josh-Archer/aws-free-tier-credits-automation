# Task plugin: RDS — create a free-tier MySQL db.t3.micro, then delete it.

function Invoke-TaskRdsCheck {
    aws rds describe-db-instances --max-items 1 --output json | Out-Null
}

function Invoke-TaskRdsProvision {
    Write-Host "Creating RDS Database (db.t3.micro MySQL)..."
    $dbName = "freetier-db-$(Get-Random)"
    if ($null -ne $script:CurrentTaskState) {
        $script:CurrentTaskState["RDSId"] = $dbName
    }
    aws rds create-db-instance `
        --db-instance-identifier $dbName `
        --allocated-storage 20 `
        --engine mysql `
        --engine-version 8.0 `
        --instance-class db.t3.micro `
        --master-username admin `
        --master-user-password "FreeTierPassword123!" `
        --no-publicly-accessible `
        --skip-final-snapshot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create RDS Database: $dbName" -ForegroundColor Red
        if ($null -ne $script:CurrentTaskState) {
            $script:CurrentTaskState.Remove("RDSId")
        }
        throw "Failed to create RDS Database: $dbName"
    }
    Write-Host "Created RDS Database: $dbName" -ForegroundColor Green
    return @{ RDSId = $dbName }
}

function Invoke-TaskRdsCleanup {
    param([hashtable]$State)
    if ($State -and $State.RDSId) {
        Write-Host "Deleting RDS Database: $($State.RDSId)..."
        aws rds delete-db-instance --db-instance-identifier $State.RDSId --skip-final-snapshot | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to delete RDS database: $($State.RDSId)" -ForegroundColor Red
            throw "Failed to delete RDS database: $($State.RDSId)"
        }
        Write-Host "Destroyed RDS." -ForegroundColor Green
    }
}
