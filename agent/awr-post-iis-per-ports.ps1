<#
  AWR "Admin request post-delivery" script - IIS binding per port

  Binds the delivered certificate to the IIS HTTPS bindings on exactly the ports that
  arrive as script parameters (e.g. ["50001", "443"] from awr-api-trigger). A port that
  has no IIS binding, or only an HTTP binding, is skipped silently (logged, no error).

  Bindings are selected by port only: IP-based (*:443:), fixed-IP and SNI bindings are all
  updated. Bindings that use the Central Certificate Store are left alone. There is no
  name matching against the currently bound certificate - the port list is the intent.

  IMPORTANT: The script writes NOTHING to stdout/stderr - any output makes the
  AWR delivery fail. Log only to $LogFile, result only as exit code.

  Exit codes: 0  = OK, at least one binding updated (or already current)
              10 = delivery data (incl. no usable port parameter), 11 = import,
              12 = binding update failed, 13 = unexpected,
              14 = no binding updated - the certificate was rolled out for nothing
              (1, 127 and 4294770688 are reserved by the agent)
#>

# First of all: turn off progress/warnings/info (before the first cmdlet call)
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# ==== Configuration ====
$IisAppId = '{4dc3e181-e14b-4a21-b022-59fc669b0914}'       # default AppId of IIS
$LogFile  = Join-Path $env:ProgramData 'DigiCert\awr-iis-binding.log'
# =======================

$script:rc = 0
$script:CliArgs = @($args)   # parameters may also arrive as command-line arguments

function Log($msg) {
    try { Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) } catch {}
}

# Port numbers from the parameter values: separate values ("50001", "443") as well as one
# value with separators ("50001,443" / "50001 443"). Non-ports are logged and ignored.
function Get-Ports($values) {
    $ports = @()
    foreach ($v in @($values)) {
        foreach ($tok in ("$v" -split '[,;\s]+')) {
            if (-not $tok) { continue }
            if ($tok -match '^\d{1,5}$' -and [int]$tok -ge 1 -and [int]$tok -le 65535) { $ports += [int]$tok }
            else { Log "WARNING: parameter '$tok' is not a port - ignored." }
        }
    }
    $ports | Select-Object -Unique
}

# Split an IIS binding into its parts. bindingInformation is "<ip>:<port>:<hostname>".
function Parse-Binding($b) {
    if ("$($b.bindingInformation)" -notmatch '^(.+):(\d+):(.*)$') { return }
    $ip = $Matches[1]; $port = [int]$Matches[2]; $hostName = $Matches[3]   # keep before the next -match
    $site = if ("$($b.ItemXPath)" -match "@name='([^']+)'") { $Matches[1] } else { '?' }
    [pscustomobject]@{
        Site = $site; Protocol = "$($b.protocol)"; Ip = $ip; Port = $port
        HostName = $hostName; SslFlags = [int]$b.sslFlags; Info = $b.bindingInformation
    }
}

# Safety net: only log unexpected errors, output nothing
trap { Log "ERROR unexpected: $_"; exit 13 }

