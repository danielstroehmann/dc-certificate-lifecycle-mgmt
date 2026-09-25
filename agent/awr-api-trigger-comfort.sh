#!/usr/bin/env bash
# Comfort version of awr-api-trigger.sh: creates an AWR (admin web request) via the TLM API,
# but asks for everything interactively. Instance, account, profile, agent and post-delivery
# script are picked by number from what the API returns; CN, delivery path and the script
# parameters are typed in one by one (an empty first parameter means: no parameters). The config
# block below only preselects entries in the menus.
#
# Endpoint: POST /mpki/api/v1/automation/admin-web-request  (API key needs "Run automation")
# Auto-renew is taken from the chosen profile: its own auto_renew_settings (days before expiry,
# time, zone) are sent 1:1, so TLM schedules the next AWR run ("Auto renew scheduled").
# Requires curl and jq >= 1.6. Runs on macOS (bash 3.2) and Linux.
#
# Usage:
#   ./awr-api-trigger-comfort.sh                 # interactive, asks for confirmation before sending
#   ./awr-api-trigger-comfort.sh --dry-run       # everything except the final POST
#   ./awr-api-trigger-comfort.sh --format pkcs12
#
# Exit codes: 0 = OK or aborted by the user, 1 = API/HTTP error, 2 = usage / missing tool

set -eu -o pipefail

# ==== Defaults (preselected in the menus when the API returns them) ====
HOSTS=('one.nl.digicert.com' 'one.ch.digicert.com' 'one.digicert.com')
DEFAULT_HOST=2                                   # 1-based index into HOSTS
ACCOUNT_ID=''                                    # optional: paste your TLM IDs here to preselect them
PROFILE_ID=''                                    # (empty = no default, the menus simply ask)
AGENT_ID=''
SCRIPT_ID=''
DEFAULT_PATH='C:\Certificate'                    # delivery folder on the agent VM, Windows style
# ========================================================================

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-f|--format pfx|pkcs12] [-n|--dry-run]

  -f, --format   certificate format (default: pfx)
  -n, --dry-run  everything except the final POST

Instance, account, profile, agent, script, CN, path and script parameters are asked interactively.
USAGE
}

# ---- Arguments ----
FORMAT='pfx'
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--format)  [ $# -ge 2 ] || { usage >&2; exit 2; }; FORMAT="$2"; shift 2 ;;
        --format=*)   FORMAT="${1#*=}"; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool (please install)" >&2; exit 2; }
done

# ---- Colors (only when stdout is a terminal) ----
if [ -t 1 ]; then
    RED=$(tput setaf 1 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
    BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
else
    RED=''; GREEN=''; BOLD=''; RESET=''
fi

# ---- Temp files (mode 600) for secrets, request body and responses; removed on exit ----
umask 077
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/awr-api.XXXXXX")
CURL_CFG="$TMP_DIR/curl.cfg"     # holds the API key header, keeps it out of the process list
BODY="$TMP_DIR/body.json"
RESP="$TMP_DIR/response.json"
cleanup() { rm -rf "$TMP_DIR"; unset API_KEY PFX_PW; }
trap cleanup EXIT

# Read a secret without echo. $1 = prompt, $2 = target variable name
read_secret() {
    local value
    IFS= read -r -s -p "$1: " value
    printf '\n'
    printf -v "$2" '%s' "$value"
}

# Ask for a value. $1 = prompt, $2 = target variable, $3 = default ('' = required)
ask() {
    local value
    while :; do
        if [ -n "$3" ]; then IFS= read -r -p "$1 [$3]: " value; value=${value:-$3}
        else IFS= read -r -p "$1: " value; fi
        [ -n "$value" ] && break
        echo "Input required."
    done
    printf -v "$2" '%s' "$value"
}

# Read a secret and echo an asterisk per character (backspace supported). $1 = prompt, $2 = target variable
read_masked() {
    local value='' ch
    printf '%s: ' "$1"
    while IFS= read -r -s -n 1 ch; do
        case "$ch" in
            '')            break ;;                                        # Enter
            $'\x7f'|$'\b') if [ -n "$value" ]; then value=${value%?}; printf '\b \b'; fi ;;
            *)             value+=$ch; printf '*' ;;
        esac
    done
    printf '\n'
    printf -v "$2" '%s' "$value"
}

