#!/bin/bash
# Post-script hook for TLS certificate deployment.
# Reads certificate metadata from the DC1_POST_SCRIPT_DATA environment variable
# (base64-encoded JSON), extracts the certificate and key file paths, then
# copies them to /etc/digicert/certs/ and restarts Docker Compose services.

set -euo pipefail

command -v jq &>/dev/null || apt-get install -y -q jq

DATA=$(echo "$DC1_POST_SCRIPT_DATA" | base64 -d)
FOLDER=$(echo "$DATA" | jq -r .certfolder)
CERT="$FOLDER/$(echo "$DATA" | jq -r .files[0])"
KEY="$FOLDER/$(echo "$DATA"  | jq -r .files[1])"

mkdir -p /etc/digicert/certs
cp "$CERT" /etc/digicert/certs/server.crt
cp "$KEY"  /etc/digicert/certs/server.key
chmod 644 /etc/digicert/certs/server.crt
chmod 600 /etc/digicert/certs/server.key

cd /usr/local/docker
docker exec webserver nginx -s reload &>/dev/null

