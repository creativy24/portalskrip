#!/bin/sh
# Library: Jaringan & Utilitas

. /usr/lib/portal/logging.sh
ENDPOINTS_CONF="/usr/lib/portal/conf/endpoints.conf"
PORTAL_TYPES_CONF="/usr/lib/portal/conf/portal_types.conf"

load_config() {
    lc_config_file="/usr/lib/portal/conf/network.conf"
    if [ -f "$lc_config_file" ] && [ -s "$lc_config_file" ]; then
        . "$lc_config_file"
        log_auto "SYSTEM" "Konfigurasi jaringan dari $lc_config_file dimuat"
    else
        log_auto "SYSTEM" "File konfigurasi tidak ditemukan, pakai nilai bawaan"
    fi
}
load_config

if command -v jsonfilter >/dev/null 2>&1; then
    HAS_JSONFILTER=1
else
    HAS_JSONFILTER=0
fi

detect_version() {
    if [ -f /etc/openwrt_release ]; then
        FULL_VERSION=$(grep 'DISTRIB_RELEASE' /etc/openwrt_release | cut -d"'" -f2)
        MAJOR_VERSION=$(echo "$FULL_VERSION" | cut -d. -f1)
        MINOR_VERSION=$(echo "$FULL_VERSION" | cut -d. -f2)
        log_auto "SYSTEM" "OpenWrt ${FULL_VERSION} (versi mayor ${MAJOR_VERSION}, minor ${MINOR_VERSION})"
    else
        log_auto "SYSTEM" "Bukan OpenWrt, hentikan skrip" "ERROR"
        echo "ERROR: Bukan OpenWrt." >&2
        exit 1
    fi
    if [ "$MAJOR_VERSION" -lt 19 ]; then
        IS_LEGACY=1
        log_auto "SYSTEM" "Mode: Legacy (versi ${FULL_VERSION})"
    elif [ "$MAJOR_VERSION" -eq 19 ]; then
        IS_LEGACY=1
        log_auto "SYSTEM" "Mode: Legacy (versi ${FULL_VERSION})"
    elif [ "$MAJOR_VERSION" -eq 21 ]; then
        IS_LEGACY=0
        log_auto "SYSTEM" "Mode: Transisi (versi ${FULL_VERSION})"
    else
        IS_LEGACY=0
        log_auto "SYSTEM" "Mode: Modern (versi ${FULL_VERSION})"
    fi
    if command -v jsonfilter >/dev/null 2>&1; then
        HAS_JSONFILTER=1; log_auto "SYSTEM" "jsonfilter tersedia"
    else
        HAS_JSONFILTER=0; log_auto "SYSTEM" "jsonfilter tidak tersedia, pakai grep/sed manual"
    fi

}

detect_switch_arch() {
    if command -v swconfig >/dev/null 2>&1 && swconfig list 2>/dev/null | grep -q 'switch'; then
        SWITCH_TYPE="swconfig"; IS_SWCONFIG=1; IS_DSA=0
    else
        SWITCH_TYPE="DSA"; IS_SWCONFIG=0; IS_DSA=1
    fi
    log_auto "SYSTEM" "Arsitektur switch: ${SWITCH_TYPE}"
}

init_routing_params() {
    if [ -x /etc/init.d/mwan3 ] && /etc/init.d/mwan3 status >/dev/null 2>&1; then
        MWAN3_ACTIVE=1
        MWAN3_TABLE=$(uci -q get mwan3.globals.table 2>/dev/null || echo "1")
        MWAN3_PRIORITY=$(uci -q get mwan3.globals.priority 2>/dev/null || echo "10")
        log_auto "SYSTEM" "MWAN3 aktif: table=${MWAN3_TABLE}, priority=${MWAN3_PRIORITY}"
    else
        MWAN3_ACTIVE=0
        MWAN3_TABLE=""
        MWAN3_PRIORITY=""
        log_auto "SYSTEM" "MWAN3 tidak aktif"
    fi

    log_auto "SYSTEM" "Mode routing: Dedicated Table Deterministik"
}

_routing_safe_name() {
    _rsn_out=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
    [ -n "$_rsn_out" ] || _rsn_out="unknown"
    printf '%s' "$_rsn_out"
}

_routing_read_lock_value() {
    [ -f "$1/$2" ] || return 1
    cat "$1/$2" 2>/dev/null
}

_routing_is_numeric() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

_routing_release_global_lock() {
    rm -f "$ROUTING_GLOBAL_LOCK/pid" "$ROUTING_GLOBAL_LOCK/started_at" 2>/dev/null
    rmdir "$ROUTING_GLOBAL_LOCK" 2>/dev/null
}

_routing_lock_is_active() {
    _rlia_lock="$1"
    [ -d "$_rlia_lock" ] || return 1

    _rlia_pid=$(_routing_read_lock_value "$_rlia_lock" pid) || return 1
    _routing_is_numeric "$_rlia_pid" || return 1
    [ "$_rlia_pid" -gt 0 ] || return 1
    kill -0 "$_rlia_pid" 2>/dev/null || return 1

    _rlia_started=$(_routing_read_lock_value "$_rlia_lock" started_at) || return 0
    _routing_is_numeric "$_rlia_started" || return 0
    [ "$_rlia_started" -gt 0 ] || return 0

    _rlia_now=$(date '+%s' 2>/dev/null) || return 0
    _routing_is_numeric "$_rlia_now" || return 0
    [ "$_rlia_now" -gt 0 ] || return 0

    _routing_is_numeric "$ROUTING_OWNER_TIMEOUT" || return 0
    [ "$ROUTING_OWNER_TIMEOUT" -gt 0 ] || return 0

    [ $((_rlia_now - _rlia_started)) -lt "$ROUTING_OWNER_TIMEOUT" ] || return 1
    return 0
}

_routing_remove_lock_routes() {
    _rrlr_lock="$1"
    [ -d "$_rrlr_lock" ] || return 0

    _rrlr_table=$(_routing_read_lock_value "$_rrlr_lock" table)
    _rrlr_priority=$(_routing_read_lock_value "$_rrlr_lock" priority)
    _rrlr_ip=$(_routing_read_lock_value "$_rrlr_lock" ip)

    if _routing_is_numeric "$_rrlr_table" && _routing_is_numeric "$_rrlr_priority"; then
        if [ -n "$_rrlr_ip" ]; then
            ip rule del from "$_rrlr_ip" table "$_rrlr_table" priority "$_rrlr_priority" >/dev/null 2>&1
        fi
        ip route del default table "$_rrlr_table" >/dev/null 2>&1
        ip route flush table "$_rrlr_table" >/dev/null 2>&1
    fi

    rm -rf "$_rrlr_lock" >/dev/null 2>&1
    return 0
}