# Local IANA time zone for the auto-renew time (the UI uses the browser's zone); UTC as fallback
local_zone() {
    local z=${TZ:-} link
    if [ -z "$z" ] && link=$(readlink /etc/localtime 2>/dev/null); then z=${link##*zoneinfo/}; fi
    if [ -z "$z" ] && [ -r /etc/timezone ]; then z=$(head -n1 /etc/timezone); fi
    case "$z" in [A-Za-z]*/[A-Za-z]*|UTC|GMT) printf '%s' "$z" ;; *) printf 'UTC' ;; esac
}

# Auto-renew settings of a profile from the last response: the object under cc_settings /
# ca_settings (CertCentral / private CA profiles), searched anywhere in the JSON; empty if absent
auto_renew_from_resp() {
    jq -c '[.. | objects | select(has("auto_renew_settings")) | .auto_renew_settings | objects | select(has("auto_renew_time"))] | first // empty' "$RESP" 2>/dev/null || true
}
# Renewal window in days from the last response: renewal_window_days or renewal_period_days,
# the first value > 0 anywhere in the JSON; 0 if absent
renew_days_from_resp() {
    jq -r '[.. | objects | (.renewal_window_days, .renewal_period_days) | select(. != null) | tonumber? | select(. > 0)] | (first // 0) | floor' "$RESP" 2>/dev/null || echo 0
}
# Human-readable text for a profile auto-renew object on stdin
auto_renew_text() {
    jq -r 'if .auto_renew_certificate_and_order == true then
             (if .before_expiration == true then "shortly before expiry"
              else "\(.auto_renew_time.days // 0) days before expiry, \(.auto_renew_time.hours // 0):\(.auto_renew_time.minutes // 0 | tostring | if length < 2 then "0" + . else . end) \(.auto_renew_time.time_format // "" | ascii_upcase) \(.auto_renew_time.zone // "")" end)
             + " (auto-renew settings of the profile)"
           else "off (auto-renew disabled in the profile)" end'
}

# http_call METHOD URL [BODYFILE]: response body -> $RESP, status code -> $HTTP_CODE
http_call() {
    local method=$1 url=$2 body=${3:-}
    if [ -n "$body" ]; then
        HTTP_CODE=$(curl -sS --tlsv1.2 -K "$CURL_CFG" -X "$method" "$url" \
                    -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$body" \
                    -o "$RESP" -w '%{http_code}')
    else
        HTTP_CODE=$(curl -sS --tlsv1.2 -K "$CURL_CFG" -X "$method" "$url" -o "$RESP" -w '%{http_code}')
    fi
}

http_ok() { case "$HTTP_CODE" in 2??) return 0 ;; *) return 1 ;; esac; }

show_api_error() {
    echo "${RED}HTTP error: $HTTP_CODE${RESET}" >&2
    if [ -s "$RESP" ]; then jq . "$RESP" 2>/dev/null || cat "$RESP"; echo; fi >&2
}

# GET that must succeed, otherwise the error is shown and the script ends
must_get() { http_call GET "$1"; http_ok || { show_api_error; exit 1; }; }

# load_menu: reads "id<TAB>name<TAB>label" lines from stdin into the MENU_* arrays
load_menu() {
    MENU_IDS=(); MENU_NAMES=(); MENU_LABELS=()
    local id name label
    while IFS=$'\t' read -r id name label; do
        [ -n "$id" ] || continue
        MENU_IDS+=("$id"); MENU_NAMES+=("$name"); MENU_LABELS+=("$label")
    done
}

