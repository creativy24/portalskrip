#!/bin/sh
# Landing Script: WMS (pra-login)
SCRIPT_NAME="wms.sh"
SCRIPT_BASE=$(basename "$0" .sh)
CONTEXT_NAME=$(echo "$SCRIPT_BASE" | tr 'a-z' 'A-Z')

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh
. /usr/lib/portal/conf/user_agent.conf

trap 'cleanup_temp_routing >/dev/null 2>&1' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

PORTAL_DOMAIN_IP_CONF="/usr/lib/portal/conf/portal_domain_ip.conf"

PORTAL_URL="$1"
IP="$2"
GATEWAY="$4"
IPC="$5"
LOGICAL="$6"

if [ -z "$LOGICAL" ]; then
    log_auto "SYSTEM" "LANDING: Logical parameter kosong. Keluar." "ERROR"
    exit 1
fi

if [ -z "$PORTAL_TYPE" ] || [ -z "$PATH_URL" ]; then
    log_auto "$LOGICAL" "LANDING: Kontrak portal tidak lengkap (PORTAL_TYPE/PATH_URL kosong). Keluar." "ERROR"
    exit 1
fi

CONTRACT_CHECK=$(portal_contract_lookup_identity "$PORTAL_TYPE" "$PATH_URL" 2>/dev/null)
if [ -z "$CONTRACT_CHECK" ]; then
    log_auto "$LOGICAL" "LANDING: Kontrak portal tidak valid atau tidak terdaftar (portal_type=$PORTAL_TYPE, path_url=$PATH_URL). Keluar." "ERROR"
    exit 1
fi

log_auto "$LOGICAL" "LANDING: Pra-Login dimulai" "INFO"
log_auto "$LOGICAL" "LANDING: Logical: $LOGICAL, URL: $PORTAL_URL" "INFO"
log_auto "$LOGICAL" "LANDING: IP: $IP, IPC: $IPC, Gateway: $GATEWAY" "INFO"
log_auto "$LOGICAL" "LANDING: Kontrak: portal_type=$PORTAL_TYPE, path_url=$PATH_URL" "INFO"

if [ -z "$PORTAL_URL" ] || [ -z "$IP" ] || [ -z "$GATEWAY" ]; then
    log_auto "$LOGICAL" "LANDING: Argumen tidak lengkap. Keluar." "ERROR"
    exit 1
fi

DOMAIN=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $1}')
PORT=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $2}')
[ -z "$PORT" ] && {
    case "$PORTAL_URL" in
        https://*) PORT="443" ;;
        *) PORT="80" ;;
    esac
}

log_auto "$LOGICAL" "LANDING: Domain: $DOMAIN, Port: $PORT" "INFO"

RESOLVED_IP=""
if [ -f "$PORTAL_DOMAIN_IP_CONF" ] && [ -s "$PORTAL_DOMAIN_IP_CONF" ]; then
    IP_LIST=$(grep -E "^${DOMAIN}[[:space:]]" "$PORTAL_DOMAIN_IP_CONF" 2>/dev/null | awk '{print $2}' | grep -v '^$')
    if [ -n "$IP_LIST" ]; then
        IP_DEFAULT=$(echo "$IP_LIST" | head -1)
        log_auto "$LOGICAL" "LANDING: IP default untuk $DOMAIN dari $PORTAL_DOMAIN_IP_CONF: $IP_DEFAULT" "INFO"
        RESOLVED_IP="$IP_DEFAULT"
    fi
fi

if [ -z "$RESOLVED_IP" ]; then
    RESOLVED_IP="$GATEWAY"
    IP_LIST="$GATEWAY"
    log_auto "$LOGICAL" "LANDING: Menggunakan GATEWAY sebagai IP portal: $GATEWAY" "INFO"
fi

if [ -n "$7" ]; then
    DEVICE="$7"
    log_auto "$LOGICAL" "LANDING: Device diterima dari parameter: $DEVICE" "INFO"
else
    DEVICE=$(ip -4 addr show | grep -F "$IP" | awk '{print $NF}' | head -1)
    if [ -z "$DEVICE" ]; then
        log_auto "$LOGICAL" "LANDING: Tidak dapat menentukan device untuk IP $IP dan parameter device kosong" "ERROR"
        exit 1
    fi
    log_auto "$LOGICAL" "LANDING: Device ditentukan dari IP (fallback): $DEVICE" "INFO"
fi

log_auto "$LOGICAL" "LANDING: Menyiapkan routing sementara terisolasi..." "INFO"
if ! setup_temp_routing "$LOGICAL" "$IP" "$GATEWAY" "$DEVICE"; then
    log_auto "$LOGICAL" "LANDING: Gagal menyiapkan routing sementara terisolasi" "ERROR"
    exit 1