_routing_active_lock_values() {
    _rav_key="$1"
    for _rav_lock in ${ROUTING_OWNER_LOCK_PREFIX}*${ROUTING_OWNER_LOCK_SUFFIX}; do
        [ -d "$_rav_lock" ] || continue
        _routing_lock_is_active "$_rav_lock" || continue
        _routing_read_lock_value "$_rav_lock" "$_rav_key"
    done
}

cleanup_temp_routing() {
    [ -n "$DEDICATED_LOCK" ] || return 0

    if [ ! -d "$DEDICATED_LOCK" ]; then
        DEDICATED_TABLE=""
        DEDICATED_PRIORITY=""
        DEDICATED_LOCK=""
        return 0
    fi

    _ctr_pid=$(_routing_read_lock_value "$DEDICATED_LOCK" pid)
    if [ -n "$_ctr_pid" ] && [ "$_ctr_pid" != "$$" ] && kill -0 "$_ctr_pid" 2>/dev/null; then
        log_auto "SYSTEM" "Cleanup routing dilewati: lock masih dimiliki PID $_ctr_pid" "WARN"
        return 1
    fi

    _ctr_table=$(_routing_read_lock_value "$DEDICATED_LOCK" table)
    _ctr_priority=$(_routing_read_lock_value "$DEDICATED_LOCK" priority)
    _ctr_ip=$(_routing_read_lock_value "$DEDICATED_LOCK" ip)

    if _routing_is_numeric "$_ctr_table" && _routing_is_numeric "$_ctr_priority"; then
        if [ -n "$_ctr_ip" ]; then
            ip rule del from "$_ctr_ip" table "$_ctr_table" priority "$_ctr_priority" >/dev/null 2>&1
        fi
        ip route del default table "$_ctr_table" >/dev/null 2>&1
        ip route flush table "$_ctr_table" >/dev/null 2>&1
    fi

    rm -rf "$DEDICATED_LOCK" >/dev/null 2>&1
    DEDICATED_TABLE=""
    DEDICATED_PRIORITY=""
    DEDICATED_LOCK=""
    return 0
}

