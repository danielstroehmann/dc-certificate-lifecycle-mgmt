# Allowing PowerShell scripts on the agent VM

The DigiCert ONE agent runs the post-delivery scripts in this folder (`awr-post-*.ps1`)
with Windows PowerShell (`powershell.exe`) under its service account, which is
**Local System (SYSTEM)** by default. You run the same scripts yourself through
`awr-simulator.ps1` under **your own account**.

Windows refuses to run `.ps1` files until the *execution policy* allows it, and the
policy is stored per account. So both accounts need it. This is a one-time setup per VM.

All commands below go into a PowerShell started **as administrator**.
What each script in this folder does and how trigger, simulator and post-delivery scripts
work together is described in [SCRIPTS.md](SCRIPTS.md).

## 1. Check what is already set

```powershell
Get-ExecutionPolicy -List
```

| Scope | Meaning |
|-------|---------|
| `MachinePolicy` / `UserPolicy` | Set by group policy. If either is not `Undefined`, everything below is ignored and the AD admins have to change the GPO. |
| `LocalMachine` | Applies to every account on this VM, including SYSTEM. Windows Server ships with `RemoteSigned` here, Windows 10/11 with `Restricted`. |
| `CurrentUser` | Applies to the account you are logged on as. |

If `LocalMachine` already shows `RemoteSigned` and no GPO scope is set, nothing needs to be done.

## 2. Allow it for all accounts at once (recommended)

```powershell
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

One command, covers SYSTEM, your account and everyone else on the VM.
`RemoteSigned` means: scripts stored on this machine run, scripts downloaded from
the internet need a signature (see step 4).

## 3. Alternative: only the two accounts, machine-wide policy untouched

Use this if the `LocalMachine` policy has to stay as it is.

```powershell
# Your own account
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# SYSTEM account (the agent). Its CurrentUser policy lives under HKEY_USERS\S-1-5-18.
$key = 'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name ExecutionPolicy -Value RemoteSigned
Get-ItemProperty -Path $key | Select-Object ExecutionPolicy
```

If the agent service does not run as SYSTEM, check which account it uses and set the
policy for that account instead (log on as that account and run the `CurrentUser` command):

```powershell
Get-CimInstance Win32_Service -Filter "Name LIKE '%DigiCert%'" | Select-Object Name, StartName
```

## 4. Unblock files that came from the internet

Files downloaded with a browser or received by mail carry a "mark of the web", and
`RemoteSigned` refuses them even after step 2 or 3. Files copied over RDP or a network
share usually do not have it. To be safe, unblock the folder once after copying:

```powershell
Unblock-File -Path C:\path\to\scripts\*.ps1
```

## 5. Verify

Your own account, from the folder with the scripts:

```powershell
powershell.exe -NoProfile -File .\awr-post-iis-all.ps1; $LASTEXITCODE
```

No red "running scripts is disabled on this system" text and exit code `10` means the
policy is fine: the script ran and only complained, via its exit code, that no delivery
data was present. `awr-simulator.ps1` starts the post-delivery scripts the same way the
agent does, without `-ExecutionPolicy Bypass`, so a green simulator run proves it too.

SYSTEM cannot be tested from your session. The proof is a real admin web request from
Trust Lifecycle Manager: the endpoint shows *Automation successful* and
`C:\ProgramData\DigiCert\awr-iis-binding.log` gets new lines. If the policy still blocks
SYSTEM, the request fails and the agent log reports that running scripts is disabled.

## Notes

- PowerShell 7 (`pwsh`) keeps its own execution policy. The agent uses `powershell.exe`,
  so the commands above are all that is needed. If you also run the scripts with `pwsh`,
  repeat step 2 inside a `pwsh` window.
- Order of precedence, highest first: `MachinePolicy`, `UserPolicy`, `Process`,
  `CurrentUser`, `LocalMachine`. A `CurrentUser` value overrides `LocalMachine` for that
  account.
- Undo: `Set-ExecutionPolicy Undefined -Scope LocalMachine` (or `-Scope CurrentUser`), and
  for SYSTEM remove the `ExecutionPolicy` value under the registry key from step 3.