fi

PROFILES=$(grep '^UA_' /usr/lib/portal/conf/user_agent.conf | awk -F= '{print $1}' | sed 's/^UA_//')
if [ -z "$PROFILES" ]; then
    log_auto "$LOGICAL" "LANDING: Tidak ada profil User-Agent ditemukan" "ERROR"
    cleanup_temp_routing
    exit 1
fi
PROFILE=$(echo "$PROFILES" | awk 'BEGIN{srand()} {a[NR]=$0} END{if(NR>0) print a[int(rand()*NR)+1]}')
log_auto "$LOGICAL" "LANDING: Profil terpilih: $PROFILE" "INFO"

load_browser_profile "$PROFILE" "$CONTEXT_NAME"

[ -z "$ACCEPT_ENCODING" ] && ACCEPT_ENCODING="gzip, deflate"

COOKIE_JAR="/tmp/${LOGICAL}_cookies.txt"
HEADER_DUMP="/tmp/${LOGICAL}_headers.txt"
ERROR_LOG="/tmp/${LOGICAL}_error.log"
HTML_FILE="/tmp/${LOGICAL}_response.html"
HTML_GZ="/tmp/${LOGICAL}_response.html.gz"
HTTP_CODE_FILE="/tmp/${LOGICAL}_http_code.txt"

rm -f "$COOKIE_JAR" "$HEADER_DUMP" "$ERROR_LOG" "$HTML_FILE" "$HTML_GZ" "$HTTP_CODE_FILE" >/dev/null 2>&1
touch "$COOKIE_JAR" >/dev/null 2>&1
chmod 600 "$COOKIE_JAR" >/dev/null 2>&1

log_auto "$LOGICAL" "LANDING: Pre-flight: Menginisialisasi cookie jar dari $PORTAL_URL" "INFO"
curl -s -L --max-time 5 \
    --interface "$DEVICE" \
    -c "$COOKIE_JAR" \
    "$PORTAL_URL" >/dev/null 2>&1
log_auto "$LOGICAL" "LANDING: Cookie jar diinisialisasi dari pre-flight" "DEBUG"

log_curl_error() {
    if [ -s "$ERROR_LOG" ]; then
        while IFS= read -r line; do
            log_auto "$LOGICAL" "LANDING: curl: $line" "ERROR"
        done < "$ERROR_LOG"
    fi
}

LAST_HTTP_STATUS=""

do_curl_request() {
    dc_resolve_ip="$1"
    dc_resolve_opt=""
    if [ -n "$dc_resolve_ip" ]; then
        dc_resolve_opt="--resolve ${DOMAIN}:${PORT}:${dc_resolve_ip}"
        log_auto "$LOGICAL" "LANDING: Menggunakan --resolve ${DOMAIN}:${PORT}:${dc_resolve_ip}" "INFO"
    else
        log_auto "$LOGICAL" "LANDING: Tanpa --resolve, curl akan resolve sendiri" "INFO"
    fi

    CURLRC="/tmp/${LOGICAL}_curlrc"
    rm -f "$CURLRC" "$HEADER_DUMP" "$ERROR_LOG" "$HTML_GZ" "$HTTP_CODE_FILE" >/dev/null 2>&1

    ORDER_STR="$HEADER_ORDER"

    if [ -z "$ORDER_STR" ]; then
        log_auto "$LOGICAL" "LANDING: HEADER_ORDER untuk profil $PROFILE tidak ditemukan. Eksekusi dihentikan." "ERROR"
        return 1
    fi

    OLD_IFS="$IFS"
    IFS='|'
    for hdr in $ORDER_STR; do
        val=$(get_header_value "$hdr")
        if [ -n "$val" ]; then
            echo "header = \"$val\"" >> "$CURLRC"
        fi
    done
    IFS="$OLD_IFS"

    log_auto "$LOGICAL" "LANDING: curlrc dibuat di $CURLRC untuk profil $PROFILE" "DEBUG"

    curl -sS -L --max-time 15 \
        --interface "$DEVICE" \
        $dc_resolve_opt \
        -K "$CURLRC" \
        -b "$COOKIE_JAR" \
        -c "$COOKIE_JAR" \
        -D "$HEADER_DUMP" \
        -o "$HTML_GZ" \
        -w '%{http_code}\n' \
        "$PORTAL_URL" >"$HTTP_CODE_FILE" 2>"$ERROR_LOG"

    LAST_HTTP_STATUS=$(tail -n 1 "$HTTP_CODE_FILE" 2>/dev/null)

    if [ -z "$LAST_HTTP_STATUS" ] && [ -s "$HEADER_DUMP" ]; then
        LAST_HTTP_STATUS=$(grep -E '^HTTP/' "$HEADER_DUMP" | tail -n 1 | awk '{print $2}')
    fi

    rm -f "$CURLRC" >/dev/null 2>&1
}