# select_item TITLE [PRESELECTED_ID]: shows the menu, sets SEL_ID and SEL_NAME
select_item() {
    local title=$1 pre=${2:-} n i def='' choice
    n=${#MENU_IDS[@]}
    if [ "$n" -eq 0 ]; then echo "${RED}No entries found: $title${RESET}" >&2; exit 1; fi
    printf '\n%s%s%s\n' "$BOLD" "$title" "$RESET"
    for ((i = 0; i < n; i++)); do
        if [ "${MENU_IDS[$i]}" = "$pre" ]; then def=$((i + 1)); fi
        printf '  %2d) %s\n' $((i + 1)) "${MENU_LABELS[$i]}"
    done
    while :; do
        if [ -n "$def" ]; then read -r -p "Choice [$def]: " choice; choice=${choice:-$def}
        else read -r -p "Choice: " choice; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then break; fi
        echo "Please enter a number from 1 to $n."
    done
    SEL_ID=${MENU_IDS[$((choice - 1))]}
    SEL_NAME=${MENU_NAMES[$((choice - 1))]}
    echo "  -> $SEL_NAME  ($SEL_ID)"
}

# 1) Instance
load_menu < <(for h in "${HOSTS[@]}"; do printf '%s\t%s\t%s\n' "$h" "$h" "$h"; done)
select_item 'DigiCert ONE instance' "${HOSTS[$((DEFAULT_HOST - 1))]}"
HOST_NAME=$SEL_ID
BASE="https://$HOST_NAME/mpki/api/v1"

# 2) API key
read_masked 'API key (service user with "Run automation")' API_KEY
printf 'header = "X-API-Key: %s"\n' "$API_KEY" > "$CURL_CFG"

# 3) Account: taken from the business units, which carry their account (id + name) and
#    can be listed without knowing an account ID first
must_get "$BASE/business-unit?limit=100"
load_menu < <(jq -r '[.items[]? | .account | select(.id)] | unique_by(.id) | sort_by(.name) | .[]
                     | [.id, .name, (.name + "  " + .id)] | @tsv' "$RESP")
select_item 'Account' "$ACCOUNT_ID"
ACCOUNT_ID=$SEL_ID; ACCOUNT_NAME=$SEL_NAME

# 4) Profile (only those of the chosen account)
must_get "$BASE/profile?limit=100"
load_menu < <(jq -r --arg acc "$ACCOUNT_ID" '
    [(if type == "array" then . else (.items // []) end)[] | select(.account_id == $acc)] | sort_by(.name) | .[]
    | [.id, .name, (.name + "  [" + (.enrollment_method // "-") + ", " + (.status // "-") + "]  " + .id)] | @tsv' "$RESP")
select_item 'Certificate profile' "$PROFILE_ID"
PROFILE_ID=$SEL_ID; PROFILE_NAME=$SEL_NAME

# 4b) Auto-renew for the AWR, taken from the chosen profile.
#     The profile's own auto_renew_settings (under cc_settings for CertCentral profiles, ca_settings
#     for private CAs) are taken over 1:1 when an endpoint returns them; the public v1 response often
#     does not, so v2, v3 and the UI API are tried as well. Fallback: the renewal window in days.
must_get "$BASE/profile/$PROFILE_ID"
PROFILE_KEYS=$(jq -r 'if type == "object" then (keys | join(", ")) else type end' "$RESP" 2>/dev/null)
RENEW_JSON=$(auto_renew_from_resp)
RENEW_DAYS=$(renew_days_from_resp)
for alt in "https://$HOST_NAME/mpki/api/v2/profile/$PROFILE_ID" "https://$HOST_NAME/mpki/api/v3/profile/$PROFILE_ID" "https://$HOST_NAME/mpki/ui-api/v1/profile/$PROFILE_ID"; do
    [ -z "$RENEW_JSON" ] || break
    http_call GET "$alt" || continue
    http_ok || continue
    RENEW_JSON=$(auto_renew_from_resp)
    [ "$RENEW_DAYS" -gt 0 ] || RENEW_DAYS=$(renew_days_from_resp)
done
ZONE=$(local_zone)
if [ -n "$RENEW_JSON" ]; then RENEW_TEXT=$(printf '%s' "$RENEW_JSON" | auto_renew_text)
elif [ "$RENEW_DAYS" -gt 0 ]; then RENEW_TEXT="$RENEW_DAYS days before expiry, 01:00 AM $ZONE (renewal window of the profile)"
else RENEW_TEXT="off - no auto-renew settings and no renewal window in the profile (fields: $PROFILE_KEYS)"; fi
echo "  Auto-renew: $RENEW_TEXT"

# 5) Agent
must_get "$BASE/agent?account_id=$ACCOUNT_ID&limit=100"
load_menu < <(jq -r '[.items[]?] | sort_by(.name) | .[]
    | [.id, .name, (.name + "  [" + (.host_name // "-") + ", " + (.status // "-") + ", " + (.os_name // "-") + "]  " + .id)] | @tsv' "$RESP")
select_item 'Agent' "$AGENT_ID"
AGENT_ID=$SEL_ID; AGENT_NAME=$SEL_NAME

# 6) Post-delivery script
must_get "$BASE/agent/script?account_id=$ACCOUNT_ID"
load_menu < <(jq -r '[(if type == "array" then . else (.items // []) end)[]] | sort_by(.name) | .[]
    | [.id, .name, (.name + "  [" + (.type // "-") + ", " + (.os // "-") + ", " + (.path // "-") + "]  " + .id)] | @tsv' "$RESP")
select_item 'Post-delivery script' "$SCRIPT_ID"
SCRIPT_ID=$SEL_ID; SCRIPT_NAME=$SEL_NAME

# 7) CN, delivery path, script parameters (one per prompt, empty input ends the list)
echo
ask 'Common Name (CN)' CN ''
ask 'Delivery path on the agent' CERT_PATH "$DEFAULT_PATH"
echo 'Script parameters (empty input ends the list, empty right away = no parameters):'
PARAMS=()
i=1
while :; do
    IFS= read -r -p "Parameter $i: " p
    [ -n "$p" ] || break
    PARAMS+=("$p"); i=$((i + 1))
done
if [ ${#PARAMS[@]} -gt 0 ]; then PARAM_TEXT="${PARAMS[*]}"; else PARAM_TEXT='(none)'; fi

# 8) PFX password
read_secret 'PFX password' PFX_PW

# 9) Request body. Password via the environment, parameters via --args (always a JSON array).
PFX_PW="$PFX_PW" jq -n \
    --arg account_id  "$ACCOUNT_ID" \
    --arg profile_id  "$PROFILE_ID" \
    --arg cn          "$CN" \
    --arg agent_id    "$AGENT_ID" \
    --arg script_id   "$SCRIPT_ID" \
    --arg script_name "$SCRIPT_NAME" \
    --arg format      "$FORMAT" \
    --arg path        "$CERT_PATH" \
    --argjson renew_days "$RENEW_DAYS" \
    --arg zone        "$ZONE" \
    --argjson profile_renew "${RENEW_JSON:-null}" \
    '{
        account_id:  $account_id,
        profile_id:  $profile_id,
        cn:          $cn,
        action_type: "ENROLL",
        certificate_services_agreement: true,
        auto_renew_settings: (if $profile_renew != null then
            ({ auto_renew_certificate_and_order: ($profile_renew.auto_renew_certificate_and_order == true),
               before_expiration: ($profile_renew.before_expiration == true) }
             + (if ($profile_renew.auto_renew_time | type) == "object"
                then { auto_renew_time: ($profile_renew.auto_renew_time
                        | with_entries(select(.key == "days" or .key == "hours" or .key == "minutes" or .key == "time_format" or .key == "zone"))) }
                else {} end))
        elif $renew_days > 0 then {
            auto_renew_certificate_and_order: true,
            before_expiration: false,
            auto_renew_time: { days: $renew_days, hours: 1, minutes: 0, time_format: "AM", zone: $zone }
        } else { auto_renew_certificate_and_order: false, before_expiration: false } end),
        cert_delivery_settings: [{
            delivery_method: "agent",
            agent_ids:       [$agent_id],
            delivery_configs: [{
                format:   $format,
                path:     $path,
                password: env.PFX_PW,
                scripts: [{
                    agent_id:    $agent_id,
                    script_id:   $script_id,
                    script_name: $script_name,
                    script_type: "POSTHOOK",
                    parameters:  $ARGS.positional
                }]
            }]
        }]
    }' --args ${PARAMS[@]+"${PARAMS[@]}"} > "$BODY"

printf '\n%sSummary%s\n' "$BOLD" "$RESET"
printf '  %-10s: %s\n' \
    'Instance'  "$HOST_NAME" \
    'Account'   "$ACCOUNT_NAME  ($ACCOUNT_ID)" \
    'Profile'   "$PROFILE_NAME  ($PROFILE_ID)" \
    'Agent'     "$AGENT_NAME  ($AGENT_ID)" \
    'Script'    "$SCRIPT_NAME  ($SCRIPT_ID)" \
    'CN'        "$CN" \
    'Path'      "$CERT_PATH" \
    'Parameters' "$PARAM_TEXT" \
    'Format'    "$FORMAT" \
    'Renewal'   "$RENEW_TEXT"
printf '\nRequest body (password masked):\n'
jq '.cert_delivery_settings[].delivery_configs[].password = "***"' "$BODY"

if [ "$DRY_RUN" -eq 1 ]; then printf '\nDryRun - nothing sent.\n'; exit 0; fi

read -r -p "Create the AWR now? [y/N]: " yn
case "$yn" in j|J|y|Y) ;; *) echo 'Aborted, nothing sent.'; exit 0 ;; esac

# 10) Create the AWR
http_call POST "$BASE/automation/admin-web-request" "$BODY"
if http_ok; then
    printf '\n%sOK (%s) - AWR created.%s\n' "$GREEN" "$HTTP_CODE" "$RESET"
    echo "Next: TLM > Inventory > Endpoints (Tracker) and on the VM C:\\ProgramData\\DigiCert\\awr-iis-binding.log"
else
    show_api_error
    exit 1
fi
