# YubiKey EST enrollment

Provisions a YubiKey PIV slot with a certificate from DigiCert ONE Trust Lifecycle Manager (TLM): the private key is generated on the YubiKey, a CSR is signed through PKCS#11 and submitted to the TLM EST endpoint, and the returned certificate is written back into the slot. All secrets and parameters live in a local, git-ignored `.env`, never in the scripts.

## Prerequisites

- A YubiKey 5 with PIV and a TLM enrollment profile with EST enabled plus its enrollment code.
- The tools, installed once with the setup script for your platform:

  ```bash
  ./setup-mac.sh      # Homebrew: ykman, opensc, openssl, libp11, curl
  ./setup-linux.sh    # apt (Debian/Ubuntu): yubikey-manager, ykcs11, opensc, libengine-pkcs11-openssl, openssl, curl
  ```

  macOS only: `libykcs11.dylib` is not part of the Homebrew ykman package, install the Yubico PIV Tool as well (`brew install yubico-piv-tool` or the Yubico installer).

## Usage

```bash
./config-mac.sh              # or ./config-linux.sh - asks for profile ID, enrollment code, CN, PIN, ... and writes .env
./mac-est-enroll.sh          # CN only
./mac-est-enroll-msca.sh     # CN + email SAN, for the Microsoft CA backed profile
```

Use the `linux-*` scripts on Linux. Several `.env` files (one per person or key) can be kept and selected with `ENV_FILE=.env.alice ./mac-est-enroll.sh`.

**Warning:** every enroll script starts with `ykman piv reset`. All PIV keys and certificates on the YubiKey are wiped, and PIN, PUK and management key return to the [Yubico factory defaults](https://developers.yubico.com/PIV/Introduction/Admin_access.html). `PIN` and `MGMT_KEY` in `.env` must therefore hold those defaults. The script then replaces the management key with a random one stored PIN-protected on the key.

## Files

| File | Purpose |
|------|---------|
| `config-mac.sh`, `config-linux.sh` | Interactive `.env` generator with platform defaults |
| `mac-est-enroll.sh`, `linux-est-enroll.sh` | Enroll with CN only |
| `*-est-enroll-msca.sh` | Enroll with CN and email SAN |
| `setup-mac.sh`, `setup-linux.sh` | Install dependencies |
| `init.bat` | Windows helper: verify PIN and set CHUID with yubico-piv-tool |
| `.env` | Your secrets and parameters, git-ignored, mode 600 |

## `.env` variables

| Variable | Meaning |
|----------|---------|
| `EST_BASE_URL` | DigiCert ONE EST base URL |
| `EST_PROFILE_ID`, `EST_PROFILE_ID_MSCA` | TLM profile IDs (`TLM-<uuid>`) for the plain and the msca scripts |
| `ENROLL_CODE` | TLM enrollment code, sent as HTTP Basic credential |
| `CN`, `EMAIL` | Certificate subject; `EMAIL` is only used by the msca scripts |
| `SLOT`, `PIN`, `MGMT_KEY` | PIV slot (default `9a`), PIN and current management key |
| `PKCS11_LIB`, `PKCS11_ENGINE` | Path to `libykcs11` and to the OpenSSL pkcs11 engine |
