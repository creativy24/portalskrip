#!/bin/sh
# Login Executor: WMS
SCRIPT_NAME="login_executor_wms.sh"

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh
. /usr/lib/portal/conf/user_agent.conf

trap 'cleanup_temp_routing >/dev/null 2>&1' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if [ -z "$LOGICAL" ] || [ -z "$DEVICE" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$PORTAL_URL" ]; then
    log_auto "${LOGICAL:-SYSTEM}" "LOGIN: Parameter wajib kurang" "ERROR"
    echo "Parameter wajib kurang"
    exit 1
fi

SESSION_FILE="/etc/portal/portal_session_${LOGICAL}"
if [ -f "$SESSION_FILE" ]; then
    PROFILE=$(grep '^browser=' "$SESSION_FILE" | cut -d'=' -f2)
    log_auto "$LOGICAL" "LOGIN: State browser dibaca dari session: $PROFILE" "INFO"
else
    PROFILE="CHROME"
    log_auto "$LOGICAL" "LOGIN: Session file tidak ditemukan, fallback ke CHROME" "WARN"
fi

load_browser_profile "$PROFILE" "WMS"

GW_ID=$(echo "$PORTAL_URL" | sed -n 's/.*gw_id=\([^&]*\).*/\1/p')
CLIENT_MAC=$(echo "$PORTAL_URL" | sed -n 's/.*client_mac=\([^&]*\).*/\1/p')
WLAN=$(echo "$PORTAL_URL" | sed -n 's/.*wlan=\([^&]*\).*/\1/p' | sed 's/%20/ /g')
IPC_VAL=$(echo "$PORTAL_URL" | sed -n 's/.*ipc=\([^&]*\).*/\1/p')
[ -z "$IPC_VAL" ] && IPC_VAL="$IPC"

[ -z "$IPC" ] && IPC=$(ip -4 addr show dev "$DEVICE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$IPC" ]; then
    log_auto "$LOGICAL" "LOGIN: IP interface tidak ditemukan untuk device $DEVICE" "ERROR"
    echo "Gagal menentukan IP interface"
    exit 1
fi

LEX_GW=$(get_gateway "$DEVICE")
if [ -z "$LEX_GW" ]; then 
    log_auto "$LOGICAL" "LOGIN: Gagal mendapatkan gateway via UCI/routing untuk $DEVICE, mencoba fallback default route" "WARN"
    LEX_GW=$(ip route show default dev "$DEVICE" 2>/dev/null | awk '{print $3}' | head -1)
fi

if [ -z "$LEX_GW" ] || [ "$LEX_GW" = "$NULL_GATEWAY" ]; then
    log_auto "$LOGICAL" "LOGIN: Tidak dapat menentukan gateway untuk $DEVICE. Membatalkan login." "ERROR"
    echo "Gagal menentukan gateway"
    exit 1
fi
log_auto "$LOGICAL" "LOGIN: Gateway yang digunakan: $LEX_GW" "INFO"

if ! setup_temp_routing "$LOGICAL" "$IPC" "$LEX_GW" "$DEVICE"; then
    log_auto "$LOGICAL" "LOGIN: Gagal menyiapkan routing sementara terisolasi" "ERROR"
    echo "Gagal menyiapkan routing sementara"
    exit 1
fi

DOMAIN=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}')

RESOLVE_OPT=""
RESOLVED_LOGIN_IP=$(get_portal_ip "$DOMAIN")
if [ -n "$RESOLVED_LOGIN_IP" ]; then
    PORT=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $2}')
    [ -z "$PORT" ] && PORT="443"
    RESOLVE_OPT="--resolve ${DOMAIN}:${PORT}:${RESOLVED_LOGIN_IP}"
    log_auto "$LOGICAL" "LOGIN: DNS Bypass aktif untuk Login: $RESOLVE_OPT" "INFO"
else
    log_auto "$LOGICAL" "LOGIN: IP untuk $DOMAIN tidak ditemukan di portal_domain_ip.conf, menggunakan DNS sistem (fallback)." "WARN"
fi

LOGIN_URL="https://${DOMAIN}/wms/auth/authnew/autologin/quarantine.php?ipc=${IPC_VAL}&gw_id=${GW_ID}&mac=${CLIENT_MAC}&redirect=&wlan=${WLAN}&landURL="

CURLRC="/tmp/${LOGICAL}_wms_curlrc"
HEADER_DUMP="/tmp/${LOGICAL}_wms_headers.txt"
HTML_FILE="/tmp/${LOGICAL}_wms_response.html"
ERROR_LOG="/tmp/${LOGICAL}_wms_error.log"

