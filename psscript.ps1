Param (
    [Parameter(Mandatory = $true)]
    [string]
    $AzureUserName,

    [string]
    $AzurePassword,

    [string]
    $AzureTenantID,

    [string]
    $AzureSubscriptionID,

    [string]
    $ODLID,

    [string]
    $InstallCloudLabsShadow,

    [string]
    $DeploymentID,

    [string]
    $vmAdminUsername,

    [string]
    $vmAdminPassword,

    [string]
    $trainerUserName,

    [string]
    $trainerUserPassword
)

Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append
[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

Function CreateCredFile($AzureUserName, $AzurePassword, $AzureTenantID, $AzureSubscriptionID, $DeploymentID)
{
    $WebClient = New-Object System.Net.WebClient
    $WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/AzureCreds.txt","C:\LabFiles\AzureCreds.txt")
    $WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/AzureCreds.ps1","C:\LabFiles\AzureCreds.ps1")

    New-Item -ItemType directory -Path C:\LabFiles -force

    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureUserNameValue", "$AzureUserName"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzurePasswordValue", "$AzurePassword"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureTenantIDValue", "$AzureTenantID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureSubscriptionIDValue", "$AzureSubscriptionID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "DeploymentIDValue", "$DeploymentID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"

    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureUserNameValue", "$AzureUserName"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzurePasswordValue", "$AzurePassword"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureTenantIDValue", "$AzureTenantID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureSubscriptionIDValue", "$AzureSubscriptionID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "DeploymentIDValue", "$DeploymentID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"

    Copy-Item "C:\LabFiles\AzureCreds.txt" -Destination "C:\Users\Public\Desktop"
}

CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID

# Module installs happen inside the async task below (keeps the CSE short).

# =====================================================================================
# Write the seeding script. Order is deliberate:
#   1) LABELS + POLICY FIRST (the critical deliverable, most reliable) - so nothing else
#      can block them.
#   2) ancillary settings after (org customization/audit, EnableMIPLabels, EnableAIPIntegration)
#      each guarded with retries; SPO is wrapped in a hard-timeout job so it can NEVER hang
#      the task the way it did before.
# =====================================================================================
$labelScriptPath = "C:\LabFiles\SensitivityLabels.ps1"
$labelScript = @'
Start-Transcript -Path "C:\WindowsAzure\Logs\SensitivityLabels.log" -Append
$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- modules (async, off the CSE critical path) ---
try { Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted } catch {}
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force } catch {} }
foreach ($m in @("AIPService","ExchangeOnlineManagement","Microsoft.Online.SharePoint.PowerShell")) {
    if (-not (Get-Module -ListAvailable -Name $m)) { try { Install-Module $m -Scope AllUsers -Force -AllowClobber } catch { Write-Host "module $m : $($_.Exception.Message)" } }
}
Import-Module AIPService -Force
Import-Module ExchangeOnlineManagement -Force

