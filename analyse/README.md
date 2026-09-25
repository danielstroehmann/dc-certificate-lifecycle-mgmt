# analyse

Two standalone Bash helpers for looking at and touching up certificates. They need only `openssl` and run on macOS (LibreSSL) and Linux.

## check-public-cert

Connects to a TLS endpoint, fetches the certificate chain and prints a compact summary of the leaf certificate:

- Subject (CN, organisation, country) and DNS SANs
- Certificate type DV / OV / EV (via the CA/Browser Forum policy OID) and public vs. private trust (via the `openssl s_client` verify result)
- Validity period with days remaining, flagged `OK`, `WARNING` (< 30 days) or `CRITICAL` (< 14 days)
- Signing CA and root CA, serial number, fingerprint

```bash
./check-public-cert example.com          # port defaults to 443
./check-public-cert 10.0.0.5 8443
./check-public-cert                      # prompts for host and port
```

## reset-pwd-pkcs12

Changes the password of a PKCS#12 (`.p12` / `.pfx`) file. Fully interactive: asks for the file, verifies the current password, asks for the new password twice and for a new filename. The re-encrypted file is verified before it is written next to the original; the original is then deleted.

```bash
./reset-pwd-pkcs12
```

Notes: passwords are typed visibly (no hidden input), and the key passes through an unencrypted temporary PEM that is removed on exit.
