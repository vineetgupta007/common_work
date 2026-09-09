<#
.SYNOPSIS
    Retrieves all permissions associated with an Entra ID (Azure AD) Application.

.DESCRIPTION
    Given an Application (Client) ID, this script reports:
      1. API permissions REQUESTED in the app registration manifest (RequiredResourceAccess)
         - split into Application and Delegated types
      2. Application permissions actually GRANTED (admin-consented app role assignments)
      3. Delegated permissions actually GRANTED (OAuth2 permission grants / scopes)
      4. Any Entra directory roles assigned directly to the app's service principal
         (e.g. Global Reader, Privileged Role Administrator)

    Requesting a permission in the manifest does NOT mean it's usable — it must be
    admin-consented. This script separates "requested" from "granted" so you can
    spot permissions that are still pending consent, and catch any granted
    permissions that aren't reflected in the manifest.

.PARAMETER AppId
    The Application (Client) ID of the target app registration (GUID).

.NOTES
    Requires: Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns,
              Microsoft.Graph.Identity.DirectoryManagement modules.
    Required Graph scopes to run: Application.Read.All, Directory.Read.All

.EXAMPLE
    .\Get-EntraAppPermissions.ps1 -AppId "11111111-2222-3333-4444-555555555555"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AppId,

    [switch]$ExportCsv,

    [string]$OutputPath = ".\EntraAppPermissions_$($AppId).csv"
)

# --- Ensure required modules are available ---
$requiredModules = @(
    "Microsoft.Graph.Applications",
    "Microsoft.Graph.Identity.SignIns",
    "Microsoft.Graph.Identity.DirectoryManagement"
)
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Installing missing module: $m" -ForegroundColor Yellow
        Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $m -ErrorAction Stop
}

# --- Connect to Microsoft Graph ---
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "Application.Read.All", "Directory.Read.All" -NoWelcome
}

# --- Resolve the application and its service principal ---
# Note: Microsoft first-party apps (e.g. Microsoft Graph PowerShell / Graph Command
# Line Tools, appId 14d82eec-204b-4c2f-b7e8-296a70dab67e) have NO app registration
# object in YOUR tenant — the registration lives in Microsoft's tenant. They only
# appear in yours as an enterprise application (service principal), created the
# first time someone consents. So we resolve the service principal first and treat
# the app registration as optional.
$app = Get-MgApplication -Filter "appId eq '$AppId'"
$sp  = Get-MgServicePrincipal -Filter "appId eq '$AppId'"

if (-not $app -and -not $sp) {
    Write-Error "No app registration or service principal found with AppId '$AppId' in this tenant. Verify the ID and your access."
    return
}

if (-not $app) {
    Write-Host "No local app registration (likely a Microsoft first-party or multi-tenant app whose registration lives outside this tenant)." -ForegroundColor Yellow
}
if (-not $sp) {
    Write-Warning "App registration found, but no matching Service Principal exists (app may not be provisioned/consented in this tenant yet)."
}

$displayName = if ($app) { $app.DisplayName } elseif ($sp) { $sp.DisplayName } else { "(unknown)" }
Write-Host "`nApp Name:   $displayName" -ForegroundColor Cyan
Write-Host "App ID:     $AppId"
if ($app) { Write-Host "App Object ID: $($app.Id)" }
if ($sp)  { Write-Host "SP Object ID:  $($sp.Id)" }
Write-Host ""

$results = New-Object System.Collections.Generic.List[Object]

# --- 1. Permissions REQUESTED in the manifest (RequiredResourceAccess) ---
# Only available when the app registration exists in this tenant.
foreach ($resource in $app.RequiredResourceAccess) {
    $resourceSp = Get-MgServicePrincipal -Filter "appId eq '$($resource.ResourceAppId)'"
    $resourceName = if ($resourceSp) { $resourceSp.DisplayName } else { $resource.ResourceAppId }

    foreach ($perm in $resource.ResourceAccess) {
        $permType = if ($perm.Type -eq "Role") { "Application" } else { "Delegated" }

        # Resolve the friendly permission name from the resource SP's manifest
        $permName = $perm.Id
        if ($resourceSp) {
            if ($permType -eq "Application") {
                $match = $resourceSp.AppRoles | Where-Object { $_.Id -eq $perm.Id }
                if ($match) { $permName = $match.Value }
            } else {
                $match = $resourceSp.Oauth2PermissionScopes | Where-Object { $_.Id -eq $perm.Id }
                if ($match) { $permName = $match.Value }
            }
        }

        $results.Add([PSCustomObject]@{
            Category   = "Requested (Manifest)"
            Resource   = $resourceName
            Permission = $permName
            Type       = $permType
            Status     = "Requested — verify consent below"
        })
    }
}

# --- 2. Application permissions actually GRANTED (app role assignments) ---
if ($sp) {
    $appRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All
    foreach ($assignment in $appRoleAssignments) {
        $resourceSp = Get-MgServicePrincipal -ServicePrincipalId $assignment.ResourceId
        $roleName = ($resourceSp.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }).Value

        $results.Add([PSCustomObject]@{
            Category   = "Granted - Application"
            Resource   = $resourceSp.DisplayName
            Permission = $roleName
            Type       = "Application"
            Status     = "Consented"
        })
    }

    # --- 3. Delegated permissions actually GRANTED (OAuth2 permission grants) ---
    $oauthGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id -All
    foreach ($grant in $oauthGrants) {
        $resourceSp = Get-MgServicePrincipal -ServicePrincipalId $grant.ResourceId
        $scopes = $grant.Scope -split " " | Where-Object { $_ -ne "" }

        foreach ($scope in $scopes) {
            $results.Add([PSCustomObject]@{
                Category   = "Granted - Delegated"
                Resource   = $resourceSp.DisplayName
                Permission = $scope
                Type       = "Delegated"
                Status     = "Consented (ConsentType: $($grant.ConsentType))"
            })
        }
    }

    # --- 4. Directory roles assigned directly to this app's service principal ---
    $directoryRoles = Get-MgDirectoryRole -All
    foreach ($role in $directoryRoles) {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All
        if ($members.Id -contains $sp.Id) {
            $results.Add([PSCustomObject]@{
                Category   = "Directory Role Assignment"
                Resource   = "Microsoft Entra ID"
                Permission = $role.DisplayName
                Type       = "Directory Role"
                Status     = "Assigned"
            })
        }
    }
}

# --- Output ---
$results | Sort-Object Category, Resource, Permission | Format-Table -AutoSize -Wrap

if ($ExportCsv) {
    $results | Sort-Object Category, Resource, Permission | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Host "`nExported to $OutputPath" -ForegroundColor Green
}

if (-not $sp) {
    Write-Host "`nNote: Since no Service Principal exists for this app in the tenant, only 'Requested (Manifest)' permissions could be shown — nothing has been consented/granted yet." -ForegroundColor Yellow
}
