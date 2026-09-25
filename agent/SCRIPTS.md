# Scripts in this folder

Everything here is about **admin web requests (AWR)** in DigiCert Trust Lifecycle Manager (TLM):
TLM issues a certificate, the DigiCert ONE agent on the target machine writes it to a folder
and then runs a *post-delivery script* that installs it. The scripts fall into three groups:

| Group | Scripts | Runs on |
|-------|---------|---------|
| Trigger: creates the AWR in TLM via the API | `awr-api-trigger-comfort.sh`, `awr-api-trigger-comfort.ps1` | your workstation (macOS/Linux, Windows) |
| Post-delivery: installs the delivered certificate | `awr-post-iis-all.ps1`, `awr-post-iis-per-ports.ps1`, `awr-post-docker-restart.sh`, `awr-post-fortiweb.sh`, `awr-post-config-example.sh` | the agent machine, started by the agent |
| Simulator: runs a post-delivery script locally, without TLM and without the agent | `awr-simulator.sh`, `awr-simulator.ps1` | the agent machine, or any test box |

`README.md` explains the one-time step that has to come first on a Windows agent: allowing
PowerShell scripts for your account and for SYSTEM.

## How they fit together

```
 workstation                    TLM                        agent machine
 ───────────                    ───                        ─────────────
 awr-api-trigger-comfort  ──►  POST admin-web-request  ──►  agent writes cert to <path>
   (instance, account,          issues certificate           sets DC1_POST_SCRIPT_DATA
    profile, agent, script,     schedules auto-renew         runs awr-post-*.ps1 / .sh
    CN, path, parameters)                                        │
                                                                 ▼
                                Tracker: Automation successful / Auto renew scheduled
                                (exit code 0, no output)  or  failed (exit code, output)

 awr-simulator  ──────────────────────────────────────────►  same thing without TLM and agent:
   (parameters, script)                                      self-signed cert to <folder>,
                                                             DC1_POST_SCRIPT_DATA, run script
```

The simulator replaces the whole left and middle part. Use it first, then the trigger.

## The contract between agent and post-delivery script

Every post-delivery script gets the same input and has to obey the same rules:

- **Input:** the environment variable `DC1_POST_SCRIPT_DATA`, base64-encoded JSON:

  ```json
  {"args":["50001","443"],"certfolder":"C:\\Certificate","files":["cert.pfx"],"password":"..."}
  ```

  `args` are the script parameters entered in TLM or in the trigger. The scripts here also
  accept them as command-line arguments; the simulator passes them both ways.
- **No output.** Anything written to stdout or stderr makes the delivery fail in TLM.
  The scripts log to a file instead.
- **Result only as exit code.** `0` = success. The scripts here use `10` = delivery data
  unusable, `11` = certificate import failed, `12` = binding/installation failed,
  `13` = unexpected error, `14` = nothing was updated. `1`, `127` and `4294770688` are
  reserved by the agent.

## Trigger

### awr-api-trigger-comfort.sh / awr-api-trigger-comfort.ps1

Same behaviour, two platforms. Creates one AWR through `POST /mpki/api/v1/automation/admin-web-request`.
Everything is asked interactively and picked by number from what the API returns:

1. TLM instance (`one.nl.digicert.com`, `one.ch.digicert.com`, `one.digicert.com`)
2. API key (masked input, needs the "Run automation" permission)
3. Account, certificate profile, agent, post-delivery script (as registered in TLM)
4. Common Name, delivery path on the agent (default `C:\Certificate`)
5. Script parameters, one per prompt, Enter on an empty prompt ends the list, zero is fine
6. PFX password, then a summary and a confirmation before sending

The auto-renew settings of the chosen profile (days before expiry, time, zone) are copied into
the request, so TLM shows *Auto renew scheduled* afterwards and re-runs the AWR before expiry.
The config block at the top only preselects menu entries, it never bypasses a menu.

