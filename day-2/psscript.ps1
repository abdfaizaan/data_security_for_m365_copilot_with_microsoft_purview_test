
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

# =====================================================================================
# DAY 2 CUSTOM SCRIPT EXTENSION
#
# Mirrors the proven Day 1 psscript.ps1 structure. The substantive differences:
#
#   1. The embedded seeding script is Day2-Seed.ps1, which adds the custom SIT, the
#      DLP for Copilot policy and rule, the Insider Risk policy, Communication
#      Compliance, Copilot app retention, the eDiscovery case, and the eDiscovery
#      Manager / Insider Risk / Communication Compliance role groups.
#
#   2. The scheduled task fires at T+45 minutes rather than T+30. Day 2 has more
#      tenant work to do and there is no cost to waiting, since deployment is at T-48h.
#
# WHAT THIS SCRIPT DOES NOT DO:
#   - It does not create the SharePoint site or the 5 test files. That is your separate
#     SharePoint provisioning script and it must also run.
#   - It does not create the second lab user. CloudLabs provisions that at tenant
#     creation, with a base licence, SharePoint read on the ContosoFinance site, no
#     admin roles, no MFA, and a password that does not require change at first sign-in.
#
# TIMING: leave the VM running for 3 HOURS after deployment. The seeding task can wait
# up to ~2 hours for Azure RMS to provision on a fresh tenant, and deallocating mid-run
# kills it with no resume.
#
# VERIFICATION: grep the seeding log for SUMMARY.
#   Select-String -Path C:\WindowsAzure\Logs\Day2Seeding.log -Pattern "SUMMARY:"
# You want "baseline OK". "CORE OK" means Exercises 1 and 2 work but something in 3, 4
# or 5 is missing. "BASELINE INCOMPLETE" means do not hand the tenant to learners.
# =====================================================================================

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
# Write the Day 2 seeding script. Order inside it is deliberate: labels and the label
# policy first (the critical deliverable and the most reliable step), then the Day 2
# policy objects, then the ancillary tenant settings. Nothing downstream can block the
# labels.
#
# The two inner here-strings below use @" rather than @' so that their terminators
# cannot close this outer literal here-string. Any $ inside them that must survive to
# the generated file is backtick-escaped.
# =====================================================================================
$seedScriptPath = "C:\LabFiles\Day2Seeding.ps1"
$seedScript = @'
# =====================================================================================
# DAY 2 TENANT SEEDING SCRIPT
#
# Runs on the learner jump VM as SYSTEM, scheduled by Day2-psscript.ps1.
# Logs to C:\WindowsAzure\Logs\Day2Seeding.log
#
# -------------------------------------------------------------------------------------
# AUTHENTICATION MODEL
# -------------------------------------------------------------------------------------
# Uses the ODL admin username + password read from C:\LabFiles\AzureCreds.txt.
#
# Why this is acceptable on CloudLabs ODL tenants:
#   - Security defaults are off and MFA is not enforced on these tenants
#   - The credential is already on the VM's desktop for the learner to use
#   - No client secret is introduced; the learner has local admin on this VM, so
#     placing an app secret here would be strictly worse
#
# If MFA ever appears on ODL tenants this script fails at the auth probe and says
# so loudly rather than half-completing. The migration path is a service principal
# with Compliance Administrator + an app-only IPPS connection via certificate.
# Do NOT migrate to a client secret on this VM.
# -------------------------------------------------------------------------------------
#
# OBJECT NAMES ARE LOCKED. They match environment 103906 exactly so that lab guide
# screenshots taken from that tenant stay valid. Do not rename without re-shooting
# every screenshot that shows a policy list or policy detail page.
#
#   Labels          Public, Internal, Confidential, HighlyConfidential,
#                   Confidential-Finance
#   Label policy    Lab-Confidential-Policy
#   Custom SIT      Contoso Employee ID
#   DLP policy      Lab-Copilot-DLP-Test
#   DLP rule        Lab-Block-Copilot-On-Labels
#   IRM policy      Lab-Risky-AI-Usage
#   Comm compliance Lab-Copilot-Comm-Compliance
#   Retention       Lab-Copilot-Retention / Lab-Copilot-Retention-Rule
#   eDiscovery case Lab-Copilot-Investigation
# =====================================================================================

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$logPath = "C:\WindowsAzure\Logs\Day2Seeding.log"
New-Item -ItemType Directory -Path (Split-Path $logPath) -Force -ErrorAction SilentlyContinue | Out-Null
Start-Transcript -Path $logPath -Append -ErrorAction SilentlyContinue

Write-Host "===== DAY 2 SEEDING STARTED $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="

# =====================================================================================
# HELPERS
# =====================================================================================

function Invoke-WithRetry {
    param(
        [scriptblock]$Script,
        [string]$Name,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 30
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            & $Script
            Write-Host "OK: $Name"
            return $true
        } catch {
            Write-Host "$Name attempt $i/$Attempts failed: $($_.Exception.Message)"
            if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
        }
    }
    Write-Host "GAVE UP: $Name after $Attempts attempts"
    return $false
}