setup_temp_routing() {
    _str_logical="$1"
    _str_ip="$2"
    _str_gateway="$3"
    _str_device="$4"

    if [ -z "$_str_ip" ]; then
        log_auto "${_str_logical:-SYSTEM}" "setup_temp_routing: IP kosong" "ERROR"
        return 1
    fi

    if [ -z "$_str_gateway" ] || [ "$_str_gateway" = "$NULL_GATEWAY" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: gateway kosong atau NULL_GATEWAY" "ERROR"
        return 1
    fi

    if [ -z "$_str_device" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: device kosong" "ERROR"
        return 1
    fi

    if [ -n "$DEDICATED_LOCK" ] && [ -d "$DEDICATED_LOCK" ]; then
        if ! cleanup_temp_routing; then
            log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: cleanup lock lama gagal" "ERROR"
            return 1
        fi
    fi

    if [ -z "$FULL_VERSION" ]; then
        detect_version
        detect_switch_arch
        init_routing_params
    fi

    if [ -z "$ROUTING_GLOBAL_LOCK" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_GLOBAL_LOCK tidak dikonfigurasi" "ERROR"
        return 1
    fi

    if [ -z "$ROUTING_OWNER_LOCK_PREFIX" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_OWNER_LOCK_PREFIX tidak dikonfigurasi" "ERROR"
        return 1
    fi

    if [ -z "$ROUTING_OWNER_LOCK_SUFFIX" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_OWNER_LOCK_SUFFIX tidak dikonfigurasi" "ERROR"
        return 1
    fi

    if ! _routing_is_numeric "$ROUTING_TABLE_MIN"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_TABLE_MIN tidak valid" "ERROR"
        return 1
    fi

    if ! _routing_is_numeric "$ROUTING_TABLE_MAX"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_TABLE_MAX tidak valid" "ERROR"
        return 1
    fi

    if ! _routing_is_numeric "$ROUTING_PRIORITY_MIN"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_PRIORITY_MIN tidak valid" "ERROR"
        return 1
    fi

    if ! _routing_is_numeric "$ROUTING_PRIORITY_MAX"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_PRIORITY_MAX tidak valid" "ERROR"
        return 1
    fi

    if ! _routing_is_numeric "$ROUTING_OWNER_TIMEOUT"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_OWNER_TIMEOUT tidak valid" "ERROR"
        return 1
    fi

    if ! _routing_is_numeric "$ROUTING_GLOBAL_LOCK_TIMEOUT"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_GLOBAL_LOCK_TIMEOUT tidak valid" "ERROR"
        return 1
    fi

    if [ "$ROUTING_TABLE_MAX" -lt "$ROUTING_TABLE_MIN" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_TABLE_MAX lebih kecil dari ROUTING_TABLE_MIN" "ERROR"
        return 1
    fi

    if [ "$ROUTING_PRIORITY_MAX" -lt "$ROUTING_PRIORITY_MIN" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_PRIORITY_MAX lebih kecil dari ROUTING_PRIORITY_MIN" "ERROR"
        return 1
    fi

    if [ "$ROUTING_OWNER_TIMEOUT" -le 0 ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_OWNER_TIMEOUT harus lebih besar dari 0" "ERROR"
        return 1
    fi

    if [ "$ROUTING_GLOBAL_LOCK_TIMEOUT" -le 0 ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ROUTING_GLOBAL_LOCK_TIMEOUT harus lebih besar dari 0" "ERROR"
        return 1
    fi

    _str_safe=$(_routing_safe_name "${_str_logical:-$_str_ip}")
    _str_owner_lock="${ROUTING_OWNER_LOCK_PREFIX}${_str_safe}${ROUTING_OWNER_LOCK_SUFFIX}"

    _str_wait=0
    while ! mkdir "$ROUTING_GLOBAL_LOCK" 2>/dev/null; do
        _str_lock_pid=$(_routing_read_lock_value "$ROUTING_GLOBAL_LOCK" pid) || _str_lock_pid=""
        _str_lock_started=$(_routing_read_lock_value "$ROUTING_GLOBAL_LOCK" started_at) || _str_lock_started=""
        _str_lock_stale=0

        if _routing_is_numeric "$_str_lock_pid" && [ "$_str_lock_pid" -gt 0 ]; then
            if ! kill -0 "$_str_lock_pid" 2>/dev/null; then
                _str_lock_stale=1
            elif _routing_is_numeric "$_str_lock_started" && [ "$_str_lock_started" -gt 0 ]; then
                _str_now=$(date '+%s' 2>/dev/null) || _str_now=""

                if _routing_is_numeric "$_str_now" &&
                   [ "$_str_now" -gt 0 ] &&
                   [ $((_str_now - _str_lock_started)) -ge "$ROUTING_GLOBAL_LOCK_TIMEOUT" ]; then
                    _str_lock_stale=1
                fi
            fi
        fi

        if [ "$_str_lock_stale" -eq 0 ] && [ "$_str_wait" -ge 3 ]; then
            if ! _routing_is_numeric "$_str_lock_pid" || [ "$_str_lock_pid" -le 0 ]; then
                _str_lock_stale=1
            elif ! _routing_is_numeric "$_str_lock_started" || [ "$_str_lock_started" -le 0 ]; then
                _str_lock_stale=1
            fi
        fi

        if [ "$_str_lock_stale" -eq 1 ]; then
            log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: melepas stale global routing lock: $ROUTING_GLOBAL_LOCK" "WARN"
            _routing_release_global_lock
            continue
        fi

        sleep 1 >/dev/null 2>&1
        _str_wait=$((_str_wait + 1))

        if [ "$_str_wait" -ge "$ROUTING_GLOBAL_LOCK_TIMEOUT" ]; then
            log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: timeout menunggu global routing lock setelah ${_str_wait}s" "ERROR"
            return 1
        fi
    done

    if ! echo $$ > "$ROUTING_GLOBAL_LOCK/pid" 2>/dev/null; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: gagal menulis pid global routing lock" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    if ! date '+%s' > "$ROUTING_GLOBAL_LOCK/started_at" 2>/dev/null; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: gagal menulis started_at global routing lock" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    for _str_lock in ${ROUTING_OWNER_LOCK_PREFIX}*${ROUTING_OWNER_LOCK_SUFFIX}; do
        [ -d "$_str_lock" ] || continue
        if ! _routing_lock_is_active "$_str_lock"; then
            log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: membersihkan stale owner lock: $_str_lock" "WARN"
            _routing_remove_lock_routes "$_str_lock"
        fi
    done

    if [ -d "$_str_owner_lock" ] && _routing_lock_is_active "$_str_owner_lock"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: owner lock masih aktif sah: $_str_owner_lock" "WARN"
        _routing_release_global_lock
        return 1
    fi

    _str_used_tables=" $(_routing_active_lock_values table | tr '\n' ' ') "
    _str_sys_tables=$(ip route show table all 2>/dev/null | grep -oE 'table [0-9]+' | awk '{print $2}' | sort -n | uniq | tr '\n' ' ')
    _str_rule_tables=$(ip rule show 2>/dev/null | grep -oE 'lookup [0-9]+' | awk '{print $2}' | sort -n | uniq | tr '\n' ' ')
    _str_used_tables="${_str_used_tables}${_str_sys_tables}${_str_rule_tables} "

    if [ "${MWAN3_ACTIVE:-0}" -eq 1 ] && [ -n "${MWAN3_TABLE:-}" ]; then
        _str_used_tables="${_str_used_tables}${MWAN3_TABLE} "
    fi

    _str_table_range=$((ROUTING_TABLE_MAX - ROUTING_TABLE_MIN + 1))
    if [ "$_str_table_range" -le 0 ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: rentang table tidak valid" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    _str_hash_hex=$(printf '%s' "$_str_safe" | md5sum 2>/dev/null | cut -c1-3)
    if [ -z "$_str_hash_hex" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: md5sum gagal menghasilkan hash" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    _str_hash_dec=$(printf "%d" "0x${_str_hash_hex}" 2>/dev/null) || _str_hash_dec=""
    if ! _routing_is_numeric "$_str_hash_dec"; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: konversi hash ke desimal gagal" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    _str_table=$((ROUTING_TABLE_MIN + (_str_hash_dec % _str_table_range)))
    _str_table_try=0
    _str_table_found=0

    while [ "$_str_table_try" -lt "$_str_table_range" ]; do
        _str_table_used=0
        case "$_str_used_tables" in
            *" $_str_table "*) _str_table_used=1 ;;
        esac

        if [ "$_str_table_used" -eq 0 ]; then
            _str_table_found=1
            break
        fi

        _str_table=$((_str_table + 1))
        [ "$_str_table" -gt "$ROUTING_TABLE_MAX" ] && _str_table="$ROUTING_TABLE_MIN"
        _str_table_try=$((_str_table_try + 1))
    done

    if [ "$_str_table_found" -eq 0 ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: rentang routing table habis: ${ROUTING_TABLE_MIN}-${ROUTING_TABLE_MAX}" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    if [ "${MWAN3_ACTIVE:-0}" -eq 1 ]; then
        _str_prio_min=1
        _str_mwan3_prio="${MWAN3_PRIORITY:-}"

        if ! _routing_is_numeric "$_str_mwan3_prio" || [ "$_str_mwan3_prio" -le 1 ]; then
            log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: priority mwan3 tidak valid atau terlalu rendah: ${_str_mwan3_prio:-kosong}" "ERROR"
            _routing_release_global_lock
            return 1
        fi

        _str_prio_max=$((_str_mwan3_prio - 1))
    else
        _str_prio_min="$ROUTING_PRIORITY_MIN"
        _str_prio_max="$ROUTING_PRIORITY_MAX"
    fi

    if [ "$_str_prio_max" -lt "$_str_prio_min" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: rentang priority tidak valid: ${_str_prio_min}-${_str_prio_max}" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    _str_used_priorities=" $(_routing_active_lock_values priority | tr '\n' ' ') "
    _str_system_priorities=$(ip rule show 2>/dev/null | awk -F: '{gsub(/ /, "", $1); if ($1 != "") print $1}' | tr '\n' ' ')
    _str_used_priorities="${_str_used_priorities}${_str_system_priorities} "

    _str_prio_range=$((_str_prio_max - _str_prio_min + 1))
    _str_prio_start=$((_str_prio_min + (_str_hash_dec % _str_prio_range)))
    _str_p="$_str_prio_start"
    _str_prio_try=0
    _str_priority=""

    while [ "$_str_prio_try" -lt "$_str_prio_range" ]; do
        _str_prio_used=0
        case "$_str_used_priorities" in
            *" $_str_p "*) _str_prio_used=1 ;;
        esac

        if [ "$_str_prio_used" -eq 0 ]; then
            _str_priority="$_str_p"
            break
        fi

        _str_p=$((_str_p + 1))
        [ "$_str_p" -gt "$_str_prio_max" ] && _str_p="$_str_prio_min"
        _str_prio_try=$((_str_prio_try + 1))
    done

    if [ -z "$_str_priority" ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: rentang routing priority habis: ${_str_prio_min}-${_str_prio_max}" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    if ! mkdir "$_str_owner_lock" 2>/dev/null; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: gagal membuat owner lock: $_str_owner_lock" "ERROR"
        _routing_release_global_lock
        return 1
    fi

    if ! echo $$ > "$_str_owner_lock/pid" 2>/dev/null; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: gagal menulis pid owner lock: $_str_owner_lock" "ERROR"
        rm -rf "$_str_owner_lock" >/dev/null 2>&1
        _routing_release_global_lock
        return 1
    fi

    if ! date '+%s' > "$_str_owner_lock/started_at" 2>/dev/null; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: gagal menulis started_at owner lock: $_str_owner_lock" "ERROR"
        rm -rf "$_str_owner_lock" >/dev/null 2>&1
        _routing_release_global_lock
        return 1
    fi

    echo "$_str_table" > "$_str_owner_lock/table" 2>/dev/null
    echo "$_str_priority" > "$_str_owner_lock/priority" 2>/dev/null
    echo "$_str_logical" > "$_str_owner_lock/logical" 2>/dev/null
    echo "$_str_ip" > "$_str_owner_lock/ip" 2>/dev/null
    echo "$_str_device" > "$_str_owner_lock/device" 2>/dev/null
    echo "$_str_gateway" > "$_str_owner_lock/gateway" 2>/dev/null

    _routing_release_global_lock

    _str_rule_out=$(ip rule add from "$_str_ip" table "$_str_table" priority "$_str_priority" 2>&1)
    _str_rule_rc=$?

    if [ "$_str_rule_rc" -ne 0 ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ip rule add gagal rc=$_str_rule_rc out=$_str_rule_out" "ERROR"
        _routing_remove_lock_routes "$_str_owner_lock"
        return 1
    fi

    _str_subnet=$(ip -4 route show dev "$_str_device" scope link 2>/dev/null | awk 'NF {print $1; exit}')

    if [ -n "$_str_subnet" ]; then
        _str_subnet_out=$(ip route add "$_str_subnet" dev "$_str_device" table "$_str_table" 2>&1)
        _str_subnet_rc=$?

        if [ "$_str_subnet_rc" -ne 0 ]; then
            log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ip route add subnet gagal rc=$_str_subnet_rc out=$_str_subnet_out; lanjut mencoba default route" "WARN"
        fi
    fi

    _str_default_out=$(ip route replace default via "$_str_gateway" dev "$_str_device" table "$_str_table" 2>&1)
    _str_default_rc=$?

    if [ "$_str_default_rc" -ne 0 ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ip route replace default tanpa onlink gagal rc=$_str_default_rc out=$_str_default_out; mencoba onlink" "WARN"

        _str_default_out=$(ip route replace default via "$_str_gateway" dev "$_str_device" table "$_str_table" onlink 2>&1)
        _str_default_rc=$?
    fi

    if [ "$_str_default_rc" -ne 0 ]; then
        log_auto "${_str_logical:-$_str_ip}" "setup_temp_routing: ip route replace default gagal rc=$_str_default_rc out=$_str_default_out" "ERROR"
        _routing_remove_lock_routes "$_str_owner_lock"
        return 1
    fi

    DEDICATED_TABLE="$_str_table"
    DEDICATED_PRIORITY="$_str_priority"
    DEDICATED_LOCK="$_str_owner_lock"

    log_auto "${_str_logical:-$_str_ip}" "Routing sementara terisolasi siap (table=$DEDICATED_TABLE, priority=$DEDICATED_PRIORITY, owner=$DEDICATED_LOCK)" "INFO"
    return 0
}

get_physical_interface() {
    gpi_iface="$1"; [ -z "$gpi_iface" ] && return 1
    if [ "$IS_DSA" -eq 1 ]; then
        log_auto "SYSTEM" "$gpi_iface adalah port DSA, langsung pakai" "DEBUG"
        echo "$gpi_iface"; return 0
    fi
    if [ -f /proc/net/vlan/config ] && [ -s /proc/net/vlan/config ]; then
        gpi_vlan_parent=$(awk -v if="$gpi_iface" 'NF>=5 && $1 !~ /^#/ && $1 == if {print $5; exit}' /proc/net/vlan/config 2>/dev/null)
        if [ -n "$gpi_vlan_parent" ]; then
            log_auto "SYSTEM" "$gpi_iface adalah VLAN dari $gpi_vlan_parent" "DEBUG"
            echo "$gpi_vlan_parent"; return 0
        fi
    fi
    if [ -d "/sys/class/net/$gpi_iface/brif" ]; then
        gpi_first_member=$(ls /sys/class/net/$gpi_iface/brif/ 2>/dev/null | head -1)
        if [ -n "$gpi_first_member" ]; then
            log_auto "SYSTEM" "$gpi_iface adalah bridge, anggota pertama: $gpi_first_member" "DEBUG"
            echo "$gpi_first_member"; return 0
        fi
    fi
    if is_bridge_member "$gpi_iface"; then
        gpi_bridge_master=""
        for gpi_br in /sys/class/net/*/brif; do
            if [ -d "$gpi_br/$gpi_iface" ]; then
                gpi_bridge_master=$(echo "$gpi_br" | cut -d/ -f5); break
            fi
        done
        if [ -n "$gpi_bridge_master" ]; then
            log_auto "SYSTEM" "$gpi_iface adalah port bridge, master: $gpi_bridge_master" "DEBUG"
            echo "$gpi_bridge_master"; return 0
        fi
    fi
    log_auto "SYSTEM" "$gpi_iface adalah interface fisik langsung" "DEBUG"
    echo "$gpi_iface"; return 0
}

get_gateway() {
    gg_iface="$1"
    [ -z "$gg_iface" ] && return 1
    if command -v jsonfilter >/dev/null 2>&1; then
        gg_gw=$(ubus call network.interface dump 2>/dev/null | jsonfilter -e "@.interface[@.interface='$gg_iface'].route[@.target='0.0.0.0'].nexthop" 2>/dev/null | head -1)
        if [ -n "$gg_gw" ] && [ "$gg_gw" != "$NULL_GATEWAY" ]; then
            log_auto "SYSTEM" "Gateway dari ubus logical ($gg_iface): $gg_gw" "DEBUG"
            echo "$gg_gw"; return 0
        fi
    fi
    gg_net_name=$(uci -q show network 2>/dev/null | grep -E "\.(device|ifname)='$gg_iface'" | head -1 | cut -d. -f2)
    [ -z "$gg_net_name" ] && gg_net_name=$(uci -q show network 2>/dev/null | grep -E "\.(device|ifname)=\"?$gg_iface\"?" | head -1 | cut -d. -f2)   
    if [ -n "$gg_net_name" ]; then
        gg_gw=$(ubus call network.interface dump 2>/dev/null | jsonfilter -e "@.interface[@.interface='$gg_net_name'].route[@.target='0.0.0.0'].nexthop" 2>/dev/null | head -1)
        if [ -n "$gg_gw" ] && [ "$gg_gw" != "$NULL_GATEWAY" ]; then
            log_auto "SYSTEM" "Gateway dari ubus ($gg_net_name): $gg_gw" "DEBUG"
            echo "$gg_gw"; return 0
        fi
    fi
    gg_gw=$(ip route show table all 2>/dev/null | grep "dev $gg_iface" | grep "via" | awk '{print $3}' | head -1)
    if [ -n "$gg_gw" ] && [ "$gg_gw" != "$NULL_GATEWAY" ]; then
        log_auto "SYSTEM" "Gateway dari tabel routing: $gg_gw" "DEBUG"
        echo "$gg_gw"; return 0
    fi
    gg_subnet=$(ip -4 addr show dev "$gg_iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
    if [ -n "$gg_subnet" ]; then
        gg_gw=$(echo "$gg_subnet" | cut -d'/' -f1 | sed 's/\.[0-9]*$/.1/')
        if [ -n "$gg_gw" ] && [ "$gg_gw" != "$NULL_GATEWAY" ]; then
            log_auto "SYSTEM" "Gateway fallback dari subnet ($gg_iface): $gg_gw" "DEBUG"
            echo "$gg_gw"; return 0
        fi
    fi
    log_auto "SYSTEM" "Tidak dapat menentukan gateway untuk $gg_iface" "DEBUG"
    return 1
}

get_wan_info() {
    log_auto "SYSTEM" "Mengumpulkan data interface WAN"
    gwi_entries=""
    for gwi_net in $(ubus list network.interface.* 2>/dev/null | sed 's/network\.interface\.//'); do
        case "$gwi_net" in loopback|lan) continue ;; esac
        if [ "$HAS_JSONFILTER" -eq 1 ]; then
            gwi_json=$(ubus call "network.interface.$gwi_net" status 2>/dev/null) || continue
            gwi_up=$(echo "$gwi_json" | jsonfilter -e '@.up' 2>/dev/null)
            [ "$gwi_up" != "true" ] && continue
            gwi_device=$(echo "$gwi_json" | jsonfilter -e '@.device' 2>/dev/null)
            [ -z "$gwi_device" ] && gwi_device=$(echo "$gwi_json" | jsonfilter -e '@.l3_device' 2>/dev/null)
            [ -z "$gwi_device" ] && gwi_device=$(echo "$gwi_json" | jsonfilter -e '@.ifname' 2>/dev/null)
            [ -z "$gwi_device" ] && gwi_device="$gwi_net"
            gwi_ip=$(echo "$gwi_json" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
            gwi_gw=$(echo "$gwi_json" | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
        else
            gwi_json=$(ubus call "network.interface.$gwi_net" status 2>/dev/null) || continue
            gwi_up=$(echo "$gwi_json" | grep -o '"up":[^,}]*' 2>/dev/null | head -1 | grep -o 'true\|false')
            [ "$gwi_up" != "true" ] && continue
            gwi_device=$(echo "$gwi_json" | grep -o '"device":"[^"]*"' 2>/dev/null | head -1 | sed 's/"device":"//;s/"//')
            [ -z "$gwi_device" ] && gwi_device=$(echo "$gwi_json" | grep -o '"l3_device":"[^"]*"' 2>/dev/null | head -1 | sed 's/"l3_device":"//;s/"//')
            [ -z "$gwi_device" ] && gwi_device=$(echo "$gwi_json" | grep -o '"ifname":"[^"]*"' 2>/dev/null | head -1 | sed 's/"ifname":"//;s/"//')
            [ -z "$gwi_device" ] && gwi_device="$gwi_net"
            gwi_ip=$(echo "$gwi_json" | grep -o '"address":"[^"]*"' 2>/dev/null | head -1 | sed 's/"address":"//;s/"//')
            gwi_gw=$(echo "$gwi_json" | grep -o '"nexthop":"[^"]*"' 2>/dev/null | head -1 | sed 's/"nexthop":"//;s/"//')
        fi
        [ -z "$gwi_ip" ] && continue
        if [ -z "$gwi_gw" ] || [ "$gwi_gw" = "$NULL_GATEWAY" ]; then
            gwi_gw=$(get_gateway "$gwi_net")
        fi
        if [ -z "$gwi_gw" ] || [ "$gwi_gw" = "$NULL_GATEWAY" ]; then
            gwi_gw=$(get_gateway "$gwi_device")
        fi
        if [ -z "$gwi_gw" ] || [ "$gwi_gw" = "$NULL_GATEWAY" ]; then
            log_auto "$gwi_net" "Gateway tidak valid (kosong/NULL_GATEWAY), interface dilewati dari daftar WAN terdeteksi" "WARN"
            continue
        fi
        gwi_physical_desc=$(get_physical_interface "$gwi_device")
        log_auto "$gwi_net" "device=$gwi_device, fisik=$gwi_physical_desc, IP=$gwi_ip, GW=$gwi_gw"
        gwi_entries="${gwi_entries}${gwi_net} ${gwi_physical_desc} ${gwi_ip} ${gwi_gw}
"
    done
    echo "$gwi_entries"
}

is_bridge_member() {
    ibm_iface="$1"; [ -z "$ibm_iface" ] && return 1
    escaped_iface=$(echo "$ibm_iface" | sed 's/[.[\*^$+?(){|]/\\&/g')
    if uci -q show network 2>/dev/null | grep -qE "\.ports='[^']*${escaped_iface}[^']*'"; then
        log_auto "SYSTEM" "$ibm_iface adalah anggota bridge (UCI ports)" "DEBUG"
        return 0
    fi
    if uci -q show network 2>/dev/null | grep -qE "\.ifname='[^']*${escaped_iface}[^']*'"; then
        log_auto "SYSTEM" "$ibm_iface adalah anggota bridge (UCI ifname)" "DEBUG"
        return 0
    fi
    if [ -d "/sys/class/net/${ibm_iface}/brif" ] && [ "$(ls /sys/class/net/${ibm_iface}/brif/ 2>/dev/null | wc -l)" -gt 0 ]; then
        log_auto "SYSTEM" "$ibm_iface adalah bridge master" "DEBUG"
        return 0
    fi
    if [ -d "/sys/class/net/${ibm_iface}/brport" ]; then
        log_auto "SYSTEM" "$ibm_iface adalah port bridge (brport)" "DEBUG"
        return 0
    fi
    if [ "$IS_LEGACY" -eq 1 ] && [ "$IS_SWCONFIG" -eq 1 ]; then
        if [ -f /proc/net/vlan/config ] && grep -q "^${ibm_iface}" /proc/net/vlan/config 2>/dev/null; then
            log_auto "SYSTEM" "$ibm_iface adalah VLAN (swconfig legacy)" "DEBUG"
            return 0
        fi
    fi
    return 1
}

get_rep_if() {
    for grif_iface in $(ls /sys/class/net 2>/dev/null); do
        case "$grif_iface" in lo|docker*|veth*|virbr*|tap*|tun*|sit*|ppp*|6to4*|gre*|gretap*|ifb*|bond*) continue ;; esac
        if [ "$IS_DSA" -eq 1 ]; then
            if is_bridge_member "$grif_iface"; then continue; fi
        else
            case "$grif_iface" in br-*|*.*) continue ;; esac
        fi
        echo "$grif_iface"; return 0
    done
    return 1
}

json_escape() {
    printf '%s' "$1" | awk '{gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\r/, ""); gsub(/\n/, ""); gsub(/\t/, "\\t"); printf "%s", $0;}'
}

random_endpoint() {
    [ -f "$ENDPOINTS_CONF" ] && [ -s "$ENDPOINTS_CONF" ] && awk 'BEGIN{srand();} {a[NR]=$0} END{if(NR>0) print a[int(rand()*NR)+1]}' "$ENDPOINTS_CONF"
}

reload_service() {
    rs_uci_section="$1"
    log_auto "SYSTEM" "Muat ulang layanan untuk: $rs_uci_section"
    case "$rs_uci_section" in
        wireless.*)
            if command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1; then
                log_auto "SYSTEM" "WiFi dimuat ulang (wifi reload)"
            elif command -v wifi >/dev/null 2>&1; then
                wifi >/dev/null 2>&1; log_auto "SYSTEM" "WiFi dimuat ulang (wifi)"
            else log_auto "SYSTEM" "Perintah wifi tidak ditemukan" "ERROR"; fi ;;
        network.*)
            if [ -x /etc/init.d/network ]; then
                /etc/init.d/network reload >/dev/null 2>&1; log_auto "SYSTEM" "Network dimuat ulang"
            else log_auto "SYSTEM" "/etc/init.d/network tidak ditemukan" "ERROR"; fi ;;
        *) log_auto "SYSTEM" "Tidak tahu cara memuat ulang: $rs_uci_section" "ERROR";;
    esac
}

disable_rebind_protection() {
    drp_rebind=$(uci -q get dhcp.@dnsmasq[0].rebind_protection 2>/dev/null)
    if [ "$drp_rebind" = "0" ]; then
        log_auto "SYSTEM" "rebind_protection sudah 0, tidak ada yang diubah"
        return 0
    fi
    uci set dhcp.@dnsmasq[0].rebind_protection='0'; uci commit dhcp
    if [ -x /etc/init.d/dnsmasq ]; then
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
        log_auto "SYSTEM" "rebind_protection diubah dari '${drp_rebind:-tidak ada}' menjadi 0, dnsmasq direstart"
    else log_auto "SYSTEM" "/etc/init.d/dnsmasq tidak ditemukan" "ERROR"; fi
}

restart_interface() {
    ri_logical="$1"
    [ -z "$ri_logical" ] && { log_auto "SYSTEM" "restart_interface: nama interface kosong" "ERROR"; return 1; }
    log_auto "$ri_logical" "Restart interface: $ri_logical"
    if [ -x /sbin/ifdown ] && [ -x /sbin/ifup ]; then
        log_auto "$ri_logical" "Menggunakan ifdown/ifup untuk $ri_logical" "DEBUG"
        /sbin/ifdown "$ri_logical" >/dev/null 2>&1
        sleep 1
        /sbin/ifup "$ri_logical" >/dev/null 2>&1
        return 0
    fi
    if command -v ubus >/dev/null 2>&1; then
        log_auto "$ri_logical" "Menggunakan ubus untuk $ri_logical" "DEBUG"
        ubus call network.interface."$ri_logical" down >/dev/null 2>&1
        sleep 1
        ubus call network.interface."$ri_logical" up >/dev/null 2>&1
        return 0
    fi
    if [ -x /etc/init.d/network ]; then
        log_auto "$ri_logical" "Menggunakan /etc/init.d/network reload" "DEBUG"
        /etc/init.d/network reload >/dev/null 2>&1
        return 0
    fi
    log_auto "$ri_logical" "Tidak dapat merestart interface $ri_logical: tidak ada metode yang tersedia" "ERROR"
    return 1
}

restart_interface_specific() {
    ris_logical="$1"
    [ -z "$ris_logical" ] && { log_auto "SYSTEM" "restart_interface_specific: nama interface kosong" "ERROR"; return 1; }
    log_auto "$ris_logical" "Restart spesifik interface: $ris_logical (ISOLASI ABSOLUT: tidak mempengaruhi interface lain)"

    if [ -x /sbin/ifdown ] && [ -x /sbin/ifup ]; then
        log_auto "$ris_logical" "Menggunakan ifdown/ifup spesifik untuk $ris_logical" "DEBUG"
        /sbin/ifdown "$ris_logical" >/dev/null 2>&1
        sleep 1 >/dev/null 2>&1
        /sbin/ifup "$ris_logical" >/dev/null 2>&1
        log_auto "$ris_logical" "Interface $ris_logical berhasil direstart secara spesifik (ifdown/ifup)"
        return 0
    fi

    if command -v ubus >/dev/null 2>&1; then
        log_auto "$ris_logical" "Menggunakan ubus spesifik untuk $ris_logical" "DEBUG"
        ubus call network.interface."$ris_logical" down >/dev/null 2>&1
        sleep 1 >/dev/null 2>&1
        ubus call network.interface."$ris_logical" up >/dev/null 2>&1
        log_auto "$ris_logical" "Interface $ris_logical berhasil direstart secara spesifik (ubus)"
        return 0
    fi

    log_auto "$ris_logical" "Gagal restart interface $ris_logical: ifdown/ifup dan ubus tidak tersedia. Isolasi gagal." "ERROR"
    return 1
}

load_browser_profile() {
    local lbp_profile="$1"
    local lbp_context="$2"

    [ -z "$lbp_profile" ] && return 1

    case "$lbp_profile" in
        *[!A-Za-z0-9_]*)
            log_auto "SYSTEM" "Profil browser tidak valid: $lbp_profile" "ERROR"
            return 1
            ;;
    esac

    if [ -n "$lbp_context" ]; then
        case "$lbp_context" in
            *[!A-Za-z0-9_]*)
                log_auto "SYSTEM" "Konteks browser tidak valid: $lbp_context" "ERROR"
                return 1
                ;;
        esac
    fi

    local lbp_vars="UA ACCEPT ACCEPT_LANG ACCEPT_ENCODING PRIORITY SEC_CH_UA SEC_CH_UA_MOBILE SEC_CH_UA_PLATFORM SEC_FETCH_SITE DNT BROWSER_NAME"
    local lbp_var
    local lbp_ctx_name
    local lbp_base_name
    local lbp_ctx_set
    local lbp_val

    for lbp_var in $lbp_vars; do
        lbp_base_name="${lbp_var}_${lbp_profile}"
        lbp_ctx_name=""
        lbp_ctx_set=""
        lbp_val=""

        if [ -n "$lbp_context" ]; then
            lbp_ctx_name="${lbp_var}_${lbp_context}_${lbp_profile}"
            eval "lbp_ctx_set=\${${lbp_ctx_name}+x}"
        fi

        if [ -n "$lbp_ctx_set" ]; then
            eval "lbp_val=\"\${${lbp_ctx_name}}\""
        else
            eval "lbp_val=\"\${${lbp_base_name}:-}\""
        fi

        eval "export ${lbp_var}=\"\$lbp_val\""
    done

    export BROWSER="$BROWSER_NAME"

    local lbp_hdr_ctx_name=""
    local lbp_hdr_base_name="HEADER_ORDER_${lbp_profile}"
    local lbp_hdr_ctx_set=""
    local lbp_hdr_val=""

    if [ -n "$lbp_context" ]; then
        lbp_hdr_ctx_name="HEADER_ORDER_${lbp_context}_${lbp_profile}"
        eval "lbp_hdr_ctx_set=\${${lbp_hdr_ctx_name}+x}"
    fi

    if [ -n "$lbp_hdr_ctx_set" ]; then
        eval "lbp_hdr_val=\"\${${lbp_hdr_ctx_name}}\""
    else
        eval "lbp_hdr_val=\"\${${lbp_hdr_base_name}:-}\""
    fi

    export HEADER_ORDER="$lbp_hdr_val"

    log_auto "SYSTEM" "Profil HTTP $lbp_profile untuk konteks ${lbp_context:-global} berhasil dimuat" "DEBUG"
}

get_header_value() {
    case "$1" in
        Host) echo "Host: $DOMAIN" ;;
        User-Agent) echo "User-Agent: $UA" ;;
        Accept) echo "Accept: $ACCEPT" ;;
        Accept-Language) echo "Accept-Language: $ACCEPT_LANG" ;;
        Accept-Encoding) echo "Accept-Encoding: $ACCEPT_ENCODING" ;;
        Connection) echo "Connection: keep-alive" ;;
        Upgrade-Insecure-Requests) echo "Upgrade-Insecure-Requests: 1" ;;
        Priority) [ -n "$PRIORITY" ] && echo "Priority: $PRIORITY" ;;
        Pragma) echo "Pragma: no-cache" ;;
        Cache-Control) echo "Cache-Control: no-cache" ;;
        DNT) [ -n "$DNT" ] && echo "DNT: $DNT" ;;
        sec-ch-ua) [ -n "$SEC_CH_UA" ] && echo "sec-ch-ua: $SEC_CH_UA" ;;
        sec-ch-ua-mobile) [ -n "$SEC_CH_UA_MOBILE" ] && echo "sec-ch-ua-mobile: $SEC_CH_UA_MOBILE" ;;
        sec-ch-ua-platform) [ -n "$SEC_CH_UA_PLATFORM" ] && echo "sec-ch-ua-platform: $SEC_CH_UA_PLATFORM" ;;
        Sec-Fetch-Site) [ -n "$SEC_FETCH_SITE" ] && echo "Sec-Fetch-Site: $SEC_FETCH_SITE" ;;
        Sec-Fetch-Mode) [ -n "$SEC_FETCH_SITE" ] && echo "Sec-Fetch-Mode: navigate" ;;
        Sec-Fetch-Dest) [ -n "$SEC_FETCH_SITE" ] && echo "Sec-Fetch-Dest: document" ;;
        Sec-Fetch-User) [ -n "$SEC_FETCH_SITE" ] && echo "Sec-Fetch-User: ?1" ;;
        Referer) [ -n "$REFERER_URL" ] && echo "Referer: $REFERER_URL" ;;
    esac
}

get_portal_ip() {
    local gpi_domain="$1"
    local gpi_conf="/usr/lib/portal/conf/portal_domain_ip.conf"
    if [ -f "$gpi_conf" ] && [ -s "$gpi_conf" ]; then
        local gpi_ip=$(grep -E "^${gpi_domain}[[:space:]]" "$gpi_conf" 2>/dev/null | awk '{print $2}' | head -1)
        if [ -n "$gpi_ip" ]; then
            echo "$gpi_ip"
            return 0
        fi
    fi
    return 1
}

get_random_hostname() {
    grh_exclude="$1"
    grh_pool="/usr/lib/portal/conf/hostname_pool.conf"
    
    if [ ! -f "$grh_pool" ] || [ ! -s "$grh_pool" ]; then
        log_auto "SYSTEM" "Pool hostname tidak ditemukan di $grh_pool" "ERROR"
        return 1
    fi
    
    grh_candidates=$(grep -v '^#' "$grh_pool" | grep -v '^$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [ -n "$grh_exclude" ]; then
        grh_candidates=$(echo "$grh_candidates" | grep -v "^${grh_exclude}$")
    fi
    
    if [ -z "$grh_candidates" ]; then
        log_auto "SYSTEM" "Pool kosong setelah exclude '$grh_exclude', pakai pool penuh" "WARN"
        grh_candidates=$(grep -v '^#' "$grh_pool" | grep -v '^$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    
    grh_result=$(echo "$grh_candidates" | awk 'BEGIN{srand()} {a[NR]=$0} END{if(NR>0) print a[int(rand()*NR)+1]}')
    
    if [ -z "$grh_result" ]; then
        log_auto "SYSTEM" "Gagal acak hostname dari pool" "ERROR"
        return 1
    fi
    
    log_auto "SYSTEM" "Hostname terpilih: $grh_result (exclude: ${grh_exclude:-none})" "DEBUG"
    echo "$grh_result"
    return 0
}

json_get() {
    local jg_file="$1"
    local jg_key="$2"
    local jg_result=""
    local jg_has_nested=0

    [ ! -f "$jg_file" ] && {
        log_auto "SYSTEM" "json_get: file tidak ditemukan: $jg_file" "ERROR"
        return 1
    }

    if command -v jsonfilter >/dev/null 2>&1; then
        jg_result=$(jsonfilter -i "$jg_file" -e "@.$jg_key" 2>/dev/null)
    else
        case "$jg_key" in
            *.*|*'['*|*']'*)
                jg_has_nested=1
                ;;
        esac

        if [ "$jg_has_nested" -eq 1 ]; then
            log_auto "SYSTEM" "json_get: jsonfilter tidak tersedia, key nested/array tidak didukung: $jg_key" "ERROR"
            return 1
        fi

        case "$jg_key" in
            *[!A-Za-z0-9_-]*)
                log_auto "SYSTEM" "json_get: key tidak valid untuk fallback: $jg_key" "ERROR"
                return 1
                ;;
        esac

        jg_result=$(grep -o "\"$jg_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$jg_file" 2>/dev/null | head -1 | sed "s/\"$jg_key\"[[:space:]]*:[[:space:]]*\"//;s/\"$//")
        if [ -z "$jg_result" ]; then
            jg_result=$(grep -o "\"$jg_key\"[[:space:]]*:[[:space:]]*[0-9]*" "$jg_file" 2>/dev/null | head -1 | sed "s/\"$jg_key\"[[:space:]]*:[[:space:]]*//")
        fi
        if [ -z "$jg_result" ]; then
            jg_result=$(grep -o "\"$jg_key\"[[:space:]]*:[[:space:]]*\(true\|false\)" "$jg_file" 2>/dev/null | head -1 | sed "s/\"$jg_key\"[[:space:]]*:[[:space:]]*//")
        fi
    fi

    if [ -z "$jg_result" ]; then
        log_auto "SYSTEM" "json_get: key '$jg_key' tidak ditemukan di $jg_file" "DEBUG"
        return 1
    fi

    printf '%s\n' "$jg_result"
    return 0
}

_portal_param_present() {
    local ppp_url="$1"
    local ppp_param="$2"

    [ -z "$ppp_param" ] && return 1

    case "$ppp_param" in
        *[!A-Za-z0-9_]*)
            return 1
            ;;
    esac

    printf '%s\n' "$ppp_url" | awk -v p="$ppp_param" '
        BEGIN { found = 0 }
        {
            if (index($0, "?" p "=") > 0) { found = 1; exit }
            if (index($0, "&" p "=") > 0) { found = 1; exit }
        }
        END {
            if (found) exit 0
            exit 1
        }
    '
}

portal_contract_normalize_path_url() {
    pcnp_rule="$1"
    pcnp_detected="$2"
    pcnp_correct="$3"

    if [ -z "$pcnp_rule" ]; then
        return 1
    fi

    case "$pcnp_rule" in
        *%path%*)
            pcnp_final="${pcnp_correct:-$pcnp_detected}"
            pcnp_final=$(printf '%s' "$pcnp_final" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
            if [ -z "$pcnp_final" ]; then
                return 1
            fi
            printf '%s' "$pcnp_rule" | sed "s/%path%/$pcnp_final/g"
            ;;
        *)
            printf '%s' "$pcnp_rule"
            ;;
    esac
}

portal_contract_match_url() {
    pcm_url="$1"
    pcm_body="$2"

    if [ -z "$pcm_url" ]; then
        echo "unknown|0||spaces|||"
        return 1
    fi

    if [ ! -f "$PORTAL_TYPES_CONF" ]; then
        echo "unknown|0||spaces|||"
        return 1
    fi

    pcm_path=$(echo "$pcm_url" | awk -F'://' '{print $2}' | awk -F'/' '{print $2}' | awk -F'?' '{print $1}')

    while IFS='|' read -r rule_path rule_params rule_type rule_html rule_correct rule_encode rule_show_params rule_path_url rule_landing rule_executor || [ -n "$rule_path" ]; do
        [ -z "$rule_path" ] && continue
        case "$rule_path" in \#*) continue ;; esac
        [ "$pcm_path" = "$rule_path" ] || continue

        pcm_all_match=1

        if [ -n "$rule_params" ]; then
            OLDIFS="$IFS"
            IFS=','
            for pcm_param in $rule_params; do
                [ -z "$pcm_param" ] && continue

                if ! _portal_param_present "$pcm_url" "$pcm_param"; then
                    pcm_all_match=0
                    break
                fi
            done
            IFS="$OLDIFS"
        fi

        [ "$pcm_all_match" -eq 1 ] || continue

        if [ -n "$rule_html" ] && [ -n "$pcm_body" ]; then
            pcm_html_match=0
            OLDIFS="$IFS"
            IFS=','
            for pcm_ciri in $rule_html; do
                [ -z "$pcm_ciri" ] && continue

                if printf '%s\n' "$pcm_body" | grep -qiF -- "$pcm_ciri"; then
                    pcm_html_match=1
                    break
                fi
            done
            IFS="$OLDIFS"
            [ "$pcm_html_match" -eq 1 ] || continue
        fi

        pcm_generated_path_url=$(portal_contract_normalize_path_url "$rule_path_url" "$pcm_path" "$rule_correct")

        if [ -z "$pcm_generated_path_url" ] || [ -z "$rule_landing" ] || [ -z "$rule_executor" ]; then
            continue
        fi

        echo "${rule_type}|${rule_show_params:-0}|${rule_correct}|${rule_encode:-spaces}|${pcm_generated_path_url}|${rule_landing}|${rule_executor}"
        return 0
    done < "$PORTAL_TYPES_CONF"

    echo "unknown|0||spaces|||"
    return 1
}

portal_contract_lookup_identity() {
    pcl_type="$1"
    pcl_path_url="$2"

    if [ -z "$pcl_type" ] || [ -z "$pcl_path_url" ]; then
        return 1
    fi

    if [ ! -f "$PORTAL_TYPES_CONF" ]; then
        return 1
    fi

    while IFS='|' read -r rule_path rule_params rule_type rule_html rule_correct rule_encode rule_show_params rule_path_url rule_landing rule_executor || [ -n "$rule_path" ]; do
        [ -z "$rule_path" ] && continue
        case "$rule_path" in \#*) continue ;; esac
        [ "$rule_type" = "$pcl_type" ] || continue

        pcl_matched=0

        if [ "$rule_path_url" = "$pcl_path_url" ]; then
            pcl_matched=1
        elif [ "$rule_path_url" = "*" ]; then
            pcl_matched=1
        else
            case "$rule_path_url" in
                *%path%*)
                    pcl_glob=$(printf '%s' "$rule_path_url" | sed 's/%path%/*/g')
                    case "$pcl_path_url" in
                        $pcl_glob) pcl_matched=1 ;;
                    esac
                    ;;
            esac
        fi

        if [ "$pcl_matched" -eq 1 ] && [ -n "$rule_landing" ] && [ -n "$rule_executor" ]; then
            printf '%s|%s\n' "$rule_landing" "$rule_executor"
            return 0
        fi
    done < "$PORTAL_TYPES_CONF"

    return 1
}

portal_contract_default_url_path() {
    pcdup_type="$1"

    if [ -z "$pcdup_type" ]; then
        return 1
    fi

    if [ ! -f "$PORTAL_TYPES_CONF" ]; then
        return 1
    fi

    while IFS='|' read -r rule_path rule_params rule_type rule_html rule_correct rule_encode rule_show_params rule_path_url rule_landing rule_executor || [ -n "$rule_path" ]; do
        [ -z "$rule_path" ] && continue
        case "$rule_path" in \#*) continue ;; esac

        if [ "$rule_type" = "$pcdup_type" ]; then
            printf '%s\n' "${rule_correct:-$rule_path}"
            return 0
        fi
    done < "$PORTAL_TYPES_CONF"

    return 1
}

if [ "$NETWORK_SH_EXEC" = "1" ]; then
    case "$1" in
        reload_service) reload_service "$2" ;;
        disable_rebind_protection) disable_rebind_protection ;;
        restart_interface) restart_interface "$2" ;;
        restart_interface_specific) restart_interface_specific "$2" ;;
        contract_lookup_identity) portal_contract_lookup_identity "$2" "$3" ;;
        contract_lookup_url) portal_contract_match_url "$2" "" ;;
        contract_default_url_path) portal_contract_default_url_path "$2" ;;
        *) log_auto "SYSTEM" "Fungsi tidak dikenal: $1" "ERROR" ;;
    esac
    exit 0
fi