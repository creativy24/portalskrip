#!/bin/sh
# mwan3_watchdog.sh — Watchdog mwan3: reset state, pulih terukur, verifikasi cepat

SCRIPT_NAME="mwan3_watchdog.sh"
WD_CONF_PACKAGE="mwan3_watchdog"
LOGGER_TAG_DEFAULT="mwan3_watchdog"
LOGGER_TAG="$LOGGER_TAG_DEFAULT"

now() {
    date +%s 2>/dev/null || printf '0'
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_true() {
    case "$1" in
        1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
        *) return 1 ;;
    esac
}

uint_or_default() {
    local value="$1" default="$2"
    if is_uint "$value"; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

percent_or_default() {
    local value="$1" default="$2"
    if is_uint "$value" && [ "$value" -le 100 ]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

cfg_get() {
    local option="$1" default="$2" value=""
    if command -v uci >/dev/null 2>&1; then
        value=$(uci -q get "${WD_CONF_PACKAGE}.globals.${option}" 2>/dev/null)
    fi
    if [ -n "$value" ]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

log_msg() {
    local level="$1" profile="$2"
    shift 2
    [ -z "$profile" ] && profile="SISTEM"
    logger -t "$LOGGER_TAG" "$level | $SCRIPT_NAME | [$profile] $*" >/dev/null 2>&1
}

current_pid() {
    local stat_line pid
    if [ -r /proc/self/stat ]; then
        read -r stat_line < /proc/self/stat 2>/dev/null
        pid=${stat_line%% *}
        if is_uint "$pid"; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    printf '%s' "$$"
}

valid_iface() {
    case "$1" in
        '') return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

count_words() {
    local n=0 w
    for w in $1; do
        n=$((n + 1))
    done
    printf '%s' "$n"
}

sequence_item() {
    local seq="$1" idx="$2" i=1 s
    for s in $seq; do
        if [ "$i" -eq "$idx" ]; then
            printf '%s' "$s"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

_interruptible_sleep() {
    local total="$1" i=0
    is_uint "$total" || total=0
    while [ "$i" -lt "$total" ]; do
        sleep 1
        i=$((i + 1))
    done
}

ENABLED=$(cfg_get enabled 1)
CHECK_INTERVAL=$(uint_or_default "$(cfg_get check_interval 60)" 60)
STABILIZE_INTERVAL=$(uint_or_default "$(cfg_get stabilize_interval 15)" 15)
STABILIZE_SECONDS=$(uint_or_default "$(cfg_get stabilize_seconds 30)" 30)
FAILURE_THRESHOLD=$(uint_or_default "$(cfg_get failure_threshold 2)" 2)
HEAL_COOLDOWN=$(uint_or_default "$(cfg_get heal_cooldown 30)" 30)
HEAL_RETRY_INTERVAL=$(uint_or_default "$(cfg_get heal_retry_interval 15)" 15)
HEAL_SETTLE=$(uint_or_default "$(cfg_get heal_settle 5)" 5)
HEAL_STOP_SLEEP=$(uint_or_default "$(cfg_get heal_stop_sleep 2)" 2)
HEAL_TIMEOUT=$(uint_or_default "$(cfg_get heal_timeout 30)" 30)
MAX_HEAL_ATTEMPTS=$(uint_or_default "$(cfg_get max_heal_attempts 2)" 2)
HEAL_SEQUENCE=$(cfg_get heal_sequence 'restart stop_start')
HEAL_FLUSH_CONNTRACK=$(cfg_get heal_flush_conntrack 0)
MAX_GLOBAL_HEALS=$(uint_or_default "$(cfg_get max_global_heals 3)" 3)
GLOBAL_HEAL_WINDOW=$(uint_or_default "$(cfg_get global_heal_window 300)" 300)
GLOBAL_MUTE_TIME=$(uint_or_default "$(cfg_get global_mute_time 300)" 300)
LOCK_STALE_SECONDS=$(uint_or_default "$(cfg_get lock_stale_seconds 300)" 300)
PROBE_SUCCESS_PERCENT=$(percent_or_default "$(cfg_get probe_success_percent 80)" 80)
VERIFY_COUNT=$(uint_or_default "$(cfg_get verify_count 3)" 3)
VERIFY_TIMEOUT=$(uint_or_default "$(cfg_get verify_timeout 2)" 2)
MAX_PARALLEL_WORKERS=$(uint_or_default "$(cfg_get max_parallel_workers 2)" 2)
WORKER_TIMEOUT=$(uint_or_default "$(cfg_get worker_timeout 90)" 90)
RUN_DIR=$(cfg_get run_dir /var/run/mwan3_watchdog)
LOCK_ROOT=$(cfg_get lock_root /var/lock/mwan3_watchdog)
STATE_DIR=$(cfg_get state_dir "$RUN_DIR/state")
TRACK_STATUS_DIR=$(cfg_get track_status_dir /var/run/mwan3track)
MWAN3_INIT=$(cfg_get mwan3_init /etc/init.d/mwan3)
RTMON_PATTERN=$(cfg_get rtmon_pattern /usr/sbin/mwan3rtmon)
LOGGER_TAG=$(cfg_get logger_tag "$LOGGER_TAG_DEFAULT")

if [ "$CHECK_INTERVAL" -lt 30 ]; then CHECK_INTERVAL=30; fi
if [ "$STABILIZE_INTERVAL" -lt 5 ]; then STABILIZE_INTERVAL=5; fi
if [ "$STABILIZE_SECONDS" -lt 10 ]; then STABILIZE_SECONDS=10; fi
if [ "$FAILURE_THRESHOLD" -lt 1 ]; then FAILURE_THRESHOLD=1; fi
if [ "$HEAL_COOLDOWN" -lt 10 ]; then HEAL_COOLDOWN=10; fi
if [ "$HEAL_RETRY_INTERVAL" -lt 5 ]; then HEAL_RETRY_INTERVAL=5; fi
if [ "$HEAL_SETTLE" -lt 1 ]; then HEAL_SETTLE=1; fi
if [ "$HEAL_STOP_SLEEP" -lt 1 ]; then HEAL_STOP_SLEEP=1; fi
if [ "$HEAL_TIMEOUT" -lt 5 ]; then HEAL_TIMEOUT=5; fi
if [ "$MAX_HEAL_ATTEMPTS" -lt 1 ]; then MAX_HEAL_ATTEMPTS=1; fi
if [ "$MAX_GLOBAL_HEALS" -lt 1 ]; then MAX_GLOBAL_HEALS=1; fi
if [ "$GLOBAL_HEAL_WINDOW" -lt 60 ]; then GLOBAL_HEAL_WINDOW=60; fi
if [ "$GLOBAL_MUTE_TIME" -lt 60 ]; then GLOBAL_MUTE_TIME=60; fi
if [ "$LOCK_STALE_SECONDS" -lt 30 ]; then LOCK_STALE_SECONDS=30; fi
if [ "$PROBE_SUCCESS_PERCENT" -lt 1 ]; then PROBE_SUCCESS_PERCENT=1; fi
if [ "$VERIFY_COUNT" -lt 1 ]; then VERIFY_COUNT=1; fi
if [ "$VERIFY_TIMEOUT" -lt 1 ]; then VERIFY_TIMEOUT=1; fi
if [ "$MAX_PARALLEL_WORKERS" -lt 1 ]; then MAX_PARALLEL_WORKERS=1; fi
if [ "$MAX_PARALLEL_WORKERS" -gt 4 ]; then MAX_PARALLEL_WORKERS=4; fi
if [ "$WORKER_TIMEOUT" -lt 30 ]; then WORKER_TIMEOUT=30; fi
if is_true "$HEAL_FLUSH_CONNTRACK"; then HEAL_FLUSH_CONNTRACK=1; else HEAL_FLUSH_CONNTRACK=0; fi

for cmd in uci logger ping pgrep date awk sed grep mkdir rm cat mv ln sleep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_msg ERROR SISTEM "Dependensi hilang: $cmd"
        exit 0
    fi
done

MWAN3_BIN=$(cfg_get mwan3_bin "")
if [ -n "$MWAN3_BIN" ] && [ ! -x "$MWAN3_BIN" ]; then
    MWAN3_BIN=""
fi
if [ -z "$MWAN3_BIN" ]; then
    MWAN3_BIN=$(command -v mwan3 2>/dev/null)
fi
if [ -z "$MWAN3_BIN" ]; then
    log_msg ERROR SISTEM "Dependensi hilang: mwan3"
    exit 0
fi

if ! is_true "$ENABLED"; then
    log_msg INFO SISTEM "Watchdog nonaktif"
    exit 0
fi

mkdir -p "$LOCK_ROOT" "$RUN_DIR" >/dev/null 2>&1 || {
    log_msg ERROR SISTEM "Gagal buat direktori runtime"
    exit 0
}

lock_acquire_file() {
    local lock="$1" tmp data pid ts age cur now_ts
    tmp="$lock.tmp.$(current_pid)"

    if ! printf '%s %s\n' "$(current_pid)" "$(now)" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" >/dev/null 2>&1
        return 1
    fi

    if ln "$tmp" "$lock" >/dev/null 2>&1; then
        rm -f "$tmp" >/dev/null 2>&1
        return 0
    fi

    rm -f "$tmp" >/dev/null 2>&1

    data=$(cat "$lock" 2>/dev/null)
    [ -z "$data" ] && return 1

    pid=${data%% *}
    ts=${data##* }
    if ! is_uint "$pid" || ! is_uint "$ts"; then
        return 1
    fi

    cur=$(current_pid)
    if [ "$pid" = "$cur" ]; then
        return 0
    fi

    if kill -0 "$pid" >/dev/null 2>&1; then
        now_ts=$(now)
        age=$((now_ts - ts))
        if [ "$age" -lt "$LOCK_STALE_SECONDS" ]; then
            return 1
        fi
    fi

    rm -f "$lock" >/dev/null 2>&1
    tmp="$lock.tmp.$(current_pid)"
    if printf '%s %s\n' "$(current_pid)" "$(now)" > "$tmp" 2>/dev/null; then
        if ln "$tmp" "$lock" >/dev/null 2>&1; then
            rm -f "$tmp" >/dev/null 2>&1
            return 0
        fi
        rm -f "$tmp" >/dev/null 2>&1
    fi
    return 1
}

lock_release_file() {
    local lock="$1" data pid
    data=$(cat "$lock" 2>/dev/null)
    [ -z "$data" ] && return 0
    pid=${data%% *}
    if [ "$pid" = "$(current_pid)" ]; then
        rm -f "$lock" >/dev/null 2>&1
    fi
    return 0
}

state_read() {
    local iface="$1" key="$2" default="$3" value
    valid_iface "$iface" || {
        printf '%s' "$default"
        return 1
    }
    value=$(cat "$STATE_DIR/$iface/$key" 2>/dev/null)
    if [ -n "$value" ]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

state_write() {
    local iface="$1" key="$2" value="$3" dir
    valid_iface "$iface" || return 1
    dir="$STATE_DIR/$iface"
    mkdir -p "$dir" >/dev/null 2>&1 || return 1
    printf '%s\n' "$value" > "$dir/$key" 2>/dev/null
}

global_read() {
    state_read "_global" "$1" "$2"
}

global_write() {
    state_write "_global" "$1" "$2"
}

is_mwan3_running() {
    pgrep -f "$RTMON_PATTERN" >/dev/null 2>&1
}

get_mwan3_interfaces() {
    local name enabled
    for name in $(uci -q show mwan3 2>/dev/null | sed -n 's/^mwan3\.\([^=]*\)=interface$/\1/p'); do
        valid_iface "$name" || continue
        enabled=$(uci -q get "mwan3.${name}.enabled" 2>/dev/null)
        if [ "$enabled" = "1" ]; then
            printf '%s\n' "$name"
        fi
    done
}

get_track_status() {
    local iface="$1" f value
    valid_iface "$iface" || {
        printf 'tidak-valid'
        return 1
    }
    f="$TRACK_STATUS_DIR/$iface/STATUS"
    if [ -f "$f" ]; then
        value=$(cat "$f" 2>/dev/null)
        printf '%s' "${value:-tidak-ada}"
    else
        printf 'tidak-ada'
    fi
}

resolve_bind_device() {
    local iface="$1" dev
    valid_iface "$iface" || {
        printf ''
        return 1
    }
    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        dev=$(ubus -t 5 call "network.interface.${iface}" status 2>/dev/null | jsonfilter -e '@["device"]' 2>/dev/null)
    fi
    if [ -z "$dev" ]; then
        dev="$iface"
    fi
    printf '%s' "$dev"
}

probe_one_target() {
    local mode="$1" iface="$2" bind="$3" count="$4" timeout="$5" target="$6" out
    if [ "$mode" = "production" ]; then
        out=$(ping -I "$bind" -c "$count" -W "$timeout" "$target" 2>/dev/null)
    else
        out=$("$MWAN3_BIN" use "$iface" ping -c "$count" -W "$timeout" "$target" 2>/dev/null)
    fi
    printf '%s\n' "$out" | awk '
        BEGIN { tx=0; rx=0; loss=100 }
        /packets transmitted/ {
            n=split($0, parts, ",")
            if (n >= 1) { split(parts[1], f1, " "); tx=f1[1]+0 }
            if (n >= 2) { split(parts[2], f2, " "); rx=f2[1]+0 }
            if (n >= 3) { split(parts[3], f3, " "); loss=f3[1]+0 }
        }
        END { printf "%d %d %d\n", tx, rx, loss }
    ' 2>/dev/null
}

probe_success() {
    local tx="$1" rx="$2"
    is_uint "$tx" || return 1
    is_uint "$rx" || return 1
    [ "$tx" -gt 0 ] || return 1
    [ $((rx * 100)) -ge $((tx * PROBE_SUCCESS_PERCENT)) ]
}

run_probe_set() {
    local mode="$1" iface="$2" bind="$3" count="$4" timeout="$5" reliability="$6" targets="$7" quiet="${8:-0}"
    local success=0 total=0 target res tx rx loss status uji

    for target in $targets; do
        [ -z "$target" ] && continue
        total=$((total + 1))
        res=$(probe_one_target "$mode" "$iface" "$bind" "$count" "$timeout" "$target")
        set -- $res
        tx="${1:-0}"
        rx="${2:-0}"
        loss="${3:-100}"

        if probe_success "$tx" "$rx"; then
            status="OK"
            success=$((success + 1))
        else
            status="GAGAL"
        fi

        if [ "$mode" = "production" ]; then
            uji="produksi"
        else
            uji="bypass"
        fi

        if [ "$quiet" != "1" ]; then
            log_msg INFO "$iface" "Uji $uji $status: $target $rx/$tx ${loss}%"
        fi
    done

    if [ "$total" -eq 0 ]; then
        printf '0 0 0\n'
        return 0
    fi

    if [ "$reliability" -gt "$total" ]; then
        if [ "$quiet" != "1" ]; then
            log_msg WARN "$iface" "Keandalan $reliability > target $total, pakai $total"
        fi
        reliability="$total"
    fi

    if [ "$reliability" -lt 1 ]; then
        reliability=1
    fi

    if [ "$success" -ge "$reliability" ]; then
        printf '1 %d %d\n' "$success" "$total"
    else
        printf '0 %d %d\n' "$success" "$total"
    fi
}

bypass_short() {
    case "$1" in
        OK) printf 'OK' ;;
        FAIL) printf 'GAGAL' ;;
        TIDAK) printf 'TIDAK' ;;
        LEWAT) printf 'LEWAT' ;;
        SKIP) printf 'LEWAT' ;;
        *) printf '?' ;;
    esac
}

