# dc-tlm

Scripts for certificate lifecycle management with DigiCert ONE Trust Lifecycle Manager (TLM): issuing certificates via ACME and EST, delivering and installing them through the DigiCert ONE agent, and inspecting the result. Everything is plain shell, PowerShell, batch and static HTML, built for labs, demos and proof-of-concepts. Secrets and parameters never live in the scripts; each directory has an interactive generator that writes a git-ignored `.env`.

| Directory | What you find there | Docs |
|-----------|---------------------|------|
| [`agent/`](agent/) | Admin web requests with the DigiCert ONE agent: an API trigger that creates the request in TLM, post-delivery scripts that install the delivered certificate (IIS bindings, nginx in Docker, Fortinet FortiWeb) and a simulator that runs them locally without TLM | [agent/SCRIPTS.md](agent/SCRIPTS.md), [agent/README.md](agent/README.md) (PowerShell execution policy on Windows) |
| [`analyse/`](analyse/) | Inspect the certificate of a TLS endpoint (type, trust, validity, chain, SANs) and change the password of a PKCS#12 file | [analyse/README.md](analyse/README.md) |
| [`certbot/`](certbot/) | Certificates from TLM via ACME with plain `certbot`, External Account Binding and DNS-01 by hand, plus a guide to automating DNS-01 for zones without API access | [certbot/README.md](certbot/README.md), [certbot/CNAME-DELEGATION.md](certbot/CNAME-DELEGATION.md) |
| [`homepage/`](homepage/) | Self-contained demo landing pages, served behind a TLS endpoint as the visual target of a certificate demo | none, open the HTML files |
| [`yubikey/`](yubikey/) | Enroll a TLM certificate into a YubiKey PIV slot via EST: key generated on the key, CSR signed through PKCS#11 | [yubikey/README.md](yubikey/README.md) |
