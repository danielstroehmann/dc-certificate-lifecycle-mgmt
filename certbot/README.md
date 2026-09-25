# certbot

Issues a certificate from DigiCert ONE Trust Lifecycle Manager (TLM) through its ACME endpoint with plain `certbot`, using the DNS-01 challenge and External Account Binding (EAB). The DNS TXT record is set by hand, so nothing but `certbot` and the EAB credentials of a TLM enrollment profile is needed and any DNS provider works.

## Prerequisites

- `certbot` (`brew install certbot`, `snap install certbot --classic` or `apt install certbot`).
- An ACME enrollment profile in TLM. Take the ACME directory URL, the EAB Key ID (KID) and the EAB HMAC key from it.
- A way to create a TXT record in the DNS zone of the domain. A control panel is enough, no API required.

## Usage

```bash
cd certbot
./setup.sh                        # asks for ACME URL, KID, HMAC and contact email, writes .env
./run-tlm.sh www.example.com      # one FQDN
./run-tlm.sh '*.example.com'      # wildcard, if the enrollment profile allows it
```

`run-tlm.sh` reads `.env` from the current directory, so run it from inside `certbot/`.

## Scripts

### setup.sh

Interactive `.env` generator. Asks for four values and writes them as exported shell variables to `.env` next to the script, mode 600:

| Variable | Meaning | Example |
|----------|---------|---------|
| `URL` | ACME directory URL of the TLM ACME endpoint | `https://one.digicert.com/mpki/api/v1/acme/v2/directory` |
| `KID` | EAB Key ID of the enrollment profile | `abc123...` |
| `HMAC` | EAB HMAC key of the enrollment profile, typed hidden | `base64url string` |
| `EMAIL` | Contact address for the ACME account | `you@example.com` |

`.env` is git-ignored. Run `setup.sh` again to switch to another enrollment profile or account.

### run-tlm.sh

Sources `.env` and calls `certbot certonly` for the domain given as the first argument:

| Option | Effect |
|--------|--------|
| `--manual --preferred-challenges dns` | DNS-01 challenge without hooks: certbot prints the TXT record and waits for Enter |
| `-d "$1"` | The identifier to certify, exactly one per run |
| `--key-type rsa --rsa-key-size 2048` | RSA 2048 key pair |
| `--server "$URL"` | ACME directory from `.env` |
| `--eab-kid "$KID" --eab-hmac-key "$HMAC"` | Binds the ACME account to the TLM enrollment profile |
| `--agree-tos --email "$EMAIL"` | Accepts the terms; contact address from `.env` |
| `--disable-hook-validation` | No effect here, only matters when hooks are used |
| `-v` | Verbose output |

What happens during a run:

1. On the first run certbot registers an ACME account at TLM with the EAB credentials and stores it under `/etc/letsencrypt/accounts/`. Later runs reuse it.
2. certbot prints the record to create: name `_acme-challenge.<domain>`, type TXT, value the validation token.
3. You create that record, wait until it is publicly resolvable (`dig TXT _acme-challenge.<domain>`) and press Enter.
4. TLM validates the record and issues the certificate.
5. Key and certificate land in `/etc/letsencrypt/live/<domain>/` as `privkey.pem`, `cert.pem`, `chain.pem` and `fullchain.pem`. Delete the TXT record afterwards, certbot does not do it without a cleanup hook.

certbot writes to `/etc/letsencrypt` by default and therefore needs root or `sudo`. To run as a normal user add `--config-dir`, `--work-dir` and `--logs-dir` pointing to a writable directory.

**Renewal:** the certificate is stored as a manual lineage and `certbot renew` refuses it (`An authentication script must be provided with --manual-auth-hook when using the manual plugin non-interactively`). Renew by running `./run-tlm.sh <domain>` again and setting the new TXT record. Unattended renewals need `--manual-auth-hook` / `--manual-cleanup-hook` scripts that talk to a DNS API, see below.

## Use cases

- **Prove that a TLM ACME profile works.** Fastest end-to-end test of URL, KID and HMAC with a real domain. No DNS automation, no agent, no plugin.
- **One-off certificates where DNS is managed by hand.** POCs, demos and lab systems whose zone sits in a control panel or with another team. DNS-01 works for hosts that are not reachable from the internet, as only the DNS record has to be public.
- **Wildcard certificates.** DNS-01 is the only ACME challenge that allows `*.example.com`.
- **Starting point for automation.** The same `certbot certonly` call plus `--manual-auth-hook` and `--manual-cleanup-hook` turns this into an unattended workflow. When the authoritative zone has no API or must not be written to, delegate the challenge to a separate zone: [CNAME-DELEGATION.md](CNAME-DELEGATION.md) explains the one-time CNAME, the hook contract and the certbot invocation.

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Interactive `.env` generator |
| `run-tlm.sh` | Requests one certificate from TLM via ACME, DNS-01 by hand |
| `.env` | ACME URL, EAB credentials and contact email, git-ignored, mode 600 |
| [`CNAME-DELEGATION.md`](CNAME-DELEGATION.md) | How to automate DNS-01 for zones without API access by delegating `_acme-challenge` via CNAME |