reason_short() {
    case "$1" in
        mwan3_rule_inconsistency) printf 'aturan mwan3' ;;
        downstream_failure) printf 'hilir' ;;
        production_failure_bypass_unsupported) printf 'bypass tidak ada' ;;
        *) printf 'tak diketahui' ;;
    esac
}

worker_body() {
    local iface="$1"
    local status targets count timeout reliability bind
    local prod_res prod_ok prod_success prod_total
    local bypass_res bypass_ok bypass_status bypass_summary

    if ! valid_iface "$iface"; then
        log_msg ERROR SISTEM "Antarmuka tidak valid: $iface"
        return 1
    fi

    status=$(get_track_status "$iface")
    if [ "$status" != "online" ]; then
        state_write "$iface" prod_ok "skip"
        state_write "$iface" prod_summary "-"
        state_write "$iface" bypass_status "LEWAT"
        state_write "$iface" bypass_summary "-"
        log_msg INFO "$iface" "Track $status"
        return 0
    fi

    targets=$(uci -q get "mwan3.${iface}.track_ip" 2>/dev/null)
    if [ -z "$targets" ]; then
        state_write "$iface" prod_ok "1"
        state_write "$iface" prod_summary "0/0"
        state_write "$iface" bypass_status "TIDAK"
        state_write "$iface" bypass_summary "-"
        log_msg INFO "$iface" "Target kosong: aktif"
        return 0
    fi

    count=$(uci -q get "mwan3.${iface}.count" 2>/dev/null)
    timeout=$(uci -q get "mwan3.${iface}.timeout" 2>/dev/null)
    reliability=$(uci -q get "mwan3.${iface}.reliability" 2>/dev/null)

    count=$(uint_or_default "$count" 1)
    timeout=$(uint_or_default "$timeout" 4)
    reliability=$(uint_or_default "$reliability" 1)

    if [ "$count" -lt 1 ]; then count=1; fi
    if [ "$timeout" -lt 1 ]; then timeout=1; fi
    if [ "$reliability" -lt 1 ]; then reliability=1; fi

    bind=$(resolve_bind_device "$iface")
    log_msg DEBUG "$iface" "Ikatan: $bind"

    prod_res=$(run_probe_set production "$iface" "$bind" "$count" "$timeout" "$reliability" "$targets" 0)
    set -- $prod_res
    prod_ok="${1:-0}"
    prod_success="${2:-0}"
    prod_total="${3:-0}"

    state_write "$iface" prod_ok "$prod_ok"
    state_write "$iface" prod_summary "$prod_success/$prod_total"

    if [ "$BYPASS_SUPPORTED" = "1" ]; then
        bypass_res=$(run_probe_set bypass "$iface" "$bind" "$count" "$timeout" "$reliability" "$targets" 0)
        set -- $bypass_res
        bypass_ok="${1:-0}"
        bypass_success="${2:-0}"
        bypass_total="${3:-0}"
        if [ "$bypass_ok" = "1" ]; then
            bypass_status="OK"
        else
            bypass_status="FAIL"
        fi
        bypass_summary="$bypass_success/$bypass_total"
    else
        bypass_status="TIDAK"
        bypass_summary="-"
        log_msg DEBUG "$iface" "Bypass tidak tersedia"
    fi

    state_write "$iface" bypass_status "$bypass_status"
    state_write "$iface" bypass_summary "$bypass_summary"
    return 0
}

