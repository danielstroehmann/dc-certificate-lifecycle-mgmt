#!/usr/bin/env bash
# AWR simulator - runs a post-delivery script locally the way the DigiCert ONE agent does,
# without an agent and without an AWR: creates a self-signed test certificate, writes it to the
# delivery folder, puts the delivery data into DC1_POST_SCRIPT_DATA (base64 JSON: args,
# certfolder, files, password) and starts the chosen script in its own process. Afterwards it
# reports the exit code and any output (a post-delivery script must not write anything).
#
# The script parameters are typed in one by one (an empty first parameter means: no parameters).
# They go into DC1_POST_SCRIPT_DATA.args and are also passed as command-line arguments.
# The post-delivery script is picked by number from the .sh files next to this script.
#
# Usage:
#   ./awr-simulator.sh                 # format pem: certificate + key file (what the .sh post scripts read)
#   ./awr-simulator.sh --format pfx    # one PKCS#12 file plus password
#   ./awr-simulator.sh --keep          # keep the delivered files after the run
#
# Requires openssl and jq. Runs on macOS (bash 3.2) and Linux.
# Exit codes: 0 = post script returned 0 and wrote nothing, 1 = post script failed or wrote
#             output, 2 = usage / missing tool / no script found

set -eu -o pipefail

# ==== Configuration ====
DOMAIN='*.stroehmi.casa'          # CN and SAN of the test certificate
FOLDER='/tmp/certificate'         # delivery folder (certfolder in the delivery data)
BASENAME='test'                   # file name without extension
PASSWORD='P@ssw0rd'               # PFX password (pfx format only)
FORMAT='pem'                      # pem = <name>.crt + <name>.key, pfx = <name>.pfx + password
# =======================

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-f|--format pem|pfx] [-k|--keep]
  -f, --format   delivery format (default: $FORMAT)
  -k, --keep     keep the delivered files after the run
  -h, --help     this help
Script parameters and the post-delivery script are asked interactively.
USAGE
}

KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--format)  [ $# -ge 2 ] || { usage >&2; exit 2; }; FORMAT="$2"; shift 2 ;;
        --format=*)   FORMAT="${1#*=}"; shift ;;
        -k|--keep)    KEEP=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; exit 2 ;;
    esac
done
case "$FORMAT" in pem|pfx) ;; *) echo "Unknown format '$FORMAT' (pem or pfx)." >&2; exit 2 ;; esac

for tool in openssl jq base64; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool (please install)" >&2; exit 2; }
done