```
./awr-api-trigger-comfort.sh              # bash 3.2+, needs curl and jq >= 1.6
./awr-api-trigger-comfort.sh --dry-run    # shows the request body, sends nothing
./awr-api-trigger-comfort.sh --format pkcs12

.\awr-api-trigger-comfort.ps1             # Windows PowerShell 5.1 or PowerShell 7
.\awr-api-trigger-comfort.ps1 -DryRun
```

Exit codes: `0` OK or aborted by you, `1` API error (the response is printed), `2` usage or missing tool.

## Post-delivery scripts

### awr-post-iis-all.ps1  (Windows, IIS)

No parameters. Finds every IIS HTTPS binding of the form `*:<port>:` (any IP, no host name,
no SNI, no Central Certificate Store), imports the PFX into `LocalMachine\My` and switches
those ports to the new certificate with `netsh http update sslcert`. Safety net: a port is
only switched if the certificate currently bound there shares at least one DNS name with
the new one (`$RequireNameMatch`, set to `$false` to switch all of them). Leave the
parameter field in TLM empty. Log: `C:\ProgramData\DigiCert\awr-iis-binding.log`.

Exit `12` also when no candidate port exists or nothing was switched.

### awr-post-iis-per-ports.ps1  (Windows, IIS)

Takes the ports as parameters, e.g. `50001` and `443` (separate parameters or one value
`50001,443`). Binds the certificate to exactly those ports. A port with no IIS binding or
only an HTTP binding is skipped silently. IP-based, fixed-IP and SNI bindings are all
updated, Central Certificate Store bindings are left alone. There is no name matching:
the port list is the intent. Same log file as above.

Exit `0` as soon as at least one binding was updated or already current, `14` when none
was, so a certificate that was rolled out for nothing is visible in TLM.

### awr-post-docker-restart.sh  (Linux)

No parameters. Expects a **pem** delivery: `files[0]` is the certificate, `files[1]` the
key. Copies them to `/etc/digicert/certs/server.crt` and `server.key`, sets permissions
and reloads nginx inside the `webserver` container (`docker exec webserver nginx -s reload`).
Installs `jq` with apt if missing.

### awr-post-config-example.sh  (Linux, example)

Same pem input. Writes a complete nginx configuration for `docker.stroehmi.casa` (HTTP to
HTTPS redirect plus the HTTPS server with the delivered files) to the path given as first
parameter, default `/usr/local/docker/server/data/nginx/nginx.conf`, then restarts the
`proxy` container. Template for "generate config, then restart" style deployments.

### awr-post-fortiweb.sh  (Linux, Fortinet FortiWeb)

Installs the certificate on a FortiWeb appliance through its REST API, so FortiWeb
certificates get renewed without anyone logging in to the appliance. Expects a **pem**
delivery (`.crt` and `.key`) and two parameters:

| Parameter | Value |
|-----------|-------|
| 1 | FortiWeb host name or IP, without scheme or port |
| 2 | Value of the `Authorization` header: base64 of `{"username":"<user>","password":"<password>","vdom":"root"}` |

```bash
echo -n '{"username":"tlm-agent","password":"<password>","vdom":"root"}' | base64 | tr -d '\n'
```

Use a dedicated FortiWeb administrator whose access profile is limited to certificate
management: the token is only base64, not encrypted, and is stored as a plain AWR parameter in TLM.

Talks to `https://<host>:8443/api/v2.0` with `curl -k` (no TLS verification). Reads the CN
from the delivered certificate; if FortiWeb already lists a local certificate of that name it
is deleted first (renewal), then certificate and key are uploaded with
`system/certificate.local.import_certificate`. Log: `/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log`.
Needs `curl`, `jq`, `openssl` and GNU `sed`, so Linux only.

- **Exit `1` on every error**, not `10` to `14` like the other scripts. The `ERROR:` log line
  carries the HTTP status and response body of the FortiWeb API.
- **Log path is tied to agent version 3.1.9.** With another version the directory is missing,
  the `echo >>` in `log()` prints to stderr, and that output alone fails the AWR. Adjust
  `LOGFILE` after installing or updating the agent.
