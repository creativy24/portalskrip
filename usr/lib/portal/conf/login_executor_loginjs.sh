#!/bin/sh
# Login Executor: @wifi.id Next.js (loginjs)
SCRIPT_NAME="login_executor_loginjs.sh"

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh
. /usr/lib/portal/conf/user_agent.conf

trap 'cleanup_temp_routing >/dev/null 2>&1' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

CONTEXT_NAME="LOGINJS"
LOGIN_ENDPOINT_CONF="/usr/lib/portal/conf/login_endpoints.conf"

# Kontrak protokol check-login loginjs.
# Host login dan host referer/origin dibaca dari login_endpoints.conf.
# Path berikut terbukti dari baseline dan belum tersedia sebagai konfigurasi.
LOGIN_SCHEME="https"
LOGIN_PATH="/luwak_wifi/wpdefault/check-login"

_append_curl_header_line() {
    local line
    line=$(printf '%s' "$1" | tr -d '\r\n')
    [ -z "$line" ] && return 0

    local escaped
    escaped=$(printf '%s' "$line" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf 'header = "%s"\n' "$escaped" >> "$CURLRC"
}

_json_escape_fallback() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' | awk 'BEGIN { ORS="" } { if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

_build_json_payload_lua() {
    JSON_LUA_PORTAL_TYPE="$PORTAL_TYPE" \
    JSON_LUA_USERNAME="$USERNAME_SAFE" \
    JSON_LUA_PASSWORD="$PASSWORD_SAFE" \
    JSON_LUA_GW_ID="$GW_ID_SAFE" \
    JSON_LUA_IPC="$IPC_SAFE" \
    JSON_LUA_URL="$PORTAL_URL_SAFE" \
    JSON_LUA_USERAGENT="$UA_SAFE" \
    JSON_LUA_MAC="$CLIENT_MAC_SAFE" \
    JSON_LUA_APNAME="$APNAME_SAFE" \
    JSON_LUA_WLAN="$WLAN_SAFE" \
    lua -e '
local json
local ok, mod = pcall(require, "luci.jsonc")
if ok then
    json = mod
else
    ok, mod = pcall(require, "luci.json")
    if ok then
        json = mod
    else
        os.exit(1)
    end
end

local function g(k)
    local v = os.getenv(k)
    if v == nil then return "" end
    return v
end

local t = {
    username = g("JSON_LUA_USERNAME"),
    password = g("JSON_LUA_PASSWORD"),
    gw_id = g("JSON_LUA_GW_ID"),
    ipc = g("JSON_LUA_IPC"),
    url = g("JSON_LUA_URL"),
    useragent = g("JSON_LUA_USERAGENT"),
    ssid = g("JSON_LUA_PORTAL_TYPE"),
    mac = g("JSON_LUA_MAC"),
    apname = g("JSON_LUA_APNAME"),
    wlan = g("JSON_LUA_WLAN")
}

local ok2, s = pcall(json.stringify, t)
if not ok2 or s == nil then
    os.exit(1)
end

io.write(s)
'
}

_build_json_payload_fallback() {
    printf '{"username":"%s","password":"%s","gw_id":"%s","ipc":"%s","url":"%s","useragent":"%s","ssid":"%s","mac":"%s","apname":"%s","wlan":"%s"}' \
        "$(_json_escape_fallback "$USERNAME_SAFE")" \
        "$(_json_escape_fallback "$PASSWORD_SAFE")" \
        "$(_json_escape_fallback "$GW_ID_SAFE")" \
        "$(_json_escape_fallback "$IPC_SAFE")" \
        "$(_json_escape_fallback "$PORTAL_URL_SAFE")" \
        "$(_json_escape_fallback "$UA_SAFE")" \
        "$(_json_escape_fallback "$PORTAL_TYPE")" \
        "$(_json_escape_fallback "$CLIENT_MAC_SAFE")" \
        "$(_json_escape_fallback "$APNAME_SAFE")" \
        "$(_json_escape_fallback "$WLAN_SAFE")"
}

if [ -z "$LOGICAL" ] || [ -z "$DEVICE" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    log_auto "$LOGICAL" "LOGIN: Parameter wajib kurang" "ERROR"
    echo "Parameter wajib kurang"
    exit 1
fi

case "$LOGICAL" in
    *[!A-Za-z0-9_.-]*)
        log_auto "$LOGICAL" "LOGIN: Logical name tidak valid" "ERROR"
        echo "Logical name tidak valid"
        exit 1
        ;;
esac

case "$DEVICE" in
    *[!A-Za-z0-9_.-]*)
        log_auto "$LOGICAL" "LOGIN: Device name tidak valid" "ERROR"
        echo "Device name tidak valid"
        exit 1
        ;;
esac

if [ -z "$PORTAL_TYPE" ] || [ -z "$PATH_URL" ]; then
    log_auto "$LOGICAL" "LOGIN: Kontrak portal tidak lengkap (PORTAL_TYPE/PATH_URL kosong)" "ERROR"
    echo "Kontrak portal tidak lengkap"
    exit 1
fi

CONTRACT_CHECK=$(portal_contract_lookup_identity "$PORTAL_TYPE" "$PATH_URL" 2>/dev/null)
if [ -z "$CONTRACT_CHECK" ]; then
    log_auto "$LOGICAL" "LOGIN: Kontrak portal tidak valid atau tidak terdaftar (portal_type=$PORTAL_TYPE, path_url=$PATH_URL)" "ERROR"
    echo "Kontrak portal tidak valid"
    exit 1
fi

if [ ! -f "$LOGIN_ENDPOINT_CONF" ]; then
    log_auto "$LOGICAL" "LOGIN: login_endpoints.conf tidak ditemukan: $LOGIN_ENDPOINT_CONF" "ERROR"
    echo "Konfigurasi login endpoint tidak ditemukan"
    exit 1
fi

LOGIN_HOST=$(awk -F'|' -v pt="$PORTAL_TYPE" '$1 == pt {print $2; exit}' "$LOGIN_ENDPOINT_CONF")
REFERER_HOST=$(awk -F'|' -v pt="$PORTAL_TYPE" '$1 == pt {print $3; exit}' "$LOGIN_ENDPOINT_CONF")

if [ -z "$LOGIN_HOST" ] || [ -z "$REFERER_HOST" ]; then
    log_auto "$LOGICAL" "LOGIN: Endpoint login/referer tidak ditemukan untuk portal_type=$PORTAL_TYPE di $LOGIN_ENDPOINT_CONF" "ERROR"
    echo "Endpoint login tidak dikonfigurasi"
    exit 1
fi

case "$LOGIN_HOST" in
    ''|*[!A-Za-z0-9._-]*)
        log_auto "$LOGICAL" "LOGIN: Login host tidak valid: $LOGIN_HOST" "ERROR"
        echo "Login host tidak valid"
        exit 1
        ;;