run_with_timeout() {
    local t="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$t" "$@" >/dev/null 2>&1
        return $?
    fi

    "$@" >/dev/null 2>&1 &
    local pid=$! i=0 rc=0
    while [ "$i" -lt "$t" ]; do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            wait "$pid" >/dev/null 2>&1
            rc=$?
            return "$rc"
        fi
        sleep 1
        i=$((i + 1))
    done

    kill -TERM "$pid" >/dev/null 2>&1
    sleep 1
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill -KILL "$pid" >/dev/null 2>&1
    fi
    wait "$pid" >/dev/null 2>&1
    return 124
}

run_heal_cmd() {
    local desc="$1"
    shift
    local start end rc dur
    start=$(now)
    log_msg INFO SISTEM "Perintah: $desc"
    run_with_timeout "$HEAL_TIMEOUT" "$@"
    rc=$?
    end=$(now)
    dur=$((end - start))

    if [ "$rc" -eq 0 ]; then
        log_msg INFO SISTEM "Perintah: SELESAI OK ${dur}s"
    elif [ "$rc" -eq 124 ]; then
        log_msg ERROR SISTEM "Perintah: TIMEOUT ${dur}s"
    else
        log_msg ERROR SISTEM "Perintah: GAGAL ${dur}s rc=$rc"
    fi
    return "$rc"
}