rm -f "$CURLRC" "$HEADER_DUMP" "$HTML_FILE" "$ERROR_LOG" >/dev/null 2>&1

ORDER_STR="$HEADER_ORDER"
if [ -z "$ORDER_STR" ]; then
    log_auto "$LOGICAL" "LOGIN: HEADER_ORDER untuk profil $PROFILE tidak ditemukan." "ERROR"
    cleanup_temp_routing
    exit 1
fi

OLD_IFS="$IFS"
IFS='|'
for hdr in $ORDER_STR; do
    val=$(get_header_value "$hdr")
    if [ -n "$val" ]; then
        escaped_val=$(printf '%s' "$val" | sed 's/"/\\"/g')
        printf 'header = "%s"\n' "$escaped_val" >> "$CURLRC"
    fi
done
IFS="$OLD_IFS"

printf 'header = "Content-Type: application/x-www-form-urlencoded; charset=UTF-8"\n' >> "$CURLRC"
printf 'header = "X-Requested-With: XMLHttpRequest"\n' >> "$CURLRC"
printf 'header = "Origin: https://%s"\n' "$DOMAIN" >> "$CURLRC"
printf 'header = "Referer: %s"\n' "$PORTAL_URL" >> "$CURLRC"

log_auto "$LOGICAL" "LOGIN: curlrc dibuat di $CURLRC" "DEBUG"

PAYLOAD="username_=${USERNAME}&username=${USERNAME}&password=${PASSWORD}"

log_auto "$LOGICAL" "LOGIN: Mengirim request login ke $LOGIN_URL" "INFO"

curl -s -S --max-time 15 \
    --interface "$DEVICE" \
    $RESOLVE_OPT \
    -K "$CURLRC" \
    -D "$HEADER_DUMP" \
    -o "$HTML_FILE" \
    -X POST \
    --data-raw "$PAYLOAD" \
    "$LOGIN_URL" 2>"$ERROR_LOG"

CURL_EXIT=$?

log_auto "$LOGICAL" "LOGIN: Membersihkan routing sementara terisolasi..." "INFO"
cleanup_temp_routing

if [ "$CURL_EXIT" -ne 0 ]; then
    log_auto "$LOGICAL" "LOGIN: Curl gagal dengan exit code: $CURL_EXIT" "ERROR"
    echo "Koneksi gagal"
    exit 1
fi

HTTP_STATUS=$(head -1 "$HEADER_DUMP" 2>/dev/null | awk '{print $2}')
log_auto "$LOGICAL" "LOGIN: HTTP Status: $HTTP_STATUS" "INFO"

MSG_FILE="/tmp/${LOGICAL}_last_login_message.txt"
LOGIN_SUCCESS=0
FINAL_MSG=""

if [ "$HTTP_STATUS" = "200" ]; then
    if grep -q '"result"[[:space:]]*:[[:space:]]*1' "$HTML_FILE" || grep -qi 'login anda berhasil' "$HTML_FILE"; then
        LOGIN_SUCCESS=1
        FINAL_MSG="Login Berhasil"
        log_auto "$LOGICAL" "LOGIN: Login BERHASIL (Respons sukses terdeteksi)" "OK"
    else
        ERR_MSG=$(grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' "$HTML_FILE" 2>/dev/null | head -1 | sed 's/"message"[[:space:]]*:[[:space:]]*"//; s/"$//')
        if [ -n "$ERR_MSG" ]; then
            FINAL_MSG="$ERR_MSG"
            log_auto "$LOGICAL" "LOGIN: Login GAGAL. Response: $ERR_MSG" "ERROR"
        else
            FINAL_MSG="Login Gagal (WMS)"
            log_auto "$LOGICAL" "LOGIN: Login GAGAL (Format respons tidak dikenali)" "ERROR"
        fi
    fi
else
    LOGIN_SUCCESS=0
    FINAL_MSG="Login Gagal (HTTP $HTTP_STATUS)"
    log_auto "$LOGICAL" "LOGIN: Login GAGAL (Status HTTP: $HTTP_STATUS)" "ERROR"
fi

printf '%s' "$FINAL_MSG" > "$MSG_FILE"

if [ "$LOGIN_SUCCESS" -eq 1 ]; then
    echo "Login Berhasil"
    exit 0
else
    echo "$FINAL_MSG"
    exit 1
fi