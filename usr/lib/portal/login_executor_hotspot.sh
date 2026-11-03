#!/bin/sh
# Login Executor: Hotspot MikroTik
SCRIPT_NAME="login_executor_hotspot.sh"

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

DOMAIN=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $1}')
SCHEME=$(echo "$PORTAL_URL" | awk -F'://' '{print $1}')
export DOMAIN
export REFERER_URL="$PORTAL_URL"

SESSION_FILE="/etc/portal/portal_session_${LOGICAL}"
RESOLVE_OPT=""
if [ -f "$SESSION_FILE" ]; then
    PROFILE=$(grep '^browser=' "$SESSION_FILE" | cut -d'=' -f2)
    log_auto "$LOGICAL" "LOGIN: State browser dibaca dari session: $PROFILE" "INFO"
    RESOLVED_IP=$(grep '^resolved_ip=' "$SESSION_FILE" | cut -d'=' -f2)
    if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "auto" ]; then
        PORT=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $2}')
        [ -z "$PORT" ] && {
            case "$SCHEME" in
                https) PORT="443" ;;
                *) PORT="80" ;;
            esac
        }
        RESOLVE_OPT="--resolve ${DOMAIN}:${PORT}:${RESOLVED_IP}"
        log_auto "$LOGICAL" "LOGIN: DNS Bypass aktif dari session (Hotspot): $RESOLVE_OPT" "INFO"
    else
        log_auto "$LOGICAL" "LOGIN: resolved_ip tidak valid di session, menggunakan DNS sistem (fallback)." "INFO"
    fi
else
    PROFILE="CHROME"
    log_auto "$LOGICAL" "LOGIN: Session file tidak ditemukan, fallback ke CHROME" "WARN"
fi

load_browser_profile "$PROFILE" "HOTSPOT"

BASE_URL=$(echo "$PORTAL_URL" | cut -d'?' -f1)
DST=$(echo "$PORTAL_URL" | sed -n 's/.*[?&]dst=\([^&]*\).*/\1/p')
[ -z "$DST" ] && DST="/"

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

if ! setup_temp_routing "$LOGICAL" "$IPC" "$LEX_GW" "$DEVICE"; then
    log_auto "$LOGICAL" "LOGIN: Gagal menyiapkan routing sementara terisolasi" "ERROR"
    echo "Gagal menyiapkan routing sementara"
    exit 1
fi

CURLRC="/tmp/${LOGICAL}_hotspot_curlrc"
HEADER_DUMP="/tmp/${LOGICAL}_hotspot_headers.txt"
HTML_FILE="/tmp/${LOGICAL}_response.html"
ERROR_LOG="/tmp/${LOGICAL}_hotspot_error.log"

rm -f "$CURLRC" "$HEADER_DUMP" "$ERROR_LOG" >/dev/null 2>&1

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

printf 'header = "Content-Type: application/x-www-form-urlencoded"\n' >> "$CURLRC"
printf 'header = "Origin: %s://%s"\n' "$SCHEME" "$DOMAIN" >> "$CURLRC"
printf 'header = "Referer: %s"\n' "$PORTAL_URL" >> "$CURLRC"

log_auto "$LOGICAL" "LOGIN: curlrc dibuat di $CURLRC" "DEBUG"

USERNAME_SAFE=$(printf '%s' "$USERNAME" | tr -d '\r\n')
PASSWORD_SAFE=$(printf '%s' "$PASSWORD" | tr -d '\r\n')

CHAP_ID=$(grep -o 'name="chap-id"[^>]*value="[^"]*"' "$HTML_FILE" 2>/dev/null | sed 's/.*value="\([^"]*\)".*/\1/' | head -1)
CHAP_CHALLENGE=$(grep -o 'name="chap-challenge"[^>]*value="[^"]*"' "$HTML_FILE" 2>/dev/null | sed 's/.*value="\([^"]*\)".*/\1/' | head -1)

LOGIN_PASSWORD="$PASSWORD_SAFE"
LOGIN_MODE="PAP"

