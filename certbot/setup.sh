#!/bin/bash
set -euo pipefail

OUT="$(dirname "$(realpath "$0")")/.env"

read -rp  "ACME Directory URL: " URL
read -rp  "EAB Key ID (KID):   " KID
read -rsp "EAB HMAC Key:       " HMAC
echo
read -rp  "Contact email:      " EMAIL

cat > "$OUT" <<EOF
export URL="${URL}"
export KID="${KID}"
export HMAC="${HMAC}"
export EMAIL="${EMAIL}"
EOF

chmod 600 "$OUT"
echo "Written: $OUT"
