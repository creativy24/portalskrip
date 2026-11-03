#!/bin/sh
# Logout Executor: Universal
SCRIPT_NAME="logout_executor.sh"

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh
. /usr/lib/portal/conf/user_agent.conf

trap 'cleanup_temp_routing >/dev/null 2>&1' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if [ -z "$LOGICAL" ] || [ -z "$DEVICE" ] || [ -z "$PORTAL_TYPE" ]; then
    log_auto "${LOGICAL:-SYSTEM}" "LOGOUT: Parameter wajib kurang" "ERROR"
    echo "Parameter wajib kurang"
    exit 1
fi

SESSION_FILE="/etc/portal/portal_session_${LOGICAL}"
PROFILE="CHROME"
RESOLVED_IP=""

if [ -f "$SESSION_FILE" ]; then
    PROFILE=$(grep '^browser=' "$SESSION_FILE" | cut -d'=' -f2)
    RESOLVED_IP=$(grep '^resolved_ip=' "$SESSION_FILE" | cut -d'=' -f2)
    log_auto "$LOGICAL" "LOGOUT: State browser dibaca dari session: $PROFILE" "INFO"
else
    log_auto "$LOGICAL" "LOGOUT: Session file tidak ditemukan, menggunakan fallback CHROME" "WARN"
fi

load_browser_profile "$PROFILE" "LOGOUT"

[ -z "$IPC" ] && IPC=$(ip -4 addr show dev "$DEVICE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$IPC" ]; then
    log_auto "$LOGICAL" "LOGOUT: IP interface tidak ditemukan untuk device $DEVICE" "ERROR"
    echo "Gagal menentukan IP interface"
    exit 1
fi

LEX_GW=$(get_gateway "$DEVICE")
if [ -z "$LEX_GW" ]; then
    LEX_GW=$(ip route show default dev "$DEVICE" 2>/dev/null | awk '{print $3}' | head -1)
fi

if [ -z "$LEX_GW" ] || [ "$LEX_GW" = "$NULL_GATEWAY" ]; then
    log_auto "$LOGICAL" "LOGOUT: Gagal mendapatkan gateway secara otomatis untuk device $DEVICE" "ERROR"
    echo "Gagal menentukan gateway"
    exit 1
fi
log_auto "$LOGICAL" "LOGOUT: Gateway dinamis terdeteksi: $LEX_GW" "INFO"

if ! setup_temp_routing "$LOGICAL" "$IPC" "$LEX_GW" "$DEVICE"; then
    log_auto "$LOGICAL" "LOGOUT: Gagal menyiapkan routing sementara terisolasi" "ERROR"
    echo "Gagal menyiapkan routing sementara"
    exit 1
fi

LOGOUT_SUCCESS=0
RESPONSE_BODY="/tmp/${LOGICAL}_logout_response.html"
rm -f "$RESPONSE_BODY" >/dev/null 2>&1

if [ "$PORTAL_TYPE" = "wms" ] || [ "$PORTAL_TYPE" = "@wifi.id" ]; then
    TARGET_URLS="https://welcome2.wifi.id/authnew/logout/logoutx.php https://welcome2.wifi.id/logout"
    DOMAIN="welcome2.wifi.id"
    
    RESOLVE_OPT=""
    TARGET_IP=$(get_portal_ip "$DOMAIN")
    if [ -n "$TARGET_IP" ]; then
        RESOLVE_OPT="--resolve ${DOMAIN}:443:${TARGET_IP}"
        log_auto "$LOGICAL" "LOGOUT: DNS Bypass aktif untuk Logout: $RESOLVE_OPT" "INFO"
    fi

    for url in $TARGET_URLS; do
        log_auto "$LOGICAL" "LOGOUT: Mencoba POST logout ke $url" "INFO"
        
        HTTP_STATUS=$(curl -s -S --max-time 10 \
            --interface "$DEVICE" \
            $RESOLVE_OPT \
            -X POST \
            -H "Origin: https://logout.wifi.id" \
            -H "Referer: https://logout.wifi.id/" \
            -H "User-Agent: $UA" \
            -o "$RESPONSE_BODY" \
            -w "%{http_code}" \
            "$url" 2>/dev/null)

        if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ]; then
            if grep -qi "Logout Berhasil\|logout berhasil\|success" "$RESPONSE_BODY" 2>/dev/null || [ "$HTTP_STATUS" = "302" ]; then
                LOGOUT_SUCCESS=1
                log_auto "$LOGICAL" "LOGOUT: Logout $PORTAL_TYPE BERHASIL via $url" "OK"
                break
            fi
        fi
    done

elif [ "$PORTAL_TYPE" = "hotspot" ]; then
    DOMAIN=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $1}')
    SCHEME=$(echo "$PORTAL_URL" | awk -F'://' '{print $1}')
    [ -z "$SCHEME" ] && SCHEME="http"
    
    TARGET_URL="${SCHEME}://${DOMAIN}/logout?erase-cookie=on"
    
    RESOLVE_OPT=""
    if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "auto" ]; then
        PORT=$(echo "$PORTAL_URL" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}' | awk -F':' '{print $2}')
        [ -z "$PORT" ] && { [ "$SCHEME" = "https" ] && PORT="443" || PORT="80"; }
        RESOLVE_OPT="--resolve ${DOMAIN}:${PORT}:${RESOLVED_IP}"
        log_auto "$LOGICAL" "LOGOUT: DNS Bypass (Session) aktif untuk Logout: $RESOLVE_OPT" "INFO"
    fi

    log_auto "$LOGICAL" "LOGOUT: Mengirim GET logout ke $TARGET_URL" "INFO"
    
    HTTP_STATUS=$(curl -s -S --max-time 10 \
        --interface "$DEVICE" \
        $RESOLVE_OPT \
        -H "User-Agent: $UA" \
        -o "$RESPONSE_BODY" \
        -w "%{http_code}" \
        "$TARGET_URL" 2>/dev/null)

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ] || [ "$HTTP_STATUS" = "303" ]; then
        LOGOUT_SUCCESS=1
        log_auto "$LOGICAL" "LOGOUT: Logout Hotspot BERHASIL (HTTP Status: $HTTP_STATUS)" "OK"
    else
        log_auto "$LOGICAL" "LOGOUT: Logout Hotspot GAGAL (HTTP Status: $HTTP_STATUS)" "ERROR"
    fi
else
    log_auto "$LOGICAL" "LOGOUT: Tipe portal tidak dikenali untuk logout: $PORTAL_TYPE" "ERROR"
fi

log_auto "$LOGICAL" "LOGOUT: Membersihkan state lokal dan routing..." "INFO"
rm -f "$SESSION_FILE" >/dev/null 2>&1
rm -f "/tmp/${LOGICAL}_cookies.txt" >/dev/null 2>&1
rm -f "$RESPONSE_BODY" >/dev/null 2>&1
cleanup_temp_routing

if [ "$LOGOUT_SUCCESS" -eq 1 ]; then
    echo "Logout Berhasil"
    exit 0
else
    echo "Logout Gagal"
    exit 1
fi