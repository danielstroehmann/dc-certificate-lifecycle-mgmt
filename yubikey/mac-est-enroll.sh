#!/bin/bash
# Enroll a DigiCert TLM certificate into a YubiKey PIV slot via EST (macOS).
# Subject: CN only. All secrets and parameters come from ./.env (create it with ./config-mac.sh).
# WARNING: this resets the PIV application first and wipes all keys and certificates on the YubiKey.
set -euo pipefail

# --- Load configuration ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found. Run ./config-mac.sh first."; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in EST_BASE_URL EST_PROFILE_ID ENROLL_CODE CN SLOT PIN MGMT_KEY PKCS11_LIB PKCS11_ENGINE; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is not set in $ENV_FILE"; exit 1; }
done
EST_URL="$EST_BASE_URL/$EST_PROFILE_ID/simpleenroll"

[[ -f "$PKCS11_LIB" ]] || { echo "ERROR: $PKCS11_LIB not found. Fix PKCS11_LIB in $ENV_FILE."; exit 1; }
[[ -f "$PKCS11_ENGINE" ]] || { echo "ERROR: $PKCS11_ENGINE not found. Run: brew install libp11"; exit 1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Prepare the YubiKey -----------------------------------------------------
ykman piv reset --force

echo "Setting management key to PIN-protected..."
ykman piv access change-management-key \
  --management-key "$MGMT_KEY" \
  --pin "$PIN" \
  --protect

echo "Generating RSA-2048 key in slot $SLOT..."
ykman piv keys generate \
  --algorithm RSA2048 \
  --pin-policy once \
  --touch-policy never \
  --pin "$PIN" \
  "$SLOT" "$TMPDIR/pubkey.pem"

SERIAL=$(ykman info | awk '/Serial number/{print $NF}')

# --- Build the CSR on the YubiKey via PKCS#11 --------------------------------
cat > "$TMPDIR/csr.cnf" << CNF
[req]
distinguished_name = dn
prompt             = no

[dn]
CN = $CN
CNF

cat > "$TMPDIR/openssl.cnf" << CNF
openssl_conf = openssl_init

[openssl_init]
engines = engine_section

[engine_section]
pkcs11 = pkcs11_section

[pkcs11_section]
engine_id    = pkcs11
dynamic_path = $PKCS11_ENGINE
MODULE_PATH  = $PKCS11_LIB
init         = 0
CNF

echo "Generating CSR..."
OPENSSL_CONF="$TMPDIR/openssl.cnf" \
openssl req -new \
  -engine pkcs11 \
  -keyform engine \
  -key "pkcs11:token=YubiKey%20PIV%20%23${SERIAL};id=%01;type=private;pin-value=$PIN" \
  -config "$TMPDIR/csr.cnf" \
  -sha256 \
  -out "$TMPDIR/csr.pem"

openssl req -in "$TMPDIR/csr.pem" -noout -text | grep "Subject:"

# --- Submit to EST and import the certificate --------------------------------
PASSCODE_B64=$(printf '%s' "$ENROLL_CODE" | base64 | tr -d '\n')

echo "Submitting CSR to EST..."
HTTP_CODE=$(curl -s \
  --request POST \
  --location "$EST_URL" \
  --header "Content-Type: text/plain" \
  --header "Authorization: Basic $PASSCODE_B64" \
  --data-binary "@$TMPDIR/csr.pem" \
  -o "$TMPDIR/response.b64" \
  -w "%{http_code}")

[[ "$HTTP_CODE" == "200" ]] || { echo "ERROR: EST returned HTTP $HTTP_CODE"; cat "$TMPDIR/response.b64"; exit 1; }

base64 -D -i "$TMPDIR/response.b64" -o "$TMPDIR/response.p7.der"
openssl pkcs7 -inform DER -in "$TMPDIR/response.p7.der" -print_certs -out "$TMPDIR/cert.pem"
openssl x509 -in "$TMPDIR/cert.pem" -noout -subject -issuer -dates -ext subjectAltName

echo "Importing certificate into slot $SLOT..."
ykman piv certificates import \
  --pin "$PIN" \
  "$SLOT" "$TMPDIR/cert.pem"

ykman piv info