# =====================================================================================
# AUTHENTICATION MODEL - READ THIS BEFORE CHANGING ANYTHING BELOW
# =====================================================================================
#
# This script authenticates as the CloudLabs ODL ADMIN USER, using the username and
# password that CloudLabs itself writes to C:\LabFiles\AzureCreds.txt. This is the
# standard CloudLabs pattern and is used by other shipping labs on this platform.
#
# Five places depend on it:
#   1. Connect-IPPSSession  -Credential   (labels, policy, role groups, SITs, DLP)
#   2. Connect-ExchangeOnline -Credential (audit, Organization Management)
#   3. Graph ROPC       (grant_type=password) - EnableMIPLabels
#   4. SharePoint ROPC  (grant_type=password) - EnableAIPIntegration
#
# WHY THIS WORKS: ODL tenants ship with security defaults and Conditional Access OFF.
# Confirmed with the CloudLabs team on 2026-08-31, and verified on three live tenants.
#
# NOT AFFECTED by the Azure mandatory MFA enforcement (Phase 2, from 1 July 2026): that
# enforcement is scoped to requests against https://management.azure.com/ only, i.e. Azure
# Resource Manager operations. Nothing in this script touches ARM - every call goes to
# Exchange Online, Security & Compliance, Graph or SharePoint.
#
# -------------------------------------------------------------------------------------
# IF THIS EVER STARTS FAILING WITH AUTH ERRORS, READ HERE FIRST
# -------------------------------------------------------------------------------------
# Symptom: AADSTS50076 / AADSTS50079 / "strong authentication required", or the auth probe
# below writing FATAL. Cause: MFA is now being enforced on this tenant - most likely
# security defaults or a Conditional Access policy was switched on, NOT the Azure ARM
# enforcement.
#
# The password-based flows here CANNOT be made to work with MFA. ROPC is incompatible with
# MFA by design, and Microsoft has deprecated the username-password flow
# (AcquireTokenByUsernamePassword, MSAL 4.74.0; UsernamePasswordCredential,
# Azure.Identity 1.14.0-beta.2). A Temporary Access Pass does NOT help - it cannot be
# presented by any of these cmdlets.
#
# THE FIX IS APP-ONLY (SERVICE PRINCIPAL) AUTH. It needs:
#   * A certificate on the app registration. Exchange Online and Security & Compliance
#     PowerShell support app-only with CERTIFICATES ONLY - client secrets do NOT work.
#     Graph does accept a client secret (Connect-MgGraph -ClientSecretCredential).
#   * API permissions, both Application, both admin-consented:
#       - Office 365 Exchange Online          -> Exchange.ManageAsApp   (Connect-ExchangeOnline)
#       - Microsoft Exchange Online Protection -> Exchange.ManageAsApp  (Connect-IPPSSession)
#     Note: two different APIs, same permission name. Easy to miss.
#   * An Entra directory role on the service principal: Compliance Administrator covers
#     labels, DLP, SITs, role groups and audit.
#   * For SharePoint: Sites.FullControl.All, or keep the manual T-24h portal click
#     (Purview -> Information Protection -> "Turn on now") as the fallback.
#
# Then replace the four connections with:
#   Connect-IPPSSession    -AppId <id> -CertificateThumbprint <thumb> -Organization <tenant>.onmicrosoft.com
#   Connect-ExchangeOnline -AppId <id> -CertificateThumbprint <thumb> -Organization <tenant>.onmicrosoft.com
#   Graph + SharePoint: client-credentials token instead of grant_type=password
#
# IMPORTANT: if you move to app-only, the certificate must NOT live on this VM. Learners
# have local administrator here and the CSE writes this script to disk. Move that work to
# the provisioning script that runs off-VM with the app identity.
# =====================================================================================
$c        = Get-Content "C:\LabFiles\AzureCreds.txt" | ConvertFrom-StringData
$upn      = $c.AzureUserName
$pwd      = $c.AzurePassword
$tenantId = $c.AzureTenantID
$org      = $upn.Split("@")[-1]
$sec      = ConvertTo-SecureString $pwd -AsPlainText -Force
$cred     = New-Object System.Management.Automation.PSCredential($upn, $sec)

function Invoke-WithRetry {
    param([scriptblock]$Script,[string]$Name,[int]$Max=5,[int]$Delay=60)
    for ($i=1; $i -le $Max; $i++) {
        try { & $Script; Write-Host "$Name : ok"; return $true }
        catch { Write-Host "$Name attempt $i/$Max failed: $($_.Exception.Message)"; if ($i -lt $Max) { Start-Sleep -Seconds $Delay } }
    }
    Write-Host "$Name : gave up after $Max attempts"; return $false
}

# =====================================================================================
# 1) LABELS + POLICY FIRST
# =====================================================================================
# AUTH PROBE: if this fails, nothing below can work. Say so once, loudly, and stop -
# rather than grinding through five retries per block and burying the cause in noise.
# A tenant that cannot authenticate must announce itself at DEPLOY time, not at 9am.
$ippsOk = Invoke-WithRetry { Connect-IPPSSession -Credential $cred -DisableWAM -ErrorAction Stop } "Connect-IPPSSession" 5 30

