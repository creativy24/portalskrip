#!/bin/sh
# MAC SPOOF DETECTION LIBRARY
SCRIPT_NAME="mac_spoof.sh"

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh

MAC_CACHE_DIR="/etc/portal"
MAC_CACHE_FILE="mac_spoof.cache"
MAC_CACHE_PATH="${MAC_CACHE_DIR}/${MAC_CACHE_FILE}"
MAC_TEST_ADDR="02:11:22:33:44:55"

check_mac_spoof_support() {
    if [ -z "$SWITCH_TYPE" ]; then
        detect_version
        detect_switch_arch
    fi

    mkdir -p "$MAC_CACHE_DIR" >/dev/null 2>&1

    if [ -f "$MAC_CACHE_PATH" ] && [ -s "$MAC_CACHE_PATH" ]; then
        cat "$MAC_CACHE_PATH"
        return 0
    fi

    _now=$(date +%s)
    _rep_if=$(get_rep_if)

    if [ -z "$_rep_if" ]; then
        log_auto "SYSTEM" "MAC_SPOOF: Tidak ada interface yang tersedia untuk pengujian MAC spoof." "WARN"
        _res='{"supported":false,"level":"no_interface","checked_at":'$_now'}'
        echo "$_res" > "$MAC_CACHE_PATH"
        echo "$_res"
        return 0
    fi

    if is_bridge_member "$_rep_if"; then
        log_auto "SYSTEM" "MAC_SPOOF: Interface $_rep_if adalah anggota bridge. Pengujian MAC spoof dilewati." "INFO"
        _res='{"supported":false,"level":"bridge_skip","checked_at":'$_now'}'
        echo "$_res" > "$MAC_CACHE_PATH"
        echo "$_res"
        return 0
    fi

    _orig_mac=$(cat "/sys/class/net/$_rep_if/address" 2>/dev/null | tr 'a-f' 'A-F' | sed 's/[[:space:]]//g')

    case "$_orig_mac" in
        [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) ;;
        *)
            log_auto "SYSTEM" "MAC_SPOOF: Alamat MAC pada interface $_rep_if tidak valid: $_orig_mac" "ERROR"
            _res='{"supported":false,"level":"invalid_mac","checked_at":'$_now'}'
            echo "$_res" > "$MAC_CACHE_PATH"
            echo "$_res"
            return 0
        ;;
    esac

    _operstate=$(cat "/sys/class/net/$_rep_if/operstate" 2>/dev/null)
    _has_default=$(ip route show table all 2>/dev/null | grep -c "default.*dev $_rep_if" 2>/dev/null || echo 0)

    if [ "$_operstate" = "up" ] && [ "$_has_default" -gt 0 ]; then
        log_auto "SYSTEM" "MAC_SPOOF: Interface $_rep_if sedang aktif (operstate=$_operstate, default_route=$_has_default). Pengujian MAC spoof dilewati." "INFO"
        _res='{"supported":false,"level":"skipped_active","checked_at":'$_now'}'
        echo "$_res" > "$MAC_CACHE_PATH"
        echo "$_res"
        return 0
    fi

    _level="none"
    _result="false"

    ip link set dev "$_rep_if" down >/dev/null 2>&1

    if ip link set dev "$_rep_if" address "$MAC_TEST_ADDR" >/dev/null 2>&1; then
        _cur_mac=$(cat "/sys/class/net/$_rep_if/address" 2>/dev/null | tr 'a-f' 'A-F' | sed 's/[[:space:]]//g')
        case "$_cur_mac" in
            "$MAC_TEST_ADDR")
                _level="kernel"
                log_auto "SYSTEM" "MAC_SPOOF: MAC spoof didukung pada tingkat kernel." "OK"
                ;;
            *)
                _level="driver"
                log_auto "SYSTEM" "MAC_SPOOF: MAC spoof didukung pada tingkat driver." "OK"
                ;;
        esac
    else
        log_auto "SYSTEM" "MAC_SPOOF: MAC spoof tidak didukung pada interface $_rep_if." "FAIL"
    fi

    ip link set dev "$_rep_if" address "$_orig_mac" >/dev/null 2>&1

    if ip link show dev "$_rep_if" 2>/dev/null | grep -qi "link/ether $_orig_mac"; then
        case "$_level" in
            kernel|driver) _result="true" ;;
            *) _result="false" ;;
        esac
    else
        log_auto "SYSTEM" "MAC_SPOOF: Gagal mengembalikan MAC asli pada interface $_rep_if!" "ERROR"
        _level="rollback_fail"
        _result="false"
    fi

    ip link set dev "$_rep_if" up >/dev/null 2>&1

    _res='{"supported":'$_result',"level":"'$_level'","checked_at":'$_now'}'
    echo "$_res" > "$MAC_CACHE_PATH"
    echo "$_res"
    log_auto "SYSTEM" "MAC_SPOOF: Hasil pengujian MAC spoof: didukung=$_result, tingkat=$_level." "OK"

    return 0
}