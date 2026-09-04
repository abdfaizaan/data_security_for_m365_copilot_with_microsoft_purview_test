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

# =====================================================================================
# LABCONFIG.TXT - values the seeding script needs that AzureCreds.txt may not carry
#
# WHY THIS EXISTS: the seeding script below is embedded as a SINGLE-QUOTED here-string,
# so nothing in it is interpolated at CSE time and it cannot see $DeploymentID. It also
# runs later, as a separate scheduled task in a fresh process, with none of these
# parameters available.
#
# The SharePoint sharing block needs DeploymentID to build the site URL. Relying on the
# downloaded CloudLabs AzureCreds.txt template carrying a DeploymentID key is an
# assumption about a file we do not control, so we write our own and read that first.
# =====================================================================================
@"
DeploymentID = $DeploymentID
TenantDomain = $($AzureUserName.Split('@')[-1])
"@ | Set-Content -Path "C:\LabFiles\LabConfig.txt" -Encoding UTF8
Write-Host "LabConfig.txt written (DeploymentID = $DeploymentID)"

# =====================================================================================
# Write the seeding script. Order is deliberate:
#   1)  LABELS + POLICY FIRST (the critical deliverable, most reliable) - so nothing else
#       can block them.
#   1b) PURVIEW ROLE GROUPS.
#   1c) DAY 2 COMPLIANCE OBJECTS (DLP, Insider Risk, eDiscovery case). These need the
#       label GUIDs, and they need to be TWO DAYS OLD by the time Day 2 runs, which is why
#       they are seeded here at T-48h rather than built by learners.
#   2)  ancillary settings (org customization/audit, EnableMIPLabels, EnableAIPIntegration)
#       each guarded with retries.
#   3)  SHAREPOINT FILE SHARING last, so the separate site-creation process has the
#       maximum possible time to finish before we try to share from the site.
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
#   1. Connect-IPPSSession  -Credential   (labels, policy, role groups, DLP, IRM, eDiscovery)
#   2. Connect-ExchangeOnline -Credential (audit, Organization Management)
#   3. Graph ROPC       (grant_type=password) - EnableMIPLabels
#   4. SharePoint ROPC  (grant_type=password) - EnableAIPIntegration
#   5. SharePoint ROPC  (grant_type=password) - per-item file sharing
#
# WHY THIS WORKS: OTU tenants ship with security defaults and Conditional Access OFF.
# Confirmed and verified on three live tenants.
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
# Then replace the connections with:
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

# LabConfig.txt is written by the CSE. Prefer it over AzureCreds.txt for DeploymentID,
# because the AzureCreds template is downloaded from CloudLabs and we do not control
# whether it carries that key.
$deployId = $null
try {
    $lc = Get-Content "C:\LabFiles\LabConfig.txt" -ErrorAction Stop | ConvertFrom-StringData
    $deployId = $lc.DeploymentID
} catch { Write-Host "LabConfig.txt not readable: $($_.Exception.Message)" }
if (-not $deployId) { $deployId = $c.DeploymentID }
Write-Host "DeploymentID resolved as: '$deployId'"

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
    Write-Host "FINAL SUMMARY: labels=0/5 policy=NO"
    Write-Host "FINAL SUMMARY: BASELINE INCOMPLETE - do not hand this tenant to learners"
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
# Public and Internal always survive and the other three do not.
#
# Connect-AipService / Enable-AipService were tried and are NOT used: RMS came up on its own
# without them, and they added a dependency for no proven benefit. The retry loop below is
# the fix - it simply waits for the service to appear.
# -------------------------------------------------------------------------------------
# CREATE + VERIFY
#
# CRITICAL FIX: New-Label reports RmsException as a NON-TERMINATING error. With
# $ErrorActionPreference = "Continue" and no -ErrorAction Stop, the catch never fired and
# the script logged "created label: X" for labels that did not exist.
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