if [ -n "$CHAP_ID" ] && [ -n "$CHAP_CHALLENGE" ]; then
    CHAP_STRING="${CHAP_ID}${PASSWORD_SAFE}${CHAP_CHALLENGE}"
    HASHED_PASSWORD=$(printf '%s' "$CHAP_STRING" | md5sum | awk '{print $1}')

    if [ -n "$HASHED_PASSWORD" ]; then
        LOGIN_PASSWORD="$HASHED_PASSWORD"
        LOGIN_MODE="CHAP"
        log_auto "$LOGICAL" "LOGIN: Mode CHAP terdeteksi. Menggunakan password ter-hash." "INFO"
    else
        log_auto "$LOGICAL" "LOGIN: Hash CHAP gagal, fallback PAP." "WARN"
    fi
else
    log_auto "$LOGICAL" "LOGIN: Mode PAP terdeteksi. Menggunakan plain text password." "INFO"
fi

log_auto "$LOGICAL" "LOGIN: Mengirim request login ke $BASE_URL (mode=$LOGIN_MODE)" "INFO"

curl -s -S --max-time 15 \
    --interface "$DEVICE" \
    $RESOLVE_OPT \
    -K "$CURLRC" \
    -D "$HEADER_DUMP" \
    -o "/tmp/${LOGICAL}_hotspot_response.html" \
    -X POST \
    --data-urlencode "username=${USERNAME_SAFE}" \
    --data-urlencode "password=${LOGIN_PASSWORD}" \
    -d "dst=${DST}" \
    -d "popup=true" \
    "$BASE_URL" 2>"$ERROR_LOG"

CURL_EXIT=$?

log_auto "$LOGICAL" "LOGIN: Membersihkan routing sementara terisolasi..." "INFO"
cleanup_temp_routing

if [ "$CURL_EXIT" -ne 0 ]; then
    log_auto "$LOGICAL" "LOGIN: Curl gagal dengan exit code: $CURL_EXIT" "ERROR"
    echo "Koneksi gagal"
    exit 1
fi

HTTP_STATUS=$(head -1 "$HEADER_DUMP" 2>/dev/null | awk '{print $2}')
RESPONSE_HTML="/tmp/${LOGICAL}_hotspot_response.html"
log_auto "$LOGICAL" "LOGIN: HTTP Status: $HTTP_STATUS" "INFO"

LOGIN_SUCCESS=0
if [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ] || [ "$HTTP_STATUS" = "303" ] || [ "$HTTP_STATUS" = "307" ]; then
    LOGIN_SUCCESS=1
    log_auto "$LOGICAL" "LOGIN: Login BERHASIL (Redirect ke destination)" "OK"
elif [ "$HTTP_STATUS" = "200" ]; then
    if grep -qi "error=" "$RESPONSE_HTML" || \
       grep -qi "invalid username" "$RESPONSE_HTML" || \
       grep -qi "invalid password" "$RESPONSE_HTML" || \
       grep -qi "nama pengguna atau kata sandi salah" "$RESPONSE_HTML" || \
       grep -qi "kode voucher salah" "$RESPONSE_HTML"; then
        LOGIN_SUCCESS=0
        log_auto "$LOGICAL" "LOGIN: Login GAGAL (Halaman error terdeteksi)" "ERROR"
    else
        LOGIN_SUCCESS=1
        log_auto "$LOGICAL" "LOGIN: Login BERHASIL (Status 200 tanpa indikator error)" "OK"
    fi
else
    LOGIN_SUCCESS=0
    log_auto "$LOGICAL" "LOGIN: Login GAGAL (Status HTTP tidak dikenali)" "ERROR"
fi

MSG_FILE="/tmp/${LOGICAL}_last_login_message.txt"

if [ "$LOGIN_SUCCESS" -eq 1 ]; then
    printf '%s' "Login Berhasil" > "$MSG_FILE"
    echo "Login Berhasil"
    exit 0
else
    ERR_MSG=$(grep -oi 'var error = "[^"]*"' "$RESPONSE_HTML" 2>/dev/null | head -1 | sed 's/var error = "//i; s/"$//')
    if [ -z "$ERR_MSG" ]; then
        if grep -qi "invalid username\|nama pengguna.*salah" "$RESPONSE_HTML"; then
            ERR_MSG="Username salah"
        elif grep -qi "invalid password\|kata sandi.*salah" "$RESPONSE_HTML"; then
            ERR_MSG="Password salah"
        elif grep -qi "kode voucher salah" "$RESPONSE_HTML"; then
            ERR_MSG="Voucher invalid/expired"
        else
            ERR_MSG="Login Gagal (Hotspot)"
        fi
    fi
    printf '%s' "$ERR_MSG" > "$MSG_FILE"
    echo "$ERR_MSG"
    exit 1
fi