CURL_EXIT=1
if [ -n "$RESOLVED_IP" ]; then
    log_auto "$LOGICAL" "LANDING: Mencoba curl dengan IP default: $RESOLVED_IP" "INFO"
    do_curl_request "$RESOLVED_IP"
    CURL_EXIT=$?
    log_curl_error

    if [ "$CURL_EXIT" -ne 0 ] || [ "$LAST_HTTP_STATUS" != "200" ]; then
        log_auto "$LOGICAL" "LANDING: IP default belum menghasilkan HTTP 200 (curl=$CURL_EXIT, HTTP=${LAST_HTTP_STATUS:-none}); mencoba fallback..." "WARN"
        ESCAPED_IP=$(echo "$RESOLVED_IP" | sed 's/\./\\./g')
        FALLBACK_IPS=$(echo "$IP_LIST" | grep -v "^${ESCAPED_IP}$" | awk 'BEGIN{srand()} {a[NR]=$0} END{srand(); for(i=NR;i>0;i--){j=int(rand()*i)+1; tmp=a[i]; a[i]=a[j]; a[j]=tmp} for(i=1;i<=NR;i++) print a[i]}')

        if [ -n "$FALLBACK_IPS" ]; then
            for FALLBACK_IP in $FALLBACK_IPS; do
                log_auto "$LOGICAL" "LANDING: Mencoba fallback IP: $FALLBACK_IP" "INFO"
                do_curl_request "$FALLBACK_IP"
                CURL_EXIT=$?
                log_curl_error

                if [ "$CURL_EXIT" -eq 0 ] && [ "$LAST_HTTP_STATUS" = "200" ]; then
                    log_auto "$LOGICAL" "LANDING: Fallback IP berhasil: $FALLBACK_IP" "OK"
                    RESOLVED_IP="$FALLBACK_IP"
                    break
                fi

                log_auto "$LOGICAL" "LANDING: Fallback IP $FALLBACK_IP belum menghasilkan HTTP 200 (curl=$CURL_EXIT, HTTP=${LAST_HTTP_STATUS:-none})" "WARN"
            done
        fi
    fi
else
    log_auto "$LOGICAL" "LANDING: Tanpa IP terkonfigurasi, curl akan resolve sendiri via dedicated routing" "INFO"
    do_curl_request ""
    CURL_EXIT=$?
    log_curl_error
fi

log_auto "$LOGICAL" "LANDING: Membersihkan routing sementara terisolasi..." "INFO"
cleanup_temp_routing

HTTP_STATUS="$LAST_HTTP_STATUS"

if [ "$CURL_EXIT" -ne 0 ]; then
    log_auto "$LOGICAL" "LANDING: Gagal mengakses portal setelah semua percobaan (curl exit: $CURL_EXIT)" "ERROR"
    exit 1
fi

if [ ! -s "$HEADER_DUMP" ]; then
    log_auto "$LOGICAL" "LANDING: Header respons kosong" "ERROR"
    exit 1
fi

