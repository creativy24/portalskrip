#!/bin/sh
# Deteksi Captive Portal Multi-WAN
SCRIPT_NAME="deteksiportal.sh"
RUN_ID="$$-$(date '+%s' 2>/dev/null || echo 0)"
PORTAL_RECORDS_FILE="/tmp/portal_records.${RUN_ID}.tmp"
WAN_ENTRIES_TMP="/tmp/wan_entries.${RUN_ID}.tmp"
HTML_SIGNATURES_CONF="/usr/lib/portal/conf/html_signatures.conf"
TAB="$(printf '\t')"
. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh

DETECT_LOCK_PREFIX="/tmp/portal_detect_"
DETECT_LOCK_SUFFIX=".lock"
DETECT_LOCK_TIMEOUT="${DETECT_LOCK_TIMEOUT:-300}"
DETECT_LOCK_PATH=""

acquire_detect_lock() {
    local adl_logical="$1"
    local adl_safe
    adl_safe=$(printf '%s' "$adl_logical" | tr -c 'A-Za-z0-9_.-' '_')
    DETECT_LOCK_PATH="${DETECT_LOCK_PREFIX}${adl_safe}${DETECT_LOCK_SUFFIX}"

    if mkdir "$DETECT_LOCK_PATH" 2>/dev/null; then
        date '+%s' > "$DETECT_LOCK_PATH/started_at" 2>/dev/null || echo "0" > "$DETECT_LOCK_PATH/started_at" 2>/dev/null
        echo $$ > "$DETECT_LOCK_PATH/pid" 2>/dev/null
        return 0
    fi

    local adl_pid
    local adl_started
    local adl_now
    local adl_stale=0

    adl_pid=$(cat "$DETECT_LOCK_PATH/pid" 2>/dev/null)
    adl_started=$(cat "$DETECT_LOCK_PATH/started_at" 2>/dev/null)
    adl_now=$(date '+%s' 2>/dev/null || echo "0")

    case "$adl_started" in
        ''|*[!0-9]*) adl_started="" ;;
    esac

    case "$adl_now" in
        ''|*[!0-9]*) adl_now="0" ;;
    esac

    if [ -z "$adl_pid" ] || ! kill -0 "$adl_pid" 2>/dev/null; then
        adl_stale=1
    elif [ -z "$adl_started" ] || [ "$adl_started" -le 0 ]; then
        adl_stale=1
    elif [ "$adl_now" -gt 0 ] && [ $((adl_now - adl_started)) -ge "$DETECT_LOCK_TIMEOUT" ]; then
        adl_stale=1
    fi

    if [ "$adl_stale" -eq 1 ]; then
        log_auto "$adl_logical" "Membersihkan stale lock deteksi: $DETECT_LOCK_PATH" "WARN"
        rm -rf "$DETECT_LOCK_PATH" >/dev/null 2>&1

        if mkdir "$DETECT_LOCK_PATH" 2>/dev/null; then
            date '+%s' > "$DETECT_LOCK_PATH/started_at" 2>/dev/null || echo "0" > "$DETECT_LOCK_PATH/started_at" 2>/dev/null
            echo $$ > "$DETECT_LOCK_PATH/pid" 2>/dev/null
            return 0
        fi
    fi

    DETECT_LOCK_PATH=""
    return 1
}

release_detect_lock() {
    if [ -n "$DETECT_LOCK_PATH" ]; then
        rm -rf "$DETECT_LOCK_PATH" >/dev/null 2>&1
        DETECT_LOCK_PATH=""
    fi
}

validate_safe_input() {
    local input="$1"
    local name="$2"
    if [ -n "$input" ] && ! printf '%s' "$input" | grep -qE '^[a-zA-Z0-9._:@/?=&%+-]+$'; then
        log_auto "SYSTEM" "Input tidak valid untuk $name: $input" "WARN"
        return 1
    fi
    return 0
}