# =====================================================================================
# 1b) PURVIEW ROLE GROUPS (still inside the IPPS session opened above)
#
# WHY: the CloudLabs ODL user is an Entra Global Administrator, but the Purview portal
# checks explicit ROLE GROUP membership, which a GA does not get automatically. Without
# these, Content Explorer throws "Permission required" on every location and the DSPM AI
# activity view reports "Your role can't view AI Visits or user risk levels".
#
# NOTE: the stored object names have NO SPACES, unlike the names shown in the portal
# dialog ("Content Explorer List Viewer"). Confirmed on a live tenant with:
#   Get-RoleGroup | Where-Object { $_.Name -like "*Content*" } | Select-Object Name
#
# eDiscovery Manager IS spaced, because it belongs to a different family of role group. It
# is needed for Day 2 Exercise 4 Task 3, and it is NOT sufficient on its own - case
# membership is added separately in section 1c-iii.
#
# Membership takes ~30-60 min to propagate and needs a fresh sign-in. Doing it here at
# deploy time (T-48h) means learners never encounter the permission errors.
# =====================================================================================
foreach ($rg in @(
    "ContentExplorerListViewer",
    "ContentExplorerContentViewer",
    "DataSecurityAIContentViewers",
    "InsiderRiskManagement",
    "InsiderRiskManagementAnalysts",
    "InsiderRiskManagementInvestigators",
    "CommunicationCompliance",
    "CommunicationComplianceAnalysts",
    "CommunicationComplianceInvestigators"
    "eDiscoveryManager",
    "Organization Management"
    )) {
    try {
        Add-RoleGroupMember $rg -Member $upn -ErrorAction Stop
        Write-Host "role group: added $upn to $rg"
    } catch {
        Write-Host "role group $rg : $($_.Exception.Message)"
    }
}

try {
    Add-RoleGroupMember "eDiscovery Manager" -Member $upn -ErrorAction Stop
    Write-Host "role group: added $upn to eDiscovery Manager"
} catch {
    Write-Host "role group eDiscovery Manager : $($_.Exception.Message)"
}

# =====================================================================================
# 1c) DAY 2 COMPLIANCE OBJECTS
#
# WHY THESE LIVE IN THE DAY 1 SCRIPT: Day 1 and Day 2 share one environment. This script
# runs at T-48h, which makes every object below two days old by the time Day 2 starts.
# That is exactly what Day 2 needs, because DLP for Copilot takes up to four hours to
# distribute and Insider Risk needs days to accumulate signal.
#
# COMMUNICATION COMPLIANCE IS DELIBERATELY ABSENT. See section 1c-iv.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  DAY 2 COMPLIANCE OBJECTS"
Write-Host "=============================================================="

# -------------------------------------------------------------------------------------
# 1c-i) DLP for Copilot - Lab-Copilot-DLP-Test
#
# ############ READ THIS BEFORE CHANGING THE LABEL LIST ############
#
# The rule conditions on the "Confidential" label ONLY. This is deliberate and it is
# load-bearing across BOTH days. Do not add the other two encrypted labels.
#
#   Confidential-Finance -> Day 1 Ex 4 Task 6. Copilot MUST SUCCEED on this file.
#                           If DLP matches it, Day 1's central demo breaks.
#   Highly Confidential  -> Day 2 Ex 1 Task 3. The block MUST come from label usage
#                           rights alone. If DLP also matches, the learner cannot tell
#                           the two mechanisms apart and the exercise teaches nothing.
#   Confidential         -> Day 2 Ex 2 Task 4. This is the DLP demo. MATCH THIS ONE.
#
# One label per mechanism keeps all three exercises unambiguous.
# ##################################################################
#
# Parameter shapes VERIFIED CREATED on otuwamoc103906, 2 Sept 2026. The Locations JSON and
# -EnforcementPlanes are both required; the Copilot location cannot be expressed any other
# way. On read-back the service echoes each label with both "name" and "id" set to the same
# GUID - that is normalisation, not a problem.
# -------------------------------------------------------------------------------------
$dlpPolicyName = "Lab-Copilot-DLP-Test"
$dlpRuleName   = "Lab-Block-Copilot-On-Labels"

