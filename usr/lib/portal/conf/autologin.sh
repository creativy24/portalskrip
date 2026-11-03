#!/bin/sh
SCRIPT_NAME="autologin.sh"
. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh
. /usr/lib/portal/lib_autologin.sh

PROFILE_DIR="/etc/portal/profiles"
STATE_DIR="/etc/portal/state"

if [ "$1" = "oneshot" ]; then
    PID_FILE="/var/run/portal_autologin_oneshot_$$.pid"
    trap 'rm -f "$PID_FILE" >/dev/null 2>&1; log_auto "SYSTEM" "Oneshot selesai (PID: $$)"' EXIT INT TERM
else
    PID_FILE="/var/run/portal_autologin.pid"
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE" >/dev/null 2>&1; log_auto "SYSTEM" "Daemon berhenti (PID: $$)"' EXIT INT TERM
fi

if [ "$1" != "child" ] && [ "$1" != "oneshot" ]; then
    log_auto "SYSTEM" "DAEMON AUTO-LOGIN DIMULAI (PID: $$)"
    log_auto "SYSTEM" "Interval cek: ${CHECK_INTERVAL:-60} detik"
    log_auto "SYSTEM" "Ping target: ${PING_TARGET:-tidak terdefinisi}"
fi

validate_interface_state() {
    local device="$1"
    local logical="$2"

    if [ ! -d "/sys/class/net/$device" ]; then
        log_auto "$logical" "Device $device tidak ditemukan, skip siklus ini" "WARN"
        return 1
    fi

    local operstate=$(cat "/sys/class/net/$device/operstate" 2>/dev/null)
    if [ "$operstate" != "up" ] && [ "$operstate" != "unknown" ]; then
        log_auto "$logical" "Interface $device tidak UP (state: $operstate), skip siklus ini" "WARN"
        return 1
    fi

    local ip_addr=$(ip -4 addr show dev "$device" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    if [ -z "$ip_addr" ] || [ "$ip_addr" = "0.0.0.0" ] || echo "$ip_addr" | grep -q "^169\.254\."; then
        log_auto "$logical" "Interface $device tidak memiliki IP valid (IP: ${ip_addr:-kosong}), skip siklus ini" "WARN"
        return 1
    fi

    local gateway=$(ip route show dev "$device" 2>/dev/null | awk '/default/{print $3}' | head -1)
    if [ -n "$gateway" ]; then
        if ! ip neigh show dev "$device" 2>/dev/null | grep -q "$gateway"; then
            if ! ping -I "$device" -c 1 -W 1 "$gateway" >/dev/null 2>&1; then
                log_auto "$logical" "Gateway $gateway tidak reachable dari $device, skip siklus ini" "WARN"
                return 1
            fi
        fi
    fi
    
    log_auto "$logical" "Pre-flight validation OK (device=$device, ip=$ip_addr, gw=${gateway:-none})" "DEBUG"
    return 0
}

MAX_CHILD_PROCESSES=5

count_active_children() {
    local count=0
    for lock_dir in /tmp/portal_autologin_*.lifecycle.lock; do
        [ -d "$lock_dir" ] || continue
        local pid_file="$lock_dir/pid"
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                count=$((count + 1))
            fi
        fi
    done
    echo "$count"
}

main_loop() {
    log_auto "SYSTEM" "AUTO LOGIN DIMULAI (PID: $$). Mode: Multi-process terisolasi per-profil (max $MAX_CHILD_PROCESSES simultan)."
    while true; do
        local active_children=$(count_active_children)
        for profile_file in "$PROFILE_DIR"/*.json; do
            [ -f "$profile_file" ] || continue
            
            local profile_name=$(basename "$profile_file" .json)
            local lifecycle_lock="/tmp/portal_autologin_${profile_name}.lifecycle.lock"
            local lifecycle_pid="$lifecycle_lock/pid"
            local is_running=0

            if [ -f "$lifecycle_pid" ]; then
                local child_pid=$(cat "$lifecycle_pid" 2>/dev/null)
                if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
                    is_running=1
                    log_auto "$profile_name" "Child sudah berjalan (PID: $child_pid)" "DEBUG"
                else
                    log_auto "$profile_name" "Stale lifecycle lock terdeteksi (PID: ${child_pid:-kosong}); membersihkan" "WARN"
                    rm -rf "$lifecycle_lock" >/dev/null 2>&1
                fi
            fi

            if [ "$is_running" -eq 0 ]; then
                local enabled=$(json_get "$profile_file" "autoLoginReconnect.enabled")
                if [ "$enabled" != "true" ]; then
                    log_auto "$profile_name" "Auto-login tidak aktif, tidak spawn child" "DEBUG"
                    continue
                fi

                active_children=$(count_active_children)
                if [ "$active_children" -ge "$MAX_CHILD_PROCESSES" ]; then
                    log_auto "$profile_name" "Limit tercapai ($active_children/$MAX_CHILD_PROCESSES), tunda spawn" "WARN"
                    continue
                fi

                local candidate_ip=$(ip -4 addr show dev "$(json_get "$profile_file" "device" 2>/dev/null)" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
                if [ -n "$candidate_ip" ]; then
                    local ip_conflict=0
                    for other_lock in /tmp/portal_autologin_*.lifecycle.lock; do
                        [ -d "$other_lock" ] || continue
                        local other_name=$(basename "$other_lock" | sed 's/^portal_autologin_//; s/\.lifecycle\.lock$//')
                        [ "$other_name" = "$profile_name" ] && continue
                        local other_pid_file="$other_lock/pid"
                        [ -f "$other_pid_file" ] || continue
                        local other_pid=$(cat "$other_pid_file" 2>/dev/null)
                        [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null || continue
                        local other_file="$PROFILE_DIR/${other_name}.json"
                        [ -f "$other_file" ] || continue
                        local other_ip=$(ip -4 addr show dev "$(json_get "$other_file" "device" 2>/dev/null)" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
                        if [ "$other_ip" = "$candidate_ip" ] && [ -n "$other_ip" ]; then
                            ip_conflict=1
                            log_auto "$profile_name" "IP $candidate_ip sudah dipakai oleh profil $other_name, tunda spawn" "WARN"
                            break
                        fi
                    done

                    if [ "$ip_conflict" -eq 1 ]; then
                        continue
                    fi
                fi
                
                sh "$0" child "$profile_name" >/dev/null 2>&1 &
            fi
        done
        sleep 10 >/dev/null 2>&1
    done
}

process_profile() {
    local profile_file="$1"
    local profile_name="$2"
    local auto_enabled=$(json_get "$profile_file" "autoLoginReconnect.enabled")
    [ "$auto_enabled" != "true" ] && { log_auto "$profile_name" "Auto-login tidak aktif"; return 0; }

    local exec_lock="/tmp/portal_autologin_${profile_name}.exec.lock"
    local exec_pid_file="$exec_lock/pid"

    if [ -f "$exec_pid_file" ]; then
        local owner_pid=$(cat "$exec_pid_file" 2>/dev/null)
        if [ -n "$owner_pid" ] && [ "$owner_pid" != "$$" ] && kill -0 "$owner_pid" 2>/dev/null; then
            log_auto "$profile_name" "Proses login/probe sedang berjalan (PID: $owner_pid); skip eksekusi ganda" "WARN"
            return 0
        fi
        log_auto "$profile_name" "Stale exec lock terdeteksi (PID: ${owner_pid:-kosong}); membersihkan" "WARN"
        rm -rf "$exec_lock" >/dev/null 2>&1
    fi

    mkdir -p "$exec_lock"
    echo $$ > "$exec_pid_file"
    trap 'rm -rf "$exec_lock" >/dev/null 2>&1' EXIT INT TERM

    log_auto "$profile_name" "Exec lock diambil (PID: $$)" "DEBUG"
    
    local state_file="$STATE_DIR/${profile_name}.state"
    local current_state=$(read_state "$state_file" "STATE")
    [ -z "$current_state" ] && current_state="first_login"
    
    local interface=$(json_get "$profile_file" "interface")
    local device=$(json_get "$profile_file" "device")
    local portal_type=$(json_get "$profile_file" "portal_type")
    
    if [ -z "$interface" ] || [ -z "$device" ]; then
        log_auto "$profile_name" "interface atau device kosong di profil, skip" "ERROR"
        return 1
    fi

    if ! validate_interface_state "$device" "$profile_name"; then
        log_auto "$profile_name" "Pre-flight validation gagal, menunggu siklus berikutnya" "WARN"
        return 0
    fi

    local current_ip=$(ip -4 addr show dev "$device" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

    if [ -n "$current_ip" ]; then
        for other_lock in /tmp/portal_autologin_*.lifecycle.lock; do
            [ -d "$other_lock" ] || continue
            local other_name=$(basename "$other_lock" | sed 's/^portal_autologin_//; s/\.lifecycle\.lock$//')
            [ "$other_name" = "$profile_name" ] && continue
            local other_pid_file="$other_lock/pid"
            [ -f "$other_pid_file" ] || continue
            local other_pid=$(cat "$other_pid_file" 2>/dev/null)
            [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null || continue
            local other_file="$PROFILE_DIR/${other_name}.json"
            [ -f "$other_file" ] || continue
            local other_device=$(json_get "$other_file" "device" 2>/dev/null)
            local other_ip=$(ip -4 addr show dev "$other_device" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
            if [ "$other_ip" = "$current_ip" ]; then
                log_auto "$profile_name" "IP $current_ip sedang dipakai oleh profil aktif $other_name. Skip siklus." "WARN"
                return 0
            fi
        done
    fi
    if [ -z "$current_ip" ]; then
        log_auto "$profile_name" "Tidak dapat menemukan IP address untuk device $device, skip" "WARN"
        return 1
    fi

    local current_gateway=$(ip route show dev "$device" 2>/dev/null | awk '/default/{print $3}' | head -1)
    [ -z "$current_gateway" ] && current_gateway=$(get_gateway "$device")
    
    if [ -z "$current_gateway" ]; then
        log_auto "$profile_name" "Gateway tidak ditemukan untuk device $device. Skip siklus." "ERROR"
        return 0
    fi

    log_auto "$profile_name" "Real-Time Network Verification via deteksiportal.sh"

    local tmp_probe="/tmp/portal_probe_$$.txt"
    local probe_output=""

    sh /usr/lib/portal/deteksiportal.sh single "$interface" "$device" skip_landing > "$tmp_probe" 2>/dev/null
    local probe_status=$?
    probe_output=$(cat "$tmp_probe" 2>/dev/null)
    rm -f "$tmp_probe" 2>/dev/null

    if [ $probe_status -ne 0 ]; then
        local probe_reason="Detection error"
        if echo "$probe_output" | grep -q '"status":"error"'; then
            probe_reason=$(echo "$probe_output" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
            [ -z "$probe_reason" ] && probe_reason="Detection error"
        fi
        log_auto "$profile_name" "Deteksi gagal: $probe_reason" "ERROR"
        update_state "$state_file" "STATE" "detection_error"
        update_state_audit "$state_file" "check_internet" "failed" "$probe_reason"
        return 1
    fi

    if echo "$probe_output" | grep -q '"portal_url"'; then
        log_auto "$profile_name" "Portal terdeteksi. Memulai proses auto-login."

        local new_portal_url=$(echo "$probe_output" | grep -o '"portal_url":"[^"]*"' | cut -d'"' -f4)
        local new_portal_type=$(echo "$probe_output" | grep -o '"portal_type":"[^"]*"' | cut -d'"' -f4)
        local new_path_url=$(echo "$probe_output" | grep -o '"path_url":"[^"]*"' | cut -d'"' -f4)
        local new_gw_id=$(echo "$probe_output" | grep -o '"gw_id":"[^"]*"' | cut -d'"' -f4)
        local new_client_mac=$(echo "$probe_output" | grep -o '"client_mac":"[^"]*"' | cut -d'"' -f4)
        local new_wlan=$(echo "$probe_output" | grep -o '"wlan":"[^"]*"' | cut -d'"' -f4)
        local new_sessionid=$(echo "$probe_output" | grep -o '"sessionid":"[^"]*"' | cut -d'"' -f4)
        local new_ipc=$(echo "$probe_output" | grep -o '"ipc":"[^"]*"' | cut -d'"' -f4)

        if [ -z "$new_portal_type" ] || [ "$new_portal_type" = "unknown" ] || [ -z "$new_path_url" ]; then
            log_auto "$profile_name" "Portal terdeteksi tetapi kontrak tidak valid" "ERROR"
            update_state "$state_file" "STATE" "detection_error"
            update_state_audit "$state_file" "check_internet" "failed" "Kontrak portal tidak valid"
            return 1
        fi

        local profile_path_url=$(json_get "$profile_file" "path_url")
        local profile_client_mac=$(json_get "$profile_file" "client_mac")
        local profile_mac=$(json_get "$profile_file" "mac")
        local saved_portal_type=$(json_get "$profile_file" "portal_type")
        local saved_portal_url=$(json_get "$profile_file" "portal_url")
        local effective_portal_type="$new_portal_type"
        if [ -n "$saved_portal_type" ] && [ "$saved_portal_type" != "unknown" ]; then
            effective_portal_type="$saved_portal_type"
            if [ "$saved_portal_type" != "$new_portal_type" ]; then
                log_auto "$profile_name" "Mempertahankan pilihan UI (portal_type=$saved_portal_type); mengabaikan deteksi fisik ($new_portal_type)" "INFO"
            fi
        fi

        local effective_path_url="${profile_path_url:-$new_path_url}"
        local effective_client_mac="${profile_client_mac:-$new_client_mac}"
        local final_portal_url="$saved_portal_url"

        if [ -z "$final_portal_url" ]; then
            final_portal_url="$new_portal_url"
        fi

        _replace_query_param() {
            local url="$1"
            local key="$2"
            local val="$3"
            local escaped_val=$(printf '%s' "$val" | sed 's/[&/\]/\\&/g')
            echo "$url" | sed "s/${key}=[^&]*/${key}=${escaped_val}/g"
        }

        if [ -n "$new_gw_id" ]; then
            final_portal_url=$(_replace_query_param "$final_portal_url" "gw_id" "$new_gw_id")
        fi
        
        if [ -n "$new_sessionid" ]; then
            final_portal_url=$(_replace_query_param "$final_portal_url" "sessionid" "$new_sessionid")
        fi
        
        if [ -n "$new_ipc" ]; then
            final_portal_url=$(_replace_query_param "$final_portal_url" "ipc" "$new_ipc")
        fi

        if [ -n "$effective_client_mac" ]; then
            final_portal_url=$(_replace_query_param "$final_portal_url" "client_mac" "$effective_client_mac")
        fi
        
        log_auto "$profile_name" "Portal URL direkonstruksi via string-replacement (base=saved_ui)" "DEBUG"

        set --
        [ -n "$effective_portal_type" ] && set -- "$@" "portal_type" "$effective_portal_type"
        [ -n "$effective_path_url" ] && set -- "$@" "path_url" "$effective_path_url"
        [ -n "$final_portal_url" ] && set -- "$@" "portal_url" "$final_portal_url"
        [ -n "$new_gw_id" ] && set -- "$@" "gw_id" "$new_gw_id"
        [ -n "$new_wlan" ] && set -- "$@" "wlan" "$new_wlan"
        [ -n "$new_sessionid" ] && set -- "$@" "sessionid" "$new_sessionid"
        [ -n "$new_ipc" ] && set -- "$@" "ipc" "$new_ipc"
        [ -n "$effective_client_mac" ] && set -- "$@" "client_mac" "$effective_client_mac"
        [ -n "$profile_mac" ] && set -- "$@" "mac" "$profile_mac"

        portal_type="$effective_portal_type"

        if [ $# -gt 0 ]; then
            log_auto "$profile_name" "Mengupdate profil secara atomik"
            if ! update_json_bulk "$profile_file" "$profile_name" "$@"; then
                log_auto "$profile_name" "Update Profil atomik gagal; login siklus ini dibatalkan" "ERROR"
                update_state_audit "$state_file" "json_update" "failed" "Update JSON atomik gagal untuk $profile_name"
                return 1
            fi
        else
            log_auto "$profile_name" "Tidak ada parameter portal baru untuk diupdate"
        fi

        log_auto "$profile_name" "Profil berhasil diperbarui secara atomik. Siap untuk pra-login."
        local session_file="$STATE_DIR/${profile_name}.state"
        local real_session_file="/etc/portal/portal_session_${profile_name}"
        
        if [ -f "$real_session_file" ]; then
            log_auto "$profile_name" "Menyinkronkan parameter relevan ke file session..." "DEBUG"

            local sync_portal_url=$(json_get "$profile_file" "portal_url")
            local sync_portal_type=$(json_get "$profile_file" "portal_type")
            local sync_path_url=$(json_get "$profile_file" "path_url")
            local sync_mac=$(json_get "$profile_file" "mac")  
            local sync_gw_id=$(json_get "$profile_file" "gw_id")
            local sync_client_mac=$(json_get "$profile_file" "client_mac")
            local sync_wlan=$(json_get "$profile_file" "wlan")
            local sync_sessionid=$(json_get "$profile_file" "sessionid")
            local sync_ipc=$(json_get "$profile_file" "ipc")

            _sync_session_line() {
                local key="$1"
                local val="$2"
                if [ -n "$val" ]; then
                    local escaped_val=$(printf '%s\n' "$val" | sed 's/[&/\]/\\&/g')
                    sed -i "s|^${key}=.*|${key}=${escaped_val}|" "$real_session_file" 2>/dev/null
                fi
            }

            _sync_session_line "portal_url" "$sync_portal_url"
            _sync_session_line "portal_type" "$sync_portal_type"
            _sync_session_line "path_url" "$sync_path_url"
            _sync_session_line "mac" "$sync_mac"
            _sync_session_line "gw_id" "$sync_gw_id"
            _sync_session_line "client_mac" "$sync_client_mac"
            _sync_session_line "wlan" "$sync_wlan"
            _sync_session_line "sessionid" "$sync_sessionid"
            _sync_session_line "ipc" "$sync_ipc"
            
            log_auto "$profile_name" "Sinkronisasi file session selesai." "DEBUG"
        fi

        update_state "$state_file" "STATE" "session_expired"

        local retry_count=$(read_state "$state_file" "RETRY_COUNT")
        [ -z "$retry_count" ] && retry_count=0
        local max_retry=$(json_get "$profile_file" "autoLoginReconnect.retryLimit")
        
        if [ -z "$max_retry" ] || [ "$max_retry" -eq 0 ] 2>/dev/null; then
            log_auto "$profile_name" "retryLimit tidak ada atau 0 di profil, skip auto-login" "WARN"
            return 0
        fi
        
        if [ "$retry_count" -ge "$max_retry" ]; then
            log_auto "$profile_name" "Max retry reached ($retry_count/$max_retry), stop" "WARN"
            update_state "$state_file" "STATE" "max_retry"
            update_state_audit "$state_file" "login" "max_retry" "Max retry tercapai ($retry_count/$max_retry), perlu intervensi manual"
            local notif_enabled=$(json_get "$profile_file" "notification.enabled")
            [ "$notif_enabled" = "true" ] && send_telegram_notification "$profile_file" "Max retry tercapai. Perlu intervensi manual."
            return 0
        fi

        local anti_block_enabled=$(json_get "$profile_file" "antiBlocking.enabled")
        if [ "$anti_block_enabled" = "true" ]; then
            local delay=$(json_get "$profile_file" "antiBlocking.delay")
            if [ -n "$delay" ] && [ "$delay" -gt 0 ] 2>/dev/null; then
                log_auto "$profile_name" "Anti-blocking delay ${delay}s"
                sleep "$delay" >/dev/null 2>&1
            else
                log_auto "$profile_name" "antiBlocking.delay tidak ada atau 0, skip delay" "DEBUG"
            fi
        fi
        
        handle_random_hostname "$profile_file" "$profile_name"
        
        log_auto "$profile_name" "Jalankan pra-login ($portal_type, path=$effective_path_url)"
        if ! run_landing_script "$portal_type" "$profile_file"; then
            log_auto "$profile_name" "Pra-login GAGAL" "ERROR"
            update_state "$state_file" "RETRY_COUNT" "$((retry_count + 1))"
            update_state_audit "$state_file" "landing" "failed" "Pra-login gagal untuk $profile_name"
            local notif_enabled=$(json_get "$profile_file" "notification.enabled")
            [ "$notif_enabled" = "true" ] && send_telegram_notification "$profile_file" "Pra-login gagal untuk $profile_name"
            return 1
        fi
        
        log_auto "$profile_name" "Jalankan login (path=$effective_path_url)"

        local login_output
        login_output=$(run_login_executor "$portal_type" "$profile_file")
        local login_result=$?
        
        update_state "$state_file" "LAST_ATTEMPT" "$(date '+%d-%m-%Y %H:%M:%S')"

        local msg_file="/tmp/${profile_name}_last_login_message.txt"
        local custom_message=""

        if [ -f "$msg_file" ] && [ -s "$msg_file" ]; then
            custom_message=$(cat "$msg_file" 2>/dev/null)
            custom_message=$(printf '%s' "$custom_message" | tr '\n\r' ' ')
            log_auto "$profile_name" "Pesan real-time ditemukan dari server: '$custom_message'" "DEBUG"
        fi

        local final_notif_msg=""
        
        if [ $login_result -eq 0 ]; then
            log_auto "$profile_name" "Login BERHASIL"
            update_state "$state_file" "STATE" "active"
            update_state "$state_file" "RETRY_COUNT" "0"
            update_state "$state_file" "LAST_LOGIN" "$(date '+%d-%m-%Y %H:%M:%S')"
            
            if [ -n "$custom_message" ]; then
                final_notif_msg="$custom_message"
            else
                final_notif_msg="Login berhasil ke $portal_type"
            fi
            
            update_state_audit "$state_file" "login" "success" "$final_notif_msg"
        else
            if echo "$login_output" | grep -qiE "tidak terhubung|No Session found|Login Failed"; then
                log_auto "$profile_name" "Login ditolak sementara oleh server. TIDAK menambah retry count." "WARN"
                update_state_audit "$state_file" "login" "skipped" "Login ditolak sementara, menunggu jaringan stabil"
            else
                retry_count=$((retry_count + 1))
                log_auto "$profile_name" "Login GAGAL (output: $login_output)" "ERROR"
                update_state "$state_file" "STATE" "session_expired"
                update_state "$state_file" "RETRY_COUNT" "$retry_count"
                
                if [ -n "$custom_message" ]; then
                    final_notif_msg="GAGAL: $custom_message"
                else
                    final_notif_msg="GAGAL: $(echo "$login_output" | head -c 100)"
                fi
                
                update_state_audit "$state_file" "login" "failed" "$final_notif_msg"
            fi
        fi

        local notif_enabled=$(json_get "$profile_file" "notification.enabled")
        if [ "$notif_enabled" = "true" ] && [ -n "$final_notif_msg" ]; then
            send_telegram_notification "$profile_file" "$final_notif_msg"
        fi

        rm -f "$msg_file" >/dev/null 2>&1

    else
        log_auto "$profile_name" "Tidak ada portal terdeteksi. Internet aktif."
        update_state "$state_file" "STATE" "active"
        update_state "$state_file" "RETRY_COUNT" "0"
        update_state_audit "$state_file" "check_internet" "success" "Internet aktif"
    fi

    log_auto "$profile_name" "Proses selesai; exec lock akan dilepas otomatis oleh trap" "DEBUG"
}

if [ "$1" = "child" ] && [ -n "$2" ]; then
    child_profile_name="$2"
    child_profile_file="$PROFILE_DIR/${child_profile_name}.json"
    child_lifecycle_lock="/tmp/portal_autologin_${child_profile_name}.lifecycle.lock"
    child_lifecycle_pid="$child_lifecycle_lock/pid"

    mkdir -p "$child_lifecycle_lock" >/dev/null 2>&1
    echo $$ > "$child_lifecycle_pid"
    trap 'rm -rf "$child_lifecycle_lock" >/dev/null 2>&1; log_auto "$child_profile_name" "Child process berakhir"' EXIT INT TERM

    log_auto "$child_profile_name" "Child process dimulai dengan PID mandiri: $$"

    while true; do
        if [ ! -f "$child_profile_file" ]; then
            log_auto "$child_profile_name" "Profil tidak ditemukan/dihapus; child process dihentikan"
            exit 0
        fi

        child_enabled=$(json_get "$child_profile_file" "autoLoginReconnect.enabled")
        if [ "$child_enabled" != "true" ]; then
            log_auto "$child_profile_name" "Auto-login tidak aktif; child process dihentikan"
            exit 0
        fi

        process_profile "$child_profile_file" "$child_profile_name"

        child_interval=$(json_get "$child_profile_file" "autoLoginReconnect.checkInterval")
        if [ -z "$child_interval" ] || [ "$child_interval" -lt 30 ] 2>/dev/null; then 
            child_interval=60
        fi
        if [ "$child_interval" -gt 300 ] 2>/dev/null; then 
            child_interval=300
        fi

        child_jitter=$((RANDOM % 16))
        child_total_sleep=$((child_interval + child_jitter))
        log_auto "$child_profile_name" "Tidur ${child_total_sleep}s (base=${child_interval}s + jitter=${child_jitter}s)" "DEBUG"
        sleep "$child_total_sleep" >/dev/null 2>&1
    done

    exit 0
fi

if [ "$1" = "oneshot" ] && [ -n "$2" ]; then
    os_profile_name="$2"
    os_profile_file="$PROFILE_DIR/${os_profile_name}.json"
    if [ ! -f "$os_profile_file" ]; then
        log_auto "$os_profile_name" "Profil tidak ditemukan: $os_profile_name" "ERROR"
        exit 1
    fi
    log_auto "$os_profile_name" "Mode real-time trigger untuk profil $os_profile_name"

    detect_version
    detect_switch_arch
    init_routing_params
    
    ( process_profile "$os_profile_file" "$os_profile_name" )
    
    log_auto "$os_profile_name" "Selesai memproses $os_profile_name, keluar"
    exit 0
else
    main_loop
fi