extract_param() {
    ep_url="$1"
    ep_param="$2"
    ep_value=$(echo "$ep_url" | grep -oE "(^|[?&])${ep_param}=[^&]*" | sed "s/.*=//" | head -1)
    if [ -n "$ep_value" ]; then
        log_auto "SYSTEM" "Ekstrak param: $ep_param = $ep_value" "DEBUG"
    fi
    echo "$ep_value"
}

urlencode_query_value() {
    uv_value="$1"
    uv_mode="${2:-safe}"
    [ -z "$uv_value" ] && return 0

    printf '%s' "$uv_value" | awk -v uv_mode="$uv_mode" '
    BEGIN {
        for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i

        unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-~"
        for (i = 1; i <= length(unreserved); i++) keep[substr(unreserved, i, 1)] = 1

        if (uv_mode == "safe") {
            safe_extra = "/:@!$()*,;"
            for (i = 1; i <= length(safe_extra); i++) keep[substr(safe_extra, i, 1)] = 1
        }
    }
    {
        s = $0
        n = length(s)
        out = ""
        i = 1

        while (i <= n) {
            c = substr(s, i, 1)

            if (c == "%" && i + 2 <= n) {
                hex = substr(s, i + 1, 2)
                if (hex ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
                    out = out c hex
                    i += 3
                    continue
                }
            }

            if (keep[c] == 1) {
                out = out c
            } else {
                out = out sprintf("%%%02X", ord[c])
            }

            i++
        }

        printf "%s", out
    }'
}

append_encoded_query_param() {
    aeqp_query="$1"
    aeqp_name="$2"
    aeqp_value="$3"
    aeqp_mode="${4:-safe}"

    if [ -z "$aeqp_value" ]; then
        printf '%s' "$aeqp_query"
        return 0
    fi

    aeqp_encoded=$(urlencode_query_value "$aeqp_value" "$aeqp_mode")

    if [ -z "$aeqp_query" ]; then
        printf '%s=%s' "$aeqp_name" "$aeqp_encoded"
    else
        printf '%s&%s=%s' "$aeqp_query" "$aeqp_name" "$aeqp_encoded"
    fi
}

match_html_signature() {
    mhs_body="$1"
    [ -z "$mhs_body" ] && return 1
    [ ! -f "$HTML_SIGNATURES_CONF" ] && return 1
    while IFS='|' read -r mhs_type mhs_sig1 mhs_sig2 mhs_sig3 mhs_sig4 mhs_sig5; do
        [ -z "$mhs_type" ] && continue
        case "$mhs_type" in \#*) continue ;; esac
        for mhs_sig in "$mhs_sig1" "$mhs_sig2" "$mhs_sig3" "$mhs_sig4" "$mhs_sig5"; do
            [ -z "$mhs_sig" ] && continue
            if printf '%s' "$mhs_body" | grep -qiF -- "$mhs_sig"; then
                echo "$mhs_type"
                return 0
            fi
        done
    done < "$HTML_SIGNATURES_CONF"
    return 1
}

