#!/bin/sh
# Notifikasi Telegram
SCRIPT_NAME="telegram_notify.sh"

. /usr/lib/portal/logging.sh
. /usr/lib/portal/network.sh

TOKEN="$1"
CHAT_ID="$2"
MSG="$3"

if [ "${TELEGRAM_ENABLED:-true}" != "true" ]; then
    log_auto "TELEGRAM" "NOTIFY: Dinonaktifkan secara global, lewati notifikasi" "DEBUG"
    exit 0
fi

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ] || [ -z "$MSG" ]; then
    log_auto "TELEGRAM" "NOTIFY: Parameter tidak lengkap, lewati notifikasi best-effort" "WARN"
    exit 0
fi

case "$TOKEN" in
    *[!A-Za-z0-9:_-]*)
        log_auto "TELEGRAM" "NOTIFY: Format bot token tidak valid, lewati notifikasi" "WARN"
        exit 0
        ;;
esac

case "$CHAT_ID" in
    *[!0-9-]*)
        log_auto "TELEGRAM" "NOTIFY: Format chat id tidak valid, lewati notifikasi" "WARN"
        exit 0
        ;;
esac

if [ -z "$TELEGRAM_API" ]; then
    log_auto "TELEGRAM" "NOTIFY: TELEGRAM_API kosong, lewati notifikasi" "WARN"
    exit 0
fi

case "$TELEGRAM_API" in
    */)
        TELEGRAM_API="${TELEGRAM_API%/}"
        ;;
esac

case "$TELEGRAM_API" in
    */bot)
        ;;
    *)
        log_auto "TELEGRAM" "NOTIFY: TELEGRAM_API tidak valid, harus berakhir /bot, lewati notifikasi" "WARN"
        exit 0
        ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    log_auto "TELEGRAM" "NOTIFY: curl tidak tersedia, lewati notifikasi" "WARN"
    exit 0
fi

TG_CONNECT_TIMEOUT="${TELEGRAM_CONNECT_TIMEOUT:-3}"
TG_MAX_TIME="${TELEGRAM_MAX_TIME:-5}"
TG_RETRY="${TELEGRAM_RETRY:-0}"

case "$TG_CONNECT_TIMEOUT" in
    ''|*[!0-9]*)
        TG_CONNECT_TIMEOUT=3
        ;;
esac

case "$TG_MAX_TIME" in
    ''|*[!0-9]*)
        TG_MAX_TIME=5
        ;;
esac

case "$TG_RETRY" in
    ''|*[!0-9]*)
        TG_RETRY=0
        ;;
esac

[ "$TG_CONNECT_TIMEOUT" -eq 0 ] && TG_CONNECT_TIMEOUT=3
[ "$TG_MAX_TIME" -eq 0 ] && TG_MAX_TIME=5

if [ "$TG_MAX_TIME" -lt "$TG_CONNECT_TIMEOUT" ]; then
    TG_MAX_TIME="$TG_CONNECT_TIMEOUT"
fi

[ "$TG_RETRY" -gt 2 ] && TG_RETRY=2

URL="${TELEGRAM_API}${TOKEN}/sendMessage"

http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$URL" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    --connect-timeout "$TG_CONNECT_TIMEOUT" \
    --max-time "$TG_MAX_TIME" \
    --retry "$TG_RETRY" \
    2>/dev/null)

if [ "$http_code" = "200" ]; then
    log_auto "TELEGRAM" "NOTIFY: Pesan terkirim (HTTP 200)" "INFO"
else
    log_auto "TELEGRAM" "NOTIFY: Gagal kirim (HTTP: ${http_code:-000}, connect_timeout=${TG_CONNECT_TIMEOUT}s, max_time=${TG_MAX_TIME}s, retry=${TG_RETRY})" "WARN"
fi

exit 0