# =====================================================================================
# 1. MODULES
# =====================================================================================
Write-Host ""
Write-Host "--- installing modules ---"
foreach ($m in @("ExchangeOnlineManagement", "Microsoft.Online.SharePoint.PowerShell", "AIPService")) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        try {
            Install-Module -Name $m -Force -AllowClobber -Scope AllUsers `
                -Repository PSGallery -ErrorAction Stop
            Write-Host "installed: $m"
        } catch { Write-Host "install failed for $m : $($_.Exception.Message)" }
    } else { Write-Host "already present: $m" }
}
Import-Module ExchangeOnlineManagement -Force -ErrorAction SilentlyContinue

# =====================================================================================
# 2. CREDENTIALS
# =====================================================================================
Write-Host ""
Write-Host "--- reading credentials ---"
$credFile = "C:\LabFiles\AzureCreds.txt"
if (-not (Test-Path $credFile)) {
    Write-Host "FATAL: $credFile not found. The CSE did not complete. Stopping."
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

$creds    = Get-Content $credFile
$upn      = ($creds | Select-String "AzureAdUserName").ToString().Split('=')[1].Trim()
$pwd      = ($creds | Select-String "AzureAdUserPassword").ToString().Split('=')[1].Trim()
$tenantId = ($creds | Select-String "TenantID").ToString().Split('=')[1].Trim()
$org      = $upn.Split('@')[1]

$sec  = ConvertTo-SecureString $pwd -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($upn, $sec)

Write-Host "upn: $upn"
Write-Host "org: $org"

# =====================================================================================
# 3. AUTH PROBE — fail loudly, do not limp on
# =====================================================================================
Write-Host ""
Write-Host "--- auth probe ---"
$connected = Invoke-WithRetry {
    Connect-IPPSSession -Credential $cred -DisableWAM -ShowBanner:$false -ErrorAction Stop
} "Connect-IPPSSession" 5 30

if (-not $connected) {
    Write-Host ""
    Write-Host "FATAL: cannot authenticate to Security & Compliance PowerShell."
    Write-Host "Everything below depends on this. Common causes:"
    Write-Host "  - MFA has been enabled on this tenant (check Entra security defaults)"
    Write-Host "  - the credential file holds a stale password"
    Write-Host "  - the tenant has no Purview licence assigned"
    Write-Host "SUMMARY: BASELINE INCOMPLETE - auth failed, do not hand this tenant to learners"
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

# =====================================================================================
# 4. SENSITIVITY LABELS
#
# RMS is not provisioned on a fresh tenant for some hours. Only ENCRYPTED labels
# touch it, which is why plain labels always succeed and encrypted ones fail with
# RmsException on a young tenant.
#
# The first encrypted label therefore gets a long gate (up to ~2 hours). Once it
# lands, RMS is up and the rest go through in seconds.
#
# Every creation is VERIFIED with Get-Label. New-Label reports RmsException as a
# NON-TERMINATING error, so a plain try/catch silently reports success for labels
# that do not exist.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  SENSITIVITY LABELS"
Write-Host "=============================================================="

$rights = "$($upn):VIEW,VIEWRIGHTSDATA,DOCEDIT,EDIT,PRINT,EXTRACT,REPLY,REPLYALL,FORWARD,OBJMODEL"

$labels = @(
    @{ N="Public";               D="Public";               T="Freely shareable inside and outside the organization."; F="This document is classified as Public"; E=$false },
    @{ N="Internal";             D="Internal";             T="Internal use only.";                                    H="Internal Use Only"; F="This document is classified as Internal"; E=$false },
    @{ N="Confidential";         D="Confidential";         T="Restricted to authorized personnel.";                   H="Confidential Document"; F="Confidential Document"; W="Confidential"; E=$true },
    @{ N="HighlyConfidential";   D="Highly Confidential";  T="Highly sensitive - named users only.";                  H="HIGHLY CONFIDENTIAL"; F="Unauthorized disclosure is strictly prohibited"; W="HIGHLY CONFIDENTIAL"; E=$true },
    @{ N="Confidential-Finance"; D="Confidential-Finance"; T="Finance information containing sensitive data.";        H="Confidential Document"; F="Confidential Document"; W="Confidential"; E=$true }
)

$firstEncryptedDone = $false

foreach ($l in $labels) {

    if (Get-Label -Identity $l.N -ErrorAction SilentlyContinue) {
        Write-Host "label exists: $($l.D)"
        if ($l.E) { $firstEncryptedDone = $true }
        continue
    }

    $p = @{
        Name        = $l.N
        DisplayName = $l.D
        Tooltip     = $l.T
        ContentType = "File, Email, Site, UnifiedGroup, Teamwork"
    }
    if ($l.H) { $p.ApplyContentMarkingHeaderEnabled = $true; $p.ApplyContentMarkingHeaderText = $l.H; $p.ApplyContentMarkingHeaderAlignment = "Center" }
    if ($l.F) { $p.ApplyContentMarkingFooterEnabled = $true; $p.ApplyContentMarkingFooterText = $l.F; $p.ApplyContentMarkingFooterAlignment = "Center" }
    if ($l.W) { $p.ApplyWaterMarkingEnabled = $true; $p.ApplyWaterMarkingText = $l.W; $p.ApplyWaterMarkingLayout = "Diagonal" }
    if ($l.E) {
        $p.EncryptionEnabled                          = $true
        $p.EncryptionProtectionType                   = "Template"
        $p.EncryptionRightsDefinitions                = $rights
        $p.EncryptionContentExpiredOnDateInDaysOrNever = "Never"
        $p.EncryptionOfflineAccessDays                = -1
    }

    # Retry budget: plain labels are quick. The FIRST encrypted label waits for RMS
    # to provision, which is the long pole. Subsequent encrypted labels are fast.
    if (-not $l.E) {
        $attempts = 3;  $wait = 30
    } elseif (-not $firstEncryptedDone) {
        $attempts = 12; $wait = 600     # up to 2 hours - the RMS gate
        Write-Host ""
        Write-Host ">>> RMS GATE: $($l.D) is the first encrypted label."
        Write-Host ">>> Waiting up to 2 hours for Azure Rights Management to provision."
        Write-Host ">>> This is expected on a fresh tenant. Do not kill the task."
    } else {
        $attempts = 4;  $wait = 60
    }

    $created = $false
    for ($i = 1; $i -le $attempts; $i++) {
        try { New-Label @p -ErrorAction Stop | Out-Null }
        catch { Write-Host "New-Label $($l.N) attempt $i/$attempts threw: $($_.Exception.Message)" }

        Start-Sleep -Seconds 5
        if (Get-Label -Identity $l.N -ErrorAction SilentlyContinue) {
            Write-Host "created and verified label: $($l.D)"
            $created = $true
            if ($l.E) { $firstEncryptedDone = $true }
            break
        }

        Write-Host "label $($l.N) not present after attempt $i/$attempts"
        if ($i -lt $attempts) {
            Write-Host "  waiting $wait seconds (RMS may still be provisioning)"
            Start-Sleep -Seconds $wait
        }
    }

    if (-not $created) { Write-Host "LABEL FAILED: $($l.D) does NOT exist after $attempts attempts" }
}

# --- Label policy, built only from labels that actually exist ---
Write-Host ""
Write-Host "--- label policy ---"
$policyName = "Lab-Confidential-Policy"

if (-not (Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue)) {
    $guids = @()
    foreach ($n in @("Public","Internal","Confidential","HighlyConfidential","Confidential-Finance")) {
        try {
            $g = (Get-Label -Identity $n -ErrorAction Stop).Guid
            if ($g) { $guids += $g }
        } catch { Write-Host "policy: skipping missing label $n" }
    }
    Write-Host "policy will include $($guids.Count) of 5 labels"

    if ($guids.Count -eq 0) {
        Write-Host "POLICY FAILED: no labels exist to publish"
    } else {
        for ($i = 1; $i -le 3; $i++) {
            try {
                New-LabelPolicy -Name $policyName -Labels $guids `
                    -ExchangeLocation All -SharePointLocation All -OneDriveLocation All `
                    -ModernGroupLocation All -Comment "Day2 lab label policy" -ErrorAction Stop | Out-Null
            } catch { Write-Host "New-LabelPolicy attempt $i/3 threw: $($_.Exception.Message)" }
            Start-Sleep -Seconds 5
            if (Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue) {
                Write-Host "created and verified label policy: $policyName"
                break
            }
            if ($i -lt 3) { Start-Sleep -Seconds 30 }
        }
    }
} else { Write-Host "label policy exists: $policyName" }

# =====================================================================================
# 5. CUSTOM SIT — Contoso Employee ID
#
# The <Version> element inside RulePack metadata must be present but
# minEngineVersion must NOT be set - that was what failed schema validation on the
# first attempt. This exact XML is confirmed working and confirmed matching via
# Test-DataClassification (EMP-123456, count 1, confidence 75).
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  CUSTOM SIT"
Write-Host "=============================================================="

if (Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq "Contoso Employee ID" }) {
    Write-Host "SIT exists: Contoso Employee ID"
} else {
    $sitXml = @"
<?xml version="1.0" encoding="utf-8"?>
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="A1B2C3D4-1111-2222-3333-444455556666">
    <Version major="1" minor="0" build="0" revision="0"/>
    <Publisher id="B1B2C3D4-1111-2222-3333-444455556666"/>
    <Details defaultLangCode="en-us">
      <LocalizedDetails langcode="en-us">
        <PublisherName>Contoso Lab</PublisherName>
        <Name>Contoso Lab Rule Package</Name>
        <Description>Custom SITs for the Purview Copilot lab.</Description>
      </LocalizedDetails>
    </Details>
  </RulePack>
  <Rules>
    <Entity id="C1B2C3D4-1111-2222-3333-444455556666" patternsProximity="300" recommendedConfidence="75">
      <Pattern confidenceLevel="75">
        <IdMatch idRef="Regex_ContosoEmployeeId"/>
      </Pattern>
    </Entity>
    <Regex id="Regex_ContosoEmployeeId">EMP-\d{6}</Regex>
    <LocalizedStrings>
      <Resource idRef="C1B2C3D4-1111-2222-3333-444455556666">
        <Name default="true" langcode="en-us">Contoso Employee ID</Name>
        <Description default="true" langcode="en-us">Detects Contoso employee IDs in the format EMP-123456.</Description>
      </Resource>
    </LocalizedStrings>
  </Rules>
</RulePackage>
"@

    Invoke-WithRetry {
        New-Item -ItemType Directory -Path "C:\LabFiles" -Force | Out-Null
        $sitPath = "C:\LabFiles\EmpIdSit.xml"
        [System.IO.File]::WriteAllText($sitPath, $sitXml, (New-Object System.Text.UTF8Encoding($false)))
        New-DlpSensitiveInformationTypeRulePackage `
            -FileData ([System.IO.File]::ReadAllBytes($sitPath)) -ErrorAction Stop | Out-Null
    } "SIT rule package import" 3 30 | Out-Null

    Start-Sleep -Seconds 10
    if (Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq "Contoso Employee ID" }) {
        Write-Host "created and verified SIT: Contoso Employee ID"
    } else {
        Write-Host "SIT FAILED: Contoso Employee ID does not exist"
    }
}