esac

case "$REFERER_HOST" in
    ''|*[!A-Za-z0-9._-]*)
        log_auto "$LOGICAL" "LOGIN: Referer host tidak valid: $REFERER_HOST" "ERROR"
        echo "Referer host tidak valid"
        exit 1
        ;;
esac

COOKIE_JAR="/tmp/${LOGICAL}_cookies.txt"
if [ ! -s "$COOKIE_JAR" ]; then
    log_auto "$LOGICAL" "LOGIN: Cookie jar tidak ditemukan. Lakukan pra-login (scan) terlebih dahulu." "ERROR"
    echo "Cookie jar tidak ditemukan. Lakukan pra-login terlebih dahulu."
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

if [ -z "$PROFILE" ]; then
    PROFILE="CHROME"
    log_auto "$LOGICAL" "LOGIN: Browser session kosong, fallback ke CHROME" "WARN"
fi

load_browser_profile "$PROFILE" "$CONTEXT_NAME" || {
    log_auto "$LOGICAL" "LOGIN: Gagal memuat profil browser: $PROFILE konteks $CONTEXT_NAME" "ERROR"
    echo "Gagal memuat profil browser"
    exit 1
}

USERNAME_SAFE=$(printf '%s' "$USERNAME" | tr -d '\r\n')
PASSWORD_SAFE=$(printf '%s' "$PASSWORD" | tr -d '\r\n')
PORTAL_URL_SAFE=$(printf '%s' "$PORTAL_URL" | tr -d '\r\n')
GW_ID_SAFE=$(printf '%s' "$GW_ID" | tr -d '\r\n')
CLIENT_MAC_SAFE=$(printf '%s' "$CLIENT_MAC" | tr -d '\r\n')
WLAN_SAFE=$(printf '%s' "$WLAN" | tr -d '\r\n')

[ -z "$IPC" ] && IPC=$(ip -4 addr show dev "$DEVICE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$IPC" ]; then
    log_auto "$LOGICAL" "LOGIN: IP interface tidak ditemukan untuk device $DEVICE" "ERROR"
    echo "Gagal menentukan IP interface"
    exit 1
fi
IPC_SAFE=$(printf '%s' "$IPC" | tr -d '\r\n')

LEX_GW=$(get_gateway "$DEVICE")
if [ -z "$LEX_GW" ]; then
    log_auto "$LOGICAL" "LOGIN: Gagal mendapatkan gateway via UCI/routing untuk $DEVICE, mencoba fallback default route" "WARN"
    LEX_GW=$(ip route show default dev "$DEVICE" 2>/dev/null | awk '{print $3}' | head -1)
fi

LEX_GW=$(printf '%s' "$LEX_GW" | awk '{print $1}')

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

APNAME=$(printf '%s' "$WLAN_SAFE" | cut -d':' -f1)
if [ -z "$APNAME" ]; then APNAME="UNKNOWN"; fi
APNAME_SAFE=$(printf '%s' "$APNAME" | tr -d '\r\n')
UA_SAFE=$(printf '%s' "$UA" | tr -d '\r\n')

# CATATAN PENTING: AUTH_TIME TIDAK DIUBAH FORMATNYA AGAR KOMPATIBEL DENGAN SERVER @WIFI.ID
AUTH_TIME=$(date '+%Y-%m-%d %H:%M:%S')
AUTH_TOKEN=$(printf '%s' "${USERNAME_SAFE}${AUTH_TIME}" | md5sum | cut -d' ' -f1)