CONTENT_TYPE=$(grep -i '^Content-Type:' "$HEADER_DUMP" | tail -n 1 | sed 's/^Content-Type: //i' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
SERVER_HEADER=$(grep -i '^Server:' "$HEADER_DUMP" | tail -n 1 | sed 's/^Server: //i' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
CONTENT_ENCODING=$(grep -i '^Content-Encoding:' "$HEADER_DUMP" | tail -n 1 | sed 's/^Content-Encoding: //i' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
SET_COOKIE=$(grep -i '^Set-Cookie:' "$HEADER_DUMP" | tail -n 1 | sed 's/^Set-Cookie: //i' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
LOCATION_HEADER=$(grep -i '^Location:' "$HEADER_DUMP" | tail -n 1 | sed 's/^Location: //i' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

log_auto "$LOGICAL" "LANDING: HTTP Status: ${HTTP_STATUS:-none}" "INFO"
log_auto "$LOGICAL" "LANDING: Content-Type: ${CONTENT_TYPE:-tidak ada}" "INFO"
[ -n "$SERVER_HEADER" ] && log_auto "$LOGICAL" "LANDING: Server: $SERVER_HEADER" "INFO"
[ -n "$CONTENT_ENCODING" ] && log_auto "$LOGICAL" "LANDING: Content-Encoding: $CONTENT_ENCODING" "INFO"
[ -n "$SET_COOKIE" ] && log_auto "$LOGICAL" "LANDING: Set-Cookie: $SET_COOKIE" "INFO"
[ -n "$LOCATION_HEADER" ] && log_auto "$LOGICAL" "LANDING: Location: $LOCATION_HEADER" "INFO"

if [ "$HTTP_STATUS" != "200" ]; then
    log_auto "$LOGICAL" "LANDING: HTTP status final bukan 200 OK: ${HTTP_STATUS:-none}" "ERROR"
    exit 1
fi

if [ -n "$CONTENT_TYPE" ]; then
    case "$CONTENT_TYPE" in
        text/html*)
            log_auto "$LOGICAL" "LANDING: Content-Type valid: text/html" "OK"
            ;;
        *)
            log_auto "$LOGICAL" "LANDING: Content-Type tidak sesuai: $CONTENT_TYPE (diharapkan text/html)" "ERROR"
            exit 1
            ;;
    esac
else
    log_auto "$LOGICAL" "LANDING: Content-Type tidak ditemukan di header final, lanjutkan" "WARN"
fi

if [ ! -s "$HTML_GZ" ]; then
    log_auto "$LOGICAL" "LANDING: Response HTML kosong (body 0 byte)" "ERROR"
    exit 1
fi

log_auto "$LOGICAL" "LANDING: Mendekompres HTML..." "INFO"
RESPONSE_MODE="gzip"

if ! gunzip -c "$HTML_GZ" > "$HTML_FILE" 2>/dev/null || [ ! -s "$HTML_FILE" ]; then
    log_auto "$LOGICAL" "LANDING: gunzip menghasilkan file kosong, mencoba fallback plain text (cat)" "DEBUG"
    RESPONSE_MODE="plain"
    cat "$HTML_GZ" > "$HTML_FILE" 2>/dev/null
fi

rm -f "$HTML_GZ" "$HTTP_CODE_FILE" >/dev/null 2>&1

if [ ! -s "$HTML_FILE" ]; then
    log_auto "$LOGICAL" "LANDING: Body respons kosong setelah pemrosesan" "ERROR"
    exit 1
fi

log_auto "$LOGICAL" "LANDING: HTML disimpan di $HTML_FILE ($(wc -c < "$HTML_FILE") bytes, mode=$RESPONSE_MODE)" "OK"

log_auto "$LOGICAL" "LANDING: Berhasil mengakses portal (portal_type=$PORTAL_TYPE, path_url=$PATH_URL)" "OK"

gw_id=$(echo "$PORTAL_URL" | sed -n 's/.*gw_id=\([^&]*\).*/\1/p')
client_mac=$(echo "$PORTAL_URL" | sed -n 's/.*client_mac=\([^&]*\).*/\1/p')
wlan=$(echo "$PORTAL_URL" | sed -n 's/.*wlan=\([^&]*\).*/\1/p')
sessionid=$(echo "$PORTAL_URL" | sed -n 's/.*sessionid=\([^&]*\).*/\1/p')
ipc_url=$(echo "$PORTAL_URL" | sed -n 's/.*ipc=\([^&]*\).*/\1/p')
[ -z "$ipc_url" ] && ipc="$IPC" || ipc="$ipc_url"

SESSION_FILE="/etc/portal/portal_session_${LOGICAL}"
mkdir -p /etc/portal

cat > "$SESSION_FILE" <<EOF
gw_id=$gw_id
client_mac=$client_mac
wlan=$wlan
sessionid=$sessionid
ipc=$ipc
portal_url=$PORTAL_URL
portal_type=$PORTAL_TYPE
path_url=$PATH_URL
resolved_ip=${RESOLVED_IP:-auto}
cookie_file=$COOKIE_JAR
html_file=$HTML_FILE
timestamp=$(date '+%d-%m-%Y %H:%M:%S')
browser=$BROWSER
device=$DEVICE
logical=$LOGICAL
EOF

log_auto "$LOGICAL" "LANDING: State pra-login disimpan di $SESSION_FILE" "OK"
log_auto "$LOGICAL" "LANDING: Pra-Login BERHASIL" "OK"
log_auto "$LOGICAL" "LANDING: Browser: $BROWSER, Logical: $LOGICAL, Device: $DEVICE" "INFO"
log_auto "$LOGICAL" "LANDING: Resolved IP: ${RESOLVED_IP:-auto}" "INFO"
log_auto "$LOGICAL" "LANDING: HTML: $HTML_FILE" "INFO"

exit 0