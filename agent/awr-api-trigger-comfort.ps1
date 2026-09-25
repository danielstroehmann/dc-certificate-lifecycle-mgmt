<#
  Comfort trigger for TLM admin web requests (AWR) - PowerShell version of awr-api-trigger-comfort.sh

  Creates an AWR via the TLM API and asks for everything interactively: instance, account,
  profile, agent and post-delivery script are picked by number from what the API returns;
  CN, delivery path and the script parameters are typed in one by one (an empty first
  parameter means: no parameters). The config block
  below only preselects entries in the menus. Auto-renew is taken from the chosen profile:
  its own auto_renew_settings (days before expiry, time, zone) are sent 1:1.

  Endpoint: POST /mpki/api/v1/automation/admin-web-request  (API key needs "Run automation")
  Works with Windows PowerShell 5.1 and PowerShell 7.

  Usage:
    .\awr-api-trigger-comfort.ps1                 # interactive, asks for confirmation before sending
    .\awr-api-trigger-comfort.ps1 -DryRun         # everything except the final POST
    .\awr-api-trigger-comfort.ps1 -Format pkcs12
#>
param(
    [string]$Format = 'pfx',
    [switch]$DryRun
)

# ==== Defaults (preselected in the menus when the API returns them) ====
$Hosts       = @('one.nl.digicert.com', 'one.ch.digicert.com', 'one.digicert.com')
$DefaultHost = 2                                        # 1-based index into $Hosts
$AccountId   = ''                                       # optional: paste your TLM IDs here to preselect them
$ProfileId   = ''                                       # (empty = no default, the menus simply ask)
$AgentId     = ''
$ScriptId    = ''
$DefaultPath = 'C:\Certificate'                         # delivery folder on the agent VM, Windows style
$RenewZone   = ''                                       # IANA zone for the auto-renew time, '' = derive from this machine
# ========================================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

# Masked input (asterisks), returned as plain text
function Read-Plain($prompt) {
    $s = Read-Host $prompt -AsSecureString
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Show-ApiError($err) {
    Write-Host "HTTP error: $($err.Exception.Message)" -ForegroundColor Red
    if ($err.ErrorDetails.Message) { Write-Host $err.ErrorDetails.Message }
}

# GET that must succeed, otherwise the error is shown and the script ends
function Get-Api($uri) {
    try { Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers }
    catch { Show-ApiError $_; exit 1 }
}

# Normalise list responses: plain array, or object with an items property
function Get-Items($r) {
    if ($null -eq $r) { return @() }
    if ($r -is [array]) { return $r }
    if ($r.PSObject.Properties['items']) { return @($r.items) }
    @($r)
}

function Or($value, $default) { if ($value) { "$value" } else { $default } }

# Ask for a value. Empty default = required.
function Read-Value($prompt, $default) {
    while ($true) {
        $v = if ($default) { Read-Host "$prompt [$default]" } else { Read-Host $prompt }
        if (-not $v -and $default) { $v = $default }
        if ($v) { return $v }
        Write-Host 'Input required.'
    }
}

function New-MenuItem($id, $name, $label) { [pscustomobject]@{ Id = "$id"; Name = "$name"; Label = "$label" } }

# Menu over items with Id/Name/Label; returns the chosen item
function Select-Item($title, $items, $preselectId) {
    $items = @($items)
    if ($items.Count -eq 0) { Write-Host "No entries found: $title" -ForegroundColor Red; exit 1 }
    Write-Host ''; Write-Host $title -ForegroundColor Cyan
    $def = $null
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Id -eq $preselectId) { $def = $i + 1 }
        Write-Host ('  {0,2}) {1}' -f ($i + 1), $items[$i].Label)
    }
    while ($true) {
        $c = if ($def) { Read-Host "Choice [$def]" } else { Read-Host 'Choice' }
        if (-not $c -and $def) { $c = $def }
        if ("$c" -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $items.Count) { break }
        Write-Host "Please enter a number from 1 to $($items.Count)."
    }
    $sel = $items[[int]$c - 1]
    Write-Host "  -> $($sel.Name)  ($($sel.Id))"
    $sel
}