write_portal_record() {
    wpr_logical="$1"
    wpr_physical="$2"
    wpr_ip="$3"
    wpr_gateway="$4"
    wpr_portal_url="$5"
    wpr_portal_type="$6"
    wpr_gw_id="$7"
    wpr_client_mac="$8"
    wpr_wlan="$9"
    wpr_sessionid="${10}"
    wpr_ipc="${11}"
    wpr_show_params="${12}"
    wpr_path_url="${13}"
    
    wpr_logical=$(printf '%s' "$wpr_logical" | tr '\t' ' ')
    wpr_physical=$(printf '%s' "$wpr_physical" | tr '\t' ' ')
    validate_safe_input "$wpr_logical" "logical" || wpr_logical="unknown"
    validate_safe_input "$wpr_physical" "physical" || wpr_physical="unknown"

    wpr_mac=""
    if [ "$wpr_physical" != "unknown" ]; then
        wpr_mac=$(cat "/sys/class/net/$wpr_physical/address" 2>/dev/null)
    fi
    [ -z "$wpr_mac" ] && wpr_mac="$NULL_MAC"

    [ -z "$wpr_ipc" ] && wpr_ipc="$wpr_ip"

    wpr_ip=$(printf '%s' "$wpr_ip" | tr '\t' ' ')
    wpr_gateway=$(printf '%s' "$wpr_gateway" | tr '\t' ' ')
    validate_safe_input "$wpr_ip" "ip" || wpr_ip="0.0.0.0"
    validate_safe_input "$wpr_gateway" "gateway" || wpr_gateway="0.0.0.0"

    wpr_portal_url=$(printf '%s' "$wpr_portal_url" | tr '\t' ' ')
    wpr_portal_type=$(printf '%s' "$wpr_portal_type" | tr '\t' ' ')
    wpr_path_url=$(printf '%s' "$wpr_path_url" | tr '\t' ' ')
    validate_safe_input "$wpr_path_url" "path_url" || wpr_path_url="unknown"
    validate_safe_input "$wpr_portal_type" "portal_type" || wpr_portal_type="unknown"

    wpr_gw_id=$(printf '%s' "$wpr_gw_id" | tr '\t' ' ')
    wpr_client_mac=$(printf '%s' "$wpr_client_mac" | tr '\t' ' ')
    wpr_wlan=$(printf '%s' "$wpr_wlan" | tr '\t' ' ')
    wpr_sessionid=$(printf '%s' "$wpr_sessionid" | tr '\t' ' ')
    wpr_ipc=$(printf '%s' "$wpr_ipc" | tr '\t' ' ')
    
    log_auto "$wpr_logical" "Tulis catatan portal: MAC=$wpr_mac, tipe=$wpr_portal_type, path_url=$wpr_path_url" "INFO"
    
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$wpr_logical" "$wpr_physical" "$wpr_ip" "$wpr_gateway" "$wpr_mac" "$wpr_portal_url" "$wpr_portal_type" "$wpr_path_url" \
        "$wpr_gw_id" "$wpr_client_mac" "$wpr_wlan" "$wpr_sessionid" "$wpr_ipc" "$wpr_show_params" \
        >> "$PORTAL_RECORDS_FILE"
}

cleanup_routing() {
    cleanup_temp_routing
}