if (-not $ippsOk) {
    Write-Host ""
    Write-Host "================================================================================"
    Write-Host "FATAL: cannot authenticate as $upn"
    Write-Host ""
    Write-Host "This script signs in with the ODL admin username and password. If MFA is now"
    Write-Host "enforced on this tenant (security defaults or Conditional Access), that is not"
    Write-Host "recoverable here - password and ROPC flows are incompatible with MFA."
    Write-Host ""
    Write-Host "See the AUTHENTICATION MODEL comment block near the top of this script for the"
    Write-Host "app-only (service principal + certificate) migration path."
    Write-Host ""
    Write-Host "SUMMARY: labels=0/5 policy=NO"
    Write-Host "SUMMARY: BASELINE INCOMPLETE - do not hand this tenant to learners"
    Write-Host "================================================================================"
    Stop-Transcript
    exit 1
}

try { Execute-AzureAdLabelSync } catch { Write-Host "label sync (pre): $($_.Exception.Message)" }

$rights = "$($upn):VIEW,VIEWRIGHTSDATA,DOCEDIT,EDIT,PRINT,EXTRACT,REPLY,REPLYALL,FORWARD,OBJMODEL"
$labels = @(
    @{ N="Public";              D="Public";              T="Freely shareable inside and outside the organization."; F="This document is classified as Public"; E=$false },
    @{ N="Internal";            D="Internal";            T="Internal use only.";                                    H="Internal Use Only"; F="This document is classified as Internal"; E=$false },
    @{ N="Confidential";        D="Confidential";        T="Restricted to authorized personnel.";                   H="Confidential Document"; F="Confidential Document"; W="Confidential"; E=$true },
    @{ N="HighlyConfidential";  D="Highly Confidential"; T="Highly sensitive - named users only.";                  H="HIGHLY CONFIDENTIAL"; F="Unauthorized disclosure is strictly prohibited"; W="HIGHLY CONFIDENTIAL"; E=$true },
    @{ N="Confidential-Finance";D="Confidential-Finance";T="Finance information containing sensitive data.";        H="Confidential Document"; F="Confidential Document"; W="Confidential"; E=$true }
)
# -------------------------------------------------------------------------------------
# THE RMS PROBLEM (read this before shortening any of the waits below)
#
# On 2026-08-31, two brand-new tenants failed ALL THREE encrypted labels with:
#   RmsException: "Your TenantId '<guid>' is not found in Azure RMS."
# Plain labels succeeded on the same run. Creating the same encrypted label BY HAND about
# three hours later worked first try, same tenant, same credentials.
#
# So Azure Rights Management provisions itself some hours into a new tenant's life, and the
# task firing at T+30min was simply too early. Only ENCRYPTION touches RMS, which is why
# Public and Internal always survive and the other three do not. (A separate CloudLabs lab
# creates labels successfully with no encryption at all - it never hits this.)
#
# Connect-AipService / Enable-AipService were tried and are NOT used: RMS came up on its own
# without them, and they added a dependency for no proven benefit. The retry loop below is
# the fix - it simply waits for the service to appear.
# -------------------------------------------------------------------------------------
# CREATE + VERIFY
#
# CRITICAL FIX: New-Label reports RmsException as a NON-TERMINATING error. With
# $ErrorActionPreference = "Continue" and no -ErrorAction Stop, the catch never fired and
# the script logged "created label: X" for labels that did not exist. Every run since has
# been reporting success on tenants that had only 2 of 5 labels.
#
# So: -ErrorAction Stop AND a Get-Label verification. Never trust the cmdlet's silence.
# -------------------------------------------------------------------------------------
function New-LabelVerified {
    param($L, [int]$Attempts, [int]$WaitSeconds)

    if (Get-Label -Identity $L.N -ErrorAction SilentlyContinue) {
        Write-Host "label exists: $($L.D)"
        return $true
    }

    $p = @{ Name=$L.N; DisplayName=$L.D; Tooltip=$L.T; ContentType="File, Email, Site, UnifiedGroup, Teamwork" }
    if ($L.H) { $p.ApplyContentMarkingHeaderEnabled=$true; $p.ApplyContentMarkingHeaderText=$L.H; $p.ApplyContentMarkingHeaderAlignment="Center" }
    if ($L.F) { $p.ApplyContentMarkingFooterEnabled=$true; $p.ApplyContentMarkingFooterText=$L.F; $p.ApplyContentMarkingFooterAlignment="Center" }
    if ($L.W) { $p.ApplyWaterMarkingEnabled=$true; $p.ApplyWaterMarkingText=$L.W; $p.ApplyWaterMarkingLayout="Diagonal" }
    if ($L.E) { $p.EncryptionEnabled=$true; $p.EncryptionProtectionType="Template"; $p.EncryptionRightsDefinitions=$rights; $p.EncryptionContentExpiredOnDateInDaysOrNever="Never"; $p.EncryptionOfflineAccessDays=-1 }

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            New-Label @p -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "New-Label $($L.N) attempt $i/$Attempts : $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 5
        if (Get-Label -Identity $L.N -ErrorAction SilentlyContinue) {
            Write-Host "created and verified label: $($L.D)"
            return $true
        }
        if ($i -lt $Attempts) {
            Write-Host "label $($L.N) not present yet - waiting $WaitSeconds s"
            Start-Sleep -Seconds $WaitSeconds
        }
    }
    Write-Host "LABEL FAILED: $($L.D) does NOT exist after $Attempts attempts"
    return $false
}