heal_restart() {
    if [ -x "$MWAN3_INIT" ]; then
        run_heal_cmd "$MWAN3_INIT restart" "$MWAN3_INIT" restart
    else
        run_heal_cmd "$MWAN3_BIN restart" "$MWAN3_BIN" restart
    fi
}

heal_stop_start() {
    local rc=0

    if [ -x "$MWAN3_INIT" ]; then
        run_heal_cmd "$MWAN3_INIT stop" "$MWAN3_INIT" stop || rc=1
    else
        run_heal_cmd "$MWAN3_BIN stop" "$MWAN3_BIN" stop || rc=1
    fi

    _interruptible_sleep "$HEAL_STOP_SLEEP"

    if [ "$HEAL_FLUSH_CONNTRACK" = "1" ]; then
        if command -v conntrack >/dev/null 2>&1; then
            run_heal_cmd "conntrack -F" conntrack -F || rc=1
        else
            log_msg WARN SISTEM "Conntrack flush: tidak tersedia"
        fi
    fi

    if [ -x "$MWAN3_INIT" ]; then
        run_heal_cmd "$MWAN3_INIT start" "$MWAN3_INIT" start || rc=1
    else
        run_heal_cmd "$MWAN3_BIN start" "$MWAN3_BIN" start || rc=1
    fi

    return "$rc"
}