check_captive_portal() {
    ccp_logical="$1"
    ccp_physical="$2"
    ccp_ip="$3"
    ccp_gateway="$4"

    if [ -z "$ccp_gateway" ] || [ "$ccp_gateway" = "$NULL_GATEWAY" ]; then
        log_auto "$ccp_logical" "Gateway tidak valid (kosong/NULL_GATEWAY), deteksi portal tidak dapat dilakukan dengan aman" "WARN"
        return 1
    fi

    if ! setup_temp_routing "$ccp_logical" "$ccp_ip" "$ccp_gateway" "$ccp_physical"; then
        log_auto "$ccp_logical" "Gagal menyiapkan routing sementara terisolasi" "ERROR"
        return 1
    fi
    
    ccp_portal_detected=0
    ccp_portal_url=""
    ccp_test_url=$(random_endpoint)
    [ -z "$ccp_test_url" ] && { cleanup_routing "$ccp_gateway" "$ccp_ip" "$ccp_logical"; return 1; }

    fallback_domain="$ccp_test_url"
    case "$fallback_domain" in
        *://*) fallback_domain="${fallback_domain#*://}" ;;
    esac
    fallback_domain="${fallback_domain%%/*}"

    if [ -z "$fallback_domain" ]; then
        log_auto "$ccp_logical" "Gagal mengekstrak host probe dari test_url: $ccp_test_url" "ERROR"
        cleanup_routing "$ccp_gateway" "$ccp_ip" "$ccp_logical"
        return 1
    fi

    ccp_fallback_url="http://${ccp_gateway}/"
    log_auto "$ccp_logical" "Probe endpoints Host: $fallback_domain" "INFO"
    
    ccp_response=$(curl -s -i --retry 0 --connect-timeout 2 --max-time 3 \
        --interface "$ccp_physical" \
        -H "Host: ${fallback_domain}" \
        "$ccp_fallback_url" 2>/dev/null)
        
    ccp_http_status=$(echo "$ccp_response" | head -1 | awk '{print $2}')

    if [ "$ccp_http_status" = "204" ]; then
        cleanup_routing "$ccp_gateway" "$ccp_ip" "$ccp_logical"; return 1
    fi

    if [ "$ccp_http_status" = "301" ] || [ "$ccp_http_status" = "302" ] || [ "$ccp_http_status" = "303" ] || [ "$ccp_http_status" = "307" ] || [ "$ccp_http_status" = "308" ]; then
        ccp_redirect_url=$(echo "$ccp_response" | grep -i '^Location:' | head -1 | sed 's/^Location: //i' | tr -d '\r')
        case "$ccp_redirect_url" in
            http://*|https://*)
                ccp_portal_url="$ccp_redirect_url"
                ;;
            //*)
                ccp_portal_url="http:${ccp_redirect_url}"
                ;;
            /*)
                ccp_portal_url="http://${ccp_gateway}${ccp_redirect_url}"
                ;;
            *)
                ccp_portal_url="http://${ccp_gateway}/${ccp_redirect_url}"
                ;;
        esac
        
        if ! printf '%s' "$ccp_portal_url" | grep -qE '(^|[?&])dst='; then
            encoded_dst=$(urlencode_query_value "$ccp_test_url" "strict")
            if printf '%s' "$ccp_portal_url" | grep -q '?'; then
                ccp_portal_url="${ccp_portal_url}&dst=${encoded_dst}"
            else
                ccp_portal_url="${ccp_portal_url}?dst=${encoded_dst}"
            fi
            log_auto "$ccp_logical" "Parameter dst ditambahkan secara terisolasi" "DEBUG"
        fi
      
        ccp_portal_detected=1
        log_auto "$ccp_logical" "Portal terdeteksi redirect $ccp_http_status" "INFO"
    else
        ccp_body_sample=""
        if [ "$ccp_http_status" = "200" ]; then
            ccp_body_sample=$(printf '%s' "$ccp_response" | awk 'BEGIN{found=0} /^[[:space:]]*$/{found=1; next} found{print}' | head -c 2048)
        fi

        ccp_signature_type=""
        if [ -n "$ccp_body_sample" ]; then
            ccp_signature_type=$(match_html_signature "$ccp_body_sample")
        fi

        if [ -n "$ccp_signature_type" ]; then
            ccp_default_path=$(portal_contract_default_url_path "$ccp_signature_type")
            if [ -n "$ccp_default_path" ]; then
                ccp_portal_url="http://${ccp_gateway}/${ccp_default_path}/"
                encoded_dst=$(urlencode_query_value "$ccp_test_url" "strict")
                ccp_portal_url="${ccp_portal_url}?dst=${encoded_dst}"
                ccp_portal_detected=1
                log_auto "$ccp_logical" "Portal terdeteksi via signature HTTP $ccp_http_status (type=$ccp_signature_type, path=$ccp_default_path)" "INFO"
            else
                log_auto "$ccp_logical" "Signature portal cocok ($ccp_signature_type) tetapi default path tidak ditemukan di portal_types.conf" "WARN"
            fi
        fi

        if [ "$ccp_portal_detected" -eq 0 ]; then
            log_auto "$ccp_logical" "Tidak ada portal pada Interface atau offline $ccp_http_status." "INFO"
        fi
    fi
    
    if [ "$ccp_portal_detected" -eq 1 ] && [ -n "$ccp_portal_url" ]; then
        ccp_portal_body=$(curl -s --retry 0 --connect-timeout 1 --max-time 1 --interface "$ccp_physical" "$ccp_portal_url" 2>/dev/null | head -c 2048)
        ccp_contract_result=$(portal_contract_match_url "$ccp_portal_url" "$ccp_portal_body")
        ccp_portal_type=$(echo "$ccp_contract_result" | cut -d'|' -f1)
        ccp_show_params=$(echo "$ccp_contract_result" | cut -d'|' -f2)
        ccp_corrected_path=$(echo "$ccp_contract_result" | cut -d'|' -f3)
        ccp_encode_type=$(echo "$ccp_contract_result" | cut -d'|' -f4)
        ccp_path_url=$(echo "$ccp_contract_result" | cut -d'|' -f5)
        ccp_landing_script_name=$(echo "$ccp_contract_result" | cut -d'|' -f6)
        ccp_login_executor_name=$(echo "$ccp_contract_result" | cut -d'|' -f7)
        
        ccp_show_params="${ccp_show_params:-0}"
        ccp_encode_type="${ccp_encode_type:-spaces}"

        if [ "$ccp_portal_type" = "unknown" ] || [ -z "$ccp_path_url" ] || [ -z "$ccp_landing_script_name" ] || [ -z "$ccp_login_executor_name" ]; then
            log_auto "$ccp_logical" "Portal tidak resmi atau path_url tidak valid, tolak sejak deteksi" "WARN"
            ccp_portal_detected=0
            cleanup_routing "$ccp_gateway" "$ccp_ip" "$ccp_logical"
            return 0
        fi

        ccp_gw_id=$(extract_param "$ccp_portal_url" "gw_id")
        ccp_client_mac=$(extract_param "$ccp_portal_url" "client_mac")
        ccp_wlan=$(extract_param "$ccp_portal_url" "wlan")
        ccp_sessionid=$(extract_param "$ccp_portal_url" "sessionid")
        ccp_ipc=$(extract_param "$ccp_portal_url" "ipc")
        [ -z "$ccp_ipc" ] && ccp_ipc="$ccp_ip"
        
        ccp_detected_path=$(echo "$ccp_portal_url" | awk -F'://' '{print $2}' | awk -F'/' '{print $2}' | awk -F'?' '{print $1}')
        
        if [ -n "$ccp_gw_id" ] && [ -n "$ccp_client_mac" ] && [ -n "$ccp_sessionid" ]; then
            [ -z "$ccp_corrected_path" ] && ccp_corrected_path="$ccp_detected_path"
            ccp_domain_final=$(echo "$ccp_portal_url" | awk -F'://' '{print $2}' | awk -F'/' '{print $1}')
            
            ccp_new_query=""
            ccp_new_query=$(append_encoded_query_param "$ccp_new_query" "gw_id" "$ccp_gw_id" "safe")
            ccp_new_query=$(append_encoded_query_param "$ccp_new_query" "client_mac" "$ccp_client_mac" "safe")
            ccp_new_query=$(append_encoded_query_param "$ccp_new_query" "wlan" "$ccp_wlan" "strict")
            ccp_new_query=$(append_encoded_query_param "$ccp_new_query" "sessionid" "$ccp_sessionid" "safe")

            if [ "$ccp_portal_type" != "wms" ]; then
                ccp_new_query=$(append_encoded_query_param "$ccp_new_query" "ipc" "$ccp_ipc" "safe")
            fi

            ccp_portal_url="https://${ccp_domain_final}/${ccp_corrected_path}/"
            [ -n "$ccp_new_query" ] && ccp_portal_url="${ccp_portal_url}?${ccp_new_query}"

            log_auto "$ccp_logical" "Query portal dinormalisasi (contract encode hint: ${ccp_encode_type:-spaces})" "DEBUG"
        fi
        
        write_portal_record "$ccp_logical" "$ccp_physical" "$ccp_ip" "$ccp_gateway" "$ccp_portal_url" "$ccp_portal_type" \
            "$ccp_gw_id" "$ccp_client_mac" "$ccp_wlan" "$ccp_sessionid" "$ccp_ipc" "$ccp_show_params" "$ccp_path_url"
    fi

    cleanup_routing "$ccp_gateway" "$ccp_ip" "$ccp_logical"
    return $ccp_portal_detected
}

build_json_output() {
    log_auto "SYSTEM" "Cek Output Portal dari $PORTAL_RECORDS_FILE" "INFO"

    if [ ! -s "$PORTAL_RECORDS_FILE" ]; then
        printf '{"interfaces":[]}\n'
        log_auto "SYSTEM" "Output Portal kosong" "INFO"
        return
    fi

    bjo_tmp="${PORTAL_RECORDS_FILE}.json.tmp"
    bjo_first=1

    printf '{"interfaces":[' > "$bjo_tmp"

    while IFS="$TAB" read -r bjo_logical bjo_physical bjo_ip bjo_gateway bjo_mac bjo_portal_url bjo_portal_type bjo_path_url bjo_gw_id bjo_client_mac bjo_wlan bjo_sessionid bjo_ipc bjo_show_params; do
        [ -z "$bjo_logical" ] && continue

        bjo_logical=$(json_escape "$bjo_logical")
        bjo_physical=$(json_escape "$bjo_physical")
        bjo_ip=$(json_escape "$bjo_ip")
        bjo_gateway=$(json_escape "$bjo_gateway")
        bjo_mac=$(json_escape "$bjo_mac")
        bjo_portal_url=$(json_escape "$bjo_portal_url")
        bjo_portal_type=$(json_escape "${bjo_portal_type:-unknown}")
        bjo_path_url=$(json_escape "${bjo_path_url:-unknown}")
        bjo_gw_id=$(json_escape "${bjo_gw_id:-}")
        bjo_client_mac=$(json_escape "${bjo_client_mac:-}")
        bjo_wlan=$(json_escape "${bjo_wlan:-}")
        bjo_sessionid=$(json_escape "${bjo_sessionid:-}")
        bjo_ipc=$(json_escape "${bjo_ipc:-}")

        case "${bjo_show_params:-0}" in
            0|1)
                bjo_show_params="${bjo_show_params:-0}"
                ;;
            *)
                bjo_show_params=0
                ;;
        esac

        [ "$bjo_first" -eq 0 ] && printf ',' >> "$bjo_tmp"
        bjo_first=0

        printf '{"interface":"%s","device":"%s","ip":"%s","gateway":"%s","mac":"%s","status":"Portal_Login","portal_type":"%s","path_url":"%s","portal_url":"%s","show_params":%s' \
            "$bjo_logical" "$bjo_physical" "$bjo_ip" "$bjo_gateway" "$bjo_mac" "$bjo_portal_type" "$bjo_path_url" "$bjo_portal_url" \
            "$bjo_show_params" >> "$bjo_tmp"

        if [ -n "$bjo_gw_id" ] && [ -n "$bjo_client_mac" ] && [ -n "$bjo_sessionid" ]; then
            printf ',"gw_id":"%s","client_mac":"%s","wlan":"%s","sessionid":"%s","ipc":"%s"' \
                "$bjo_gw_id" "$bjo_client_mac" "$bjo_wlan" "$bjo_sessionid" "$bjo_ipc" >> "$bjo_tmp"
        fi

        printf '}' >> "$bjo_tmp"
        log_auto "$bjo_logical" "Data Portal ditambahkan" "DEBUG"
    done < "$PORTAL_RECORDS_FILE"

    printf ']}\n' >> "$bjo_tmp"

    if command -v jsonfilter >/dev/null 2>&1; then
        if ! jsonfilter -i "$bjo_tmp" -e '@' >/dev/null 2>&1; then
            log_auto "SYSTEM" "Output JSON deteksi tidak valid, kembalikan kosong" "ERROR"
            printf '{"interfaces":[]}\n'
            rm -f "$bjo_tmp"
            return
        fi
    fi

    cat "$bjo_tmp"
    rm -f "$bjo_tmp"
    log_auto "SYSTEM" "Data Portal selesai dibuat" "INFO"
}

main() {
	trap 'cleanup_temp_routing >/dev/null 2>&1; release_detect_lock >/dev/null 2>&1; rm -f "$PORTAL_RECORDS_FILE" "$WAN_ENTRIES_TMP" "${PORTAL_RECORDS_FILE}.json.tmp" >/dev/null 2>&1' EXIT
	trap 'exit 143' TERM
	trap 'exit 130' INT
	
    if [ "$1" = "refresh_params" ] && [ -n "$2" ] && [ -n "$3" ]; then
        rp_logical="$2"
        rp_device="$3"
        
        if ! acquire_detect_lock "$rp_logical"; then
            log_auto "$rp_logical" "Lock interface sudah ada, deteksi sedang berjalan" "WARN"
            echo '{"status":"error","message":"Detection already in progress for interface"}'
            exit 1
        fi
        
        log_auto "$rp_logical" "Mode refresh_params untuk $rp_logical ($rp_device)" "INFO"
        detect_version
        detect_switch_arch
        init_routing_params
        rm -f "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
        touch "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
        chmod 600 "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
        
        rp_entries=$(get_wan_info)
        rp_ip=""; rp_gw=""
        while read -r rp_l rp_p rp_i rp_g; do
            if [ "$rp_l" = "$rp_logical" ]; then
                rp_ip="$rp_i"
                rp_gw="$rp_g"
                break
            fi
        done <<EOF
$rp_entries
EOF
        if [ -z "$rp_ip" ] || [ -z "$rp_gw" ]; then
            log_auto "$rp_logical" "Tidak dapat menemukan IP/gateway" "ERROR"
            echo '{"status":"error","message":"Interface not found"}'
            exit 1
        fi
        
        check_captive_portal "$rp_logical" "$rp_device" "$rp_ip" "$rp_gw"
        build_json_output
        release_detect_lock
        exit 0
    fi

    if [ "$1" = "single" ] && [ -n "$2" ] && [ -n "$3" ]; then
        single_logical="$2"
        single_device="$3"
        
        if ! acquire_detect_lock "$single_logical"; then
            log_auto "$single_logical" "Lock interface sudah ada, deteksi sedang berjalan" "WARN"
            echo '{"status":"error","message":"Detection already in progress for interface"}'
            exit 1
        fi
        
        log_auto "$single_logical" "Mendeteksi single interface: $single_logical ($single_device)" "INFO"
        detect_version
        detect_switch_arch
        init_routing_params
        rm -f "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
        touch "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
        chmod 600 "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
        mn_entries=$(get_wan_info)
        single_ip=""; single_gw=""
        while read -r mn_logical mn_physical mn_ip mn_gw; do
            if [ "$mn_logical" = "$single_logical" ]; then
                single_ip="$mn_ip"
                single_gw="$mn_gw"
                break
            fi
        done <<EOF
$mn_entries
EOF
        if [ -z "$single_ip" ] || [ -z "$single_gw" ]; then
            log_auto "$single_logical" "Tidak dapat menemukan IP/gateway" "ERROR"
            echo '{"interfaces":[]}'
            exit 1
        fi

        check_captive_portal "$single_logical" "$single_device" "$single_ip" "$single_gw"
        build_json_output
        release_detect_lock
        exit 0
    fi

    log_auto "SYSTEM" "Mendeteksi Captive Portal (Multi-WAN)" "INFO"
    detect_version
    detect_switch_arch
    init_routing_params

    rm -f "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
    touch "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
    chmod 600 "$PORTAL_RECORDS_FILE" >/dev/null 2>&1
    log_auto "SYSTEM" "Data Output Portal siap di $PORTAL_RECORDS_FILE" "INFO"

    mn_entries=$(get_wan_info)
    if [ -z "$mn_entries" ]; then
        log_auto "SYSTEM" "Tidak ada WAN dari ubus, coba fallback dengan get_rep_if" "WARN"
        mn_rep_if=$(get_rep_if)
        if [ -n "$mn_rep_if" ]; then
            mn_rep_ip=$(ip -4 addr show dev "$mn_rep_if" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
            mn_rep_gw=$(get_gateway "$mn_rep_if")
            if [ -n "$mn_rep_ip" ] && [ -n "$mn_rep_gw" ]; then
                mn_entries="${mn_rep_if} ${mn_rep_if} ${mn_rep_ip} ${mn_rep_gw}"
                log_auto "$mn_rep_if" "Fallback berhasil, gunakan $mn_rep_if" "INFO"
            fi
        fi
        if [ -z "$mn_entries" ]; then
            log_auto "SYSTEM" "Tidak ada interface valid, deteksi dihentikan" "ERROR"
            echo '{"interfaces":[]}'
            exit 0
        fi
    fi
    entries="$mn_entries"
    mn_total_ifaces=$(echo "$entries" | wc -l)
    log_auto "SYSTEM" "Total interface yang akan diperiksa: $mn_total_ifaces" "INFO"

    echo "$entries" > "$WAN_ENTRIES_TMP"
    while read -r mn_logical mn_physical mn_ip mn_gw; do
        [ -z "$mn_logical" ] && continue

        if ! acquire_detect_lock "$mn_logical"; then
            log_auto "$mn_logical" "Lock interface sudah ada, lewati deteksi" "WARN"
            continue
        fi

        log_auto "$mn_logical" "Proses interface: $mn_logical" "INFO"
        check_captive_portal "$mn_logical" "$mn_physical" "$mn_ip" "$mn_gw"
        release_detect_lock
    done < "$WAN_ENTRIES_TMP"

    if [ -s "$PORTAL_RECORDS_FILE" ]; then
        mn_portal_count=$(wc -l < "$PORTAL_RECORDS_FILE" 2>/dev/null)
        log_auto "SYSTEM" "$mn_portal_count dari $mn_total_ifaces interface terdeteksi portal" "INFO"
    else
        log_auto "SYSTEM" "Tidak ada portal ditemukan" "INFO"
    fi

    build_json_output

    if [ "$4" != "skip_landing" ]; then
        if [ -s "$PORTAL_RECORDS_FILE" ]; then
            while IFS="$TAB" read -r mn_logical mn_physical mn_ip mn_gateway mn_mac mn_portal_url mn_portal_type mn_path_url mn_gw_id mn_client_mac mn_wlan mn_sessionid mn_ipc mn_show_params; do
                [ -z "$mn_portal_url" ] && continue

                mn_detected_path=$(printf '%s' "$mn_portal_url" | awk -F'://' '{print $2}' | awk -F'/' '{print $2}' | awk -F'?' '{print $1}')
                mn_landing_path="$mn_path_url"
                [ -z "$mn_landing_path" ] && mn_landing_path="$mn_detected_path"

                mn_landing_script=""
                mn_contract_scripts=$(portal_contract_lookup_identity "$mn_portal_type" "$mn_landing_path")
                if [ -n "$mn_contract_scripts" ]; then
                    mn_landing_script_name=$(printf '%s' "$mn_contract_scripts" | cut -d'|' -f1)
                    mn_landing_script="/usr/lib/portal/landing/$mn_landing_script_name"
                fi

                if [ -n "$mn_landing_script" ] && [ -x "$mn_landing_script" ]; then
                    log_auto "$mn_logical" "Menjalankan landing script $mn_landing_script di background (portal_type=$mn_portal_type, path_url=$mn_landing_path)" "INFO"
                    ( exec env PORTAL_TYPE="$mn_portal_type" PATH_URL="$mn_landing_path" sh "$mn_landing_script" "$mn_portal_url" "$mn_ip" "$mn_landing_path" "$mn_gateway" "${mn_ipc:-$mn_ip}" "$mn_logical" "$mn_physical" >/dev/null 2>&1 ) &
                else
                    log_auto "$mn_logical" "Landing script tidak ditemukan untuk tipe=$mn_portal_type path_url=$mn_landing_path" "WARN"
                fi
            done < "$PORTAL_RECORDS_FILE"
        fi
    else
        log_auto "SYSTEM" "Mode quick_scan/edit: Melewati eksekusi landing script untuk menghemat sumber daya." "INFO"
    fi

    log_auto "SYSTEM" "Deteksi Captive Portal selesai" "INFO"
}

main "$@"