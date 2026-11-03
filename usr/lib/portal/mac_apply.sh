#!/bin/sh
# MAC PERSISTENCE HELPER
SCRIPT_NAME="mac_apply.sh"

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh

ACTION="$1"; UCI_SECTION="$2"; DEVICE="$3"; MAC="$4"; VENDOR="$5"
LOCK="/var/run/autologin_mac.lock"

[ -z "$UCI_SECTION" ] && { echo '{"status":"error","message":"UCI section tidak diberikan"}'; exit 1; }
[ -z "$DEVICE" ] && { echo '{"status":"error","message":"Device tidak diberikan"}'; exit 1; }

[ -e "$LOCK" ] && { echo '{"status":"busy","message":"Operation in progress"}'; exit 1; }
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" >/dev/null 2>&1' EXIT INT TERM HUP

sanitize_mac() { echo "$1" | tr 'a-f' 'A-F' | sed 's/[^0-9A-F:]//g'; }

validate_mac() {
    echo "$1" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'
}

log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Target UCI: $UCI_SECTION | Aksi: $ACTION | MAC: $MAC | Vendor: ${VENDOR:-tidak ada}" "INFO"

if [ "$ACTION" = "apply" ]; then
    MAC=$(sanitize_mac "$MAC")
    if [ -z "$MAC" ] || ! validate_mac "$MAC"; then
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Format MAC tidak valid: $MAC" "ERROR"
        echo '{"status":"error","message":"Format MAC tidak valid"}'
        exit 1
    fi

    EXISTING_ORIGINAL=$(uci -q get "$UCI_SECTION.original_macaddr" 2>/dev/null)
    if [ -z "$EXISTING_ORIGINAL" ]; then
        CURRENT_MAC=$(cat "/sys/class/net/$DEVICE/address" 2>/dev/null | tr 'a-z' 'A-Z' | sed 's/[[:space:]]//g')
        if [ -n "$CURRENT_MAC" ]; then
            uci set "$UCI_SECTION.original_macaddr"="$CURRENT_MAC" 2>/dev/null
            uci commit "${UCI_SECTION%%.*}" 2>/dev/null
            log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: MAC asli disimpan: $CURRENT_MAC" "OK"
        fi
    else
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: MAC asli sudah tersimpan sebelumnya: $EXISTING_ORIGINAL" "INFO"
    fi

    log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Menerapkan MAC address baru ke $UCI_SECTION..." "INFO"
    uci set "$UCI_SECTION.macaddr"="$MAC" 2>/dev/null
    if [ -n "$VENDOR" ]; then
        uci set "$UCI_SECTION.mac_vendor"="$VENDOR" 2>/dev/null
    fi
    uci commit "${UCI_SECTION%%.*}" 2>/dev/null

    ip link set dev "$DEVICE" down >/dev/null 2>&1
    ma_wait=0
    while [ $ma_wait -lt 10 ]; do
        ma_state=$(cat /sys/class/net/$DEVICE/operstate 2>/dev/null)
        [ "$ma_state" = "down" ] && break
        sleep 1
        ma_wait=$((ma_wait + 1))
    done
    log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Interface $DEVICE down setelah ${ma_wait} detik" "DEBUG"

    ip link set dev "$DEVICE" address "$MAC" >/dev/null 2>&1
    RC=$?
    ip link set dev "$DEVICE" up >/dev/null 2>&1

    reload_service "$UCI_SECTION"

    if [ $RC -eq 0 ]; then
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: MAC address berhasil diterapkan: $MAC" "OK"
        echo "{\"status\":\"success\",\"message\":\"MAC tersimpan ke $UCI_SECTION\",\"mac\":\"$MAC\"}"
    else
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Gagal menerapkan MAC address ke interface $DEVICE." "ERROR"
        echo '{"status":"error","message":"Gagal menerapkan MAC ke interface"}'
    fi

elif [ "$ACTION" = "revert" ]; then
    ORIGINAL_MAC=$(uci -q get "$UCI_SECTION.original_macaddr" 2>/dev/null)
    if [ -n "$ORIGINAL_MAC" ]; then
        MAC="$ORIGINAL_MAC"
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Menggunakan MAC asli dari UCI: $MAC" "INFO"
    else
        MAC=$(sanitize_mac "$MAC")
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: MAC asli dari parameter: $MAC" "INFO"
    fi

    log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Mengembalikan MAC address asli ke $UCI_SECTION..." "INFO"
    uci delete "$UCI_SECTION.macaddr" 2>/dev/null
    uci delete "$UCI_SECTION.mac_vendor" 2>/dev/null
    uci delete "$UCI_SECTION.original_macaddr" 2>/dev/null
    uci commit "${UCI_SECTION%%.*}" 2>/dev/null

    ip link set dev "$DEVICE" down >/dev/null 2>&1
    ma_wait=0
    while [ $ma_wait -lt 10 ]; do
        ma_state=$(cat /sys/class/net/$DEVICE/operstate 2>/dev/null)
        [ "$ma_state" = "down" ] && break
        sleep 1
        ma_wait=$((ma_wait + 1))
    done
    log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Interface $DEVICE down setelah ${ma_wait} detik" "DEBUG"

    ip link set dev "$DEVICE" address "$MAC" >/dev/null 2>&1
    RC=$?
    ip link set dev "$DEVICE" up >/dev/null 2>&1

    reload_service "$UCI_SECTION"

    if [ $RC -eq 0 ]; then
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: MAC address berhasil dikembalikan ke asli: $MAC" "OK"
        echo "{\"status\":\"success\",\"message\":\"MAC dikembalikan di $UCI_SECTION\",\"mac\":\"$MAC\"}"
    else
        log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Gagal mengembalikan MAC address ke interface $DEVICE." "ERROR"
        echo '{"status":"error","message":"Gagal mengembalikan MAC ke interface"}'
    fi
else
    log_auto "${DEVICE:-SYSTEM}" "MAC_APPLY: Aksi tidak valid: $ACTION" "ERROR"
    echo '{"status":"error","message":"Aksi tidak valid"}'
    exit 1
fi