$plainLabels = @($labels | Where-Object { -not $_.E })
$encLabels   = @($labels | Where-Object { $_.E })

# Plain labels never needed RMS - they succeeded even on the failed runs.
foreach ($l in $plainLabels) { New-LabelVerified $l 3 30 | Out-Null }

# The FIRST encrypted label doubles as the RMS readiness gate: retry it patiently, and once
# it lands we know RMS is up, so the rest go quickly. Gating on one label caps the worst
# case at ~2 hours instead of 2 hours per label. Nothing is waiting on this - it runs as
# SYSTEM in the background at T-48h.
$rmsReady = $false
if ($encLabels.Count -gt 0) {
    Write-Host "waiting for Azure RMS via first encrypted label (up to ~2 hours)..."
    $rmsReady = New-LabelVerified $encLabels[0] 12 600
}

if ($rmsReady) {
    foreach ($l in ($encLabels | Select-Object -Skip 1)) { New-LabelVerified $l 4 60 | Out-Null }
} elseif ($encLabels.Count -gt 0) {
    Write-Host "RMS NEVER BECAME AVAILABLE - encrypted labels were not created"
}

# -------------------------------------------------------------------------------------
# POLICY - build only from labels that actually exist, and verify afterwards.
# Previously a missing label produced a null in the GUID array, New-LabelPolicy threw
# "Object reference not set to an instance of an object", and the script logged success.
# -------------------------------------------------------------------------------------
$policyName = "Lab-Confidential-Policy"
if (-not (Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue)) {

    $guids = @()
    foreach ($n in @("Public","Internal","Confidential","HighlyConfidential","Confidential-Finance")) {
        try {
            $g = (Get-Label -Identity $n -ErrorAction Stop).Guid
            if ($g) { $guids += $g }
        } catch { Write-Host "policy: skipping missing label $n" }
    }
    Write-Host "policy will publish $($guids.Count) of 5 labels"

    if ($guids.Count -eq 0) {
        Write-Host "POLICY FAILED: no labels exist to publish"
    } else {
        $polOk = $false
        for ($i = 1; $i -le 3; $i++) {
            try {
                New-LabelPolicy -Name $policyName -Labels $guids -ExchangeLocation All -SharePointLocation All -OneDriveLocation All -ModernGroupLocation All -Comment "Day1 lab label policy" -ErrorAction Stop | Out-Null
            } catch {
                Write-Host "New-LabelPolicy attempt $i/3 : $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 5
            if (Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue) {
                Write-Host "created and verified label policy: $policyName"
                $polOk = $true
                break
            }
            if ($i -lt 3) { Start-Sleep -Seconds 30 }
        }
        if (-not $polOk) { Write-Host "POLICY FAILED: $policyName does NOT exist" }
    }
}
try { Execute-AzureAdLabelSync } catch { Write-Host "label sync (post): $($_.Exception.Message)" }

# -------------------------------------------------------------------------------------
# HONEST SUMMARY - this is the line the verification runbook greps for.
# -------------------------------------------------------------------------------------
$haveLabels = @(Get-Label -ErrorAction SilentlyContinue).Count
$havePolicy = if (Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue) { "yes" } else { "NO" }
Write-Host "SUMMARY: labels=$haveLabels/5 policy=$havePolicy"
if ($haveLabels -lt 5 -or $havePolicy -eq "NO") {
    Write-Host "SUMMARY: BASELINE INCOMPLETE - do not hand this tenant to learners"
} else {
    Write-Host "SUMMARY: baseline OK"
}

# =====================================================================================
# 1b) PURVIEW ROLE GROUPS (still inside the IPPS session opened above)
#
# WHY: the CloudLabs ODL admin is an Entra Global Administrator, but the Purview portal
# checks explicit ROLE GROUP membership, which a GA does not get automatically. Without
# these, Content Explorer throws "Permission required" on every location and the DSPM AI
# activity view reports "Your role can't view AI Visits or user risk levels".
#
# NOTE: the stored object names have NO SPACES, unlike the names shown in the portal
# dialog ("Content Explorer List Viewer"). Confirmed on a live tenant with:
#   Get-RoleGroup | Where-Object { $_.Name -like "*Content*" } | Select-Object Name
#
# Membership takes ~30-60 min to propagate and needs a fresh sign-in. Doing it here at
# deploy time (T-48h) means learners never encounter the permission errors.
# =====================================================================================
foreach ($rg in @("ContentExplorerListViewer","ContentExplorerContentViewer","DataSecurityAIContentViewers")) {
    try {
        Add-RoleGroupMember $rg -Member $upn -ErrorAction Stop
        Write-Host "role group: added $upn to $rg"
    } catch {
        Write-Host "role group $rg : $($_.Exception.Message)"
    }
}

# =====================================================================================
# 2) ANCILLARY SETTINGS (after labels; none of these can block label creation now)
# =====================================================================================

# 2a) Exchange: org customization, Organization Management membership, audit verification.
#
# Organization Management holds the Audit Logs role. Without it the Purview portal shows
# "You don't have the required permissions to turn on auditing" and audit search fails,
# even for a Global Administrator.
#
# Audit is already True by default on new tenants, so we CHECK before setting. The old
# blind Set-AdminAuditLogConfig burned all 5 retries against a fresh tenant and filled the
# log with alarming errors for no benefit. We still keep the step, because the audit
# ingestion 24-HOUR CLOCK starts when recording starts - it must start at DEPLOY time,
# never when a learner clicks it during the session.
Invoke-WithRetry {
    Connect-ExchangeOnline -Credential $cred -ShowBanner:$false -DisableWAM -ErrorAction Stop

    try { Enable-OrganizationCustomization -ErrorAction Stop; Write-Host "OrgCustomization: enabled" }
    catch { Write-Host "OrgCustomization: already enabled (expected)" }

    try {
        Add-RoleGroupMember "Organization Management" -Member $upn -ErrorAction Stop
        Write-Host "role group: added $upn to Organization Management"
    } catch { Write-Host "role group Organization Management : $($_.Exception.Message)" }

    if ((Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled) {
        Write-Host "audit: already enabled - ingestion clock already running"
    } else {
        try {
            Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop
            Write-Host "audit: enabled"
        } catch { Write-Host "audit enable failed: $($_.Exception.Message)" }
    }
} "EXO setup" 5 60 | Out-Null

# 2b) EnableMIPLabels (container labels) via Graph ROPC (retry)
Invoke-WithRetry {
    $gb = @{ client_id="1950a258-227b-4e31-a9cf-717495945fc2"; scope="https://graph.microsoft.com/.default"; username=$upn; password=$pwd; grant_type="password" }
    $tok = (Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $gb).access_token
    $gh = @{ Authorization = "Bearer $tok" }
    # v1.0 directory-settings collection is /groupSettings (+ /groupSettingTemplates).
    # NOTE: /settings + /directorySettingTemplates are BETA-only names and 400 on v1.0.
    $settings = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groupSettings" -Headers $gh).value
    $u = $settings | Where-Object { $_.displayName -eq "Group.Unified" } | Select-Object -First 1
    if ($u) {
        $vals=@(); foreach($v in $u.values){ if($v.name -eq "EnableMIPLabels"){$v.value="true"}; $vals+=@{name=$v.name;value=$v.value} }
        Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/groupSettings/$($u.id)" -Headers $gh -Body (@{values=$vals}|ConvertTo-Json -Depth 6) -ContentType "application/json" | Out-Null
    } else {
        $tpl=(Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groupSettingTemplates" -Headers $gh).value | Where-Object { $_.displayName -eq "Group.Unified" }
        $vals=@(); foreach($v in $tpl.values){ $vals+=@{name=$v.name;value=$(if($v.name -eq "EnableMIPLabels"){"true"}else{$v.defaultValue})} }
        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/groupSettings" -Headers $gh -Body (@{templateId=$tpl.id;values=$vals}|ConvertTo-Json -Depth 6) -ContentType "application/json" | Out-Null
    }
} "EnableMIPLabels" 5 60 | Out-Null

# 2c) EnableAIPIntegration (SharePoint) via ROPC token + SharePoint CSOM.
#
# WHY NOT Connect-SPOService: that cmdlet tries to fall back to an interactive modern-auth
# prompt. Inside a scheduled task running as SYSTEM there is no desktop to show it, so it
# blocked on "waiting for user interaction" and killed the step. Wrapping it in a job only
# hid the hang; it still never succeeded.
#
# This version acquires a bearer token the same way EnableMIPLabels does (ROPC against the
# Azure PowerShell public client, which works because CloudLabs ODL admins have MFA and
# security defaults OFF) and sets the tenant property directly through CSOM. No interactive
# surface exists, so it cannot prompt and cannot hang - the timeout job is no longer needed.
#
# WHY IT MATTERS: without EnableAIPIntegration, sensitivity labels do not apply to Office
# files in SharePoint/OneDrive AND the SharePoint "Sensitivity" column is unavailable, which
# breaks the Exercise 4 labelling verification.
Invoke-WithRetry {
    $tenantPrefix = $org.Split('.')[0]
    $adminUrl     = "https://$tenantPrefix-admin.sharepoint.com"

    $spBody = @{
        resource   = $adminUrl
        client_id  = "1950a258-227b-4e31-a9cf-717495945fc2"
        grant_type = "password"
        username   = $upn
        password   = $pwd
    }
    $spTok = (Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -Body $spBody -ErrorAction Stop).access_token
    if (-not $spTok) { throw "no SharePoint access token returned" }

    $modPath = (Get-Module -ListAvailable Microsoft.Online.SharePoint.PowerShell |
                Sort-Object Version -Descending | Select-Object -First 1).ModuleBase
    if (-not $modPath) { throw "SharePoint Online module not found - cannot load CSOM assemblies" }

    Add-Type -Path (Join-Path $modPath "Microsoft.SharePoint.Client.dll")
    Add-Type -Path (Join-Path $modPath "Microsoft.SharePoint.Client.Runtime.dll")
    Add-Type -Path (Join-Path $modPath "Microsoft.Online.SharePoint.Client.Tenant.dll")

    # PARSE-ORDER FIX (2026-08-31): this block previously failed on every run with
    #   "Unable to find type [Microsoft.SharePoint.Client.WebRequestEventHandler]"
    # PowerShell resolves type literals when it PARSES the enclosing script block, which
    # happens before Add-Type has loaded the assemblies. Nothing to do with tokens or
    # permissions. [scriptblock]::Create parses at runtime, after the types exist.
    $csom = [scriptblock]::Create(@"
        param(`$adminUrl, `$spTok)
        `$ctx = New-Object Microsoft.SharePoint.Client.ClientContext(`$adminUrl)
        `$handler = [Microsoft.SharePoint.Client.WebRequestEventHandler]{
            param(`$s, `$e)
            `$e.WebRequestExecutor.RequestHeaders["Authorization"] = "Bearer `$spTok"
        }
        `$ctx.add_ExecutingWebRequest(`$handler)
        `$spoTenant = New-Object Microsoft.Online.SharePoint.TenantAdministration.Tenant(`$ctx)
        `$spoTenant.EnableAIPIntegration = `$true
        `$spoTenant.Update()
        `$ctx.ExecuteQuery()
"@)
    & $csom $adminUrl $spTok
    Write-Host "EnableAIPIntegration: set to true via CSOM"
} "EnableAIPIntegration (CSOM)" 5 60 | Out-Null

