<#
  AWR "Admin request post-delivery" script - IIS binding, generic (no ports/parameters)

  Switches all IIS HTTPS bindings of the form *:<port>: (no IP, no hostname, no SNI)
  to the delivered certificate - provided the certificate currently bound there
  shares at least one DNS name with the new one (e.g. *.flintgrp.com).
  Other HTTPS bindings are left untouched. Leave the Param field in TLM empty (DTAM-11844).

  IMPORTANT: The script writes NOTHING to stdout/stderr - any output makes the
  AWR delivery fail. Log only to $LogFile, result only as exit code.

  Exit codes: 0 = OK, 10 = delivery data, 11 = import, 12 = binding, 13 = unexpected
  (1, 127 and 4294770688 are reserved by the agent)
#>

# First of all: turn off progress/warnings/info (before the first cmdlet call)
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# ==== Configuration ====
$RequireNameMatch = $true                                  # $false = switch all *:<port>: bindings
$IisAppId = '{4dc3e181-e14b-4a21-b022-59fc669b0914}'       # default AppId of IIS
$LogFile  = Join-Path $env:ProgramData 'DigiCert\awr-iis-binding.log'
# =======================

$script:rc = 0

function Log($msg) {
    try { Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) } catch {}
}

function Get-DnsNames($c) {
    $names = @()
    if ($c.DnsNameList) { $names += $c.DnsNameList | ForEach-Object { $_.Unicode } }
    if ($c.Subject -match 'CN=([^,]+)') { $names += $Matches[1].Trim() }
    $names | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique
}

# Safety net: only log unexpected errors, output nothing
trap { Log "ERROR unexpected: $_"; exit 13 }

& {
    $null = New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force

    # 1) Read delivery data from the agent
    try {
        $b64 = [Environment]::GetEnvironmentVariable('DC1_POST_SCRIPT_DATA')
        if ([string]::IsNullOrEmpty($b64)) { throw 'DC1_POST_SCRIPT_DATA is empty.' }
        $data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
        $pfx  = $data.files | Where-Object { $_ -match '\.(pfx|p12)$' } | Select-Object -First 1
        if (-not $pfx) { throw 'No PFX file in the delivery.' }
        $pfxPath = Join-Path $data.certfolder $pfx
        if (-not (Test-Path $pfxPath)) { throw "PFX not found: $pfxPath" }
        Log "Delivery: $pfxPath"
    } catch { Log "ERROR delivery data: $_"; $script:rc = 10; return }

    # 2) Import into LocalMachine\My
    try {
        $pw  = ConvertTo-SecureString $data.password -AsPlainText -Force
        $imp = Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $pw -ErrorAction Stop |
               Where-Object { $_.HasPrivateKey } | Select-Object -First 1
        if (-not $imp) { throw 'No certificate with private key imported.' }
        $cert = Get-Item "Cert:\LocalMachine\My\$($imp.Thumbprint)" -ErrorAction Stop
        $newNames = @(Get-DnsNames $cert)
        Log "Imported: $($cert.Subject)  thumbprint $($cert.Thumbprint)  valid until $($cert.NotAfter)  names: $($newNames -join ', ')"
    } catch { Log "ERROR import: $_"; $script:rc = 11; return }

    # 3) Determine candidates: HTTPS bindings *:<port>: without SNI and without Central Cert Store
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $ports = @(Get-WebBinding -Protocol https |
                   Where-Object { $_.bindingInformation -match '^\*:\d+:$' -and ($_.sslFlags -band 3) -eq 0 } |
                   ForEach-Object { [int]($_.bindingInformation -replace '^\*:(\d+):$', '$1') } |
                   Sort-Object -Unique)
    } catch { Log "ERROR IIS configuration: $_"; $script:rc = 12; return }

    if ($ports.Count -eq 0) { Log 'ERROR: no HTTPS bindings *:<port>: without SNI found.'; $script:rc = 12; return }
    Log "Candidate ports: $($ports -join ', ')"

    # 4) Switch bindings
    $updated = 0
    $failed  = $false
    foreach ($port in $ports) {
        $path = "IIS:\SslBindings\0.0.0.0!${port}"
        if (-not (Test-Path $path)) { Log "WARNING: *:${port} has no certificate in http.sys - skipped."; continue }

        $sb  = Get-Item $path
        $old = $sb.Thumbprint
        if ($old -eq $cert.Thumbprint) { Log "0.0.0.0:${port}  already current."; $updated++; continue }

        if ($RequireNameMatch) {
            $store   = if ($sb.Store) { $sb.Store } else { 'My' }
            $oldCert = Get-Item "Cert:\LocalMachine\$store\$old" -ErrorAction SilentlyContinue
            if (-not $oldCert) { Log "WARNING: 0.0.0.0:${port}  certificate $old not in store $store - skipped."; continue }
            $common = @(Get-DnsNames $oldCert | Where-Object { $newNames -contains $_ })
            if ($common.Count -eq 0) { Log "0.0.0.0:${port}  different certificate ($($oldCert.Subject)) - left alone."; continue }
        }

        $out = & netsh http update sslcert "ipport=0.0.0.0:${port}" "certhash=$($cert.Thumbprint)" "appid=$IisAppId" "certstorename=MY" 2>&1
        if ($LASTEXITCODE -eq 0) { Log "0.0.0.0:${port}  $old -> $($cert.Thumbprint)"; $updated++ }
        else { Log "ERROR 0.0.0.0:${port}: $out"; $failed = $true }
    }

    if ($updated -eq 0) { Log 'ERROR: no binding switched.'; $script:rc = 12; return }
    if ($failed)        { $script:rc = 12; return }
    Log "Done: $updated binding(s) current."
} *> $null

exit $script:rc