execute_heal_strategy() {
    local strategy="$1"
    case "$strategy" in
        restart)
            heal_restart
            ;;
        stop_start)
            heal_stop_start
            ;;
        *)
            heal_restart
            ;;
    esac
}

verify_ifaces() {
    local ifaces="$1"
    local iface ok=1 targets reliability bind res rok

    for iface in $ifaces; do
        valid_iface "$iface" || continue
        targets=$(uci -q get "mwan3.${iface}.track_ip" 2>/dev/null)
        if [ -z "$targets" ]; then
            continue
        fi

        reliability=$(uci -q get "mwan3.${iface}.reliability" 2>/dev/null)
        reliability=$(uint_or_default "$reliability" 1)
        if [ "$reliability" -lt 1 ]; then reliability=1; fi

        bind=$(resolve_bind_device "$iface")
        res=$(run_probe_set production "$iface" "$bind" "$VERIFY_COUNT" "$VERIFY_TIMEOUT" "$reliability" "$targets" 1)
        set -- $res
        rok="${1:-0}"

        if [ "$rok" = "1" ]; then
            log_msg INFO "$iface" "Verifikasi produksi OK"
        else
            log_msg ERROR "$iface" "Verifikasi produksi GAGAL"
            ok=0
        fi
    done

    [ "$ok" -eq 1 ]
}

register_heal_count() {
    local now_ts window_start count muted
    now_ts=$(now)
    window_start=$(global_read heal_window_start 0)
    is_uint "$window_start" || window_start=0
    count=$(global_read heal_count 0)
    is_uint "$count" || count=0

    if [ $((now_ts - window_start)) -gt "$GLOBAL_HEAL_WINDOW" ]; then
        window_start="$now_ts"
        count=0
    fi

    count=$((count + 1))
    global_write heal_window_start "$window_start"
    global_write heal_count "$count"

    if [ "$count" -ge "$MAX_GLOBAL_HEALS" ]; then
        muted=$((now_ts + GLOBAL_MUTE_TIME))
        global_write muted_until "$muted"
        log_msg ERROR SISTEM "Circuit: $count/$GLOBAL_HEAL_WINDOW s, bisu $GLOBAL_MUTE_TIME s"
    fi
}

global_cooldown_remaining() {
    local now_ts last rem
    now_ts=$(now)
    last=$(global_read last_heal 0)
    is_uint "$last" || last=0
    if [ "$last" -eq 0 ]; then
        printf '0'
        return 0
    fi
    rem=$((HEAL_COOLDOWN - (now_ts - last)))
    if [ "$rem" -lt 0 ]; then rem=0; fi
    printf '%s' "$rem"
}

global_muted_now() {
    local now_ts muted
    now_ts=$(now)
    muted=$(global_read muted_until 0)
    is_uint "$muted" || muted=0
    [ "$now_ts" -lt "$muted" ]
}

should_run_now() {
    local iface="$1" next_run now_ts
    next_run=$(state_read "$iface" next_run 0)
    now_ts=$(now)
    is_uint "$next_run" || next_run=0
    [ "$now_ts" -ge "$next_run" ]
}

nearest_next_run() {
    local interfaces iface nr best now_ts
    now_ts=$(now)
    best=0
    interfaces=$(get_mwan3_interfaces)
    if [ -z "$interfaces" ]; then
        printf '0'
        return 0
    fi

    for iface in $interfaces; do
        valid_iface "$iface" || continue
        nr=$(state_read "$iface" next_run 0)
        is_uint "$nr" || nr=0
        if [ "$nr" -gt "$now_ts" ]; then
            if [ "$best" -eq 0 ] || [ "$nr" -lt "$best" ]; then
                best="$nr"
            fi
        fi
    done

    printf '%s' "$best"
}

sleep_until_schedule() {
    local nearest now delta
    nearest=$(nearest_next_run)
    now=$(now)

    if [ "$nearest" -gt "$now" ]; then
        delta=$((nearest - now))
    else
        delta="$CHECK_INTERVAL"
    fi

    if [ "$delta" -lt 1 ]; then delta=1; fi
    if [ "$delta" -gt "$CHECK_INTERVAL" ]; then delta="$CHECK_INTERVAL"; fi

    log_msg DEBUG SISTEM "Tidur jadwal: ${delta}s"
    _interruptible_sleep "$delta"
}

