<#
.SYNOPSIS
    Enumerates Management Groups and Subscriptions for an Entra ID / Azure tenant,
    and emits them in the managementGroupIds / subscriptionIds JSON shape.

.DESCRIPTION
    Given a Tenant ID, this script:
      1. Connects to Azure using the Az PowerShell module.
      2. Looks for the Tenant Root Management Group (ID == Tenant ID). If visible,
         that single ID is the preferred scope — it covers every current and future
         subscription in the tenant, so subscriptionIds is left empty.
      3. If the tenant root isn't visible (common — it requires elevated access),
         falls back to listing every top-level Management Group you *can* see.
      4. Always also collects the full subscription list, so you have the fallback
         data even if you decide to use the management group path.
      5. Prints ready-to-paste JSON matching the target config shape.

.PARAMETER TenantId
    The Entra ID tenant GUID.

.PARAMETER SubscriptionsOnly
    Skip management group enumeration entirely and just list subscriptions.

.NOTES
    Requires: Az.Accounts, Az.Resources modules.
    Requires: Reader (or higher) at the Management Group scope you want to see.
              Seeing the Tenant Root Management Group specifically requires being
              added as a Management Group Reader (or similar) at the root scope —
              this is a separate grant from subscription-level RBAC and typically
              needs a Global Administrator (via "Elevate access" in Entra ID) or an
              existing root MG owner to assign it.

.EXAMPLE
    .\Get-EntraScopeIds.ps1 -TenantId "00000000-0000-0000-0000-000000000000"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [switch]$SubscriptionsOnly
)

# --- Ensure required modules are present ---
foreach ($mod in @('Az.Accounts', 'Az.Resources')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing missing module: $mod" -ForegroundColor Yellow
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module Az.Accounts
Import-Module Az.Resources

# --- Connect ---
Write-Host "Connecting to tenant $TenantId ..." -ForegroundColor Cyan
Connect-AzAccount -TenantId $TenantId | Out-Null

$managementGroupIds = @()
$subscriptionIds    = @()

# --- Subscriptions (always collected — used as output if no MG, and as a sanity check either way) ---
Write-Host "Enumerating subscriptions..." -ForegroundColor Cyan
$subs = Get-AzSubscription -TenantId $TenantId | Where-Object { $_.State -eq 'Enabled' }
Write-Host "  Found $($subs.Count) enabled subscription(s):" -ForegroundColor Green
$subs | ForEach-Object { Write-Host "    - $($_.Id)  ($($_.Name))" }

# --- Management groups ---
if (-not $SubscriptionsOnly) {
    Write-Host "`nChecking for the Tenant Root Management Group..." -ForegroundColor Cyan
    try {
        $rootMG = Get-AzManagementGroup -GroupId $TenantId -ErrorAction Stop
        Write-Host "  Tenant Root Management Group is visible (ID: $TenantId)." -ForegroundColor Green
        Write-Host "  This single ID covers the whole tenant, including future subscriptions." -ForegroundColor Green
        $managementGroupIds = @($TenantId)
    }
    catch {
        Write-Host "  Tenant Root Management Group not visible to this identity." -ForegroundColor Yellow
        Write-Host "  (Needs Management Group Reader at root scope — typically granted via" -ForegroundColor Yellow
        Write-Host "   Entra ID 'Elevate access', or by an existing root MG owner.)" -ForegroundColor Yellow

        Write-Host "`n  Falling back to enumerating whatever management groups ARE visible..." -ForegroundColor Cyan
        $allMGs = Get-AzManagementGroup -ErrorAction SilentlyContinue

        if ($allMGs) {
            # A group is "top-level" (from what we can see) if it isn't listed as a
            # child of any other group in this result set.
            $childIds = @()
            foreach ($mg in $allMGs) {
                $expanded = Get-AzManagementGroup -GroupId $mg.Name -Expand -ErrorAction SilentlyContinue
                if ($expanded.Children) {
                    $childIds += $expanded.Children |
                        Where-Object { $_.Type -eq 'Microsoft.Management/managementGroups' } |
                        ForEach-Object { ($_.Id -split '/')[-1] }
                }
            }
            $topLevel = $allMGs | Where-Object { $_.Name -notin $childIds }

            if ($topLevel) {
                Write-Host "  Top-level management group(s) visible to this identity:" -ForegroundColor Green
                $topLevel | ForEach-Object { Write-Host "    - $($_.Name)  ($($_.DisplayName))" }
                $managementGroupIds = @($topLevel.Name)
                Write-Host "  NOTE: these may not cover every subscription in the tenant —" -ForegroundColor Yellow
                Write-Host "  only what's under these groups. Verify coverage before relying on this." -ForegroundColor Yellow
            }
            else {
                Write-Host "  No management groups visible. Falling back to subscriptionIds." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  No management groups visible at all. Falling back to subscriptionIds." -ForegroundColor Yellow
        }
    }
}

# --- Apply the "management group preferred, subscriptions only if none" rule ---
if ($managementGroupIds.Count -gt 0) {
    $subscriptionIds = @()   # covered by the management group; no need to enumerate
}
else {
    $subscriptionIds = @($subs.Id)
}

# --- Output ---
$config = [ordered]@{
    managementGroupIds = $managementGroupIds
    subscriptionIds    = $subscriptionIds
}

Write-Host "`n=== Config JSON ===" -ForegroundColor Cyan
$config | ConvertTo-Json -Depth 3
