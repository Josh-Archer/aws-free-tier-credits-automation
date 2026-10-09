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
    [switch]$AutoCheck
)

$ErrorActionPreference = "Stop"

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
    Write-Host "Account: $($identity.Account)"
    Write-Host "User Arn: $($identity.Arn)"
    Write-Host "Catalog last verified: $($catalog.last_verified)"
} catch {
    Write-Host "Error: Unable to verify AWS identity. Please run 'aws configure' first." -ForegroundColor Red
    exit 1
}

$script:TaskAccountId = $identity.Account

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
$currentPhase = "provisioning"
$executionCompleted = $false

function Invoke-CleanupResources {
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

    # Residual temp files from plugins
    Remove-Item -ErrorAction SilentlyContinue trust-policy.json, main.py, lambda.zip, config.txt, profiles.txt
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