reap_children() {
    local new="" pid
    for pid in $CHILD_PIDS; do
        if kill -0 "$pid" >/dev/null 2>&1; then
            new="$new $pid"
        else
            wait "$pid" >/dev/null 2>&1
        fi
    done
    CHILD_PIDS="$new"
}

wait_children() {
    local cycle_start="$1" deadline now pid
    deadline=$((cycle_start + WORKER_TIMEOUT))

    while [ -n "$CHILD_PIDS" ]; do
        now=$(now)
        if [ "$now" -ge "$deadline" ]; then
            log_msg WARN SISTEM "Batas pekerja: hentikan anak"
            for pid in $CHILD_PIDS; do
                kill -TERM "-$pid" >/dev/null 2>&1
                kill -TERM "$pid" >/dev/null 2>&1
            done
            _interruptible_sleep 2
            for pid in $CHILD_PIDS; do
                if kill -0 "$pid" >/dev/null 2>&1; then
                    kill -KILL "-$pid" >/dev/null 2>&1
                    kill -KILL "$pid" >/dev/null 2>&1
                fi
            done
            _interruptible_sleep 1
            CHILD_PIDS=""
            return 0
        fi

        reap_children
        if [ -n "$CHILD_PIDS" ]; then
            sleep 1
        fi
    done
}

_cycle_timing() {
    local cycle_start="$1" cycle_end elapsed remaining nearest now sleep_time backoff delta
    cycle_end=$(now)
    elapsed=$((cycle_end - cycle_start))
    remaining=$((CHECK_INTERVAL - elapsed))

    if [ "$remaining" -gt 0 ]; then
        OVERRUN_STREAK=0
        sleep_time="$remaining"
        nearest=$(nearest_next_run)
        now=$(now)

        if [ "$nearest" -gt "$now" ]; then
            delta=$((nearest - now))
            if [ "$delta" -lt 1 ]; then delta=1; fi
            if [ "$delta" -lt "$sleep_time" ]; then
                sleep_time="$delta"
            fi
        fi

        log_msg INFO SISTEM "Siklus: ${elapsed}s, tidur ${sleep_time}s"
        _interruptible_sleep "$sleep_time"
    else
        OVERRUN_STREAK=$((OVERRUN_STREAK + 1))
        backoff="$OVERRUN_STREAK"
        if [ "$backoff" -gt 60 ]; then backoff=60; fi
        log_msg WARN SISTEM "Overrun: ${elapsed}s, target ${CHECK_INTERVAL}s, mundur ${backoff}s"
        _interruptible_sleep "$backoff"
    fi
}

evaluate_states() {
    local interfaces="$1"
    local now_ts iface prod_ok fail_count stab bypass_status reason
    local prod_summary bypass_text muted rem muted_until

    HEAL_IFACES=""
    now_ts=$(now)

    muted=0
    muted_until=$(global_read muted_until 0)
    is_uint "$muted_until" || muted_until=0
    if [ "$muted_until" -gt "$now_ts" ]; then
        muted=1
        rem=$((muted_until - now_ts))
    else
        rem=0
    fi

    for iface in $interfaces; do
        valid_iface "$iface" || continue
        prod_ok=$(state_read "$iface" prod_ok "")

        if [ "$prod_ok" = "1" ]; then
            state_write "$iface" fail_count "0"
            stab=$(state_read "$iface" stabilize_until 0)
            is_uint "$stab" || stab=0
            if [ "$now_ts" -lt "$stab" ]; then
                state_write "$iface" stabilize_until "0"
                log_msg INFO "$iface" "Stabilisasi selesai: sehat"
            else
                log_msg INFO "$iface" "Sehat: produksi $(state_read "$iface" prod_summary "-"), bypass $(bypass_short "$(state_read "$iface" bypass_status "TIDAK")")"
            fi
            state_write "$iface" last_success "$now_ts"
            state_write "$iface" next_run "$((now_ts + CHECK_INTERVAL))"
            continue
        fi

        if [ "$prod_ok" = "0" ]; then
            state_write "$iface" last_failure "$now_ts"
            stab=$(state_read "$iface" stabilize_until 0)
            is_uint "$stab" || stab=0

            if [ "$now_ts" -lt "$stab" ]; then
                state_write "$iface" next_run "$((now_ts + STABILIZE_INTERVAL))"
                log_msg INFO "$iface" "Stabilisasi: produksi $(state_read "$iface" prod_summary "-"), bypass $(bypass_short "$(state_read "$iface" bypass_status "TIDAK")"), cek ${STABILIZE_INTERVAL}s"
                continue
            fi

            fail_count=$(state_read "$iface" fail_count 0)
            is_uint "$fail_count" || fail_count=0

            bypass_status=$(state_read "$iface" bypass_status "TIDAK")
            if [ "$bypass_status" = "OK" ]; then
                reason="mwan3_rule_inconsistency"
            elif [ "$bypass_status" = "FAIL" ]; then
                reason="downstream_failure"
            else
                reason="production_failure_bypass_unsupported"
            fi

            prod_summary=$(state_read "$iface" prod_summary "-")
            bypass_text=$(bypass_short "$bypass_status")

            if [ "$muted" = "1" ]; then
                if [ "$fail_count" -lt "$FAILURE_THRESHOLD" ]; then
                    fail_count="$FAILURE_THRESHOLD"
                fi
                state_write "$iface" fail_count "$fail_count"
                state_write "$iface" next_run "$((muted_until + 1))"
                HEAL_IFACES="$HEAL_IFACES $iface"
                continue
            fi

            if [ "$fail_count" -lt "$FAILURE_THRESHOLD" ]; then
                fail_count=$((fail_count + 1))
                state_write "$iface" fail_count "$fail_count"
                log_msg WARN "$iface" "Gagal: produksi $prod_summary, bypass $bypass_text, hit $fail_count/$FAILURE_THRESHOLD, $(reason_short "$reason")"

                if [ "$fail_count" -lt "$FAILURE_THRESHOLD" ]; then
                    state_write "$iface" next_run "$((now_ts + CHECK_INTERVAL))"
                    log_msg WARN "$iface" "Tunda: hit $fail_count/$FAILURE_THRESHOLD"
                else
                    HEAL_IFACES="$HEAL_IFACES $iface"
                fi
            else
                log_msg WARN "$iface" "Gagal: produksi $prod_summary, bypass $bypass_text, siap pulih, $(reason_short "$reason")"
                HEAL_IFACES="$HEAL_IFACES $iface"
            fi
            continue
        fi

        state_write "$iface" next_run "$((now_ts + CHECK_INTERVAL))"
    done
}