- **Port 8443 is hard-coded** in `API=`.
- **Certificates in use cannot be replaced.** FortiWeb refuses to delete a certificate that a
  server policy references; the script then exits `1`. Importing under a new name and
  switching the policy is not implemented.

## Simulator

### awr-simulator.sh / awr-simulator.ps1

Runs a post-delivery script the way the agent would, without TLM and without an agent:

1. Asks for the script parameters, one per prompt (same as the trigger).
2. Lists the `.sh` (bash version) or `.ps1` (PowerShell version) files next to it and lets
   you pick one by number.
3. Creates a self-signed certificate for `*.stroehmi.casa` in the delivery folder,
   builds `DC1_POST_SCRIPT_DATA` from it and starts the chosen script in its own process
   with no stdin, all output captured.
4. Reports exit code, any output (which would break a real AWR), thumbprint and duration.
   The simulator itself exits `0` only if the script returned `0` and wrote nothing.

| | bash | PowerShell |
|-|------|------------|
| Delivery folder | `/tmp/certificate` | `C:\Certificate` |
| Format | `pem` (crt + key) by default, `--format pfx` for a PFX with password | `pfx` with password `P@ssw0rd` |
| Keep the files | `--keep` | `-Keep` |
| Extras | | shows how many http.sys bindings carry the new thumbprint, tail of the IIS log |
| Needs | openssl, jq | Windows, administrator, execution policy per `README.md` |

The PowerShell version starts the script with `powershell.exe` and **without**
`-ExecutionPolicy Bypass`, so it also proves that scripts are allowed for your account.
The certificate is left in the store and in IIS on purpose: that is what you want to inspect.

## Examples

### IIS, all standard bindings

```powershell
# 1. on the IIS machine: dry run of the post script
.\awr-simulator.ps1
  Parameter 1:                      <Enter, no parameters>
  Post-delivery script  ->  awr-post-iis-all.ps1
  Exit code  : 0 (OK)   Output : none (OK)   Bindings : 2 binding(s) with the new certificate

# 2. from your workstation: the real thing
./awr-api-trigger-comfort.sh
  ... pick account, profile, agent, script "awr-post-iis-all", CN, path C:\Certificate
  Parameter 1:                      <Enter>
  Create the AWR now? [y/N]: y
```

Then TLM > Inventory > Endpoints shows *Auto renew scheduled* and the log on the machine has
a `Done:` line.

### IIS, only ports 50001 and 443

```powershell
.\awr-simulator.ps1
  Parameter 1: 50001
  Parameter 2: 443
  Parameter 3:                      <Enter>
  Post-delivery script  ->  awr-post-iis-per-ports.ps1
```

Same parameters in the trigger afterwards, script "awr-post-iis-per-ports" in TLM. If one of
the ports has only an HTTP binding it is skipped; if none of them could be updated the script
returns `14` and TLM shows the AWR as failed.

### Linux, nginx in Docker

```bash
# on the Docker host, format pem is the default
sudo ./awr-simulator.sh
  Parameter 1:                      <Enter>
  Post-delivery script  ->  awr-post-docker-restart.sh
```

The trigger sends the format you pass with `--format` straight through to the API. It has
been used with `pfx` and `pkcs12`; for a `pem` delivery to a Linux agent, pass `--format pem`
and check the request with `--dry-run` first, or create that AWR in the TLM UI.

### Linux, FortiWeb

```bash
sudo ./awr-simulator.sh
  Parameter 1: fortiweb.example.com
  Parameter 2: <authorization token>
  Parameter 3:                      <Enter>
  Post-delivery script  ->  awr-post-fortiweb.sh
```

The simulator uploads its self-signed `*.stroehmi.casa` certificate to the appliance, so use a
test FortiWeb and delete that certificate afterwards. The log directory of agent 3.1.9 has to
exist on the machine you run this on. Same two parameters in the trigger, with `--format pem`.

### Check the request without sending it

```bash
./awr-api-trigger-comfort.sh --dry-run
```

Prints the complete request body with the password masked. Useful to see the
`auto_renew_settings` taken from the profile and the `parameters` array before anything is
created in TLM.
