#!/bin/sh
# Login Executor: @wifi.id Classic / loginocs
SCRIPT_NAME="login_executor_classic.sh"

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh
. /usr/lib/portal/conf/user_agent.conf

trap 'cleanup_temp_routing >/dev/null 2>&1' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if [ -z "$LOGICAL" ] || [ -z "$DEVICE" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    log_auto "$LOGICAL" "LOGIN: Parameter wajib kurang" "ERROR"
    echo "Parameter wajib kurang"
    exit 1
fi

COOKIE_JAR="/tmp/${LOGICAL}_cookies.txt"
if [ ! -s "$COOKIE_JAR" ]; then
    log_auto "$LOGICAL" "LOGIN: Cookie jar tidak ditemukan. Lakukan pra-login terlebih dahulu." "ERROR"
    echo "Cookie jar tidak ditemukan. Lakukan pra-login terlebih dahulu."
    exit 1
fi

LOAD_WP=$(awk -v min=1000 -v max=5000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')

[ -z "$IPC" ] && IPC=$(ip -4 addr show dev "$DEVICE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$IPC" ]; then
    log_auto "$LOGICAL" "LOGIN: IP interface tidak ditemukan untuk device $DEVICE" "ERROR"
    echo "Gagal menentukan IP interface"
    exit 1
fi

LEC_GW=$(get_gateway "$DEVICE")
if [ -z "$LEC_GW" ]; then
    LEC_GW=$(ip route show default dev "$DEVICE" 2>/dev/null | awk '{print $3}' | head -1)
fi

if [ -z "$LEC_GW" ] || [ "$LEC_GW" = "$NULL_GATEWAY" ]; then
    log_auto "$LOGICAL" "LOGIN: Gagal mendeteksi gateway untuk device $DEVICE" "ERROR"
    echo "Gagal menentukan gateway"
    exit 1
fi

if ! setup_temp_routing "$LOGICAL" "$IPC" "$LEC_GW" "$DEVICE"; then
    log_auto "$LOGICAL" "LOGIN: Gagal menyiapkan routing sementara terisolasi" "ERROR"
    echo "Gagal menyiapkan routing sementara"
    exit 1
fi

WLAN_ENCODED=$(echo "$WLAN" | sed 's/ /%20/g')

DOMAIN=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $1}')
log_auto "$LOGICAL" "LOGIN: Domain target diekstrak secara dinamis dari URL: $DOMAIN" "INFO"
RESOLVE_OPT=""
RESOLVED_LOGIN_IP=$(get_portal_ip "$DOMAIN")
if [ -n "$RESOLVED_LOGIN_IP" ]; then
    RESOLVE_OPT="--resolve ${DOMAIN}:443:${RESOLVED_LOGIN_IP}"
    log_auto "$LOGICAL" "LOGIN: DNS Bypass aktif untuk Login: $RESOLVE_OPT" "INFO"
else
    log_auto "$LOGICAL" "LOGIN: IP untuk $DOMAIN tidak ditemukan di portal_domain_ip.conf, menggunakan DNS sistem." "WARN"
fi

LOGIN_URL="https://welcome2.wifi.id/authnew/login/check_login.php?ipc=${IPC}&gw_id=${GW_ID}&mac=${CLIENT_MAC}&redirect=&wlan=${WLAN_ENCODED}&load_wp=${LOAD_WP}"

SESSION_FILE="/etc/portal/portal_session_${LOGICAL}"
if [ -f "$SESSION_FILE" ]; then
    PROFILE=$(grep '^browser=' "$SESSION_FILE" | cut -d'=' -f2)
    log_auto "$LOGICAL" "LOGIN: State browser dibaca dari session: $PROFILE" "INFO"
else
    PROFILE="CHROME"
    log_auto "$LOGICAL" "LOGIN: Session file tidak ditemukan, fallback ke CHROME" "WARN"
fi

load_browser_profile "$PROFILE" "CLASSIC"

CURLRC="/tmp/${LOGICAL}_classic_curlrc"
rm -f "$CURLRC" >/dev/null 2>&1

write_safe_header() {
    local hdr_name="$1"
    local hdr_val="$2"
    hdr_val=$(printf '%s' "$hdr_val" | tr -d '\r')

    if [ -z "$hdr_val" ] || [ "$hdr_val" = '""' ]; then
        return
    fi
    
    local escaped_val=$(printf '%s' "$hdr_val" | sed 's/"/\\"/g')

    printf 'header = "%s: %s"\n' "$hdr_name" "$escaped_val" >> "$CURLRC"
}

printf 'header = "Host: welcome2.wifi.id"\n' >> "$CURLRC"

VAL=$(get_header_value "Accept-Language")
write_safe_header "Accept-Language" "$VAL"
printf 'header = "Accept: application/json, text/javascript, */*; q=0.01"\n' >> "$CURLRC"
printf 'header = "Cache-Control: no-cache"\n' >> "$CURLRC"
printf 'header = "Connection: keep-alive"\n' >> "$CURLRC"
printf 'header = "Content-Type: application/x-www-form-urlencoded; charset=UTF-8"\n' >> "$CURLRC"

VAL=$(get_header_value "DNT")
write_safe_header "DNT" "$VAL"

printf 'header = "Origin: https://welcome2.wifi.id"\n' >> "$CURLRC"
printf 'header = "Pragma: no-cache"\n' >> "$CURLRC"
printf 'header = "Referer: %s"\n' "$PORTAL_URL" >> "$CURLRC"
printf 'header = "Sec-Fetch-Dest: empty"\n' >> "$CURLRC"
printf 'header = "Sec-Fetch-Mode: cors"\n' >> "$CURLRC"
printf 'header = "Sec-Fetch-Site: same-origin"\n' >> "$CURLRC"

VAL=$(get_header_value "User-Agent")
write_safe_header "User-Agent" "$VAL"

printf 'header = "X-Requested-With: XMLHttpRequest"\n' >> "$CURLRC"

VAL=$(get_header_value "sec-ch-ua")
write_safe_header "sec-ch-ua" "$VAL"

VAL=$(get_header_value "sec-ch-ua-mobile")
write_safe_header "sec-ch-ua-mobile" "$VAL"

VAL=$(get_header_value "sec-ch-ua-platform")
write_safe_header "sec-ch-ua-platform" "$VAL"

PAYLOAD="username=${USERNAME}&password=${PASSWORD}&landURL="

log_auto "$LOGICAL" "LOGIN: Mengirim request login classic ke $LOGIN_URL" "INFO"

RESPONSE=$(curl -s -S --max-time 15 \
    --interface "$DEVICE" \
    $RESOLVE_OPT \
    -K "$CURLRC" \
    -b "$COOKIE_JAR" \
    -c "$COOKIE_JAR" \
    -X POST \
    -d "$PAYLOAD" \
    "$LOGIN_URL" 2>/dev/null)

CURL_EXIT=$?
rm -f "$CURLRC" >/dev/null 2>&1

log_auto "$LOGICAL" "LOGIN: Membersihkan routing sementara terisolasi..." "INFO"
cleanup_temp_routing

if [ "$CURL_EXIT" -ne 0 ]; then
    log_auto "$LOGICAL" "LOGIN: Curl gagal dengan exit code: $CURL_EXIT" "ERROR"
    echo "Koneksi gagal"
    exit 1
fi

MSG_FILE="/tmp/${LOGICAL}_last_login_message.txt"

if echo "$RESPONSE" | grep -q '"result": 1\|"Login Sukses"'; then
    log_auto "$LOGICAL" "LOGIN: Login BERHASIL" "OK"
    printf '%s' "Login Berhasil" > "$MSG_FILE"
    echo "Login Berhasil"
    exit 0
else
    log_auto "$LOGICAL" "LOGIN: Login GAGAL. Response: $RESPONSE" "ERROR"
    ERR_MSG=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
    if [ -z "$ERR_MSG" ]; then
        ERR_MSG="Server menolak login"
    fi
    printf '%s' "$ERR_MSG" > "$MSG_FILE"
    echo "$ERR_MSG"
    exit 1
fi