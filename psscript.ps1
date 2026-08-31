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
Invoke-WithRetry { Connect-IPPSSession -Credential $cred -DisableWAM -ErrorAction Stop } "Connect-IPPSSession" 5 30 | Out-Null
try { Execute-AzureAdLabelSync } catch { Write-Host "label sync (pre): $($_.Exception.Message)" }

$rights = "$($upn):VIEW,VIEWRIGHTSDATA,DOCEDIT,EDIT,PRINT,EXTRACT,REPLY,REPLYALL,FORWARD,OBJMODEL"
$labels = @(
    @{ N="Public";              D="Public";              T="Freely shareable inside and outside the organization."; F="This document is classified as Public"; E=$false },
    @{ N="Internal";            D="Internal";            T="Internal use only.";                                    H="Internal Use Only"; F="This document is classified as Internal"; E=$false },
    @{ N="Confidential";        D="Confidential";        T="Restricted to authorized personnel.";                   H="Confidential Document"; F="Confidential Document"; W="Confidential"; E=$true },
    @{ N="HighlyConfidential";  D="Highly Confidential"; T="Highly sensitive - named users only.";                  H="HIGHLY CONFIDENTIAL"; F="Unauthorized disclosure is strictly prohibited"; W="HIGHLY CONFIDENTIAL"; E=$true },
    @{ N="Confidential-Finance";D="Confidential-Finance";T="Finance information containing sensitive data.";        H="Confidential Document"; F="Confidential Document"; W="Confidential"; E=$true }
)
foreach ($l in $labels) {
    if (Get-Label -Identity $l.N -ErrorAction SilentlyContinue) { Write-Host "label exists: $($l.D)"; continue }
    $p = @{ Name=$l.N; DisplayName=$l.D; Tooltip=$l.T; ContentType="File, Email, Site, UnifiedGroup, Teamwork" }
    if ($l.H) { $p.ApplyContentMarkingHeaderEnabled=$true; $p.ApplyContentMarkingHeaderText=$l.H; $p.ApplyContentMarkingHeaderAlignment="Center" }
    if ($l.F) { $p.ApplyContentMarkingFooterEnabled=$true; $p.ApplyContentMarkingFooterText=$l.F; $p.ApplyContentMarkingFooterAlignment="Center" }
    if ($l.W) { $p.ApplyWaterMarkingEnabled=$true; $p.ApplyWaterMarkingText=$l.W; $p.ApplyWaterMarkingLayout="Diagonal" }
    if ($l.E) { $p.EncryptionEnabled=$true; $p.EncryptionProtectionType="Template"; $p.EncryptionRightsDefinitions=$rights; $p.EncryptionContentExpiredOnDateInDaysOrNever="Never"; $p.EncryptionOfflineAccessDays=-1 }
    try { New-Label @p | Out-Null; Write-Host "created label: $($l.D)" } catch { Write-Host "New-Label $($l.N) failed: $($_.Exception.Message)" }
}

$policyName = "Lab-Confidential-Policy"
if (-not (Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue)) {
    try {
        $guids = @("Public","Internal","Confidential","HighlyConfidential","Confidential-Finance") | ForEach-Object { (Get-Label -Identity $_).Guid }
        New-LabelPolicy -Name $policyName -Labels $guids -ExchangeLocation All -SharePointLocation All -OneDriveLocation All -ModernGroupLocation All -Comment "Day1 lab label policy" | Out-Null
        Write-Host "created label policy: $policyName"
    } catch { Write-Host "New-LabelPolicy failed: $($_.Exception.Message)" }
}
try { Execute-AzureAdLabelSync } catch { Write-Host "label sync (post): $($_.Exception.Message)" }

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

    $ctx = New-Object Microsoft.SharePoint.Client.ClientContext($adminUrl)
    $ctx.ExecutingWebRequest += [Microsoft.SharePoint.Client.WebRequestEventHandler]{
        param($s,$e) $e.WebRequestExecutor.RequestHeaders["Authorization"] = "Bearer $spTok"
    }

    $spoTenant = New-Object Microsoft.Online.SharePoint.TenantAdministration.Tenant($ctx)
    $spoTenant.EnableAIPIntegration = $true
    $spoTenant.Update()
    $ctx.ExecuteQuery()
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
