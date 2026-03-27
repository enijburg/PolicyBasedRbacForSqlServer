<#
.SYNOPSIS
    Full deployment wrapper for PolicyBasedRbacForSqlDatabase.

.DESCRIPTION
    Performs all three deployment phases in order:
      1. Ensure Entra ID security groups exist (idempotent - skips creation if already present)
      2. Deploy all Azure resources via az stack sub create
      3. Add the UAMI to SqlDbAdmins (idempotent - skips if already a member)

    This ensures the critical UAMI group membership step is never forgotten.

.PARAMETER StackName
    Name of the deployment stack. Defaults to 'PolicyBasedRbacDeployStack'.

.PARAMETER Location
    Azure region for the stack metadata and resources. Defaults to 'northeurope'.

.PARAMETER TemplateFile
    Path to the Bicep template. Defaults to 'infra/main.bicep'.

.PARAMETER ParametersFile
    Path to the Bicep parameters file. Defaults to 'infra/main.bicepparam'.

.EXAMPLE
    ./deploy.ps1

.EXAMPLE
    ./deploy.ps1 -StackName MyStack -Location westeurope
#>
[CmdletBinding()]
param(
    [string]$StackName     = 'PolicyBasedRbacDeployStack',
    [string]$Location      = 'northeurope',
    [string]$TemplateFile  = 'infra/main.bicep',
    [string]$ParametersFile = 'infra/main.bicepparam'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$msg) {
    Write-Host "`n=== $msg ===" -ForegroundColor Cyan
}

function Assert-ExitCode([string]$operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$operation failed (exit code $LASTEXITCODE). Check the error output above."
    }
}

function Ensure-Group([string]$displayName, [string]$description) {
    $existing = az ad group show --group $displayName --query id --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) {
        Write-Host "  Group '$displayName' already exists ($existing)" -ForegroundColor Green
        return $existing
    }

    Write-Host "  Creating group '$displayName'..." -ForegroundColor Yellow
    $body = @{
        displayName     = $displayName
        mailEnabled     = $false
        mailNickname    = $displayName -replace '\s',''
        securityEnabled = $true
        description     = $description
    } | ConvertTo-Json
    $tmpFile = [System.IO.Path]::GetTempFileName()
    $body | Out-File $tmpFile -Encoding utf8

    $result = az rest --method POST `
        --uri "https://graph.microsoft.com/v1.0/groups" `
        --headers "Content-Type=application/json" `
        --body "@$tmpFile" `
        --output json | ConvertFrom-Json
    Remove-Item $tmpFile -ErrorAction SilentlyContinue

    if (-not $result.id) { throw "Failed to create group '$displayName'" }
    Write-Host "  Created '$displayName' ($($result.id))" -ForegroundColor Green
    return $result.id
}

# ---------------------------------------------------------------------------
# Pre-flight: Verify the caller has sufficient Graph API permissions
# ---------------------------------------------------------------------------
Write-Step "Pre-flight: Checking Entra ID permissions"

$whoami = az ad signed-in-user show --query "{upn: userPrincipalName, id: id}" --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Cannot query signed-in user. Are you logged in? Run 'az login' first."
}
$signedInUser = $whoami | ConvertFrom-Json
Write-Host "  Signed in as: $($signedInUser.upn)"

# Phase 4 requires granting an Entra ID directory role, which needs
# Global Administrator or Privileged Role Administrator.
# But if the MI already has the role, no elevated permissions are needed.
$sqlServerParam = (Get-Content $ParametersFile -Raw)
$needsDirectoryRoleGrant = $sqlServerParam -match "param sqlServerName\s*=\s*'([^']+)'" -and $Matches[1] -ne ''
$skipPhase4 = $false