try { Disconnect-ExchangeOnline -Confirm:$false } catch {}
Write-Host "Seeding complete."
Stop-Transcript
'@
$labelScript | Set-Content -Path $labelScriptPath -Encoding UTF8

# Schedule the seeding task: one-time, 30 MINUTES out, as SYSTEM (no password, runs whether
# logged on or not). 30 min gives a fresh tenant time to settle before the connects.
$taskName  = "SensitivityLabels"
$startTime = (Get-Date).AddMinutes(30).ToString("HH:mm")
schtasks /create /tn $taskName /tr "powershell.exe -ExecutionPolicy Bypass -File $labelScriptPath" /sc once /st $startTime /ru SYSTEM /f /rl HIGHEST
Write-Host "SensitivityLabels task scheduled for $startTime (SYSTEM, runs whether logged on or not)."
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    Write-Error "CRITICAL: SensitivityLabels task was not created."
    Stop-Transcript
    exit 1
}

# Harden the task: StartWhenAvailable makes Windows run it as soon as the machine is next
# available if the scheduled start was MISSED.
#
# WHY THIS MATTERS: a /sc once task does NOT auto-run a missed start by default. If the VM
# is deallocated (or simply not running) at the trigger time, the seeding is silently skipped
# forever and the tenant is left with no labels. That happened on 2026-08-26 when the VM was
# stopped ~17 minutes before the task was due to fire.
#
# Read-modify-write a single property so the proven schtasks creation above is preserved.
try {
    $schedTask = Get-ScheduledTask -TaskName $taskName
    $schedTask.Settings.StartWhenAvailable = $true
    $schedTask | Set-ScheduledTask | Out-Null
    Write-Host "SensitivityLabels task: StartWhenAvailable enabled (survives a missed start)."
} catch {
    Write-Host "Could not set StartWhenAvailable: $($_.Exception.Message)"
}