# Auto-renew settings of a profile: the object under cc_settings / ca_settings (CertCentral /
# private CA profiles), searched anywhere in the response; $null if absent
function Find-AutoRenew($obj, $depth = 0) {
    if ($null -eq $obj -or $depth -gt 6 -or -not ($obj -is [System.Management.Automation.PSCustomObject])) { return $null }
    $p = $obj.PSObject.Properties['auto_renew_settings']
    if ($p -and $p.Value -is [System.Management.Automation.PSCustomObject] -and $p.Value.PSObject.Properties['auto_renew_time']) { return $p.Value }
    foreach ($p in $obj.PSObject.Properties) {
        $items = if ($p.Value -is [array]) { $p.Value } else { @($p.Value) }
        foreach ($v in $items) { $r = Find-AutoRenew $v ($depth + 1); if ($r) { return $r } }
    }
    $null
}

# Auto-renew object for the request body, built from the profile's settings ($profRenew) or the
# renewal window in days; disabled when neither exists
function New-AutoRenew($profRenew, $renewDays, $zone) {
    if ($profRenew) {
        $o = [ordered]@{ auto_renew_certificate_and_order = ($profRenew.auto_renew_certificate_and_order -eq $true)
                         before_expiration = ($profRenew.before_expiration -eq $true) }
        $t = $profRenew.auto_renew_time
        if ($t -is [System.Management.Automation.PSCustomObject]) {
            $time = [ordered]@{}
            foreach ($k in 'days', 'hours', 'minutes', 'time_format', 'zone') { if ($null -ne $t.$k) { $time[$k] = $t.$k } }
            $o.auto_renew_time = $time
        }
        return $o
    }
    if ($renewDays -gt 0) {
        return [ordered]@{ auto_renew_certificate_and_order = $true; before_expiration = $false
                           auto_renew_time = [ordered]@{ days = $renewDays; hours = 1; minutes = 0; time_format = 'AM'; zone = $zone } }
    }
    [ordered]@{ auto_renew_certificate_and_order = $false; before_expiration = $false }
}

# Human-readable text for a profile auto-renew object
function Get-AutoRenewText($r) {
    if ($r.auto_renew_certificate_and_order -ne $true) { return 'off (auto-renew disabled in the profile)' }
    if ($r.before_expiration -eq $true) { return 'shortly before expiry (auto-renew settings of the profile)' }
    $t = $r.auto_renew_time
    '{0} days before expiry, {1}:{2:00} {3} {4} (auto-renew settings of the profile)' -f $t.days, $t.hours, [int]$t.minutes, "$($t.time_format)".ToUpper(), $t.zone
}

# Renewal window in days from a profile response: renewal_window_days or renewal_period_days,
# the first value > 0 anywhere in the object; 0 if absent
function Find-RenewDays($obj, $depth = 0) {
    if ($null -eq $obj -or $depth -gt 6 -or -not ($obj -is [System.Management.Automation.PSCustomObject])) { return 0 }
    foreach ($k in 'renewal_window_days', 'renewal_period_days') {
        $p = $obj.PSObject.Properties[$k]
        if ($p -and "$($p.Value)" -match '^\d+(\.\d+)?$' -and [int][double]$p.Value -gt 0) { return [int][double]$p.Value }
    }
    foreach ($p in $obj.PSObject.Properties) {
        $items = if ($p.Value -is [array]) { $p.Value } else { @($p.Value) }
        foreach ($v in $items) { $r = Find-RenewDays $v ($depth + 1); if ($r -gt 0) { return $r } }
    }
    0
}