if ($needsDirectoryRoleGrant) {
    # First check whether the SQL Server MI already has Directory Readers.
    # Query from the service principal's memberOf — any authenticated user can read this,
    # unlike listing directoryRole members which may require admin permissions.
    $directoryReadersTemplateId = '88d8e3e3-8f55-4a1e-953a-9b9898b8876b'
    $miAlreadyHasRole = $false
    $peekMiId = az stack sub show --name $StackName --query "outputs.sqlServerPrincipalId.value" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $peekMiId) {
        $miRolesJson = az rest --method GET `
            --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$peekMiId/memberOf/microsoft.graph.directoryRole" `
            --query "value[?roleTemplateId=='$directoryReadersTemplateId']" `
            --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $miRolesJson) {
            $miAlreadyHasRole = (($miRolesJson | ConvertFrom-Json) | Measure-Object).Count -gt 0
        }
    }

    if ($miAlreadyHasRole) {
        Write-Host "  SQL Server MI already has Directory Readers — no elevated permissions needed" -ForegroundColor Green
        $skipPhase4 = 'already-granted'
    }
    else {
        # MI doesn't have the role yet (or we can't tell). Check caller's admin roles.
        $myRolesJson = az rest --method GET `
            --uri "https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole" `
            --query "value[].{name: displayName, templateId: roleTemplateId}" `
            --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not verify Entra ID admin roles for current user. Phase 4 may fail if permissions are insufficient."
        }
        else {
            $myRoles = $myRolesJson | ConvertFrom-Json
            # Global Administrator: 62e90394-69f5-4237-9190-012177145e10
            # Privileged Role Administrator: e8611ab8-c189-46e8-94e1-60213ab1f814
            $hasGlobalAdmin = $myRoles | Where-Object { $_.templateId -eq '62e90394-69f5-4237-9190-012177145e10' }
            $hasPrivRoleAdmin = $myRoles | Where-Object { $_.templateId -eq 'e8611ab8-c189-46e8-94e1-60213ab1f814' }
            if ($hasGlobalAdmin -or $hasPrivRoleAdmin) {
                Write-Host "  Entra ID admin role: OK (can grant Directory Readers)" -ForegroundColor Green
            }
            else {
                $skipPhase4 = $true
                Write-Host ""
                Write-Host "  WARNING: Insufficient Entra ID privileges — Phase 4 will be skipped" -ForegroundColor Yellow
                Write-Host "  -----------------------------------------------------------------------" -ForegroundColor Yellow
                Write-Host "  Signed-in user : $($signedInUser.upn)" -ForegroundColor Yellow
                if ($myRoles.Count -eq 0) {
                    Write-Host "  Current roles  : (none)" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  Current roles  : $($myRoles.name -join ', ')" -ForegroundColor Yellow
                }
                Write-Host "  Required role  : Global Administrator or Privileged Role Administrator" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Phase 4 grants the 'Directory Readers' Entra ID role to the SQL Server's" -ForegroundColor Yellow
                Write-Host "  managed identity. Without it, the SQL Server cannot resolve AAD group" -ForegroundColor Yellow
                Write-Host "  memberships at login time." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  After deployment completes, ask a Global Admin to paste this into Azure Cloud Shell (Bash):" -ForegroundColor Yellow
                Write-Host ""
                # Build a bash-compatible script that can be pasted directly into Cloud Shell.
                $snippet = @"
# Grant Directory Readers to SQL Server managed identity
# Paste into Azure Cloud Shell (Bash) as Global Administrator or Privileged Role Administrator
SQL_MI_ID=`$(az stack sub show --name '$StackName' --query "outputs.sqlServerPrincipalId.value" -o tsv)
DR_TEMPLATE_ID='88d8e3e3-8f55-4a1e-953a-9b9898b8876b'
ROLE_ID=`$(az rest --method GET --uri "https://graph.microsoft.com/v1.0/directoryRoles?\`$filter=roleTemplateId eq '`$DR_TEMPLATE_ID'" -o json | jq -r '.value[0].id')
az rest --method POST --uri "https://graph.microsoft.com/v1.0/directoryRoles/`$ROLE_ID/members/\`$ref" --headers "Content-Type=application/json" --body "{\"@odata.id\": \"https://graph.microsoft.com/v1.0/directoryObjects/`$SQL_MI_ID\"}"
echo "Done — Directory Readers granted to SQL Server MI `$SQL_MI_ID"
"@
                $snippet.Split([Environment]::NewLine) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                Write-Host ""
            }
        }
    }
}
else {
    Write-Host "  No SQL Server being deployed — Directory Readers grant not needed" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase 1: Ensure Entra ID groups exist
# ---------------------------------------------------------------------------
Write-Step "Phase 1: Ensure Entra ID security groups"

# Read group names from the parameters file (avoids duplicating values here)
$paramContent = Get-Content $ParametersFile -Raw
$adminGroupName = if ($paramContent -match "param aadAdminGroupName\s*=\s*'([^']+)'") { $Matches[1] } else { 'SqlDbAdmins' }
$usersGroupName = if ($paramContent -match "param aadUserGroupName\s*=\s*'([^']+)'")  { $Matches[1] } else { 'SqlDbUsers' }

$adminGroupId = Ensure-Group -displayName $adminGroupName -description "Group for SQL Server administrators"
$usersGroupId = Ensure-Group -displayName $usersGroupName -description "Group for SQL database users (db_datareader)"

# Update aadAdminGroupObjectId in the parameters file if the group was just created
# or if the stored ID differs from the current one (e.g. re-created after deletion)
$currentObjectId = if ($paramContent -match "param aadAdminGroupObjectId\s*=\s*'([^']+)'") { $Matches[1] } else { '' }
if ($currentObjectId -ne $adminGroupId) {
    Write-Host "  Updating aadAdminGroupObjectId in $ParametersFile..." -ForegroundColor Yellow
    $newContent = $paramContent -replace "(param aadAdminGroupObjectId\s*=\s*')[^']+(')", "`${1}$adminGroupId`${2}"
    Set-Content $ParametersFile -Value $newContent -Encoding utf8 -NoNewline
    Write-Host "  Updated to $adminGroupId" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase 2: Deploy Azure resources
# ---------------------------------------------------------------------------
Write-Step "Phase 2: Deploy Azure resources (az stack sub create)"

# Start the deployment without blocking, then poll for completion so that
# progress is visible instead of the terminal appearing to hang.
az stack sub create `
    --name $StackName `
    --location $Location `
    --template-file $TemplateFile `
    --parameters $ParametersFile `
    --action-on-unmanage 'detachAll' `
    --deny-settings-mode 'none' `
    --yes `
    --no-wait

if ($LASTEXITCODE -ne 0) {
    throw "Failed to start deployment (exit code $LASTEXITCODE)"
}

Write-Host "  Deployment started — polling every 15 s..." -ForegroundColor Yellow
$pollInterval = 15
$startTime    = [System.Diagnostics.Stopwatch]::StartNew()
while ($true) {
    Start-Sleep -Seconds $pollInterval
    $elapsed = [math]::Floor($startTime.Elapsed.TotalMinutes)
    $stateJson = az stack sub show --name $StackName --output json 2>$null
    if (-not $stateJson) {
        Write-Host "  [$elapsed min] Stack not yet visible — waiting..."
        continue
    }
    $state = ($stateJson | ConvertFrom-Json).provisioningState
    Write-Host "  [$elapsed min] $state"
    if ($state -eq 'succeeded') { break }
    if ($state -in @('failed', 'canceled', 'cancelled')) {
        throw "Deployment stack ended with state '$state'. Check the Azure portal for details."
    }
}

# ---------------------------------------------------------------------------
# Phase 3: Add UAMI to admin group (idempotent)
# ---------------------------------------------------------------------------
Write-Step "Phase 3: Add managed identity to '$adminGroupName'"

$uamiPrincipalId = az stack sub show `
    --name $StackName `
    --query "outputs.managedIdentityPrincipalId.value" `
    --output tsv

if (-not $uamiPrincipalId) {
    throw "Could not retrieve managedIdentityPrincipalId from deployment outputs"
}
Write-Host "  UAMI principal ID: $uamiPrincipalId"

$isMember = az ad group member check `
    --group $adminGroupName `
    --member-id $uamiPrincipalId `
    --query value `
    --output tsv

if ($isMember -eq 'true') {
    Write-Host "  UAMI is already a member of '$adminGroupName'" -ForegroundColor Green
}
else {
    az ad group member add --group $adminGroupName --member-id $uamiPrincipalId
    Write-Host "  Added UAMI to '$adminGroupName'" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase 4: Grant Directory Readers to SQL Server system-assigned identity
# ---------------------------------------------------------------------------
# The SQL server needs Directory Readers in Entra ID to resolve AAD group memberships
# at login time (e.g. checking whether a token belongs to SqlDbAdmins/SqlDbUsers).
# This cannot be done in Bicep — it is an Entra ID directory role, not an Azure RBAC role.
Write-Step "Phase 4: Grant Directory Readers to SQL Server managed identity"

if ($skipPhase4 -eq 'already-granted') {
    Write-Host "  SQL Server MI already has Directory Readers — nothing to do" -ForegroundColor Green
}
elseif ($skipPhase4) {
    Write-Host "  Skipped — insufficient Entra ID privileges (see pre-flight warning above)" -ForegroundColor Yellow
}
else {

$sqlPrincipalId = az stack sub show `
    --name $StackName `
    --query "outputs.sqlServerPrincipalId.value" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($sqlPrincipalId)) {
    Write-Host "  No SQL Server deployed (sqlServerName is empty) — skipping." -ForegroundColor Yellow
}
else {
    Write-Host "  SQL Server MI principal ID: $sqlPrincipalId"

    # Directory Readers well-known role template ID (stable across all tenants)
    $directoryReadersTemplateId = '88d8e3e3-8f55-4a1e-953a-9b9898b8876b'

    # Activate the role in this tenant if not already active
    $roleJson = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/directoryRoles?`$filter=roleTemplateId eq '$directoryReadersTemplateId'" `
        --output json 2>&1
    $role = ($roleJson | ConvertFrom-Json).value | Select-Object -First 1

    if (-not $role) {
        Write-Host "  Activating Directory Readers role in tenant..." -ForegroundColor Yellow
        $activateFile = [System.IO.Path]::GetTempFileName()
        @{ roleTemplateId = $directoryReadersTemplateId } | ConvertTo-Json | Set-Content $activateFile -Encoding utf8
        $role = az rest --method POST `
            --uri "https://graph.microsoft.com/v1.0/directoryRoles" `
            --headers "Content-Type=application/json" `
            --body "@$activateFile" `
            --output json | ConvertFrom-Json
        Remove-Item $activateFile -ErrorAction SilentlyContinue
        Assert-ExitCode "Activating Directory Readers role"
    }

    $roleId = $role.id
    Write-Host "  Directory Readers role ID: $roleId"

    # Check if SQL server MI is already a member (query from MI's perspective — works for any user)
    $miMemberOfJson = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$sqlPrincipalId/memberOf/microsoft.graph.directoryRole" `
        --query "value[?roleTemplateId=='$directoryReadersTemplateId']" `
        --output json 2>&1
    $alreadyMember = if ($LASTEXITCODE -eq 0 -and $miMemberOfJson) { (($miMemberOfJson | ConvertFrom-Json) | Measure-Object).Count -gt 0 } else { $false }

    if ($alreadyMember) {
        Write-Host "  SQL Server MI already has Directory Readers" -ForegroundColor Green
    }
    else {
        $refFile = [System.IO.Path]::GetTempFileName()
        @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$sqlPrincipalId" } | ConvertTo-Json | Set-Content $refFile -Encoding utf8
        az rest --method POST `
            --uri "https://graph.microsoft.com/v1.0/directoryRoles/$roleId/members/`$ref" `
            --headers "Content-Type=application/json" `
            --body "@$refFile"
        Remove-Item $refFile -ErrorAction SilentlyContinue
        Assert-ExitCode "Granting Directory Readers to SQL Server MI"
        Write-Host "  Granted Directory Readers to SQL Server MI" -ForegroundColor Green
    }
}

} # end skipPhase4 else

Write-Host "`nDeployment complete." -ForegroundColor Cyan