process_heal() {
    local now_ts attempt strategy rc rem muted_until iface

    [ -z "$HEAL_IFACES" ] && return 0
    now_ts=$(now)

    muted_until=$(global_read muted_until 0)
    is_uint "$muted_until" || muted_until=0
    if [ "$muted_until" -ne 0 ] && [ "$now_ts" -ge "$muted_until" ]; then
        global_write muted_until "0"
        global_write heal_attempt "0"
        global_write heal_count "0"
        global_write heal_window_start "0"
        log_msg INFO SISTEM "Bisu global berakhir"
    fi

    if global_muted_now; then
        muted_until=$(global_read muted_until 0)
        is_uint "$muted_until" || muted_until=0
        rem=$((muted_until - now_ts))
        if [ "$rem" -lt 0 ]; then rem=0; fi
        log_msg ERROR SISTEM "Bisu: global ${rem}s, antrean:$HEAL_IFACES"
        for iface in $HEAL_IFACES; do
            state_write "$iface" next_run "$((muted_until + 1))"
        done
        return 0
    fi

    rem=$(global_cooldown_remaining)
    if [ "$rem" -gt 0 ]; then
        log_msg WARN SISTEM "Tunda: cooldown global ${rem}s, antrean:$HEAL_IFACES"
        for iface in $HEAL_IFACES; do
            state_write "$iface" next_run "$((now_ts + HEAL_RETRY_INTERVAL))"
        done
        return 0
    fi

    attempt=$(global_read heal_attempt 0)
    is_uint "$attempt" || attempt=0
    attempt=$((attempt + 1))
    global_write heal_attempt "$attempt"

    if [ "$attempt" -gt "$MAX_HEAL_ATTEMPTS" ]; then
        muted_until=$((now_ts + GLOBAL_MUTE_TIME))
        global_write muted_until "$muted_until"
        global_write heal_attempt "0"
        log_msg ERROR SISTEM "Pulih: upaya habis, bisu $GLOBAL_MUTE_TIME s"
        for iface in $HEAL_IFACES; do
            state_write "$iface" next_run "$((muted_until + 1))"
        done
        return 0
    fi

    strategy=$(sequence_item "$HEAL_SEQUENCE" "$attempt") || strategy="restart"
    if [ -z "$strategy" ]; then
        strategy="restart"
    fi

    log_msg WARN SISTEM "Pulih: upaya $attempt/$MAX_HEAL_ATTEMPTS, strategi $strategy, antrean:$HEAL_IFACES"
    global_write last_heal "$now_ts"

    execute_heal_strategy "$strategy"
    rc=$?

    _interruptible_sleep "$HEAL_SETTLE"

    if verify_ifaces "$HEAL_IFACES"; then
        log_msg INFO SISTEM "Pulih: verifikasi OK"
        global_write heal_attempt "0"
        register_heal_count
        now_ts=$(now)
        for iface in $HEAL_IFACES; do
            state_write "$iface" prod_ok "1"
            state_write "$iface" fail_count "0"
            state_write "$iface" stabilize_until "$((now_ts + STABILIZE_SECONDS))"
            state_write "$iface" last_heal "$now_ts"
            state_write "$iface" last_success "$now_ts"
            state_write "$iface" next_run "$((now_ts + CHECK_INTERVAL))"
        done
    else
        log_msg ERROR SISTEM "Pulih: verifikasi GAGAL"
        register_heal_count
        now_ts=$(now)
        for iface in $HEAL_IFACES; do
            state_write "$iface" last_heal "$now_ts"
            state_write "$iface" next_run "$((now_ts + HEAL_RETRY_INTERVAL))"
        done

        if [ "$attempt" -ge "$MAX_HEAL_ATTEMPTS" ]; then
            muted_until=$((now_ts + GLOBAL_MUTE_TIME))
            global_write muted_until "$muted_until"
            global_write heal_attempt "0"
            log_msg ERROR SISTEM "Pulih: upaya habis, bisu $GLOBAL_MUTE_TIME s"
            for iface in $HEAL_IFACES; do
                state_write "$iface" next_run "$((muted_until + 1))"
            done
        fi
    fi

    return "$rc"
}

