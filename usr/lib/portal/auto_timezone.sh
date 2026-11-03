#!/bin/sh
# Auto TimeZone - Sinkronisasi zona waktu otomatis

SCRIPT_NAME="auto_timezone.sh"
. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh

TZ_CONF="/usr/lib/portal/conf/timezone.conf"
TZ_CACHE="/etc/portal/tz.cache"
LOCK="/tmp/portal_tz.lock"
TIMEOUT=5

if [ -f "$TZ_CONF" ]; then
    . "$TZ_CONF"
fi

get_posix_tz() {
    local gtz_iana_tz="$1"
    local gtz_tz_data=""
    local gtz_tz_name=""
    local gtz_tz_offset=""

    gtz_tz_data=$(TZ="$gtz_iana_tz" date +"%Z %z" 2>/dev/null)

    if [ -n "$gtz_tz_data" ]; then
        gtz_tz_name="${gtz_tz_data%% *}"
        gtz_tz_offset="${gtz_tz_data##* }"

        if [ "$gtz_tz_name" = "UTC" ] || [ "$gtz_tz_name" = "GMT" ]; then
            case "$gtz_iana_tz" in
                UTC|Etc/UTC|GMT)
                    echo "UTC0"
                    return 0
                    ;;
                *)
                    log_auto "SYSTEM" "GET_POSIX_TZ: Paket zoneinfo belum terpasang untuk $gtz_iana_tz" "ERROR"
                    return 1
                    ;;
            esac
        fi

        local gtz_sign="${gtz_tz_offset%"${gtz_tz_offset#?}"}"
        local gtz_hours="${gtz_tz_offset#?}"
        gtz_hours="${gtz_hours%"${gtz_hours#??}"}"

        local gtz_hours_num="${gtz_hours#"${gtz_hours%%[!0]*}"}"
        [ -z "$gtz_hours_num" ] && gtz_hours_num=0

        local gtz_posix_sign=""
        if [ "$gtz_sign" = "+" ]; then
            gtz_posix_sign="-"
        else
            gtz_posix_sign="+"
        fi

        echo "${gtz_tz_name}${gtz_posix_sign}${gtz_hours_num}"
        return 0
    fi

    return 1
}

[ -e "$LOCK" ] && exit 0
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" >/dev/null 2>&1' EXIT

mkdir -p /etc/portal 2>/dev/null

CURRENT_TZ=$(uci -q get system.@system[0].zonename 2>/dev/null)

CACHE_TZ=""
if [ -f "$TZ_CACHE" ]; then
    CACHE_TZ=$(tail -1 "$TZ_CACHE" 2>/dev/null)
fi

if [ -n "$CURRENT_TZ" ] && [ "$CURRENT_TZ" != "UTC" ] && [ "$CURRENT_TZ" != "Etc/UTC" ] && [ "$CURRENT_TZ" = "$CACHE_TZ" ]; then
    log_auto "SYSTEM" "CHECK_TZ: Zona waktu sudah benar: $CURRENT_TZ" "SKIP"
    exit 0
fi

IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')

if [ -z "$IFACE" ] && [ -s "/tmp/portal_records" ]; then
    IFACE=$(head -1 /tmp/portal_records 2>/dev/null | awk -F'\t' '{print $2}')
fi

if [ -z "$IFACE" ]; then
    log_auto "SYSTEM" "CHECK_IFACE: Tidak ada interface jaringan yang tersedia" "ERROR"
    exit 1
fi

log_auto "SYSTEM" "API_CALL: Menggunakan interface: $IFACE untuk mengakses API timezone" "INFO"

RESP=$(curl --interface "$IFACE" -s -m $TIMEOUT "$TZ_API" 2>/dev/null)

if [ -z "$RESP" ]; then
    log_auto "SYSTEM" "API_CALL: Gagal menghubungi API timezone" "ERROR"
    exit 1
fi

log_auto "SYSTEM" "API_RESPONSE: Respons API: $RESP" "DEBUG"

if [ "$HAS_JSONFILTER" -eq 1 ]; then
    STATUS=$(echo "$RESP" | jsonfilter -e '@.status' 2>/dev/null)
    if [ "$STATUS" = "success" ]; then
        NEW_TZ=$(echo "$RESP" | jsonfilter -e '@.timezone' 2>/dev/null)
    fi
    log_auto "SYSTEM" "JSON_PARSE: Parsing dengan jsonfilter: status=$STATUS, tz=$NEW_TZ" "DEBUG"
elif command -v jshn >/dev/null 2>&1; then
    . /usr/share/libubox/jshn.sh 2>/dev/null
    json_load "$RESP" 2>/dev/null
    json_get_var STATUS status 2>/dev/null
    if [ "$STATUS" = "success" ]; then
        json_get_var NEW_TZ timezone 2>/dev/null
    fi
    log_auto "SYSTEM" "JSON_PARSE: Parsing dengan jshn: status=$STATUS, tz=$NEW_TZ" "DEBUG"
else
    STATUS=$(echo "$RESP" | grep -o '"status":"[^"]*"' 2>/dev/null | head -1 | sed 's/"status":"//;s/"//')
    if [ "$STATUS" = "success" ]; then
        NEW_TZ=$(echo "$RESP" | grep -o '"timezone":"[^"]*"' 2>/dev/null | head -1 | sed 's/"timezone":"//;s/"//')
    fi
    log_auto "SYSTEM" "JSON_PARSE: Parsing dengan grep/sed: status=$STATUS, tz=$NEW_TZ" "DEBUG"
fi

if [ -z "$NEW_TZ" ] || ! printf '%s' "$NEW_TZ" | grep -qE '^[A-Za-z0-9/_+-]+$'; then
    log_auto "SYSTEM" "JSON_PARSE: Respons API tidak valid: status=$STATUS tz=$NEW_TZ" "ERROR"
    exit 1
fi

if [ "$CURRENT_TZ" != "$NEW_TZ" ]; then
    uci set system.@system[0].zonename="$NEW_TZ"

    POSIX_TZ=$(get_posix_tz "$NEW_TZ")
    if [ -n "$POSIX_TZ" ]; then
        uci set system.@system[0].timezone="$POSIX_TZ"
        log_auto "SYSTEM" "UCI_SET: POSIX timezone diset: $POSIX_TZ" "OK"
    else
        uci delete system.@system[0].timezone 2>/dev/null
        log_auto "SYSTEM" "UCI_SET: POSIX timezone dihapus (tidak tersedia)" "INFO"
    fi

    uci commit system

    if [ -x /etc/init.d/sysntpd ]; then
        /etc/init.d/sysntpd restart >/dev/null 2>&1
        log_auto "SYSTEM" "SERVICE_RESTART: sysntpd direstart" "OK"
    elif [ -x /etc/init.d/ntpd ]; then
        /etc/init.d/ntpd restart >/dev/null 2>&1
        log_auto "SYSTEM" "SERVICE_RESTART: ntpd direstart" "OK"
    elif [ -x /etc/init.d/chronyd ]; then
        /etc/init.d/chronyd restart >/dev/null 2>&1
        log_auto "SYSTEM" "SERVICE_RESTART: chronyd direstart" "OK"
    else
        log_auto "SYSTEM" "SERVICE_RESTART: Tidak ada time service (sysntpd/ntpd/chronyd) ditemukan" "ERROR"
    fi

    log_auto "SYSTEM" "TZ_UPDATE: Zona waktu diperbarui: $CURRENT_TZ menjadi $NEW_TZ" "OK"
else
    log_auto "SYSTEM" "TZ_UPDATE: Zona waktu sudah sesuai: $CURRENT_TZ" "SKIP"
fi

echo "$NEW_TZ" > "$TZ_CACHE"
log_auto "SYSTEM" "CACHE_SAVE: Cache disimpan: $NEW_TZ" "OK"

exit 0