if [ -t 1 ]; then
    RED=$(tput setaf 1 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
    BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
else
    RED=''; GREEN=''; BOLD=''; RESET=''
fi

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF_NAME=$(basename "$0")

# 1) Script parameters (one per prompt, empty input ends the list)
echo 'Script parameters (empty input ends the list, empty right away = no parameters):'
PARAMS=()
i=1
while :; do
    IFS= read -r -p "Parameter $i: " p
    [ -n "$p" ] || break
    PARAMS+=("$p"); i=$((i + 1))
done
if [ ${#PARAMS[@]} -gt 0 ]; then PARAM_TEXT="${PARAMS[*]}"; else PARAM_TEXT='(none)'; fi

# 2) Post-delivery script: the .sh files in this folder, except this script
SCRIPTS=()
for f in "$SELF_DIR"/*.sh; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" != "$SELF_NAME" ] || continue
    SCRIPTS+=("$f")
done
n=${#SCRIPTS[@]}
if [ "$n" -eq 0 ]; then echo "${RED}No .sh files found in $SELF_DIR${RESET}" >&2; exit 2; fi
printf '\n%sPost-delivery script%s\n' "$BOLD" "$RESET"
for ((i = 0; i < n; i++)); do
    printf '  %2d) %s\n' $((i + 1)) "$(basename "${SCRIPTS[$i]}")"
done
while :; do
    read -r -p "Choice: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then break; fi
    echo "Please enter a number from 1 to $n."
done
TARGET=${SCRIPTS[$((choice - 1))]}
TARGET_NAME=$(basename "$TARGET")
echo "  -> $TARGET_NAME"

# 3) Self-signed test certificate in the delivery folder
mkdir -p "$FOLDER"
CRT="$FOLDER/$BASENAME.crt"; KEY="$FOLDER/$BASENAME.key"; PFX="$FOLDER/$BASENAME.pfx"
CFG=$(mktemp "${TMPDIR:-/tmp}/awr-sim.XXXXXX")
trap 'rm -f "$CFG"' EXIT
cat > "$CFG" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = $DOMAIN
[ext]
subjectAltName = DNS:$DOMAIN
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 -config "$CFG" \
    -keyout "$KEY" -out "$CRT" >/dev/null 2>&1 \
    || { echo "${RED}openssl could not create the test certificate.${RESET}" >&2; exit 1; }
THUMBPRINT=$(openssl x509 -in "$CRT" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')

if [ "$FORMAT" = 'pfx' ]; then
    PFX_PW="$PASSWORD" openssl pkcs12 -export -inkey "$KEY" -in "$CRT" -out "$PFX" -passout env:PFX_PW \
        || { echo "${RED}openssl could not create the PFX.${RESET}" >&2; exit 1; }
    rm -f "$CRT" "$KEY"                       # the agent delivers only the PFX
    FILES=("$BASENAME.pfx"); PW="$PASSWORD"
else
    FILES=("$BASENAME.crt" "$BASENAME.key")   # files[0] = certificate, files[1] = key
    PW=''
fi
FILE_TEXT=$(IFS=,; echo "${FILES[*]}" | sed 's/,/, /g')

# 4) Delivery data like the agent: base64 JSON in DC1_POST_SCRIPT_DATA
FILES_JSON=$(printf '%s\n' "${FILES[@]}" | jq -R . | jq -cs .)
JSON=$(jq -cn --arg folder "$FOLDER" --arg pw "$PW" --argjson files "$FILES_JSON" \
    '{args: $ARGS.positional, certfolder: $folder, files: $files, password: $pw}' \
    --args ${PARAMS[@]+"${PARAMS[@]}"})
DC1_POST_SCRIPT_DATA=$(printf '%s' "$JSON" | base64 | tr -d '\n')
export DC1_POST_SCRIPT_DATA

printf '\n%sSimulation%s\n' "$BOLD" "$RESET"
printf '  %-11s: %s\n' \
    'Script'     "$TARGET_NAME" \
    'Parameters' "$PARAM_TEXT" \
    'Format'     "$FORMAT" \
    'Folder'     "$FOLDER" \
    'Files'      "$FILE_TEXT" \
    'Thumbprint' "$THUMBPRINT" \
    'Run as'     "$(id -un)  (the agent usually runs as root)"
printf '  %-11s: %s\n' 'Delivery' "$JSON" | sed "s/\"password\":\"[^\"]*\"/\"password\":\"***\"/"

# 5) Start the post-delivery script in its own process, no stdin, capture all output
START=$(date +%s)
set +e
if [ -x "$TARGET" ]; then
    OUT=$("$TARGET" ${PARAMS[@]+"${PARAMS[@]}"} 2>&1 </dev/null)
else
    OUT=$(bash "$TARGET" ${PARAMS[@]+"${PARAMS[@]}"} 2>&1 </dev/null)
fi
RC=$?
set -e
DURATION=$(( $(date +%s) - START ))
unset DC1_POST_SCRIPT_DATA
if [ "$KEEP" -eq 0 ]; then rm -f "$CRT" "$KEY" "$PFX"; fi

# 6) Evaluation
echo
if [ "$RC" -eq 0 ]; then
    printf '  %-11s: %s%s (OK)%s\n' 'Exit code' "$GREEN" "$RC" "$RESET"
else
    printf '  %-11s: %s%s (expected 0)%s\n' 'Exit code' "$RED" "$RC" "$RESET"
fi
if [ -n "$OUT" ]; then
    printf '  %-11s: %sPRESENT - would break the AWR:%s\n' 'Output' "$RED" "$RESET"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
else
    printf '  %-11s: %snone (OK)%s\n' 'Output' "$GREEN" "$RESET"
fi
printf '  %-11s: %ss\n' 'Duration' "$DURATION"
if [ "$KEEP" -eq 1 ]; then printf '  %-11s: kept in %s\n' 'Files' "$FOLDER"; fi

if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then exit 0; else exit 1; fi