detect_mwan3_version() {
    local v=""
    if command -v opkg >/dev/null 2>&1; then
        v=$(opkg info mwan3 2>/dev/null | awk '/^Version:/ {print $2; exit}')
    fi
    if [ -n "$v" ]; then
        log_msg INFO SISTEM "Versi mwan3: $v"
    else
        log_msg DEBUG SISTEM "Versi mwan3: tidak terdeteksi"
    fi
}

main_loop() {
    local cycle_start interfaces first_iface iface pid ran child_count

    log_msg INFO SISTEM "Mulai: PID $(current_pid), interval ${CHECK_INTERVAL}s, sekuens $HEAL_SEQUENCE"
    detect_mwan3_version

    while true; do
        cycle_start=$(now)
        HEAL_IFACES=""

        if ! is_mwan3_running; then
            if [ "$MWAN3_ACTIVE_LAST" != "inactive" ]; then
                log_msg INFO SISTEM "mwan3 tidak aktif"
                MWAN3_ACTIVE_LAST="inactive"
            fi
            _interruptible_sleep "$CHECK_INTERVAL"
            continue
        fi

        if [ "$MWAN3_ACTIVE_LAST" != "active" ]; then
            log_msg INFO SISTEM "mwan3 aktif"
            MWAN3_ACTIVE_LAST="active"
        fi

        interfaces=$(get_mwan3_interfaces)
        if [ -z "$interfaces" ]; then
            log_msg INFO SISTEM "Tidak ada antarmuka aktif"
            _interruptible_sleep "$CHECK_INTERVAL"
            continue
        fi

        if [ "$CAPABILITY_DETECTED" != "1" ]; then
            first_iface=""
            for iface in $interfaces; do
                first_iface="$iface"
                break
            done

            BYPASS_SUPPORTED=0
            if [ -n "$first_iface" ] && "$MWAN3_BIN" use "$first_iface" true >/dev/null 2>&1; then
                BYPASS_SUPPORTED=1
            fi
            CAPABILITY_DETECTED=1
            log_msg DEBUG SISTEM "Kemampuan: bypass=$BYPASS_SUPPORTED"
        fi

        CHILD_PIDS=""
        PROBED_IFACES=""
        child_count=0
        ran=0

        for iface in $interfaces; do
            if ! valid_iface "$iface"; then
                log_msg ERROR SISTEM "Antarmuka tidak valid: $iface"
                continue
            fi

            if ! should_run_now "$iface"; then
                log_msg DEBUG "$iface" "Lewat: jadwal"
                continue
            fi

            while [ "$child_count" -ge "$MAX_PARALLEL_WORKERS" ]; do
                reap_children
                child_count=$(count_words "$CHILD_PIDS")
                if [ "$child_count" -ge "$MAX_PARALLEL_WORKERS" ]; then
                    sleep 1
                fi
            done

            (
                trap - EXIT INT TERM
                worker_body "$iface"
            ) &

            pid=$!
            CHILD_PIDS="$CHILD_PIDS $pid"
            PROBED_IFACES="$PROBED_IFACES $iface"
            child_count=$((child_count + 1))
            ran=1
        done

        if [ "$ran" -eq 1 ]; then
            wait_children "$cycle_start"
            evaluate_states "$PROBED_IFACES"
            process_heal
            _cycle_timing "$cycle_start"
        else
            sleep_until_schedule
        fi
    done
}

_handle_stop() {
    trap - INT TERM EXIT
    local pid

    for pid in $CHILD_PIDS; do
        kill -TERM "-$pid" >/dev/null 2>&1
        kill -TERM "$pid" >/dev/null 2>&1
    done

    for pid in $CHILD_PIDS; do
        wait "$pid" >/dev/null 2>&1
    done

    if [ -n "$GLOBAL_LOCK" ]; then
        lock_release_file "$GLOBAL_LOCK"
    fi

    log_msg INFO SISTEM "Berhenti: PID $(current_pid)"
    exit 0
}

GLOBAL_LOCK="$LOCK_ROOT/global.lock"

if ! lock_acquire_file "$GLOBAL_LOCK"; then
    log_msg INFO SISTEM "Instance lain aktif"
    exit 0
fi

rm -rf "$STATE_DIR" >/dev/null 2>&1
mkdir -p "$STATE_DIR" >/dev/null 2>&1 || {
    log_msg ERROR SISTEM "Gagal bersihkan state"
    lock_release_file "$GLOBAL_LOCK"
    exit 0
}
log_msg INFO SISTEM "State dibersihkan"

CHILD_PIDS=""
PROBED_IFACES=""
HEAL_IFACES=""
MWAN3_ACTIVE_LAST=""
BYPASS_SUPPORTED=0
CAPABILITY_DETECTED=0
OVERRUN_STREAK=0

trap '_handle_stop' INT TERM EXIT

main_loop