# IANA zone for the auto-renew time (the UI uses the browser's zone)
function Get-LocalZone {
    if ($RenewZone) { return $RenewZone }
    $tz = [TimeZoneInfo]::Local
    if ($tz.Id -match '^[A-Za-z]+/[A-Za-z_]+' -or $tz.Id -eq 'UTC') { return $tz.Id }      # PowerShell 7 on Linux/macOS
    if ([TimeZoneInfo].GetMethods().Name -contains 'TryConvertWindowsIdToIanaId') {       # .NET 6+ (PowerShell 7 on Windows)
        $iana = ''
        if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId($tz.Id, [ref]$iana)) { return $iana }
    }
    $map = @{                                                                             # Windows PowerShell 5.1: common zones
        'W. Europe Standard Time' = 'Europe/Berlin';  'Central Europe Standard Time' = 'Europe/Budapest'
        'Central European Standard Time' = 'Europe/Warsaw'; 'Romance Standard Time' = 'Europe/Paris'
        'GMT Standard Time' = 'Europe/London'; 'FLE Standard Time' = 'Europe/Kiev'; 'E. Europe Standard Time' = 'Europe/Chisinau'
        'Eastern Standard Time' = 'America/New_York'; 'Central Standard Time' = 'America/Chicago'
        'Mountain Standard Time' = 'America/Denver'; 'Pacific Standard Time' = 'America/Los_Angeles'; 'UTC' = 'UTC'
    }
    if ($map[$tz.Id]) { return $map[$tz.Id] }
    'UTC'
}

# 1) Instance
$hostItems = $Hosts | ForEach-Object { New-MenuItem $_ $_ $_ }
$HostName  = (Select-Item 'DigiCert ONE instance' $hostItems $Hosts[$DefaultHost - 1]).Id
$base      = "https://$HostName/mpki/api/v1"

# 2) API key
$apiKey = Read-Plain 'API key (service user with "Run automation")'
$script:headers = @{ 'X-API-Key' = $apiKey }

# 3) Account: taken from the business units, which carry their account (id + name) and
#    can be listed without knowing an account ID first
$accItems = Get-Items (Get-Api "$base/business-unit?limit=100") |
            ForEach-Object { $_.account } | Where-Object { $_ -and $_.id } |
            Sort-Object -Property id -Unique | Sort-Object -Property name |
            ForEach-Object { New-MenuItem $_.id $_.name "$($_.name)  $($_.id)" }
$acc = Select-Item 'Account' $accItems $AccountId
$AccountId = $acc.Id

# 4) Profile (only those of the chosen account)
$profItems = Get-Items (Get-Api "$base/profile?limit=100") |
             Where-Object { $_.account_id -eq $AccountId } | Sort-Object -Property name |
             ForEach-Object { New-MenuItem $_.id $_.name ('{0}  [{1}, {2}]  {3}' -f $_.name, (Or $_.enrollment_method '-'), (Or $_.status '-'), $_.id) }
$prof = Select-Item 'Certificate profile' $profItems $ProfileId
$ProfileId = $prof.Id

# 4b) Auto-renew for the AWR, taken from the chosen profile.
#     The profile's own auto_renew_settings (under cc_settings for CertCentral profiles, ca_settings
#     for private CAs) are taken over 1:1 when an endpoint returns them; the public v1 response often
#     does not, so v2, v3 and the UI API are tried as well. Fallback: the renewal window in days.
$profDetail = Get-Api "$base/profile/$ProfileId"
$profRenew  = Find-AutoRenew $profDetail
$RenewDays  = Find-RenewDays $profDetail
foreach ($alt in @("https://$HostName/mpki/api/v2/profile/$ProfileId", "https://$HostName/mpki/api/v3/profile/$ProfileId", "https://$HostName/mpki/ui-api/v1/profile/$ProfileId")) {
    if ($profRenew) { break }
    try { $r = Invoke-RestMethod -Method Get -Uri $alt -Headers $headers } catch { continue }
    $profRenew = Find-AutoRenew $r
    if ($RenewDays -eq 0) { $RenewDays = Find-RenewDays $r }
}
$Zone = Get-LocalZone
$RenewText = if ($profRenew) { Get-AutoRenewText $profRenew }
             elseif ($RenewDays -gt 0) { "$RenewDays days before expiry, 01:00 AM $Zone (renewal window of the profile)" }
             else { "off - no auto-renew settings and no renewal window in the profile (fields: $($profDetail.PSObject.Properties.Name -join ', '))" }
$autoRenew = New-AutoRenew $profRenew $RenewDays $Zone
Write-Host "  Auto-renew: $RenewText"

# 5) Agent
$agentItems = Get-Items (Get-Api "$base/agent?account_id=$AccountId&limit=100") | Sort-Object -Property name |
              ForEach-Object { New-MenuItem $_.id $_.name ('{0}  [{1}, {2}, {3}]  {4}' -f $_.name, (Or $_.host_name '-'), (Or $_.status '-'), (Or $_.os_name '-'), $_.id) }
