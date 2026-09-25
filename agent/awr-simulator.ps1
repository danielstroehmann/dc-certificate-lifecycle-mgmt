<#
  AWR simulator - runs a post-delivery script locally the way the DigiCert ONE agent does,
  without an agent and without an AWR: creates a self-signed test certificate, exports it as
  PFX into the delivery folder, puts the delivery data into DC1_POST_SCRIPT_DATA (base64 JSON:
  args, certfolder, files, password) and starts the chosen script in its own PowerShell
  process. Afterwards it reports the exit code and any output (a post-delivery script must
  not write anything), the http.sys bindings and the tail of the log file.

  The script parameters are typed in one by one (an empty first parameter means: no
  parameters). They go into DC1_POST_SCRIPT_DATA.args and are also passed as command-line
  arguments. The post-delivery script is picked by number from the .ps1 files next to this
  script. PowerShell version of awr-simulator.sh (PFX format only).

  Windows only (New-SelfSignedCertificate, LocalMachine store, netsh); run as administrator.
  Works with Windows PowerShell 5.1 and PowerShell 7. Scripts must be allowed to run for
  your account (README.md, execution policy).

  Usage:
    .\awr-simulator.ps1          # interactive
    .\awr-simulator.ps1 -Keep    # keep the delivered PFX after the run

  Exit codes: 0 = post script returned 0 and wrote nothing, 1 = post script failed or wrote
              output, 2 = no script found / certificate could not be created
#>
#requires -RunAsAdministrator
param(
    [switch]$Keep
)

# ==== Configuration ====
$Domain   = '*.stroehmi.casa'                                  # CN and SAN of the test certificate
$Folder   = 'C:\Certificate'                                   # delivery folder (certfolder in the delivery data)
$BaseName = 'test'                                             # file name without extension
$Password = 'P@ssw0rd'                                         # PFX password
$LogFile  = Join-Path $env:ProgramData 'DigiCert\awr-iis-binding.log'   # log of the IIS post scripts
# =======================

$PfxPath = Join-Path $Folder "$BaseName.pfx"

# 1) Script parameters (one per prompt, empty input ends the list)
Write-Host 'Script parameters (empty input ends the list, empty right away = no parameters):'
$Params = @()
$i = 1
while ($true) {
    $p = Read-Host "Parameter $i"
    if (-not $p) { break }
    $Params += "$p"; $i++
}
$ParamText = if ($Params.Count -gt 0) { $Params -join ' ' } else { '(none)' }

# 2) Post-delivery script: the .ps1 files in this folder, except this script
$selfName = Split-Path -Leaf $PSCommandPath
$scripts  = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File | Where-Object { $_.Name -ne $selfName } | Sort-Object Name)
if ($scripts.Count -eq 0) { Write-Host "No .ps1 files found in $PSScriptRoot" -ForegroundColor Red; exit 2 }
Write-Host ''; Write-Host 'Post-delivery script' -ForegroundColor Cyan
for ($i = 0; $i -lt $scripts.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), $scripts[$i].Name) }
while ($true) {
    $c = Read-Host 'Choice'
    if ("$c" -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $scripts.Count) { break }
    Write-Host "Please enter a number from 1 to $($scripts.Count)."
}
$Target = $scripts[[int]$c - 1].FullName
Write-Host "  -> $(Split-Path -Leaf $Target)"

# 3) Self-signed test certificate as PFX in the delivery folder; removed from the store again
#    so that the import in the post-delivery script is actually tested
try {
    $null = New-Item -ItemType Directory -Path $Folder -Force
    $cert = New-SelfSignedCertificate -DnsName $Domain -CertStoreLocation Cert:\LocalMachine\My `
                -FriendlyName "awr-simulator $(Get-Date -Format s)" -ErrorAction Stop
    $null = Export-PfxCertificate -Cert $cert -FilePath $PfxPath -ErrorAction Stop `
                -Password (ConvertTo-SecureString $Password -AsPlainText -Force)
    Remove-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" -DeleteKey -ErrorAction Stop
} catch {
    Write-Host "Could not create the test certificate: $_" -ForegroundColor Red; exit 2
}

# 4) Delivery data like the agent: base64 JSON in DC1_POST_SCRIPT_DATA
$json = [ordered]@{ args = @($Params); certfolder = $Folder; files = @("$BaseName.pfx"); password = $Password } | ConvertTo-Json -Compress
$env:DC1_POST_SCRIPT_DATA = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

# The agent runs post-delivery scripts with Windows PowerShell; fall back to pwsh where it is missing
$psExe = if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' } else { 'pwsh' }

Write-Host ''; Write-Host 'Simulation' -ForegroundColor Cyan
foreach ($row in @(
    @('Script',     (Split-Path -Leaf $Target)),
    @('Parameters', $ParamText),
    @('Format',     'pfx'),
    @('Folder',     $Folder),
    @('Files',      "$BaseName.pfx"),
    @('Thumbprint', $cert.Thumbprint),
    @('Run as',     "$env:USERNAME  via $psExe"),
    @('Delivery',   ($json -replace '"password":"[^"]*"', '"password":"***"')))) {
    Write-Host ('  {0,-11}: {1}' -f $row[0], $row[1])
}

# 5) Start the post-delivery script in its own process (like the agent) and capture all output.
#    Deliberately without -ExecutionPolicy Bypass: the execution policy of this account is part
#    of the test (see README.md).
$sw  = [Diagnostics.Stopwatch]::StartNew()
$out = & $psExe -NoProfile -NonInteractive -File $Target @Params 2>&1
$rc  = $LASTEXITCODE
$sw.Stop()
Remove-Item Env:\DC1_POST_SCRIPT_DATA -ErrorAction SilentlyContinue
if (-not $Keep) { Remove-Item $PfxPath -Force -ErrorAction SilentlyContinue }

# 6) Evaluation
Write-Host ''
if ($rc -eq 0) { Write-Host ('  {0,-11}: {1} (OK)' -f 'Exit code', $rc) -ForegroundColor Green }
else           { Write-Host ('  {0,-11}: {1} (expected 0)' -f 'Exit code', $rc) -ForegroundColor Red }
if ($out) {
    Write-Host ('  {0,-11}: PRESENT - would break the AWR:' -f 'Output') -ForegroundColor Red
    $out | ForEach-Object { Write-Host "    | $_" }
} else {
    Write-Host ('  {0,-11}: none (OK)' -f 'Output') -ForegroundColor Green
}
Write-Host ('  {0,-11}: {1:0.0}s' -f 'Duration', $sw.Elapsed.TotalSeconds)
if ($Keep) { Write-Host ('  {0,-11}: kept as {1}' -f 'Files', $PfxPath) }

# http.sys bindings: how many carry the new certificate now
$ssl = @(netsh http show sslcert 2>$null)
$bound = @($ssl | Select-String -SimpleMatch $cert.Thumbprint).Count
Write-Host ('  {0,-11}: {1} binding(s) with the new certificate' -f 'Bindings', $bound)
$ssl | Select-String 'IP:port|Hostname:port|Certificate Hash' | ForEach-Object { Write-Host "    $($_.Line.Trim())" }

if (Test-Path $LogFile) {
    Write-Host ''; Write-Host "Log (last lines of $LogFile):"
    Get-Content $LogFile -Tail 8 | ForEach-Object { Write-Host "    $_" }
}

if ($rc -eq 0 -and -not $out) { exit 0 } else { exit 1 }