# =====================================================================================
# 6. DLP FOR COPILOT — the pre-made policy the learner tests against
#
# Created in Enable mode at deploy time so it has ~48 hours to distribute and is
# genuinely enforcing when class starts. The learner builds their own equivalent
# during Exercise 2, which will NOT enforce within the 4-hour class - the guide
# says so explicitly.
#
# CONFIRMED WORKING on 103906: Copilot refused a Confidential-labelled file with
# "None of the files or resources you requested are available due to your
# organization's policies."
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  DLP FOR COPILOT"
Write-Host "=============================================================="

$dlpPolicyName = "Lab-Copilot-DLP-Test"
$dlpRuleName   = "Lab-Block-Copilot-On-Labels"

if (-not (Get-DlpCompliancePolicy -Identity $dlpPolicyName -ErrorAction SilentlyContinue)) {
    $locations = '[{"Workload": "Applications", "Location": "Copilot.M365", "Inclusions": [{"Type": "Tenant", "Identity": "All"}], "LocationSource": "PurviewConfig", "LocationType": "Group"}]'

    Invoke-WithRetry {
        New-DlpCompliancePolicy -Name $dlpPolicyName `
            -Mode Enable `
            -Locations $locations `
            -EnforcementPlanes ("CopilotExperiences") `
            -Comment "Day2 lab - pre-made policy, live before class so it actually enforces" `
            -ErrorAction Stop | Out-Null
    } "New-DlpCompliancePolicy" 3 30 | Out-Null
} else { Write-Host "DLP policy exists: $dlpPolicyName" }

if (Get-DlpCompliancePolicy -Identity $dlpPolicyName -ErrorAction SilentlyContinue) {
    Write-Host "verified DLP policy: $dlpPolicyName"

    if (-not (Get-DlpComplianceRule -Identity $dlpRuleName -ErrorAction SilentlyContinue)) {

        # Sensitivity labels go inside ContentContainsSensitiveInformation as a
        # 'labels' array with type = Sensitivity. This is the part the DSPM
        # one-click recommendation gets wrong - it emits only an external-sender
        # condition, which protects nothing we care about.
        $labelGuids = @()
        foreach ($n in @("Confidential","HighlyConfidential","Confidential-Finance")) {
            try {
                $g = (Get-Label -Identity $n -ErrorAction Stop).Guid.ToString()
                if ($g) { $labelGuids += $g; Write-Host "  rule will match label $n -> $g" }
            } catch { Write-Host "  rule: label $n not found, skipping" }
        }

        if ($labelGuids.Count -eq 0) {
            Write-Host "DLP RULE FAILED: no encrypted labels exist to match on"
        } else {
            $cond = @(
                @{
                    operator = "And"
                    groups   = @(
                        @{
                            operator = "Or"
                            name     = "Default"
                            labels   = @( $labelGuids | ForEach-Object { @{ name = $_; type = "Sensitivity" } } )
                        }
                    )
                }
            )

            Invoke-WithRetry {
                New-DlpComplianceRule -Name $dlpRuleName `
                    -Policy $dlpPolicyName `
                    -ContentContainsSensitiveInformation $cond `
                    -RestrictAccess @(@{ setting = "ExcludeContentProcessing"; value = "Block" }) `
                    -ErrorAction Stop | Out-Null
            } "New-DlpComplianceRule" 3 30 | Out-Null

            if (Get-DlpComplianceRule -Identity $dlpRuleName -ErrorAction SilentlyContinue) {
                Write-Host "created and verified DLP rule: $dlpRuleName"
            } else {
                Write-Host "DLP RULE FAILED: $dlpRuleName does not exist"
            }
        }
    } else { Write-Host "DLP rule exists: $dlpRuleName" }
}

# =====================================================================================
# 7. ROLE GROUPS
#
# eDiscovery Manager is new for Day 2 and is REQUIRED - without it Exercise 4
# Task 3 dead-ends on "You are not a member of the Content Search case".
# Note the role group alone is not sufficient; case-level permissions are set
# in section 11.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  ROLE GROUPS"
Write-Host "=============================================================="

$roleGroups = @(
    "ContentExplorerListViewer",
    "ContentExplorerContentViewer",
    "DataSecurityAIContentViewers",
    "eDiscovery Manager",
    "Insider Risk Management",
    "Communication Compliance"
)

foreach ($rg in $roleGroups) {
    try {
        $existing = Get-RoleGroupMember -Identity $rg -ErrorAction Stop |
                    Where-Object { $_.WindowsLiveID -eq $upn -or $_.PrimarySmtpAddress -eq $upn }
        if ($existing) {
            Write-Host "already a member: $rg"
        } else {
            Add-RoleGroupMember -Identity $rg -Member $upn -Confirm:$false -ErrorAction Stop
            Write-Host "added to role group: $rg"
        }
    } catch {
        Write-Host "role group $rg : $($_.Exception.Message)"
    }
}

# Role membership is bound at session start, so reconnect before using the new
# rights below.
Write-Host ""
Write-Host "--- reconnecting IPPS to pick up new role memberships ---"
try {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    Connect-IPPSSession -Credential $cred -DisableWAM -ShowBanner:$false -ErrorAction Stop
    Write-Host "reconnected"
} catch {
    Write-Host "reconnect failed: $($_.Exception.Message) - continuing anyway"
}

# =====================================================================================
# 8. INSIDER RISK — RiskyAIUsage
#
# Created at deploy time so it has ~48 hours of warm-up before class. Whether it
# actually flags the learner's morning prompts by the afternoon is the open
# question (Test 8). If it does, Exercise 3 Tasks 2 and 4 are live; if not they
# are walkthroughs, which is what Microsoft's own labs do.
#
# Enum confirmed: PlaybookScenarioType. RiskyAIUsage is valid. So is RiskyAgents.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  INSIDER RISK"
Write-Host "=============================================================="

$irmName = "Lab-Risky-AI-Usage"
if (-not (Get-InsiderRiskPolicy -Identity $irmName -ErrorAction SilentlyContinue)) {
    Invoke-WithRetry {
        New-InsiderRiskPolicy -Name $irmName -InsiderRiskScenario RiskyAIUsage -ErrorAction Stop | Out-Null
    } "New-InsiderRiskPolicy" 3 30 | Out-Null

    if (Get-InsiderRiskPolicy -Identity $irmName -ErrorAction SilentlyContinue) {
        Write-Host "created and verified IRM policy: $irmName"
    } else {
        Write-Host "IRM FAILED: $irmName does not exist"
        Write-Host "  if this reports missing parameters, run Get-Command New-InsiderRiskPolicy -Syntax"
        Write-Host "  a TenantSetting-scenario policy may need to exist first"
    }
} else { Write-Host "IRM policy exists: $irmName" }

# =====================================================================================
# 9. COMMUNICATION COMPLIANCE
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  COMMUNICATION COMPLIANCE"
Write-Host "=============================================================="

$ccName = "Lab-Copilot-Comm-Compliance"
if (-not (Get-SupervisoryReviewPolicyV2 -Identity $ccName -ErrorAction SilentlyContinue)) {
    Invoke-WithRetry {
        New-SupervisoryReviewPolicyV2 -Name $ccName `
            -Reviewers $upn `
            -Comment "Day2 lab - review risky Copilot and messaging content" `
            -ErrorAction Stop | Out-Null
    } "New-SupervisoryReviewPolicyV2" 3 30 | Out-Null

    if (Get-SupervisoryReviewPolicyV2 -Identity $ccName -ErrorAction SilentlyContinue) {
        Write-Host "created and verified CC policy: $ccName"
        Invoke-WithRetry {
            New-SupervisoryReviewRule -Name "Lab-Copilot-CC-Rule" `
                -Policy $ccName `
                -Condition "NOT(Reviewee:none)" `
                -SamplingRate 100 -ErrorAction Stop | Out-Null
        } "New-SupervisoryReviewRule" 3 30 | Out-Null
    } else {
        Write-Host "CC FAILED: $ccName does not exist"
    }
} else { Write-Host "CC policy exists: $ccName" }

# =====================================================================================
# 10. APP RETENTION FOR COPILOT
#
# Applications = "User:M365Copilot", and -ExchangeLocation IS REQUIRED. The User:
# prefix scopes the data to user mailboxes, so the cmdlet needs to know which.
# Omitting it fails with "user applications are present, but ExchangeLocations is
# missing".
#
# The full allowed application list is a teaching asset - it includes
# ChatGPTEnterprise, CloudAIAppChatGPTConsumer, CloudAIAppGoogleGemini, DeepSeek
# and BingConsumer. See Day2_Parameter_Values_Confirmed.md.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  APP RETENTION"
Write-Host "=============================================================="

$retName = "Lab-Copilot-Retention"
if (-not (Get-AppRetentionCompliancePolicy -Identity $retName -ErrorAction SilentlyContinue)) {
    Invoke-WithRetry {
        New-AppRetentionCompliancePolicy -Name $retName `
            -Applications "User:M365Copilot" `
            -ExchangeLocation All `
            -Comment "Day2 lab - retain Copilot interactions" `
            -ErrorAction Stop | Out-Null
    } "New-AppRetentionCompliancePolicy" 3 30 | Out-Null

    if (Get-AppRetentionCompliancePolicy -Identity $retName -ErrorAction SilentlyContinue) {
        Write-Host "created and verified retention policy: $retName"
        Invoke-WithRetry {
            New-AppRetentionComplianceRule -Name "Lab-Copilot-Retention-Rule" `
                -Policy $retName `
                -RetentionDuration 2555 `
                -RetentionComplianceAction Keep `
                -ErrorAction Stop | Out-Null
        } "New-AppRetentionComplianceRule" 3 30 | Out-Null
    } else {
        Write-Host "RETENTION FAILED: $retName does not exist"
    }
} else { Write-Host "retention policy exists: $retName" }

# =====================================================================================
# 11. eDISCOVERY CASE + CASE PERMISSIONS
#
# Both parts are needed. The eDiscovery Manager role group (section 7) is not
# sufficient on its own in the unified experience - the user must also be a
# member of the CASE. Without this, Exercise 4 Task 3 dead-ends.
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  eDISCOVERY"
Write-Host "=============================================================="

$caseName = "Lab-Copilot-Investigation"
if (-not (Get-ComplianceCase -Identity $caseName -ErrorAction SilentlyContinue)) {
    Invoke-WithRetry {
        New-ComplianceCase -Name $caseName `
            -CaseType eDiscovery `
            -Description "Day2 lab - search Copilot interactions" `
            -ErrorAction Stop | Out-Null
    } "New-ComplianceCase" 3 30 | Out-Null
} else { Write-Host "eDiscovery case exists: $caseName" }

if (Get-ComplianceCase -Identity $caseName -ErrorAction SilentlyContinue) {
    Write-Host "verified eDiscovery case: $caseName"
    Invoke-WithRetry {
        Add-ComplianceCaseMember -Case $caseName -Member $upn -ErrorAction Stop | Out-Null
    } "Add-ComplianceCaseMember" 3 30 | Out-Null

    # Fallback: some tenants expose case membership only through the role group
    # holder object. If the above failed, this is the manual step for the runbook.
    Write-Host "NOTE: if case membership failed, set it in the portal:"
    Write-Host "  Purview > eDiscovery > $caseName > Case settings > Permissions"
}

# =====================================================================================
# 12. EXCHANGE — org customization, Organization Management, audit
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  EXCHANGE"
Write-Host "=============================================================="

Invoke-WithRetry {
    Connect-ExchangeOnline -Credential $cred -DisableWAM -ShowBanner:$false -ErrorAction Stop
} "Connect-ExchangeOnline" 5 60 | Out-Null

Invoke-WithRetry {
    Enable-OrganizationCustomization -ErrorAction Stop
} "Enable-OrganizationCustomization" 2 30 | Out-Null

Invoke-WithRetry {
    Add-RoleGroupMember -Identity "Organization Management" -Member $upn -Confirm:$false -ErrorAction Stop
} "Organization Management membership" 3 30 | Out-Null

Invoke-WithRetry {
    $auditOn = (Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled
    if (-not $auditOn) {
        Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop
        Write-Host "audit: enabled"
    } else {
        Write-Host "audit: already enabled"
    }
} "audit ingestion" 3 60 | Out-Null

# Audit is an EXCHANGE ONLINE org setting, not a Purview one. On environment 103908 it
# failed with "Organization ... is not licensed for Exchange email functionality" even
# though Purview labels created fine - the tenant had Purview licensing but no Exchange
# licensing. Check this explicitly so the summary can report it rather than staying
# silent.
$auditOk = $false
try { $auditOk = (Get-AdminAuditLogConfig -ErrorAction Stop).UnifiedAuditLogIngestionEnabled }
catch {
    Write-Host "audit verify failed: $($_.Exception.Message)"
    if ($_.Exception.Message -match "not licensed for Exchange") {
        Write-Host "audit: TENANT HAS NO EXCHANGE ONLINE LICENCE - this is a provisioning gap,"
        Write-Host "audit: not a script problem. Raise it before handing the tenant over."
    }
}

# =====================================================================================
# 13. CONTAINER LABELS (EnableMIPLabels) via Graph
# =====================================================================================
Write-Host ""
Write-Host "--- EnableMIPLabels ---"
Invoke-WithRetry {
    $body = @{
        resource   = "https://graph.microsoft.com"
        client_id  = "1950a258-227b-4e31-a9cf-717495945fc2"
        grant_type = "password"
        username   = $upn
        password   = $pwd
    }
    $tok = (Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -Body $body -ErrorAction Stop).access_token
    if (-not $tok) { throw "no Graph access token returned" }

    $headers = @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" }
    $uri     = "https://graph.microsoft.com/beta/settings"
    $current = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
    $grp     = $current.value | Where-Object { $_.displayName -eq "Group.Unified" }

    if ($grp) {
        $vals = $grp.values | ForEach-Object {
            if ($_.name -eq "EnableMIPLabels") { @{ name = $_.name; value = "true" } }
            else { @{ name = $_.name; value = $_.value } }
        }
        $payload = @{ values = $vals } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Method PATCH -Uri "$uri/$($grp.id)" -Headers $headers -Body $payload -ErrorAction Stop | Out-Null
    } else {
        $tmpl    = "62375ab9-6b52-47ed-826b-58e47e0e304b"
        $payload = @{ templateId = $tmpl; values = @(@{ name = "EnableMIPLabels"; value = "true" }) } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $payload -ErrorAction Stop | Out-Null
    }
    Write-Host "EnableMIPLabels: set to true"
} "EnableMIPLabels" 5 60 | Out-Null

# =====================================================================================
# 14. SHAREPOINT SENSITIVITY COLUMN (EnableAIPIntegration) via CSOM
#
# PowerShell resolves type literals at PARSE time of the enclosing script block,
# which happens BEFORE Add-Type runs. That is why the direct version failed with
# "Unable to find type [Microsoft.SharePoint.Client.WebRequestEventHandler]" on
# every run. Building the CSOM block with [scriptblock]::Create defers parsing to
# runtime, after the assemblies are loaded.
# =====================================================================================
Write-Host ""
Write-Host "--- EnableAIPIntegration ---"
# Result captured in $aipOk so the summary can report it. On 103908 this failed on every
# run while the summary still reported the tenant as fine.
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
# 15. HONEST SUMMARY — this is what the verification runbook greps for
# =====================================================================================
Write-Host ""
Write-Host "=============================================================="
Write-Host "  SUMMARY"
Write-Host "=============================================================="

try { Connect-IPPSSession -Credential $cred -DisableWAM -ShowBanner:$false -ErrorAction Stop } catch {}

$nLabels = (Get-Label -ErrorAction SilentlyContinue | Measure-Object).Count
$nPolicy = if (Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue) { "yes" } else { "NO" }
$nSit    = if (Get-DlpSensitiveInformationType -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Contoso Employee ID" }) { "yes" } else { "NO" }
$nDlp    = if (Get-DlpComplianceRule -Identity $dlpRuleName -ErrorAction SilentlyContinue) { "yes" } else { "NO" }
$nIrm    = if (Get-InsiderRiskPolicy -Identity $irmName -ErrorAction SilentlyContinue) { "yes" } else { "NO" }
$nCc     = if (Get-SupervisoryReviewPolicyV2 -Identity $ccName -ErrorAction SilentlyContinue) { "yes" } else { "NO" }
$nRet    = if (Get-AppRetentionCompliancePolicy -Identity $retName -ErrorAction SilentlyContinue) { "yes" } else { "NO" }
$nCase   = if (Get-ComplianceCase -Identity $caseName -ErrorAction SilentlyContinue) { "yes" } else { "NO" }

$nAudit = if ($auditOk) { "yes" } else { "NO" }
$nAip   = if ($aipOk)   { "yes" } else { "NO" }

Write-Host "SUMMARY: labels=$nLabels/5 labelPolicy=$nPolicy sit=$nSit dlpRule=$nDlp"
Write-Host "SUMMARY: irm=$nIrm commCompliance=$nCc retention=$nRet ediscoveryCase=$nCase"
Write-Host "SUMMARY: audit=$nAudit aipIntegration=$nAip"

# Day 2 cannot run at all without labels, the label policy and the DLP rule.
# The rest degrade individual exercises rather than killing the day.
$critical = ($nLabels -ge 5) -and ($nPolicy -eq "yes") -and ($nDlp -eq "yes")
$optional = ($nSit -eq "yes") -and ($nIrm -eq "yes") -and ($nCc -eq "yes") -and
            ($nRet -eq "yes") -and ($nCase -eq "yes")
$tenant   = ($nAudit -eq "yes") -and ($nAip -eq "yes")

if ($critical -and $optional -and $tenant) {
    Write-Host "SUMMARY: baseline OK"
} elseif ($critical) {
    Write-Host "SUMMARY: CORE OK - Exercises 1 and 2 will work, but something is missing."
    if (-not $tenant) {
        Write-Host "SUMMARY: TENANT-LEVEL PROBLEM - this is the dangerous kind, it looks fine in"
        Write-Host "SUMMARY: the portal until a learner hits it mid-exercise:"
        if ($nAudit -ne "yes") {
            Write-Host "SUMMARY:   - AUDIT OFF. Ex 4 Task 4 and all DSPM reporting will be empty."
            Write-Host "SUMMARY:     Most likely cause is NO EXCHANGE ONLINE LICENCE on the tenant."
        }
        if ($nAip -ne "yes") {
            Write-Host "SUMMARY:   - NO SHAREPOINT SENSITIVITY COLUMN. Labelling verification fails."
            Write-Host "SUMMARY:     Turn on manually: Purview > Information Protection > 'Turn on now'."
        }
    }
    if (-not $optional) {
        Write-Host "SUMMARY: Check which of Exercises 3, 4 and 5 are affected by the lines above."
    }
} else {
    Write-Host "SUMMARY: BASELINE INCOMPLETE - do not hand this tenant to learners"
}

Write-Host ""
Write-Host "===== DAY 2 SEEDING COMPLETE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
Write-Host "Seeding complete."

Stop-Transcript -ErrorAction SilentlyContinue
'@
$seedScript | Set-Content -Path $seedScriptPath -Encoding UTF8

# Schedule the seeding task: one-time, 45 MINUTES out, as SYSTEM (no password, runs
# whether logged on or not). Day 2 does more tenant work than Day 1, and deployment is
# at T-48h, so there is no cost to letting the tenant settle a little longer first.
$taskName  = "Day2Seeding"
$startTime = (Get-Date).AddMinutes(45).ToString("HH:mm")
schtasks /create /tn $taskName /tr "powershell.exe -ExecutionPolicy Bypass -File $seedScriptPath" /sc once /st $startTime /ru SYSTEM /f /rl HIGHEST
Write-Host "Day2Seeding task scheduled for $startTime (SYSTEM, runs whether logged on or not)."
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    Write-Error "CRITICAL: Day2Seeding task was not created."
    Stop-Transcript
    exit 1
}

# Harden the task: StartWhenAvailable makes Windows run it as soon as the machine is
# next available if the scheduled start was MISSED.
#
# WHY THIS MATTERS: a /sc once task does NOT auto-run a missed start by default. If the
# VM is deallocated (or simply not running) at the trigger time, the seeding is silently
# skipped forever and the tenant is left with no labels. That happened on 2026-08-26
# when the VM was stopped ~17 minutes before the task was due to fire.
#
# NOTE this covers a MISSED start, not an INTERRUPTED run. If you deallocate while the
# RMS gate is still waiting, the task is killed and does not resume. Hence the 3-hour
# rule above.
try {
    $schedTask = Get-ScheduledTask -TaskName $taskName
    $schedTask.Settings.StartWhenAvailable = $true
    $schedTask | Set-ScheduledTask | Out-Null
    Write-Host "Day2Seeding task: StartWhenAvailable enabled (survives a missed start)."
} catch {
    Write-Host "Could not set StartWhenAvailable: $($_.Exception.Message)"
}

Function updateVMShadowFile
{
$drivepath="C:\Users\Public\Documents"
(Get-Content -Path "$drivepath\Shadow.ps1") | ForEach-Object {$_ -Replace "vmAdminUsernameValue", "$vmAdminUsername"} | Set-Content -Path "$drivepath\Shadow.ps1"
net user $trainerUserName $trainerUserPassword
}
updateVMShadowFile

Remove-Item -Path "C:\ProgramData\chocolatey\lib\dotnetcore" -Recurse -Force -ErrorAction SilentlyContinue
choco install dotnetcore --force
Remove-Item -Path "C:\CloudLabs\" -Recurse -Force -ErrorAction SilentlyContinue

Function InstallModernVmValidator
{
    New-Item -ItemType directory -Path C:\CloudLabs\Validator -Force
    Invoke-WebRequest 'https://experienceazure.blob.core.windows.net/software/vm-validator/VMAgent.zip' -OutFile 'C:\CloudLabs\Validator\VMAgent.zip'
    Expand-Archive -LiteralPath 'C:\CloudLabs\Validator\VMAgent.zip' -DestinationPath 'C:\CloudLabs\Validator' -Force
    Set-ExecutionPolicy -ExecutionPolicy bypass -Force
    cmd.exe --% /c @echo off
    cmd.exe --% /c sc create "Spektra CloudLabs VM Agent" BinPath=C:\CloudLabs\Validator\VMAgent\Spektra.CloudLabs.VMAgent.exe start= auto
    cmd.exe --% /c sc start "Spektra CloudLabs VM Agent"
}

InstallModernVmValidator

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager].SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Microsoft 365 Apps. This is the slow one - 10 to 20 minutes.
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

# Edge managed bookmarks. Day 2 adds the Copilot chat endpoint, which learners use in
# almost every exercise, and the M365 admin centre for the licence checks.
$bookmarks = @(
    @{ name = "Microsoft Purview"; url = "https://purview.microsoft.com" },
    @{ name = "Microsoft 365 Copilot"; url = "https://m365.cloud.microsoft/chat" },
    @{ name = "Microsoft 365"; url = "https://www.microsoft365.com" },
    @{ name = "Microsoft 365 Admin"; url = "https://admin.microsoft.com" },
    @{ name = "SharePoint Admin"; url = "https://$($AzureUserName.Split('@')[1].Split('.')[0])-admin.sharepoint.com" },
    @{ name = "Entra Admin"; url = "https://entra.microsoft.com" }
)
$bookmarkJson = ($bookmarks | ConvertTo-Json -Compress)
Set-ItemProperty -Path $EdgePoliciesPath -Name "ManagedBookmarks" -Value $bookmarkJson -Type String

# Credentials file on the Desktop. Day 2 version also lists what the seeding script has
# pre-built, because the guide's Getting Started section refers to these by name.
$credContent = @"
=== Lab Credentials ===
Azure Username : $AzureUserName
Azure Password : $AzurePassword
Tenant ID      : $AzureTenantID
Subscription ID: $AzureSubscriptionID
Deployment ID  : $DeploymentID

=== Lab Portals ===
Microsoft Purview     : https://purview.microsoft.com
Microsoft 365 Copilot : https://m365.cloud.microsoft/chat
Microsoft 365         : https://www.microsoft365.com
Microsoft 365 Admin   : https://admin.microsoft.com

=== Lab Files ===
Test Documents : Contoso Finance SharePoint site > Documents

=== Pre-built for Day 2 ===
Sensitivity labels     : Public, Internal, Confidential, Highly Confidential, Confidential-Finance
Label policy           : Lab-Confidential-Policy
Custom SIT             : Contoso Employee ID  (matches EMP-######)
DLP for Copilot        : Lab-Copilot-DLP-Test
Insider Risk policy    : Lab-Risky-AI-Usage
Comm Compliance policy : Lab-Copilot-Comm-Compliance
Retention policy       : Lab-Copilot-Retention
eDiscovery case        : Lab-Copilot-Investigation
"@
$credContent | Out-File -FilePath "C:\Users\Public\Desktop\Lab-Credentials.txt" -Encoding UTF8

# Edge desktop shortcut
$EdgeExecutablePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$ShortcutPath = [Environment]::GetFolderPath("Desktop") + "\Microsoft Edge.lnk"
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $EdgeExecutablePath
$Shortcut.Save()
Write-Host "Microsoft Edge shortcut created on desktop."

# runuserdata is the image's userData runner - only present on the userData path.
Disable-ScheduledTask -TaskName "runuserdata" -ErrorAction SilentlyContinue
Stop-ScheduledTask   -TaskName "runuserdata" -ErrorAction SilentlyContinue

Stop-Transcript
exit 0