$agent = Select-Item 'Agent' $agentItems $AgentId
$AgentId = $agent.Id

# 6) Post-delivery script
$scriptItems = Get-Items (Get-Api "$base/agent/script?account_id=$AccountId") | Sort-Object -Property name |
               ForEach-Object { New-MenuItem $_.id $_.name ('{0}  [{1}, {2}, {3}]  {4}' -f $_.name, (Or $_.type '-'), (Or $_.os '-'), (Or $_.path '-'), $_.id) }
$scr = Select-Item 'Post-delivery script' $scriptItems $ScriptId
$ScriptId = $scr.Id; $ScriptName = $scr.Name

# 7) CN, delivery path, script parameters (one per prompt, empty input ends the list)
Write-Host ''
$Cn       = Read-Value 'Common Name (CN)' ''
$CertPath = Read-Value 'Delivery path on the agent' $DefaultPath
Write-Host 'Script parameters (empty input ends the list, empty right away = no parameters):'
$Params = @()
$i = 1
while ($true) {
    $p = Read-Host "Parameter $i"
    if (-not $p) { break }
    $Params += "$p"; $i++
}
$ParamText = if ($Params.Count -gt 0) { $Params -join ' ' } else { '(none)' }

# 8) PFX password
$pfxPw = Read-Plain 'PFX password'

# 9) Request body
$body = [ordered]@{
    account_id  = $AccountId
    profile_id  = $ProfileId
    cn          = $Cn
    action_type = 'ENROLL'
    certificate_services_agreement = $true
    auto_renew_settings = $autoRenew
    cert_delivery_settings = @(
        [ordered]@{
            delivery_method  = 'agent'
            agent_ids        = @($AgentId)
            delivery_configs = @(
                [ordered]@{
                    format   = $Format
                    path     = $CertPath
                    password = $pfxPw
                    scripts  = @(
                        [ordered]@{
                            agent_id    = $AgentId
                            script_id   = $ScriptId
                            script_name = $ScriptName
                            script_type = 'POSTHOOK'
                            parameters  = @($Params)
                        }
                    )
                }
            )
        }
    )
}
$json = $body | ConvertTo-Json -Depth 10
if ($json -notmatch '"parameters":\s*\[') { Write-Host 'parameters not serialized as an array - aborting.' -ForegroundColor Red; exit 1 }

Write-Host ''; Write-Host 'Summary' -ForegroundColor Cyan
foreach ($row in @(
    @('Instance',  $HostName),
    @('Account',   "$($acc.Name)  ($AccountId)"),
    @('Profile',   "$($prof.Name)  ($ProfileId)"),
    @('Agent',     "$($agent.Name)  ($AgentId)"),
    @('Script',    "$ScriptName  ($ScriptId)"),
    @('CN',        $Cn),
    @('Path',      $CertPath),
    @('Parameters', $ParamText),
    @('Format',    $Format),
    @('Renewal',   $RenewText))) { Write-Host ('  {0,-10}: {1}' -f $row[0], $row[1]) }
Write-Host ''; Write-Host 'Request body (password masked):'
Write-Host ($json -replace '("password":\s*")[^"]*"', '$1***"')

if ($DryRun) { Write-Host ''; Write-Host 'DryRun - nothing sent.'; exit 0 }

$yn = Read-Host 'Create the AWR now? [y/N]'
if ("$yn" -notmatch '^[jJyY]$') { Write-Host 'Aborted, nothing sent.'; exit 0 }

# 10) Create the AWR
try {
    $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$base/automation/admin-web-request" -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
    Write-Host ''; Write-Host "OK ($($resp.StatusCode)) - AWR created." -ForegroundColor Green
    Write-Host 'Next: TLM > Inventory > Endpoints (Tracker) and on the VM C:\ProgramData\DigiCert\awr-iis-binding.log'
} catch {
    Show-ApiError $_; exit 1
} finally {
    Remove-Variable apiKey, pfxPw -ErrorAction SilentlyContinue
    Remove-Variable headers -Scope Script -ErrorAction SilentlyContinue
}