& {
    $null = New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force

    # 1) Read delivery data and the port parameters
    try {
        $b64 = [Environment]::GetEnvironmentVariable('DC1_POST_SCRIPT_DATA')
        if ([string]::IsNullOrEmpty($b64)) { throw 'DC1_POST_SCRIPT_DATA is empty.' }
        $data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
        $pfx  = $data.files | Where-Object { $_ -match '\.(pfx|p12)$' } | Select-Object -First 1
        if (-not $pfx) { throw 'No PFX file in the delivery.' }
        $pfxPath = Join-Path $data.certfolder $pfx
        if (-not (Test-Path -LiteralPath $pfxPath)) { throw "PFX not found: $pfxPath" }
        Log "Delivery: $pfxPath"

        $ports = @(Get-Ports (@($data.args) + $script:CliArgs))
        Log "Parameters: DC1_POST_SCRIPT_DATA.args=[$(@($data.args) -join ', ')]  CLI=[$($script:CliArgs -join ', ')]  -> ports: $($ports -join ', ')"
        if ($ports.Count -eq 0) { throw 'No ports passed as parameters.' }
    } catch { Log "ERROR delivery data: $_"; $script:rc = 10; return }

    # 2) Import into LocalMachine\My
    try {
        $pw  = ConvertTo-SecureString $data.password -AsPlainText -Force
        $imp = Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $pw -ErrorAction Stop |
               Where-Object { $_.HasPrivateKey } | Select-Object -First 1
        if (-not $imp) { throw 'No certificate with private key imported.' }
        $cert = Get-Item "Cert:\LocalMachine\My\$($imp.Thumbprint)" -ErrorAction Stop
        Log "Imported: $($cert.Subject)  thumbprint $($cert.Thumbprint)  valid until $($cert.NotAfter)"
    } catch { Log "ERROR import: $_"; $script:rc = 11; return }

    # 3) Read all IIS bindings once
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $bindings = @(Get-WebBinding | ForEach-Object { Parse-Binding $_ } | Where-Object { $_ })
    } catch { Log "ERROR IIS configuration: $_"; $script:rc = 12; return }

    # 4) Per requested port: skip if no binding / no HTTPS binding, otherwise bind the certificate
    $updated = 0
    $failed  = $false
    $done    = @{}   # http.sys keys already handled (several sites can share one binding)
    foreach ($port in $ports) {
        $onPort = @($bindings | Where-Object { $_.Port -eq $port })
        if ($onPort.Count -eq 0) { Log "Port ${port}: no IIS binding - skipped."; continue }

        $https = @($onPort | Where-Object { $_.Protocol -eq 'https' })
        if ($https.Count -eq 0) {
            $protos = @($onPort | ForEach-Object { $_.Protocol } | Select-Object -Unique) -join '/'
            Log "Port ${port}: only ${protos}, no SSL binding - skipped."
            continue
        }

        foreach ($b in $https) {
            $where = "Port ${port} [$($b.Site)] $($b.Info)"
            if ($b.SslFlags -band 2) { Log "$where  Central Certificate Store - left alone."; continue }

            # http.sys key: SNI bindings are addressed by hostname:port, all others by ip:port
            if (($b.SslFlags -band 1) -and $b.HostName) {
                $key  = "hostnameport=$($b.HostName):${port}"
                $path = "IIS:\SslBindings\!${port}!$($b.HostName)"
            } else {
                $ip   = if ($b.Ip -eq '*') { '0.0.0.0' } else { $b.Ip }
                $key  = "ipport=${ip}:${port}"
                $path = "IIS:\SslBindings\${ip}!${port}"
            }
            if ($done.ContainsKey($key)) { continue }
            $done[$key] = $true

            $old = $null
            if (Test-Path -LiteralPath $path) { $old = (Get-Item -LiteralPath $path).Thumbprint }
            if ($old -eq $cert.Thumbprint) { Log "$where  already current."; $updated++; continue }

            # existing http.sys entry -> update, HTTPS binding without certificate -> add
            $verb = if ($old) { 'update' } else { 'add' }
            $out  = & netsh http $verb sslcert $key "certhash=$($cert.Thumbprint)" "appid=$IisAppId" "certstorename=MY" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $from = if ($old) { $old } else { '(no certificate)' }
                Log "$where  $from -> $($cert.Thumbprint)"; $updated++
            } else { Log "ERROR $where  netsh http $verb sslcert: $out"; $failed = $true }
        }
    }

    if ($failed)        { Log "ERROR: at least one binding could not be updated ($updated current)."; $script:rc = 12; return }
    if ($updated -eq 0) { Log 'ERROR: no binding updated - the certificate was rolled out for nothing.'; $script:rc = 14; return }
    Log "Done: $updated binding(s) current."
} *> $null

exit $script:rc
