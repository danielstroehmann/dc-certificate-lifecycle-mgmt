#!/bin/bash

LOGFILE="/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"; }

curl_api() {
    local tmp; tmp=$(mktemp)
    HTTP_STATUS=$(curl -k -s -g "$@" -o "$tmp" -w "%{http_code}" 2>&1)
    RESPONSE_BODY=$(cat "$tmp")
    rm -f "$tmp"
}

# Parse DC1_POST_SCRIPT_DATA
[ -z "$DC1_POST_SCRIPT_DATA" ] && { log "ERROR: DC1_POST_SCRIPT_DATA not set"; exit 1; }
JSON=$(echo "$DC1_POST_SCRIPT_DATA" | base64 -d)

{ read -r FORTIWEB_URL; read -r AUTH_TOKEN; read -r CERT_FOLDER; read -r CRT_FILE; read -r KEY_FILE; } \
    < <(echo "$JSON" | jq -r '.args[0], .args[1], .certfolder, (.files[] | select(endswith(".crt"))), (.files[] | select(endswith(".key")))')
CRT_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_PATH="${CERT_FOLDER}/${KEY_FILE}"

# Validate
[ -z "$FORTIWEB_URL" ] && { log "ERROR: FortiWeb URL (Argument 1) not provided"; exit 1; }
[ -z "$AUTH_TOKEN"   ] && { log "ERROR: Authorization token (Argument 2) not provided"; exit 1; }
if [ ! -f "$CRT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    log "ERROR: Certificate or key not found (crt=$CRT_PATH, key=$KEY_PATH)"
    exit 1
fi

API="https://${FORTIWEB_URL}:8443/api/v2.0"
AUTH_HEADER="Authorization: $AUTH_TOKEN"

# Delete existing certificate before re-import (renewal)
CN=$(openssl x509 -in "$CRT_PATH" -noout -subject 2>/dev/null \
    | sed -n 's/.*CN\s*=\s*\(.*[^[:space:]]\).*/\1/p')

if [ -n "$CN" ]; then
    curl_api -X GET "$API/system/certificate.local" \
        --header "$AUTH_HEADER" --header 'Accept: application/json'
    if [ "$HTTP_STATUS" == "200" ] && echo "$RESPONSE_BODY" | jq -e --arg cn "$CN" '.results[] | select(.name == $cn)' > /dev/null 2>&1; then
        log "Deleting existing certificate '${CN}'..."
        curl_api -X DELETE "$API/cmdb/system/certificate.local?mkey=${CN}" \
            --header "$AUTH_HEADER" --header 'Accept: application/json'
        if [ "$HTTP_STATUS" == "200" ]; then
            sleep 2
        else
            log "ERROR: Failed to delete '${CN}' (HTTP $HTTP_STATUS) - may be in use"
            exit 1
        fi
    fi
else
    log "WARNING: Could not extract CN - skipping renewal check"
fi

# Upload certificate and key
curl_api -X POST "$API/system/certificate.local.import_certificate" \
    --header "$AUTH_HEADER" --header 'Accept: application/json' \
    --form "certificateFile=@${CRT_PATH}" \
    --form "keyFile=@${KEY_PATH}" \
    --form 'type=certificate'

if [ "$HTTP_STATUS" == "200" ] || [ "$HTTP_STATUS" == "201" ]; then
    log "SUCCESS: Certificate uploaded (HTTP $HTTP_STATUS)"
else
    log "ERROR: Upload failed (HTTP $HTTP_STATUS): $RESPONSE_BODY"
    exit 1
fi
