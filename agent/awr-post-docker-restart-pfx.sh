#!/bin/bash
# Post-delivery script for TLM admin web requests (AWR), Linux, nginx in Docker.
# Reads the delivery data from DC1_POST_SCRIPT_DATA (base64-encoded JSON), takes the PKCS#12
# file (enrollment format PFX) and its password, extracts certificate plus chain and the
# private key, installs them as /etc/digicert/certs/server.crt and server.key and reloads
# nginx inside the "webserver" container. PFX counterpart of awr-post-docker-restart.sh,
# which expects a pem delivery (crt + key).
#
# Contract with the agent: no output on stdout or stderr, everything goes to the log file;
# result only as exit code. 0 = OK, 10 = delivery data unusable, 11 = certificate/key
# extraction failed, 12 = installation or nginx reload failed, 13 = unexpected error.

set -u -o pipefail

# ── Configuration ────────────────────────────────────────────────────────────
TARGET_DIR="${TARGET_DIR:-/etc/digicert/certs}"     # where nginx expects server.crt/.key
CONTAINER="${CONTAINER:-webserver}"                 # nginx container to reload
LOGFILE="${LOGFILE:-/var/log/digicert/awr-docker-restart-pfx.log}"

# ── Logging: from here on every output lands in the log file, never on the console ──
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || LOGFILE="/tmp/awr-docker-restart-pfx.log"
exec >>"$LOGFILE" 2>&1
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $2"; log "Exit $1"; exit "$1"; }
trap 'fail 13 "unexpected error in line $LINENO"' ERR
set -E

WORK=$(mktemp -d) || fail 13 "cannot create a temporary directory"
trap 'rm -rf "$WORK"' EXIT
umask 077

log "===== Start ====="

# ── Delivery data ────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null; then
    log "jq missing, installing it"
    apt-get install -y -q jq || fail 10 "jq is missing and could not be installed"
fi
[ -n "${DC1_POST_SCRIPT_DATA:-}" ] || fail 10 "DC1_POST_SCRIPT_DATA is not set"
DATA=$(printf '%s' "$DC1_POST_SCRIPT_DATA" | base64 -d 2>/dev/null) \
    || fail 10 "DC1_POST_SCRIPT_DATA is not valid base64"
FOLDER=$(jq -er '.certfolder' <<<"$DATA" 2>/dev/null) || fail 10 "no certfolder in the delivery data"
PFX=$(jq -r '.files[]? | select(test("\\.(pfx|p12)$"; "i"))' <<<"$DATA" | head -n1)
log "Folder: $FOLDER  Files: $(jq -c '.files' <<<"$DATA")"

[ -n "$PFX" ] || fail 10 "no .pfx/.p12 in the delivery (enrollment format must be PFX)"
PFX="$FOLDER/$PFX"
[ -f "$PFX" ] || fail 10 "PFX file not found: $PFX"
PFX_PASS=$(jq -r '.password // ""' <<<"$DATA")
export PFX_PASS                                       # handed to openssl via env, not argv
log "PFX: $PFX (password ${#PFX_PASS} characters)"

# ── Extract leaf + chain and key ─────────────────────────────────────────────
# OpenSSL 3 refuses older PKCS#12 encryption (RC2/3DES) unless -legacy is given
P12_OPTS=()
if ! openssl pkcs12 -in "$PFX" -passin env:PFX_PASS -noout 2>/dev/null; then
    if openssl pkcs12 -legacy -in "$PFX" -passin env:PFX_PASS -noout 2>/dev/null; then
        P12_OPTS=(-legacy); log "PFX uses legacy encryption, using -legacy"
    else
        fail 11 "cannot open the PFX (wrong password or damaged file)"
    fi
fi
p12() { openssl pkcs12 ${P12_OPTS[@]+"${P12_OPTS[@]}"} -in "$PFX" -passin env:PFX_PASS "$@"; }
pem_only() { sed -n '/-----BEGIN/,/-----END/p'; }     # drops the "Bag Attributes" lines

CRT_NEW="$WORK/server.crt"
KEY_NEW="$WORK/server.key"
p12 -clcerts -nokeys | pem_only >"$CRT_NEW"  || fail 11 "cannot extract the certificate"
p12 -cacerts -nokeys | pem_only >>"$CRT_NEW" || fail 11 "cannot extract the CA chain"
p12 -nocerts -nodes  | pem_only >"$KEY_NEW"  || fail 11 "cannot extract the private key"
unset PFX_PASS

# ── Sanity checks before anything is replaced ───────────────────────────────
grep -q 'BEGIN CERTIFICATE' "$CRT_NEW" || fail 11 "no certificate in the delivery"
grep -q 'PRIVATE KEY' "$KEY_NEW"       || fail 11 "no private key in the delivery"
PUB_CRT=$(openssl x509 -in "$CRT_NEW" -noout -pubkey 2>/dev/null) || fail 11 "certificate unreadable"
PUB_KEY=$(openssl pkey -in "$KEY_NEW" -pubout 2>/dev/null)        || fail 11 "private key unreadable"
[ "$PUB_CRT" = "$PUB_KEY" ] || fail 11 "private key does not belong to the certificate"
log "Certificate: $(openssl x509 -in "$CRT_NEW" -noout -subject -enddate | tr '\n' ' ')"
log "Chain: $(grep -c 'BEGIN CERTIFICATE' "$CRT_NEW") certificate(s) in server.crt"

# ── Install: write next to the target, then rename, so nginx never sees half a file ──
mkdir -p "$TARGET_DIR" || fail 12 "cannot create $TARGET_DIR"
install -m 644 "$CRT_NEW" "$TARGET_DIR/.server.crt.new" || fail 12 "cannot write to $TARGET_DIR"
install -m 600 "$KEY_NEW" "$TARGET_DIR/.server.key.new" || fail 12 "cannot write to $TARGET_DIR"
mv -f "$TARGET_DIR/.server.crt.new" "$TARGET_DIR/server.crt" || fail 12 "cannot replace server.crt"
mv -f "$TARGET_DIR/.server.key.new" "$TARGET_DIR/server.key" || fail 12 "cannot replace server.key"
log "Installed to $TARGET_DIR"

# ── Reload nginx in the container (config test first) ───────────────────────
docker exec "$CONTAINER" nginx -t        || fail 12 "nginx config test failed in container '$CONTAINER'"
docker exec "$CONTAINER" nginx -s reload || fail 12 "nginx reload failed in container '$CONTAINER'"
log "nginx in '$CONTAINER' reloaded"
log "Exit 0"
exit 0