if (Get-DlpCompliancePolicy -Identity $dlpPolicyName -ErrorAction SilentlyContinue) {
    Write-Host "DLP policy exists: $dlpPolicyName"
} else {
    $confGuid = $null
    try { $confGuid = (Get-Label -Identity "Confidential" -ErrorAction Stop).Guid } catch {}

    if (-not $confGuid) {
        Write-Host "DLP SKIPPED: Confidential label does not exist, so there is no label to condition on"
    } else {
        Write-Host "DLP will condition on Confidential ($confGuid) ONLY - by design"
        $dlpLocations = '[{"Workload": "Applications", "Location": "Copilot.M365", "Inclusions": [{"Type": "Tenant", "Identity": "All"}], "LocationSource": "PurviewConfig", "LocationType": "Group"}]'

        $dlpPolOk = Invoke-WithRetry {
            New-DlpCompliancePolicy -Name $dlpPolicyName `
                -Mode Enable `
                -Locations $dlpLocations `
                -EnforcementPlanes ("CopilotExperiences") `
                -Comment "Day 2 Ex 2 - pre-made policy, live before the session" `
                -ErrorAction Stop | Out-Null
        } "New-DlpCompliancePolicy" 3 30

        if ($dlpPolOk) {
            # Label condition, expressed as a labels array inside
            # ContentContainsSensitiveInformation. name = the label GUID, not display name.
            $dlpCond = @(
                @{ operator = "And"
                   groups   = @(
                       @{ operator = "Or"
                          name     = "Default"
                          labels   = @( @{ name = $confGuid; type = "Sensitivity" } ) }
                   )}
            )

            Invoke-WithRetry {
                New-DlpComplianceRule -Name $dlpRuleName `
                    -Policy $dlpPolicyName `
                    -ContentContainsSensitiveInformation $dlpCond `
                    -RestrictAccess @(@{ setting = "ExcludeContentProcessing"; value = "Block" }) `
                    -ErrorAction Stop | Out-Null
            } "New-DlpComplianceRule" 3 30 | Out-Null

            if (Get-DlpComplianceRule -Identity $dlpRuleName -ErrorAction SilentlyContinue) {
                Write-Host "created and verified DLP rule: $dlpRuleName (Confidential label only)"
            } else {
                Write-Host "DLP RULE FAILED: $dlpRuleName does NOT exist - the policy will block nothing"
            }
        }
    }
}

# -------------------------------------------------------------------------------------
# 1c-ii) Insider Risk - Lab-Risky-AI-Usage
#
# InsiderRiskScenario is an enum of type
# Microsoft.Office.CompliancePolicy.Tasks.InsiderRisk.PlaybookScenarioType.
# RiskyAIUsage is the correct member. RiskyAgents is its agent-era companion and is named
# in the Day 2 guide as a discussion point without a policy being built on it.
#
# This needs days to accumulate scoreable activity, which is why it is seeded at T-48h
# rather than built by the learner. Learners build their own in Day 2 Ex 3 Task 1 and
# review this one's alert queue in Task 2.
# -------------------------------------------------------------------------------------
$irmPolicyName = "Lab-Risky-AI-Usage"
if (Get-InsiderRiskPolicy -Identity $irmPolicyName -ErrorAction SilentlyContinue) {
    Write-Host "Insider Risk policy exists: $irmPolicyName"
} else {
    Invoke-WithRetry {
        New-InsiderRiskPolicy -Name $irmPolicyName -InsiderRiskScenario RiskyAIUsage -ErrorAction Stop | Out-Null
    } "New-InsiderRiskPolicy" 3 30 | Out-Null

    if (Get-InsiderRiskPolicy -Identity $irmPolicyName -ErrorAction SilentlyContinue) {
        Write-Host "created and verified Insider Risk policy: $irmPolicyName"
    } else {
        Write-Host "INSIDER RISK FAILED: $irmPolicyName does NOT exist"
    }
}

# -------------------------------------------------------------------------------------
# 1c-iii) eDiscovery case - Lab-Copilot-Investigation
#
# TWO THINGS ARE REQUIRED. The eDiscovery Manager role group (section 1b) is NOT enough on
# its own. Without case membership the learner gets:
#   "You are not a member of the Content Search case."
#
# Add-ComplianceCaseMember is attempted here. The 1 Sept manual run added membership
# through the portal, so if this cmdlet fails, that is the documented fallback and the log
# below says so in terms a proctor can act on.
# -------------------------------------------------------------------------------------
$caseName = "Lab-Copilot-Investigation"
if (Get-ComplianceCase -Identity $caseName -ErrorAction SilentlyContinue) {
    Write-Host "eDiscovery case exists: $caseName"
} else {
    $caseMade = $false
    foreach ($ct in @("eDiscovery", $null)) {
        try {
            if ($ct) {
                New-ComplianceCase -Name $caseName -CaseType $ct -ErrorAction Stop | Out-Null
            } else {
                New-ComplianceCase -Name $caseName -ErrorAction Stop | Out-Null
            }
            Write-Host "created eDiscovery case: $caseName (CaseType: $(if($ct){$ct}else{'default'}))"
            $caseMade = $true
            break
        } catch {
            Write-Host "New-ComplianceCase (CaseType $(if($ct){$ct}else{'default'})) : $($_.Exception.Message)"
        }
    }
    if (-not $caseMade) { Write-Host "EDISCOVERY CASE FAILED: $caseName does NOT exist" }
}

# Membership attempted separately, so an already-existing case still gets the member added.
if (Get-ComplianceCase -Identity $caseName -ErrorAction SilentlyContinue) {
    try {
        Add-ComplianceCaseMember -Case $caseName -Member $upn -ErrorAction Stop | Out-Null
        Write-Host "eDiscovery: added $upn as a member of $caseName"
    } catch {
        Write-Host "eDiscovery case membership FAILED: $($_.Exception.Message)"
        Write-Host "  MANUAL STEP REQUIRED: Purview > eDiscovery > $caseName > Case settings >"
        Write-Host "  Permissions > add $upn . Without this, Day 2 Ex 4 Task 3 is blocked."
    }
}

# -------------------------------------------------------------------------------------
# 1c-iv) Communication Compliance - NOT AUTOMATED. DO NOT ADD IT BACK.
#
# Tested and ruled out on otuwamoc103906, 2 Sept 2026.
#
# New-SupervisoryReviewPolicyV2 exists in the IPPS session but creation is BLOCKED
# server-side:
#
#   Microsoft.Exchange.Management.UnifiedPolicy.LegacySupervisionPolicyCreationException
#   "Following the February 2020 release of Communication Compliance in the Microsoft 365
#    compliance center, supervision in the Office 365 Security & Compliance Center is
#    being retired and hence this command is no longer supported."
#
# All three policy shapes were rejected identically, so this is not a parameter problem.
# There is no replacement cmdlet and no Graph API for CC policies. Creation is portal-only.
#
# CONSEQUENCE: there is no pre-made CC policy on lab tenants. Day 2 Exercise 3 Task 4
# reviews the policy the LEARNER builds in Task 3, which needs no seeding because learners
# create it through the portal wizard themselves.
#
# WHY NOT CREATE IT BY HAND AT DEPLOY TIME: a hand-created policy would still almost
# certainly show an EMPTY Pending queue on a two-day-old tenant, because CC applies a
# sampling rate and needs time and message volume to accumulate reviewable items. The
# manual work buys a policy to open, not a populated queue. Not worth per-tenant clicks
# that do not scale across learner tenants.
#
# Full finding recorded in the project as Day2_CommCompliance_Ruled_Out.md.
# -------------------------------------------------------------------------------------
Write-Host "Communication Compliance: intentionally NOT seeded (portal-only, see comment)"

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
# This version acquires a bearer token the same way EnableMIPLabels does and sets the
# tenant property directly through CSOM. No interactive surface exists, so it cannot prompt
# and cannot hang - the timeout job is no longer needed.
#
# WHY IT MATTERS: without EnableAIPIntegration, sensitivity labels do not apply to Office
# files in SharePoint/OneDrive AND the SharePoint "Sensitivity" column is unavailable,
# which breaks Day 1 Exercise 4 and every Day 2 labelling step.
#
# The result is captured in $aipOk (rather than discarded to Out-Null) so the FINAL SUMMARY
# at the end of this script can report honestly on it.
$aipOk = Invoke-WithRetry {
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
} "EnableAIPIntegration (CSOM)" 5 60

# =====================================================================================
# 3) SHAREPOINT FILE SHARING (Day 1 Exercise 2 Task 3.1)
#
# Runs last on purpose. The site and its files are created by a SEPARATE process, so this
# gives that process the maximum possible time to finish, and retries while waiting.
#
# WHAT THIS PRODUCES: direct, per-item permissions that appear in the SharePoint
# "Manage access" panel as Direct access. That is precisely the oversharing signal Day 1
# Exercise 2 Task 3.1 asks learners to find. A sharing link would appear under Links
# instead and reads less clearly in the UI.
#
# HOW IT AUTHENTICATES: the same ROPC-token pattern proven by EnableAIPIntegration, but
# against the SITE host rather than the admin host, then plain SharePoint REST. No CSOM, so
# no type-literal parse-order problem and no Add-Type needed.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  DAY 1 EX 2 TASK 3.1 - FILE SHARING"
Write-Host "=============================================================="

# -------------------------------------------------------------------------------------
# ############ SET THESE TO MATCH YOUR SITE-CREATION PROCESS ############
#
# The filenames MUST match byte for byte what is actually uploaded, including hyphens and
# letter case. Several spellings of the employee-record file are in circulation across the
# lab guides. Whatever the upload process writes is the authority - set it here, and fix
# the guides to match, not the other way round.
#
# The block logs the FULL library listing before sharing anything, so a mismatch is
# obvious in the log rather than silent.
# -------------------------------------------------------------------------------------
$financeFile  = "Finance-Report-Test.docx"
$employeeFile = "Employee-Record-test.docx"
$controlFile  = "Unlabelled-Sensitive.docx"
$docLibTitle  = "Documents"
$siteRelative = "/sites/ContosoFinance$deployId"

# Who gets what. Users come from the lab environment definition (labuser01-03).
$shareMap = @(
    @{ File = $financeFile;  Users = @("labuser02", "labuser03"); Why = "Ex 2 Task 3.1 - finance report over-shared to two users" },
    @{ File = $employeeFile; Users = @("labuser01");              Why = "Ex 2 Task 3.1 - employee record over-shared to one user" },
    @{ File = $controlFile;  Users = @("labuser01");              Why = "Day 2 Ex 1 control file - proves the user's access works before the labelled file refuses them" }
)

# -------------------------------------------------------------------------------------
# WHY $controlFile IS IN THE LIST
#
# Day 2 Exercise 1 Task 3 has the second user open an UNLABELLED file successfully first,
# then be refused on the labelled one. Without that control step the learner cannot tell a
# label block from a permissions problem, and the exercise proves nothing.
#
# labuser01 is used for both because it already holds the employee record, which is the
# file Day 2 Exercise 1 labels Highly Confidential:
#   labuser01 -> Employee-Record-test.docx   gets labelled on Day 2, then refused
#             -> Unlabelled-Sensitive.docx   stays unlabelled during Ex 1, so it opens
#
# Unlabelled-Sensitive.docx is not labelled until Day 2 Exercise 2, which runs AFTER
# Exercise 1, so it is still unlabelled at the moment the control step needs it.
# -------------------------------------------------------------------------------------

$script:sharesDone = 0
$sharesWanted = ($shareMap | ForEach-Object { $_.Users.Count } | Measure-Object -Sum).Sum
$shareOk = $false

if (-not $deployId) {
    Write-Host "SHARING SKIPPED: DeploymentID could not be resolved - cannot build the site URL"
} else {
    $shareOk = Invoke-WithRetry {

        # Reset per attempt, so a retry does not double-count and overshoot the target.
        $script:sharesDone = 0

        $tenantPrefix = $org.Split('.')[0]
        $siteHost     = "https://$tenantPrefix.sharepoint.com"
        $siteUrl      = "$siteHost$siteRelative"

        # ROPC token scoped to the SharePoint SITE host (not the -admin host).
        $spBody = @{
            resource   = $siteHost
            client_id  = "1950a258-227b-4e31-a9cf-717495945fc2"
            grant_type = "password"
            username   = $upn
            password   = $pwd
        }
        $tok = (Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -Body $spBody -ErrorAction Stop).access_token
        if (-not $tok) { throw "no SharePoint access token returned" }

        $hdr = @{
            Authorization = "Bearer $tok"
            Accept        = "application/json;odata=verbose"
        }
        $hdrPost = $hdr.Clone()
        $hdrPost["Content-Type"] = "application/json;odata=verbose"

        # Confirm the site exists before doing anything else. This is the retry point if
        # the separate site-creation process has not finished yet.
        $web = Invoke-RestMethod -Uri "$siteUrl/_api/web" -Headers $hdr -ErrorAction Stop
        Write-Host "site reachable: '$($web.d.Title)' at $siteUrl"

        # Read permission level id, resolved once.
        $readDef = Invoke-RestMethod -Uri "$siteUrl/_api/web/roledefinitions/getbyname('Read')" -Headers $hdr -ErrorAction Stop
        $readId  = $readDef.d.Id
        Write-Host "Read permission level id: $readId"

        # Pull the library once and match filenames client-side. Filtering on FileLeafRef
        # server-side is unreliable across builds, and the library holds only five items.
        $items = (Invoke-RestMethod -Uri "$siteUrl/_api/web/lists/getbytitle('$docLibTitle')/items?`$select=Id,FileLeafRef" -Headers $hdr -ErrorAction Stop).d.results
        Write-Host "library items found: $(($items | Measure-Object).Count)"
        foreach ($it in $items) { Write-Host "  id=$($it.Id)  $($it.FileLeafRef)" }

        foreach ($entry in $shareMap) {

            $match = $items | Where-Object { $_.FileLeafRef -eq $entry.File } | Select-Object -First 1
            if (-not $match) {
                Write-Host "SHARE SKIPPED: '$($entry.File)' not found - check the filename against the listing above"
                continue
            }

            $itemId  = $match.Id
            $itemApi = "$siteUrl/_api/web/lists/getbytitle('$docLibTitle')/items($itemId)"

            # Break inheritance, keeping existing assignments so the admin does not lose
            # access. A second call on an already-broken item is harmless.
            try {
                Invoke-RestMethod -Method POST -Uri "$itemApi/breakroleinheritance(copyRoleAssignments=true,clearSubscopes=false)" -Headers $hdrPost -ErrorAction Stop | Out-Null
                Write-Host "$($entry.File) : inheritance broken"
            } catch {
                Write-Host "$($entry.File) : breakroleinheritance - $($_.Exception.Message) (continuing, likely already broken)"
            }

            foreach ($u in $entry.Users) {
                $login = "$u@$org"
                $principalId = $null

                try {
                    # ensureuser resolves the login to a site principal id, creating the
                    # site user entry on first appearance.
                    $ensureBody  = (@{ logonName = $login } | ConvertTo-Json -Compress)
                    $principal   = Invoke-RestMethod -Method POST -Uri "$siteUrl/_api/web/ensureuser" -Headers $hdrPost -Body $ensureBody -ErrorAction Stop
                    $principalId = $principal.d.Id
                } catch {
                    Write-Host "SHARE FAILED (ensureuser): $login : $($_.Exception.Message)"
                    continue
                }

                # Attempt the grant, then VERIFY by reading role assignments back.
                #
                # WHY VERIFY RATHER THAN TRUST THE POST: on a retry the assignment already
                # exists and the POST may error. Counting successful POSTs would then never
                # reach the target, and the block would burn all its retries on a state
                # that is already correct. Counting verified assignments is idempotent.
                try {
                    Invoke-RestMethod -Method POST -Uri "$itemApi/roleassignments/addroleassignment(principalid=$principalId,roledefid=$readId)" -Headers $hdrPost -ErrorAction Stop | Out-Null
                } catch {
                    Write-Host "$($entry.File) -> $login : addroleassignment said - $($_.Exception.Message) (verifying anyway)"
                }

                try {
                    $ras = (Invoke-RestMethod -Uri "$itemApi/roleassignments" -Headers $hdr -ErrorAction Stop).d.results
                    if ($ras | Where-Object { $_.PrincipalId -eq $principalId }) {
                        Write-Host "SHARED (verified): $($entry.File) -> $login (Read)"
                        $script:sharesDone++
                    } else {
                        Write-Host "SHARE NOT VERIFIED: $($entry.File) -> $login"
                    }
                } catch {
                    Write-Host "SHARE VERIFY FAILED: $($entry.File) -> $login : $($_.Exception.Message)"
                }
            }
            Write-Host "  purpose: $($entry.Why)"
        }

        if ($script:sharesDone -lt $sharesWanted) { throw "only $($script:sharesDone) of $sharesWanted shares verified" }
    } "SharePoint file sharing" 8 300
}

# 8 attempts at 300s gives the site-creation process up to ~40 minutes to finish after this
# block first runs. Widen the delay if that process is slower than that.

# =====================================================================================
# FINAL SUMMARY
#
# WHY THIS EXISTS: an earlier "baseline OK" line printed immediately after the label
# policy, which is BEFORE role groups, audit and EnableAIPIntegration have run. On
# environment 103908 that produced "baseline OK" on a tenant where audit was broken and the
# SharePoint Sensitivity column was never enabled - exactly the silent failure the summary
# was meant to catch.
#
# This block re-checks everything at the true end of the run. Grep for FINAL SUMMARY.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  FINAL SUMMARY - checked after ALL steps"
Write-Host "=============================================================="

# Count OUR five labels BY NAME, not every label in the tenant.
#
# WHY: (Get-Label).Count over-counts on any tenant carrying Microsoft's default labels. It
# could report 7/5 and pass the ALL GREEN check while one of ours was actually missing.
$fLabels = 0
foreach ($n in @("Public","Internal","Confidential","HighlyConfidential","Confidential-Finance")) {
    try { if (Get-Label -Identity $n -ErrorAction Stop) { $fLabels++ } } catch {}
}

$fPolicy = "NO"
try { if (Get-LabelPolicy -Identity "Lab-Confidential-Policy" -ErrorAction SilentlyContinue) { $fPolicy = "yes" } } catch {}

# Audit is an EXCHANGE ONLINE org setting. If the tenant has no Exchange licence this
# reports NO and the cause is licensing, not the script.
$fAudit = "NO"
try { if ((Get-AdminAuditLogConfig -ErrorAction Stop).UnifiedAuditLogIngestionEnabled) { $fAudit = "yes" } }
catch { $fAudit = "UNKNOWN" }

# EnableAIPIntegration cannot be read back from here, so report whether the step ran clean.
$fAip = if ($aipOk) { "yes" } else { "NO" }

# Day 2 objects
$fDlp = "NO"; $fIrm = "NO"; $fCase = "NO"
try { if (Get-DlpComplianceRule -Identity "Lab-Block-Copilot-On-Labels" -ErrorAction SilentlyContinue) { $fDlp  = "yes" } } catch {}
try { if (Get-InsiderRiskPolicy -Identity "Lab-Risky-AI-Usage"          -ErrorAction SilentlyContinue) { $fIrm  = "yes" } } catch {}
try { if (Get-ComplianceCase    -Identity "Lab-Copilot-Investigation"   -ErrorAction SilentlyContinue) { $fCase = "yes" } } catch {}

$fShare = if ($shareOk) { "yes" } else { "NO" }

Write-Host "FINAL SUMMARY: labels=$fLabels/5 policy=$fPolicy audit=$fAudit aipIntegration=$fAip"
Write-Host "FINAL SUMMARY: sharing=$fShare ($($script:sharesDone)/$sharesWanted)"
Write-Host "FINAL SUMMARY: dlp=$fDlp irm=$fIrm ediscoveryCase=$fCase (commCompliance: portal-only, not seeded)"

$day1Ready = ($fLabels -ge 5 -and $fPolicy -eq "yes" -and $fAudit -eq "yes" -and $fAip -eq "yes" -and $fShare -eq "yes")
$day2Ready = ($fDlp -eq "yes" -and $fIrm -eq "yes" -and $fCase -eq "yes")

if ($day1Ready -and $day2Ready) {
    Write-Host "FINAL SUMMARY: ALL GREEN - tenant is ready for both days"
} else {
    if ($fLabels -lt 5 -or $fPolicy -eq "NO") {
        Write-Host "FINAL SUMMARY: BASELINE INCOMPLETE - do not hand this tenant to learners"
    } else {
        Write-Host "FINAL SUMMARY: labels and policy OK. Gaps below:"
    }
    if ($fAudit -ne "yes") {
        Write-Host "FINAL SUMMARY:   - AUDIT NOT ON. Day 1 Ex 2 and all DSPM/Activity Explorer"
        Write-Host "FINAL SUMMARY:     reporting will be empty, and Day 2 Ex 4 Task 4 fails."
        Write-Host "FINAL SUMMARY:     Check the tenant has an EXCHANGE ONLINE licence."
    }
    if ($fAip -ne "yes") {
        Write-Host "FINAL SUMMARY:   - NO SHAREPOINT SENSITIVITY COLUMN. Day 1 Ex 4 and every"
        Write-Host "FINAL SUMMARY:     Day 2 labelling step fail. Turn on manually: Purview >"
        Write-Host "FINAL SUMMARY:     Information Protection > 'Turn on now' banner."
    }
    if ($fShare -ne "yes") {
        Write-Host "FINAL SUMMARY:   - FILE SHARING INCOMPLETE ($($script:sharesDone)/$sharesWanted)."
        Write-Host "FINAL SUMMARY:     Day 1 Ex 2 Task 3.1 has no oversharing to find, and Day 2"
        Write-Host "FINAL SUMMARY:     Ex 1 Task 3 has no control file. Check the site existed and"
        Write-Host "FINAL SUMMARY:     the filenames matched the library listing logged above."
    }
    if ($fDlp -ne "yes") {
        Write-Host "FINAL SUMMARY:   - NO LIVE DLP POLICY. Day 2 Ex 2 Task 4 cannot demonstrate"
        Write-Host "FINAL SUMMARY:     enforcement. This is Day 2's centrepiece - fix before handover."
    }
    if ($fIrm -ne "yes") {
        Write-Host "FINAL SUMMARY:   - NO PRE-MADE INSIDER RISK POLICY. Day 2 Ex 3 Task 2 becomes"
        Write-Host "FINAL SUMMARY:     a guided review with no policy listed."
    }
    if ($fCase -ne "yes") {
        Write-Host "FINAL SUMMARY:   - NO EDISCOVERY CASE. Day 2 Ex 4 Task 3 is blocked."
    }
    Write-Host "FINAL SUMMARY: Day1Ready=$day1Ready  Day2Ready=$day2Ready"
}

try { Disconnect-ExchangeOnline -Confirm:$false } catch {}
Write-Host "Seeding complete."
Stop-Transcript
'@

$labelScript | Set-Content -Path $labelScriptPath -Encoding UTF8

# Schedule the seeding task: one-time, 30 MINUTES out, as SYSTEM (no password, runs whether
# logged on or not). 30 min gives a fresh tenant time to settle before the connects.
#
# WORST-CASE RUNTIME: 30 min delay + up to ~2h waiting for Azure RMS + up to ~40 min
# waiting for the SharePoint site to exist = roughly 3.5 hours. Comfortable at T-48h.
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
# is deallocated (or simply not running) at the trigger time, the seeding is silently
# skipped forever and the tenant is left with no labels.
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
# troubleshooting this tenant by hand should use PS 7.
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

# Create credentials file on Desktop for quick access.
#
# THE LABUSER SECTION MATTERS FOR DAY 2. Exercise 1 Task 3 sends the learner here to sign
# in as a second user. Passwords are auto-generated by CloudLabs, so this CSE does not know
# them and the file points at the environment page instead. If CloudLabs can inject the
# generated passwords, replace the placeholder line with the real values.
$tenantDomain = $AzureUserName.Split('@')[-1]
$credContent = @"
=== Lab Credentials ===
Azure Username : $AzureUserName
Azure Password : $AzurePassword
Tenant ID      : $AzureTenantID
Subscription ID: $AzureSubscriptionID
Deployment ID  : $DeploymentID

=== Additional Lab Users (Day 2 Exercise 1) ===
These accounts hold NO usage rights on the encrypted sensitivity labels. Day 2
Exercise 1 uses labuser01 to show that Purview refuses a user who has valid
SharePoint access but no rights on the label.

labuser01      : labuser01@$tenantDomain
labuser02      : labuser02@$tenantDomain
labuser03      : labuser03@$tenantDomain
Passwords      : see the lab environment page (auto-generated at provisioning)

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
