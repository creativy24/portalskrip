#!/bin/sh
# Library: Logging Terpusat

log_auto() {
    local profil="$1"
    local detail="$2"
    local level="${3:-INFO}"
    local script="${SCRIPT_NAME:-unknown.sh}"

    case "$level" in
        INFO|WARN|ERROR|DEBUG) ;;
        OK) level="INFO" ;;
        FAIL) level="ERROR" ;;
        SKIP) level="DEBUG" ;;
        *) level="INFO" ;;
    esac

    logger -t portal "[$level] [$script] [$profil] | $detail" >/dev/null 2>&1
}