JSON_PAYLOAD=$(_build_json_payload_lua 2>/dev/null)
JSON_RC=$?
if [ "$JSON_RC" -ne 0 ] || [ -z "$JSON_PAYLOAD" ]; then
    log_auto "$LOGICAL" "LOGIN: Builder JSON Lua gagal (rc=$JSON_RC), memakai fallback escaping" "WARN"
    JSON_PAYLOAD=$(_build_json_payload_fallback)
fi

if [ -z "$JSON_PAYLOAD" ]; then
    log_auto "$LOGICAL" "LOGIN: Gagal membangun JSON payload" "ERROR"
    echo "Gagal membangun payload login"
    cleanup_temp_routing
    exit 1
fi

log_auto "$LOGICAL" "LOGIN: JSON payload dibangun (length=${#JSON_PAYLOAD})" "DEBUG"

LOGIN_URL="${LOGIN_SCHEME}://${LOGIN_HOST}${LOGIN_PATH}"

RESOLVE_OPT=""
RESOLVED_LOGIN_IP=$(get_portal_ip "$LOGIN_HOST" 2>/dev/null | awk '{print $1}')

if [ -n "$RESOLVED_LOGIN_IP" ]; then
    case "$RESOLVED_LOGIN_IP" in
        *[!0-9.]*)
            RESOLVED_LOGIN_IP=""
            ;;
    esac
fi

if [ -n "$RESOLVED_LOGIN_IP" ]; then
    RESOLVE_OPT="--resolve ${LOGIN_HOST}:443:${RESOLVED_LOGIN_IP}"
    log_auto "$LOGICAL" "LOGIN: DNS Bypass aktif untuk Login: $RESOLVE_OPT" "INFO"
else
    log_auto "$LOGICAL" "LOGIN: IP untuk $LOGIN_HOST tidak ditemukan di portal_domain_ip.conf, menggunakan DNS sistem." "WARN"
fi

log_auto "$LOGICAL" "LOGIN: Mengirim request login ke $LOGIN_URL" "INFO"

CURLRC="/tmp/${LOGICAL}_login_curlrc"
rm -f "$CURLRC" >/dev/null 2>&1

ORDER_STR="$HEADER_ORDER"
if [ -z "$ORDER_STR" ]; then
    log_auto "$LOGICAL" "LOGIN: HEADER_ORDER untuk profil $PROFILE konteks $CONTEXT_NAME tidak ditemukan." "ERROR"
    echo "Header order tidak tersedia"
    cleanup_temp_routing
    exit 1
fi

OLD_IFS="$IFS"
IFS='|'
for hdr in $ORDER_STR; do
    case "$hdr" in
        Host)
            _append_curl_header_line "Host: ${LOGIN_HOST}"
            continue
            ;;
        Referer)
            _append_curl_header_line "Referer: https://${REFERER_HOST}/"
            continue
            ;;
        Origin|Content-Type|X-Authorization-Time|X-Authorization-Token|Accept-Encoding)
            continue
            ;;
    esac

    val=$(get_header_value "$hdr")
    if [ -n "$val" ]; then
        _append_curl_header_line "$val"
    fi
done
IFS="$OLD_IFS"

_append_curl_header_line "Content-Type: application/json"
_append_curl_header_line "Origin: https://${REFERER_HOST}"
_append_curl_header_line "X-Authorization-Time: ${AUTH_TIME}"
_append_curl_header_line "X-Authorization-Token: ${AUTH_TOKEN}"

CURL_MAX_TIME="${LOGIN_TIMEOUT:-15}"
case "$CURL_MAX_TIME" in
    ''|*[!0-9]*)
        CURL_MAX_TIME=15
        ;;
esac
[ "$CURL_MAX_TIME" -eq 0 ] && CURL_MAX_TIME=15

RESPONSE=$(curl -s -S --max-time "$CURL_MAX_TIME" \
    --interface "$DEVICE" \
    $RESOLVE_OPT \
    -K "$CURLRC" \
    -b "$COOKIE_JAR" \
    -c "$COOKIE_JAR" \
    -X POST \
    --data-raw "$JSON_PAYLOAD" \
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

if printf '%s' "$RESPONSE" | grep -Eq '"status_code"[[:space:]]*:[[:space:]]*"0"|"status"[[:space:]]*:[[:space:]]*true|Sukses Login'; then
    log_auto "$LOGICAL" "LOGIN: Login BERHASIL" "OK"
    printf '%s' "Login Berhasil" > "$MSG_FILE"
    echo "Login Berhasil"
    exit 0
else
    log_auto "$LOGICAL" "LOGIN: Login GAGAL. Response: $RESPONSE" "ERROR"
    ERR_MSG=$(printf '%s' "$RESPONSE" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"message"[[:space:]]*:[[:space:]]*"//; s/"$//')
    if [ -z "$ERR_MSG" ]; then
        ERR_MSG="Server menolak login (@wifi.id)"
    fi
    printf '%s' "$ERR_MSG" > "$MSG_FILE"
    echo "$ERR_MSG"
    exit 1
fi