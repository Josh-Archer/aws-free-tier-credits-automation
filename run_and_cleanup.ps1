<#
.SYNOPSIS
Provisions resources required to claim the AWS new account free tier credits via modular task plugins, waits, and then destroys them.

.DESCRIPTION
AWS updated its new account Free Tier (as of mid-2025) to provide earned credits for exploration tasks.
Tasks are defined in tasks/catalog.json and implemented under tasks/plugins/*.ps1 so coverage can expand when the program changes.

.PARAMETER EnableEC2
Legacy switch: set to $false to skip EC2. Prefer -Skip / -Only for new task ids.

.PARAMETER EnableRDS
Legacy switch: set to $false to skip RDS.

.PARAMETER EnableLambda
Legacy switch: set to $false to skip Lambda.

.PARAMETER EnableBudget
Legacy switch: set to $false to skip Budget.

.PARAMETER Skip
Array of task ids to skip (e.g. -Skip ec2,rds).

.PARAMETER Only
If set, only these task ids run (e.g. -Only lambda,budget).

.PARAMETER ListTasks
List catalog tasks (id, credit, description, last verified) and exit.

.PARAMETER AutoCheck
Throws a warning that AWS API does not support programmatic checking of promotional credits.
#>

[CmdletBinding()]
param (
    [bool]$EnableEC2 = $true,
    [bool]$EnableRDS = $true,
    [bool]$EnableLambda = $true,
    [bool]$EnableBudget = $true,
    [string[]]$Skip = @(),
    [string[]]$Only = @(),
    [switch]$ListTasks,
    [switch]$AutoCheck,
    [switch]$Sweep,
    [switch]$Confirm,
    [switch]$Yes,
    [switch]$Force,
    [switch]$SkipFinalSnapshot,
    [switch]$SkipRdsSnapshot
)

$ErrorActionPreference = "Stop"

$script:RunId = if ($env:RUN_ID) { $env:RUN_ID } else { "run-$([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$(Get-Random)" }
$env:RUN_ID = $script:RunId
$script:SkipFinalSnapshot = ($SkipFinalSnapshot.IsPresent -or $SkipRdsSnapshot.IsPresent -or ($env:SKIP_FINAL_SNAPSHOT -eq "true"))

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CatalogPath = Join-Path $ScriptDir "tasks\catalog.json"
$PluginsDir = Join-Path $ScriptDir "tasks\plugins"

if (-not (Test-Path $CatalogPath)) {
    Write-Host "Task catalog not found: $CatalogPath" -ForegroundColor Red
    exit 1
}

$catalog = Get-Content -Raw -Path $CatalogPath | ConvertFrom-Json
$allTasks = @($catalog.tasks)

# Plugin function map: id -> @{ Check; Provision; Cleanup }
# Loaded after sourcing plugin files. Ids must match catalog.json.
$script:TaskPluginMap = @{}

# Dot-source each plugin listed in the catalog
foreach ($task in $allTasks) {
    $pluginFile = Join-Path $PluginsDir "$($task.plugin).ps1"
    if (-not (Test-Path $pluginFile)) {
        Write-Host "Missing plugin for task '$($task.id)': $pluginFile" -ForegroundColor Red
        exit 1
    }
    . $pluginFile
}

# Register known plugins (id -> function names). New plugins: add entry here + catalog row + .ps1 file.
$script:TaskPluginMap = @{
    ec2 = @{
        Check     = { Invoke-TaskEc2Check }
        Provision = { Invoke-TaskEc2Provision }
        Cleanup   = { param($s) Invoke-TaskEc2Cleanup -State $s }
    }
    rds = @{
        Check     = { Invoke-TaskRdsCheck }
        Provision = { Invoke-TaskRdsProvision }
        Cleanup   = { param($s) Invoke-TaskRdsCleanup -State $s }
    }
    lambda = @{
        Check     = { Invoke-TaskLambdaCheck }
        Provision = { Invoke-TaskLambdaProvision }
        Cleanup   = { param($s) Invoke-TaskLambdaCleanup -State $s }
    }
    budget = @{
        Check     = { Invoke-TaskBudgetCheck }
        Provision = { Invoke-TaskBudgetProvision }
        Cleanup   = { param($s) Invoke-TaskBudgetCleanup -State $s }
    }
}

function Show-TaskList {
    Write-Host "Program: $($catalog.program)"
    Write-Host "Last verified: $($catalog.last_verified)"
    Write-Host ""
    Write-Host ("{0,-12} {1,-8} {2,-10} {3}" -f "ID", "DEFAULT", "CREDIT", "DESCRIPTION")
    Write-Host ("{0,-12} {1,-8} {2,-10} {3}" -f "------------", "--------", "----------", "-----------")
    foreach ($t in $allTasks) {
        Write-Host ("{0,-12} {1,-8} `${2,-9} {3}" -f $t.id, $t.default_enabled, $t.credit_usd, $t.description)
    }
    Write-Host ""
    Write-Host "Enable/skip: -Skip id1,id2  |  -Only id1,id2  |  legacy -EnableEC2:`$false etc."
}

if ($ListTasks) {
    Show-TaskList
    exit 0
}

if ($AutoCheck) {
    Write-Host "=======================================================" -ForegroundColor Yellow
    Write-Host "AUTO-CHECK LIMITATION" -ForegroundColor Yellow
    Write-Host "=======================================================" -ForegroundColor Yellow
    Write-Host "AWS does not provide a public API or CLI command to retrieve your Promotional Credit balance."
    Write-Host "Please use the AWS Billing Console and -Skip / -Only (or -Enable* flags) to control tasks."
    Write-Host "Catalog last verified: $($catalog.last_verified)"
    Write-Host "=======================================================" -ForegroundColor Yellow
    exit 0
}

# Resolve which tasks are enabled
$enabled = @{}
foreach ($t in $allTasks) {
    $enabled[$t.id] = [bool]$t.default_enabled
}

# Legacy bool flags (keep backward compatibility)
$legacyMap = @{
    ec2    = $EnableEC2
    rds    = $EnableRDS
    lambda = $EnableLambda
    budget = $EnableBudget
}
foreach ($k in $legacyMap.Keys) {
    if ($enabled.ContainsKey($k) -and -not $legacyMap[$k]) {
        $enabled[$k] = $false
    }
}

function Expand-TaskIdArgs {
    param([string[]]$Values)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Values) {
        foreach ($part in ($v -split ',')) {
            $id = $part.Trim()
            if ($id) { $result.Add($id) | Out-Null }
        }
    }
    return ,$result.ToArray()
}

# -Skip takes precedence for listed ids
foreach ($sid in (Expand-TaskIdArgs -Values $Skip)) {
    if (-not $enabled.ContainsKey($sid)) {
        Write-Host "Unknown task id in -Skip: $sid" -ForegroundColor Red
        Write-Host "Known: $($enabled.Keys -join ', ')"
        exit 1
    }
    $enabled[$sid] = $false
}

# -Only: exclusive set
$onlyIds = Expand-TaskIdArgs -Values $Only
if ($onlyIds.Count -gt 0) {
    foreach ($k in @($enabled.Keys)) { $enabled[$k] = $false }
    foreach ($oid in $onlyIds) {
        if (-not $enabled.ContainsKey($oid)) {
            Write-Host "Unknown task id in -Only: $oid" -ForegroundColor Red
            exit 1
        }
        $enabled[$oid] = $true
    }
}

# Validate plugin map coverage for enabled tasks
foreach ($t in $allTasks) {
    if ($enabled[$t.id] -and -not $script:TaskPluginMap.ContainsKey($t.id)) {
        Write-Host "No plugin map entry for enabled task '$($t.id)'. Add it to TaskPluginMap in run_and_cleanup.ps1." -ForegroundColor Red
        exit 1
    }
}

# --- IDENTITY CHECK ---
Write-Host "Verifying AWS CLI Identity..." -ForegroundColor Cyan
try {
    $identity = aws sts get-caller-identity --query "{Account:Account, Arn:Arn}" --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $identity.Account -or -not $identity.Arn) {
        throw "AWS identity is unavailable"
    }
    Write-Host "Account: $($identity.Account)"
    Write-Host "User Arn: $($identity.Arn)"
    Write-Host "Catalog last verified: $($catalog.last_verified)"
} catch {
    Write-Host "Error: Unable to verify AWS identity. Please run 'aws configure' first." -ForegroundColor Red
    exit 1
}

$script:TaskAccountId = $identity.Account

if (-not (Get-Command Remove-TaskIamRole -ErrorAction SilentlyContinue)) {
    function Remove-TaskIamRole {
        param([string]$RoleName)
        if (-not $RoleName) { return }
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
        } catch { }
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
        } catch { }
        aws iam delete-role --role-name $RoleName 2>$null | Out-Null
    }
}

function Invoke-SweepLeftovers {
    param(
        [string]$RunId = "",
        [bool]$IsDryRun = $false
    )

    if ($IsDryRun) {
        Write-Host "Scanning for leftover freetier resources (dry run)..." -ForegroundColor Cyan
    } elseif ($RunId) {
        Write-Host "`nCleaning up leftover resources for run $RunId..." -ForegroundColor Cyan
    } else {
        Write-Host "`nSweeping leftover freetier resources..." -ForegroundColor Cyan
    }

    $foundCount = 0
    $script:SweepErrors = New-Object System.Collections.Generic.List[string]

    # 1. EC2 Instances
    try {
        $filterArgs = if ($RunId) {
            @("--filters", "Name=tag:freetier-run-id,Values=$RunId", "Name=instance-state-name,Values=pending,running,stopping,stopped")
        } else {
            @("--filters", "Name=tag:Name,Values=freetier-*", "Name=instance-state-name,Values=pending,running,stopping,stopped")
        }
        $ec2Raw = aws ec2 describe-instances @filterArgs --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $ec2Raw) {
            $ec2Data = $ec2Raw | ConvertFrom-Json
            if ($ec2Data -and $ec2Data.Reservations) {
                foreach ($res in $ec2Data.Reservations) {
                    foreach ($inst in $res.Instances) {
                        $matches = $false
                        if ($inst.Tags) {
                            foreach ($tag in $inst.Tags) {
                                if ($RunId) {
                                    if ($tag.Key -eq "freetier-run-id" -and $tag.Value -eq $RunId) {
                                        $matches = $true
                                        break
                                    }
                                } else {
                                    if ($tag.Key -eq "Name" -and $tag.Value -and $tag.Value.StartsWith("freetier-")) {
                                        $matches = $true
                                        break
                                    }
                                }
                            }
                        }
                        if ($matches -and $inst.InstanceId) {
                            $foundCount++
                            if ($IsDryRun) {
                                Write-Host "[DRY RUN] Found leftover EC2 Instance: $($inst.InstanceId)" -ForegroundColor Cyan
                            } else {
                                Write-Host "Sweeping leftover EC2 Instance: $($inst.InstanceId)..." -ForegroundColor Cyan
                                aws ec2 terminate-instances --instance-ids $inst.InstanceId | Out-Null
                                if ($LASTEXITCODE -ne 0) {
                                    Write-Host "Failed to terminate leftover EC2 instance: $($inst.InstanceId)" -ForegroundColor Red
                                    $script:SweepErrors.Add("ec2: $($inst.InstanceId)") | Out-Null
                                } else {
                                    Write-Host "Terminated leftover EC2 Instance: $($inst.InstanceId)" -ForegroundColor Green
                                }
                            }
                        }
                    }
                }
            }
        } else {
            $script:SweepErrors.Add("ec2: describe-instances") | Out-Null
        }
    } catch {
        Write-Host "Error sweeping EC2 instances: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:SweepErrors.Add("ec2: $($_.Exception.Message)") | Out-Null
    }

    # 2. RDS Databases
    try {
        $rdsRaw = aws rds describe-db-instances --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $rdsRaw) {
            $rdsData = $rdsRaw | ConvertFrom-Json
            if ($rdsData -and $rdsData.DBInstances) {
                foreach ($db in $rdsData.DBInstances) {
                    if ($db.DBInstanceStatus -eq "deleting") { continue }
                    $matches = $false
                    if ($RunId) {
                        if ($db.TagList) {
                            foreach ($tag in $db.TagList) {
                                if ($tag.Key -eq "freetier-run-id" -and $tag.Value -eq $RunId) {
                                    $matches = $true
                                    break
                                }
                            }
                        }
                    } else {
                        if ($db.DBInstanceIdentifier -and $db.DBInstanceIdentifier.StartsWith("freetier-")) {
                            $matches = $true
                        }
                    }
                    if ($matches -and $db.DBInstanceIdentifier) {
                        $foundCount++
                        if ($IsDryRun) {
                            Write-Host "[DRY RUN] Found leftover RDS Database: $($db.DBInstanceIdentifier)" -ForegroundColor Cyan
                        } else {
                            Write-Host "Sweeping leftover RDS Database: $($db.DBInstanceIdentifier)..." -ForegroundColor Cyan
                            $skipSnap = ($script:SkipFinalSnapshot -or ($env:SKIP_FINAL_SNAPSHOT -eq "true"))
                            if ($skipSnap) {
                                aws rds delete-db-instance --db-instance-identifier $db.DBInstanceIdentifier --skip-final-snapshot | Out-Null
                            } else {
                                $snapId = "$($db.DBInstanceIdentifier)-final-snapshot"
                                aws rds delete-db-instance --db-instance-identifier $db.DBInstanceIdentifier --final-db-snapshot-identifier $snapId | Out-Null
                            }
                            if ($LASTEXITCODE -ne 0) {
                                Write-Host "Failed to delete leftover RDS database: $($db.DBInstanceIdentifier)" -ForegroundColor Red
                                $script:SweepErrors.Add("rds: $($db.DBInstanceIdentifier)") | Out-Null
                            } else {
                                Write-Host "Destroyed leftover RDS Database: $($db.DBInstanceIdentifier)" -ForegroundColor Green
                            }
                        }
                    }
                }
            }
        } else {
            $script:SweepErrors.Add("rds: describe-db-instances") | Out-Null
        }
    } catch {
        Write-Host "Error sweeping RDS databases: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:SweepErrors.Add("rds: $($_.Exception.Message)") | Out-Null
    }

    # 3. Lambda Functions
    try {
        $lambdaRaw = aws lambda list-functions --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $lambdaRaw) {
            $lambdaData = $lambdaRaw | ConvertFrom-Json
            if ($lambdaData -and $lambdaData.Functions) {
                foreach ($fn in $lambdaData.Functions) {
                    if ($fn.FunctionName -and $fn.FunctionName.StartsWith("freetier-")) {
                        $matches = $true
                        if ($RunId) {
                            $matches = $false
                            $tagRaw = aws lambda list-tags --resource $fn.FunctionName --output json 2>$null
                            if ($LASTEXITCODE -eq 0 -and $tagRaw) {
                                $tagData = $tagRaw | ConvertFrom-Json
                                if ($tagData.Tags -and $tagData.Tags."freetier-run-id" -eq $RunId) {
                                    $matches = $true
                                }
                            } else {
                                $script:SweepErrors.Add("lambda tags: $($fn.FunctionName)") | Out-Null
                            }
                        }
                        if ($matches) {
                            $foundCount++
                            if ($IsDryRun) {
                                Write-Host "[DRY RUN] Found leftover Lambda Function: $($fn.FunctionName)" -ForegroundColor Cyan
                            } else {
                                Write-Host "Sweeping leftover Lambda Function: $($fn.FunctionName)..." -ForegroundColor Cyan
                                $delOut = aws lambda delete-function --function-name $fn.FunctionName 2>&1
                                if ($LASTEXITCODE -ne 0) {
                                    $delStr = ($delOut | Out-String)
                                    if ($delStr -notmatch "ResourceNotFoundException") {
                                        Write-Host "Failed to delete leftover Lambda function: $($fn.FunctionName)" -ForegroundColor Red
                                        $script:SweepErrors.Add("lambda: $($fn.FunctionName)") | Out-Null
                                    }
                                } else {
                                    Write-Host "Destroyed leftover Lambda Function: $($fn.FunctionName)" -ForegroundColor Green
                                }
                            }
                        }
                    }
                }
            }
        } else {
            $script:SweepErrors.Add("lambda: list-functions") | Out-Null
        }
    } catch {
        Write-Host "Error sweeping Lambda functions: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:SweepErrors.Add("lambda: $($_.Exception.Message)") | Out-Null
    }

    # 4. IAM Roles
    try {
        $iamRaw = aws iam list-roles --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $iamRaw) {
            $iamData = $iamRaw | ConvertFrom-Json
            if ($iamData -and $iamData.Roles) {
                foreach ($role in $iamData.Roles) {
                    $matches = $false
                    if ($RunId) {
                        if ($role.Tags) {
                            foreach ($tag in $role.Tags) {
                                if ($tag.Key -eq "freetier-run-id" -and $tag.Value -eq $RunId) {
                                    $matches = $true
                                    break
                                }
                            }
                        }
                    } else {
                        if ($role.RoleName -and $role.RoleName.StartsWith("freetier-")) {
                            $matches = $true
                        }
                    }
                    if ($matches -and $role.RoleName) {
                        $foundCount++
                        if ($IsDryRun) {
                            Write-Host "[DRY RUN] Found leftover IAM Role: $($role.RoleName)" -ForegroundColor Cyan
                        } else {
                            Write-Host "Sweeping leftover IAM Role: $($role.RoleName)..." -ForegroundColor Cyan
                            Remove-TaskIamRole -RoleName $role.RoleName
                            if ($LASTEXITCODE -ne 0) {
                                Write-Host "Failed to delete leftover IAM role: $($role.RoleName)" -ForegroundColor Red
                                $script:SweepErrors.Add("iam: $($role.RoleName)") | Out-Null
                            } else {
                                Write-Host "Destroyed leftover IAM Role: $($role.RoleName)" -ForegroundColor Green
                            }
                        }
                    }
                }
            }
        } else {
            $script:SweepErrors.Add("iam: list-roles") | Out-Null
        }
    } catch {
        Write-Host "Error sweeping IAM roles: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:SweepErrors.Add("iam: $($_.Exception.Message)") | Out-Null
    }

    # 5. Budgets
    if ($script:TaskAccountId) {
        try {
            $budgetRaw = aws budgets describe-budgets --account-id $script:TaskAccountId --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $budgetRaw) {
                $budgetData = $budgetRaw | ConvertFrom-Json
                if ($budgetData -and $budgetData.Budgets) {
                    foreach ($b in $budgetData.Budgets) {
                        if ($b.BudgetName -and $b.BudgetName.StartsWith("freetier-")) {
                            $matches = $true
                            if ($RunId) {
                                $matches = $false
                                $bArn = "arn:aws:budgets::$($script:TaskAccountId):budget/$($b.BudgetName)"
                                $bTagRaw = aws budgets list-tags-for-resource --resource-arn $bArn --output json 2>$null
                                if ($LASTEXITCODE -eq 0 -and $bTagRaw) {
                                    $bTagData = $bTagRaw | ConvertFrom-Json
                                    if ($bTagData.ResourceTags) {
                                        foreach ($tag in $bTagData.ResourceTags) {
                                            if ($tag.Key -eq "freetier-run-id" -and $tag.Value -eq $RunId) {
                                                $matches = $true
                                                break
                                            }
                                        }
                                    }
                                } else {
                                    $script:SweepErrors.Add("budget tags: $($b.BudgetName)") | Out-Null
                                }
                            }
                            if ($matches) {
                                $foundCount++
                                if ($IsDryRun) {
                                    Write-Host "[DRY RUN] Found leftover Budget: $($b.BudgetName)" -ForegroundColor Cyan
                                } else {
                                    Write-Host "Sweeping leftover Budget: $($b.BudgetName)..." -ForegroundColor Cyan
                                    aws budgets delete-budget --account-id $script:TaskAccountId --budget-name $b.BudgetName | Out-Null
                                    if ($LASTEXITCODE -ne 0) {
                                        Write-Host "Failed to delete leftover Budget: $($b.BudgetName)" -ForegroundColor Red
                                        $script:SweepErrors.Add("budget: $($b.BudgetName)") | Out-Null
                                    } else {
                                        Write-Host "Destroyed leftover Budget: $($b.BudgetName)" -ForegroundColor Green
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                $script:SweepErrors.Add("budget: describe-budgets") | Out-Null
            }
        } catch {
            Write-Host "Error sweeping Budgets: $($_.Exception.Message)" -ForegroundColor Yellow
            $script:SweepErrors.Add("budget: $($_.Exception.Message)") | Out-Null
        }
    }

    if ($IsDryRun) {
        if ($foundCount -eq 0) {
            Write-Host "No leftover freetier resources found." -ForegroundColor Green
        } else {
            Write-Host "`nDry run complete: Found $foundCount leftover resource(s)." -ForegroundColor Yellow
            Write-Host "To delete these resources, re-run with -Confirm or -Yes." -ForegroundColor Yellow
        }
    }

    return $script:SweepErrors.Count
}

if ($Sweep) {
    $isConfirmed = $Confirm.IsPresent -or $Yes.IsPresent -or $Force.IsPresent
    if (-not $isConfirmed) {
        Write-Host "`nRunning standalone sweep dry run for leftover freetier resources..." -ForegroundColor Cyan
        Invoke-SweepLeftovers -RunId "" -IsDryRun $true | Out-Null
        exit 0
    } else {
        Write-Host "`nRunning standalone sweep for leftover freetier resources (confirmed)..." -ForegroundColor Cyan
        $errCount = Invoke-SweepLeftovers -RunId "" -IsDryRun $false
        if ($errCount -gt 0) {
            Write-Host "`nLeftover sweep completed with $errCount error(s)." -ForegroundColor Red
            exit 1
        }
        Write-Host "`nLeftover sweep completed successfully!" -ForegroundColor Green
        exit 0
    }
}

# --- PRE-FLIGHT PERMISSION CHECK ---
Write-Host "`nRunning Pre-flight Permission Checks..." -ForegroundColor Cyan
$failedChecks = 0

foreach ($t in $allTasks) {
    if (-not $enabled[$t.id]) { continue }
    $plugin = $script:TaskPluginMap[$t.id]
    try {
        & $plugin.Check
        Write-Host "  [OK] $($t.id) Read Permissions" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $($t.id) Read Permissions" -ForegroundColor Red
        $failedChecks++
    }
}

if ($failedChecks -gt 0) {
    Write-Host "`nWarning: $failedChecks permission check(s) failed. If you proceed, the script will likely fail to create resources." -ForegroundColor Yellow
}

$enabledSummary = ($allTasks | ForEach-Object { "$($_.id)=$($enabled[$_.id])" }) -join ", "
Write-Host "`nStarting AWS Free Tier Credit Automation..." -ForegroundColor Cyan
Write-Host "Enabled Tasks: $enabledSummary"

$taskStates = @{}   # id -> state hashtable from provision
$provisionedOrder = New-Object System.Collections.Generic.List[string]
$failedProvisions = New-Object System.Collections.Generic.List[string]
$failedCleanups = New-Object System.Collections.Generic.List[string]
$script:CurrentTaskId = $null
$script:CurrentTaskState = @{}
$script:CleanupPerformed = $false
$currentPhase = "provisioning"
$executionCompleted = $false

function Invoke-CleanupResources {
    if ($script:CleanupPerformed) { return }
    $script:CleanupPerformed = $true

    Write-Host "`n=== CLEANING UP RESOURCES ===" -ForegroundColor Cyan

    if ($script:CurrentTaskId) {
        $inProgId = $script:CurrentTaskId
        $inProgState = $script:CurrentTaskState
        $script:CurrentTaskId = $null
        $script:CurrentTaskState = @{}
        $plugin = $script:TaskPluginMap[$inProgId]
        if ($plugin) {
            try {
                & $plugin.Cleanup $inProgState
            } catch {
                Write-Host "Cleanup error for task '$inProgId': $($_.Exception.Message)" -ForegroundColor Yellow
                if (-not $failedCleanups.Contains($inProgId)) {
                    $failedCleanups.Add($inProgId) | Out-Null
                }
            }
        }
    }

    for ($i = $provisionedOrder.Count - 1; $i -ge 0; $i--) {
        $id = $provisionedOrder[$i]
        $plugin = $script:TaskPluginMap[$id]
        try {
            & $plugin.Cleanup $taskStates[$id]
        } catch {
            Write-Host "Cleanup error for task '$id': $($_.Exception.Message)" -ForegroundColor Yellow
            if (-not $failedCleanups.Contains($id)) {
                $failedCleanups.Add($id) | Out-Null
            }
        }
    }

    $sweepErrorCount = Invoke-SweepLeftovers -RunId $script:RunId -IsDryRun $false
    if ($sweepErrorCount -gt 0 -and -not $failedCleanups.Contains("sweep")) {
        $failedCleanups.Add("sweep") | Out-Null
    }

    # Residual temp files from plugins
    Remove-Item -ErrorAction SilentlyContinue trust-policy.json, main.py, lambda.zip, config.txt, profiles.txt
}

$script:AwsApp = @(Get-Command -CommandType Application aws)[0].Source
$script:InInterruptHandler = $false
function aws {
    & $script:AwsApp @args
    if (-not $script:InInterruptHandler -and ($LASTEXITCODE -eq 130 -or $LASTEXITCODE -eq 143)) {
        $script:InInterruptHandler = $true
        if ($currentPhase -eq "wait") {
            Write-Host "`nInterrupted during wait. Cleaning up provisioned resources..." -ForegroundColor Yellow
        } else {
            Write-Host "`nInterrupted during provisioning. Cleaning up provisioned resources..." -ForegroundColor Yellow
        }
        Invoke-CleanupResources
        [System.Environment]::Exit(130)
        exit 130
    }
}

try {
    # --- PROVISIONING ---
    Write-Host "`n=== PROVISIONING RESOURCES ===" -ForegroundColor Cyan

    foreach ($t in $allTasks) {
        if (-not $enabled[$t.id]) { continue }
        $plugin = $script:TaskPluginMap[$t.id]
        $script:CurrentTaskId = $t.id
        $script:CurrentTaskState = @{}
        try {
            $state = & $plugin.Provision
            if ($null -eq $state) { $state = @{} }
            $taskStates[$t.id] = $state
            $provisionedOrder.Add($t.id) | Out-Null
            $script:CurrentTaskId = $null
            $script:CurrentTaskState = @{}
        } catch {
            Write-Host "Failed to provision task '$($t.id)': $($_.Exception.Message)" -ForegroundColor Red
            if (-not $failedProvisions.Contains($t.id)) {
                $failedProvisions.Add($t.id) | Out-Null
            }
            $inProgState = $script:CurrentTaskState
            $taskStates[$t.id] = $inProgState
            try {
                & $plugin.Cleanup $inProgState
            } catch {
                Write-Host "Cleanup error for task '$($t.id)': $($_.Exception.Message)" -ForegroundColor Yellow
                if (-not $failedCleanups.Contains($t.id)) {
                    $failedCleanups.Add($t.id) | Out-Null
                }
            }
            $script:CurrentTaskId = $null
            $script:CurrentTaskState = @{}
        }
    }

    # --- WAITING ---
    $currentPhase = "wait"
    Write-Host "`n=======================================================" -ForegroundColor Yellow
    Write-Host "Provisioning phase complete!"
    Write-Host "Waiting 3 minutes for AWS to register the activity..." -ForegroundColor Yellow

    $waitSeconds = if ($env:WAIT_SECONDS) { [int]$env:WAIT_SECONDS } else { 180 }
    Start-Sleep -Seconds $waitSeconds
    Write-Host "=======================================================" -ForegroundColor Yellow

    # --- CLEANUP ---
    $currentPhase = "cleanup"
    Invoke-CleanupResources

    $executionCompleted = $true
} finally {
    if (-not $executionCompleted) {
        if ($currentPhase -eq "wait") {
            Write-Host "`nInterrupted during wait. Cleaning up provisioned resources..." -ForegroundColor Yellow
        } else {
            Write-Host "`nInterrupted during provisioning. Cleaning up provisioned resources..." -ForegroundColor Yellow
        }
        Invoke-CleanupResources
        [System.Environment]::Exit(130)
        exit 130
    }
}

if ($failedProvisions.Count -gt 0 -or $failedCleanups.Count -gt 0) {
    Write-Host "`n=== AUTOMATION SUMMARY: FAILURE ===" -ForegroundColor Red
    if ($failedProvisions.Count -gt 0) {
        Write-Host "Provisioning failed for: $($failedProvisions -join ', ')" -ForegroundColor Red
    }
    if ($failedCleanups.Count -gt 0) {
        Write-Host "Cleanup failed for: $($failedCleanups -join ', ')" -ForegroundColor Red
        Write-Host "The following resources may still exist in your account:" -ForegroundColor Red
        foreach ($id in $failedCleanups) {
            $state = $taskStates[$id]
            if ($state -and $state.Count -gt 0) {
                $details = ($state.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ", "
                Write-Host "  - Task $id ($details)" -ForegroundColor Red
            } else {
                Write-Host "  - Task $id" -ForegroundColor Red
            }
        }
    }
    exit 1
}

Write-Host "`nAutomation Finished Successfully!" -ForegroundColor Green
