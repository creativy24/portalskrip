#!/bin/sh
. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh

STATE_DIR="/etc/portal/state"
PROFILE_DIR="/etc/portal/profiles"

read_state() {
    local state_file="$1"; local key="$2"
    [ ! -f "$state_file" ] && return 1
    local value=$(grep "^${key}=" "$state_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
    echo "$value"
}

update_state() {
    local state_file="$1"; local key="$2"; local value="$3"
    mkdir -p "$STATE_DIR" >/dev/null 2>&1
    if [ -f "$state_file" ]; then
        local temp_file="${state_file}.tmp"
        grep -v "^${key}=" "$state_file" > "$temp_file" 2>/dev/null
        echo "${key}=${value}" >> "$temp_file"
        mv "$temp_file" "$state_file" >/dev/null 2>&1
    else
        echo "${key}=${value}" > "$state_file"
    fi
}

update_state_audit() {
    local state_file="$1"
    local action="$2"
    local result="$3"
    local message="$4"
    local timestamp=$(date '+%d-%m-%Y %H:%M:%S')
    
    update_state "$state_file" "LAST_ATTEMPT" "$timestamp"
    update_state "$state_file" "LAST_ACTION" "$action"
    update_state "$state_file" "LAST_RESULT" "$result"
    update_state "$state_file" "LAST_MESSAGE" "$message"
    
    local profile_name=$(basename "$state_file" .state)
    log_auto "$profile_name" "action=$action result=$result message=$message"
}

update_json_bulk() {
    local ujb_file="$1"
    local ujb_profile="$2"

    if [ -z "$ujb_file" ] || [ -z "$ujb_profile" ]; then
        log_auto "SYSTEM" "Parameter update_json_bulk tidak lengkap" "ERROR"
        return 1
    fi

    shift 2

    if [ ! -f "$ujb_file" ]; then
        log_auto "$ujb_profile" "File profil tidak ditemukan: $ujb_file" "ERROR"
        return 1
    fi

    if [ $# -eq 0 ]; then
        log_auto "$ujb_profile" "Tidak ada parameter untuk update JSON"
        return 0
    fi

    if [ $(( $# % 2 )) -ne 0 ]; then
        log_auto "$ujb_profile" "Parameter update_json_bulk tidak berpasangan genap" "ERROR"
        return 1
    fi

    if ! command -v lua >/dev/null 2>&1; then
        log_auto "$ujb_profile" "Lua tidak tersedia; update JSON atomik tidak dapat dijalankan" "ERROR"
        return 1
    fi

    local ujb_lock="/tmp/portal_profile_${ujb_profile}.lock"
    local ujb_wait=0
    local ujb_max_wait=50

    while ! mkdir "$ujb_lock" 2>/dev/null; do
        if [ -f "$ujb_lock/pid" ]; then
            local ujb_lock_pid=$(cat "$ujb_lock/pid" 2>/dev/null)
            if [ -n "$ujb_lock_pid" ] && ! kill -0 "$ujb_lock_pid" 2>/dev/null; then
                log_auto "$ujb_profile" "Stale profile write lock terdeteksi (PID: $ujb_lock_pid), membersihkan" "WARN"
                rm -rf "$ujb_lock" >/dev/null 2>&1
                continue
            fi
        fi

        sleep 0.1 >/dev/null 2>&1
        ujb_wait=$((ujb_wait + 1))

        if [ "$ujb_wait" -ge "$ujb_max_wait" ]; then
            log_auto "$ujb_profile" "Timeout menunggu profile write lock: $ujb_lock" "ERROR"
            return 1
        fi
    done

    echo $$ > "$ujb_lock/pid" 2>/dev/null

    log_auto "$ujb_profile" "Memulai update JSON atomik via Lua bridge: $ujb_file"

    local ujb_output
    ujb_output=$(lua /usr/lib/portal/lib_json.lua "$ujb_file" "$@" 2>&1)
    local ujb_rc=$?

    rm -rf "$ujb_lock" >/dev/null 2>&1

    if [ "$ujb_rc" -eq 0 ]; then
        log_auto "$ujb_profile" "Update JSON atomik berhasil"
        return 0
    fi

    log_auto "$ujb_profile" "Update JSON atomik gagal (rc=$ujb_rc): $ujb_output" "ERROR"
    return 1
}

get_portal_scripts() {
    local portal_type="$1"
    local path_url="$2"
    portal_contract_lookup_identity "$portal_type" "$path_url"
}

run_landing_script() {
    local portal_type="$1"; local profile_file="$2"
    local profile_name=$(basename "$profile_file" .json)
    local interface=$(json_get "$profile_file" "interface")
    local device=$(json_get "$profile_file" "device")
    local portal_url=$(json_get "$profile_file" "portal_url")
    local ip=$(json_get "$profile_file" "ipc")
    local gateway=$(json_get "$profile_file" "gateway")
    local path_url=$(json_get "$profile_file" "path_url")

    [ -z "$ip" ] && ip=$(ip -4 addr show dev "$device" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$gateway" ] && gateway=$(ip route show dev "$device" 2>/dev/null | awk '/default/{print $3}' | head -1)

    if [ -z "$path_url" ] && [ -n "$portal_url" ]; then
        local contract=$(portal_contract_match_url "$portal_url" "")
        portal_type=$(echo "$contract" | cut -d'|' -f1)
        path_url=$(echo "$contract" | cut -d'|' -f5)
    fi

    if [ -z "$path_url" ] || [ "$portal_type" = "unknown" ]; then
        log_auto "$profile_name" "path_url atau portal_type tidak valid untuk landing" "ERROR"
        return 1
    fi

    local detected_path=$(echo "$portal_url" | awk -F/ '{print $4}' | cut -d'?' -f1 | head -1)
    [ -z "$detected_path" ] && detected_path="login"

    local scripts=$(get_portal_scripts "$portal_type" "$path_url")
    [ $? -ne 0 ] && return 1
    local landing_script_name=$(echo "$scripts" | cut -d'|' -f1)
    local landing_script="/usr/lib/portal/landing/${landing_script_name}"
    [ ! -x "$landing_script" ] && { log_auto "$profile_name" "Landing script tidak ditemukan: $landing_script" "ERROR"; return 1; }
    log_auto "$profile_name" "Jalankan landing script: $landing_script (portal_type=$portal_type, path_url=$path_url, path=$detected_path)"
    export PORTAL_TYPE="$portal_type"
    export PATH_URL="$path_url"
    sh "$landing_script" "$portal_url" "$ip" "$detected_path" "$gateway" "$ip" "$interface" "$device" >/dev/null 2>&1
    local exit_code=$?
    [ $exit_code -ne 0 ] && log_auto "$profile_name" "Landing script GAGAL untuk $portal_type/$path_url (exit code: $exit_code)" "ERROR"
    return $exit_code
}

run_login_executor() {
    local portal_type="$1"; local profile_file="$2"
    local profile_name=$(basename "$profile_file" .json)
    local interface=$(json_get "$profile_file" "interface")
    local device=$(json_get "$profile_file" "device")
    local username=$(json_get "$profile_file" "username")
    local password=$(json_get "$profile_file" "password")
    local portal_url=$(json_get "$profile_file" "portal_url")
    local gw_id=$(json_get "$profile_file" "gw_id")
    local client_mac=$(json_get "$profile_file" "client_mac")
    local wlan=$(json_get "$profile_file" "wlan")
    local sessionid=$(json_get "$profile_file" "sessionid")
    local ipc=$(json_get "$profile_file" "ipc")
    local path_url=$(json_get "$profile_file" "path_url")

    if [ -z "$path_url" ] && [ -n "$portal_url" ]; then
        local contract=$(portal_contract_match_url "$portal_url" "")
        portal_type=$(echo "$contract" | cut -d'|' -f1)
        path_url=$(echo "$contract" | cut -d'|' -f5)
    fi

    if [ -z "$path_url" ] || [ "$portal_type" = "unknown" ]; then
        log_auto "$profile_name" "path_url atau portal_type tidak valid untuk executor" "ERROR"
        return 1
    fi

    local scripts=$(get_portal_scripts "$portal_type" "$path_url")
    [ $? -ne 0 ] && return 1
    local executor_script_name=$(echo "$scripts" | cut -d'|' -f2)
    local executor_script="/usr/lib/portal/${executor_script_name}"
    [ ! -x "$executor_script" ] && { log_auto "$profile_name" "Executor script tidak ditemukan: $executor_script" "ERROR"; return 1; }
    
    log_auto "$profile_name" "Jalankan executor: $executor_script (portal_type=$portal_type, path_url=$path_url)"
    export LOGICAL="$interface" DEVICE="$device" USERNAME="$username" PASSWORD="$password"
    export PORTAL_URL="$portal_url" GW_ID="$gw_id" CLIENT_MAC="$client_mac"
    export WLAN="$wlan" SESSIONID="$sessionid" IPC="$ipc"
    export PORTAL_TYPE="$portal_type" PATH_URL="$path_url"
    sh "$executor_script" 2>/dev/null
    return $?
}

send_telegram_notification() {
    local profile_file="$1"
    local message="$2"
    local profile_name=$(basename "$profile_file" .json)

    local notif_enabled=$(json_get "$profile_file" "notification.enabled")
    [ "$notif_enabled" != "true" ] && return 0

    local bot_token=$(json_get "$profile_file" "notification.botToken")
    local chat_id=$(json_get "$profile_file" "notification.chatId")

    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        log_auto "$profile_name" "Telegram credentials tidak lengkap, skip notifikasi" "WARN"
        return 1
    fi

    local interface=$(json_get "$profile_file" "interface")
    local device=$(json_get "$profile_file" "device")
    local portal_type=$(json_get "$profile_file" "portal_type")
    local path_url=$(json_get "$profile_file" "path_url")
    local portal_url=$(json_get "$profile_file" "portal_url")
    local login_method=$(json_get "$profile_file" "login_method")
    local sub_method=$(json_get "$profile_file" "sub_method")
    local ipc=$(json_get "$profile_file" "ipc")
    local mac=$(json_get "$profile_file" "mac")
    local gateway=$(json_get "$profile_file" "gateway")

    if [ -z "$sub_method" ]; then
        sub_method=$(json_get "$profile_file" "komunitas")
    fi

    if [ -z "$path_url" ] && [ -n "$portal_url" ]; then
        path_url=$(printf '%s' "$portal_url" | awk -F/ '{print $4}' | cut -d'?' -f1 | head -1)
    fi

    [ -z "$path_url" ] && path_url="Tidak Terdefinisi"
    [ -z "$portal_type" ] && portal_type="Captive Portal"
    [ -z "$login_method" ] && login_method="$path_url"

    [ -z "$interface" ] && interface="Tidak Terdeteksi"
    [ -z "$device" ] && device="Tidak Terdeteksi"

    [ -z "$mac" ] && mac=$(json_get "$profile_file" "client_mac")

    if [ -z "$ipc" ] && [ "$device" != "Tidak Terdeteksi" ]; then
        ipc=$(ip -4 addr show dev "$device" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    fi
    [ -z "$ipc" ] && ipc="Tidak Terdeteksi"

    if [ -z "$mac" ] && [ "$device" != "Tidak Terdeteksi" ]; then
        mac=$(cat "/sys/class/net/$device/address" 2>/dev/null)
    fi
    [ -z "$mac" ] && mac="Tidak Terdeteksi"

    if [ -z "$gateway" ] && [ "$device" != "Tidak Terdeteksi" ]; then
        gateway=$(ip route show dev "$device" 2>/dev/null | awk '/default/{print $3}' | head -1)
    fi
    [ -z "$gateway" ] && gateway="Tidak Terdeteksi"

    if [ -n "$sub_method" ]; then
        sub_method=$(printf '%s' "$sub_method" | tr '\n\r\t' ' ')
        if [ "$sub_method" = "$login_method" ]; then
            sub_method=""
        fi
    fi

    if [ -n "$message" ]; then
        message=$(printf '%s' "$message" | tr '\n\r\t' ' ')
    else
        message="Tidak ada pesan dari portal"
    fi

    local waktu=$(date '+%d-%m-%Y %H:%M:%S')

    local emoji_header=$(printf '\xF0\x9F\x94\x89')
    local emoji_time=$(printf '\xF0\x9F\x95\x90')
    local emoji_portal=$(printf '\xF0\x9F\x8C\x90')
    local emoji_path=$(printf '\xF0\x9F\x93\x82')
    local emoji_interface=$(printf '\xF0\x9F\x93\xB6')
    local emoji_gateway=$(printf '\xF0\x9F\x9B\x9C')
    local emoji_ip=$(printf '\xF0\x9F\x92\xBB')
    local emoji_mac=$(printf '\xF0\x9F\x8F\xB7\xEF\xB8\x8F')
    local emoji_method=$(printf '\xF0\x9F\x94\x91')
    local emoji_sub=$(printf '\xF0\x9F\xA7\xA9')
    local emoji_message=$(printf '\xF0\x9F\x92\xAC')

    local full_message="${emoji_header} INFO AUTO LOGIN ${emoji_header}
====================
${emoji_time} ${waktu}

${emoji_portal} Portal : ${portal_type}
${emoji_path} Path : ${path_url}
${emoji_interface} Interface : ${interface} / ${device}
${emoji_gateway} Gateway : ${gateway}
${emoji_ip} IP : ${ipc}
${emoji_mac} MAC : ${mac}
${emoji_method} Login Method : ${login_method}"

    if [ -n "$sub_method" ]; then
        full_message="${full_message}
${emoji_sub} Sub Method : ${sub_method}"
    fi

    full_message="${full_message}
${emoji_message} Pesan : ${message}"

    log_auto "$profile_name" "Mendelegasikan pengiriman notifikasi Telegram ke telegram_notify.sh (best-effort)"
    sh /usr/lib/portal/telegram_notify.sh "$bot_token" "$chat_id" "$full_message" >/dev/null 2>&1 &
    return 0
}

handle_random_hostname() {
    local profile_file="$1"; local profile_name="$2"
    local hostname_enabled=$(json_get "$profile_file" "randomHostname.enabled")
    [ "$hostname_enabled" != "true" ] && return 0
    local interval=$(json_get "$profile_file" "randomHostname.changeInterval")
    if [ -z "$interval" ]; then
        log_auto "$profile_name" "randomHostname.changeInterval tidak ditemukan, skip" "WARN"
        return 0
    fi
    local last_change=$(uci get system.@system[0].hostname_last_change 2>/dev/null)
    local now=$(date +%s)
    if [ -z "$last_change" ] || [ $((now - last_change)) -ge "$interval" ]; then
        local current_hostname=$(uci get system.@system[0].hostname 2>/dev/null)
        local new_hostname=$(get_random_hostname "$current_hostname")
        if [ -n "$new_hostname" ]; then
            uci set system.@system[0].hostname="$new_hostname" >/dev/null 2>&1
            uci set system.@system[0].hostname_last_change="$now" >/dev/null 2>&1
            uci commit system >/dev/null 2>&1
            hostname "$new_hostname" >/dev/null 2>&1           
            log_auto "$profile_name" "Hostname diganti dan disinkronkan ke runtime: $current_hostname -> $new_hostname"
        fi
    else
        log_auto "$profile_name" "Hostname belum waktunya ganti" "DEBUG"
    fi
}