Function updateVMShadowFile
{
#Replace vmAdminUsernameValue with VM Admin UserName in script content
$drivepath="C:\Users\Public\Documents"
(Get-Content -Path "$drivepath\Shadow.ps1") | ForEach-Object {$_ -Replace "vmAdminUsernameValue", "$vmAdminUsername"} | Set-Content -Path "$drivepath\Shadow.ps1"
#Update random password
net user $trainerUserName $trainerUserPassword
}
updateVMShadowFile

Remove-Item -Path "C:\ProgramData\chocolatey\lib\dotnetcore" -Recurse -Force
choco install dotnetcore --force
Remove-Item -Path "C:\CloudLabs\" -Recurse -Force

#Install Cloudlabs Modern VM (Windows Server 2012,2016,2019, Windows 10) Validator
Function InstallModernVmValidator
{   #dotnet core is pre-req for vmagent or validator
    #Create C:\CloudLabs\Validator directory
    New-Item -ItemType directory -Path C:\CloudLabs\Validator -Force
    Invoke-WebRequest 'https://experienceazure.blob.core.windows.net/software/vm-validator/VMAgent.zip' -OutFile 'C:\CloudLabs\Validator\VMAgent.zip'
    Expand-Archive -LiteralPath 'C:\CloudLabs\Validator\VMAgent.zip' -DestinationPath 'C:\CloudLabs\Validator' -Force
    Set-ExecutionPolicy -ExecutionPolicy bypass -Force
    cmd.exe --% /c @echo off
    cmd.exe --% /c sc create "Spektra CloudLabs VM Agent" BinPath=C:\CloudLabs\Validator\VMAgent\Spektra.CloudLabs.VMAgent.exe start= auto
    cmd.exe --% /c sc start "Spektra CloudLabs VM Agent"
}

