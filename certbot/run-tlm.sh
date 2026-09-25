#!/bin/bash
source ".env"
for v in URL KID HMAC EMAIL; do [ -n "${!v:-}" ] || { echo "ERROR: $v not set, run ./setup.sh"; exit 1; }; done

certbot certonly \
  --manual \
  --key-type rsa \
  --rsa-key-size 2048 \
  --preferred-challenges dns \
  --disable-hook-validation \
  -d "$1" \
  --agree-tos \
  --email "$EMAIL" \
  --server "$URL" \
  --eab-kid "$KID" \
  --eab-hmac-key "$HMAC" -v

  