InstallModernVmValidator

# Install Chocolatey if not installed
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager].SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Install Microsoft 365 Apps
choco install office365business -y

# PowerShell 7. The WAM broker that breaks interactive Connect-IPPSSession under PS 5.1
# ("A window handle must be configured") does not apply to the netCore build, so anyone
# troubleshooting this tenant by hand should use PS 7. Borrowed from another CloudLabs lab.
choco install powershell-core --version=7.4.2 -y

# Suppress Edge first-run experience and configure bookmarks
$EdgePoliciesPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
New-Item -Path $EdgePoliciesPath -Force | Out-Null
Set-ItemProperty -Path $EdgePoliciesPath -Name "HideFirstRunExperience" -Value 1 -Type DWord
Set-ItemProperty -Path $EdgePoliciesPath -Name "DefaultBrowserSettingEnabled" -Value 0 -Type DWord

# Create Edge managed bookmarks for lab portals
$bookmarks = @(
    @{ name = "Microsoft Purview"; url = "https://purview.microsoft.com" },
    @{ name = "Microsoft 365"; url = "https://www.microsoft365.com" },
    @{ name = "Security Copilot"; url = "https://securitycopilot.microsoft.com" },
    @{ name = "SharePoint Admin"; url = "https://$($AzureUserName.Split('@')[1].Split('.')[0])-admin.sharepoint.com" },
    @{ name = "Entra Admin"; url = "https://entra.microsoft.com" }
)
$bookmarkJson = ($bookmarks | ConvertTo-Json -Compress)
Set-ItemProperty -Path $EdgePoliciesPath -Name "ManagedBookmarks" -Value $bookmarkJson -Type String

# Create credentials file on Desktop for quick access
$credContent = @"
=== Lab Credentials ===
Azure Username : $AzureUserName
Azure Password : $AzurePassword
Tenant ID      : $AzureTenantID
Subscription ID: $AzureSubscriptionID
Deployment ID  : $DeploymentID

=== Lab Portals ===
Microsoft Purview  : https://purview.microsoft.com
Microsoft 365      : https://www.microsoft365.com
Security Copilot   : https://securitycopilot.microsoft.com

=== Lab Files ===
Test Documents : Contoso Finance SharePoint site > Documents
"@
$credContent | Out-File -FilePath "C:\Users\Public\Desktop\Lab-Credentials.txt" -Encoding UTF8

#Function InstallEdgeChromiumupdated
# Define the path to Microsoft Edge executable
$EdgeExecutablePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

# Define the path where the shortcut will be created
$ShortcutPath = [Environment]::GetFolderPath("Desktop") + "\Microsoft Edge.lnk"

# Create a WScript Shell object
$WScriptShell = New-Object -ComObject WScript.Shell

# Create a shortcut object
$Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)

# Set the target path for the shortcut
$Shortcut.TargetPath = $EdgeExecutablePath

# Save the shortcut
$Shortcut.Save()

Write-Host "Microsoft Edge shortcut created on desktop."

# runuserdata is the image's userData runner - only present on the userData path; ignore if absent.
Disable-ScheduledTask -TaskName "runuserdata" -ErrorAction SilentlyContinue
Stop-ScheduledTask   -TaskName "runuserdata" -ErrorAction SilentlyContinue

Stop-Transcript
exit 0
