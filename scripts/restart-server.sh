#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
    echo "Использование: bash scripts/restart-server.sh <имя-папки-сервера>" >&2
}

if (( $# != 1 )); then
    usage
    exit 2
fi

resolve_server "$1" || exit $?
resolve_server_jar || exit 1

FIFO="$SERVER_DIR/server_console"
PID_FILE="$SERVER_DIR/.server.pid"
LOG_FILE="$SERVER_DIR/logs/latest.log"
TIMEOUT=120
CHECK_INTERVAL=2
STOP_TIMEOUT=30
RESTART_WAIT=7

if [[ ! -s "$PID_FILE" ]]; then
    log "[ERROR] PID-файл не найден: $PID_FILE. Запустите сервер через scripts/startserver.sh '$SERVER_NAME'"
    exit 1
fi
OLD_PID="$(cat "$PID_FILE")"
if ! server_pid_is_valid "$OLD_PID" "$SERVER_DIR"; then
    log "[ERROR] PID $OLD_PID не соответствует запущенному ядру в $SERVER_DIR"
    exit 1
fi
if [[ ! -p "$FIFO" ]]; then
    log "[ERROR] FIFO не найден: $FIFO"
    exit 1
fi

if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE_BEFORE=$(wc -c < "$LOG_FILE")
    LOG_INODE_BEFORE=$(stat -c '%i' -- "$LOG_FILE")
else
    LOG_SIZE_BEFORE=0
    LOG_INODE_BEFORE=""
fi

log "[INFO] Перезапуск $SERVER_NAME (PID $OLD_PID)"
printf '%s\n' "$(server_stop_command)" > "$FIFO"

WAIT=0
while server_pid_is_valid "$OLD_PID" "$SERVER_DIR"; do
    if (( WAIT >= STOP_TIMEOUT )); then
        if server_pid_is_valid "$OLD_PID" "$SERVER_DIR"; then
            log "[ERROR] $SERVER_NAME не остановился за ${STOP_TIMEOUT}с; посылаю TERM только PID $OLD_PID"
            kill -TERM "$OLD_PID" 2>/dev/null || true
        fi
        break
    fi
    sleep 1
    ((WAIT += 1))
done

log "[INFO] Ожидание автоматического перезапуска (${RESTART_WAIT}с)..."
sleep "$RESTART_WAIT"

ELAPSED=0
NEW_PID=""
while (( ELAPSED < TIMEOUT )); do
    if [[ -s "$PID_FILE" ]]; then
        CANDIDATE_PID="$(cat "$PID_FILE")"
        if [[ "$CANDIDATE_PID" != "$OLD_PID" ]] && server_pid_is_valid "$CANDIDATE_PID" "$SERVER_DIR"; then
            NEW_PID="$CANDIDATE_PID"
            break
        fi
    fi
    sleep "$CHECK_INTERVAL"
    ((ELAPSED += CHECK_INTERVAL))
done

if [[ -z "$NEW_PID" ]]; then
    log "[ERROR] $SERVER_NAME не перезапустился за ${TIMEOUT}с"
    [[ -f "$LOG_FILE" ]] && tail -n 20 "$LOG_FILE"
    exit 1
fi

log "[INFO] Новый процесс $SERVER_NAME запущен: PID $NEW_PID (предыдущий: $OLD_PID)"
if [[ "$SERVER_KIND" == velocity ]]; then
    READY_PATTERN='Done \([0-9.]+s\)!'
    log "[INFO] Ожидание готовности Velocity по сообщению 'Done (...)!' в логе"
else
    READY_PATTERN='Done.*For help'
    log "[INFO] Ожидание готовности Paper по сообщению 'Done ... For help' в логе"
fi

ELAPSED=0
while (( ELAPSED < TIMEOUT )); do
    if ! server_pid_is_valid "$NEW_PID" "$SERVER_DIR"; then
        log "[ERROR] Процесс $SERVER_NAME завершился до подтверждения готовности"
        [[ -f "$LOG_FILE" ]] && tail -n 20 "$LOG_FILE"
        exit 1
    fi

    if [[ -f "$LOG_FILE" ]]; then
        LOG_SIZE_NOW=$(wc -c < "$LOG_FILE")
        LOG_INODE_NOW=$(stat -c '%i' -- "$LOG_FILE")
        if [[ -n "$LOG_INODE_BEFORE" && "$LOG_INODE_NOW" != "$LOG_INODE_BEFORE" ]] \
            || (( LOG_SIZE_NOW < LOG_SIZE_BEFORE )); then
            log "[WARN] Обнаружена ротация лога; проверяю файл с начала"
            LOG_SIZE_BEFORE=0
            LOG_INODE_BEFORE="$LOG_INODE_NOW"
        fi

        START_BYTE=$((LOG_SIZE_BEFORE + 1))
        if tail -c "+$START_BYTE" "$LOG_FILE" 2>/dev/null | grep -qE "$READY_PATTERN"; then
            log "[OK] $SERVER_NAME успешно загружен за ${ELAPSED}с (PID $NEW_PID)"
            exit 0
        fi
    fi

    sleep "$CHECK_INTERVAL"
    ((ELAPSED += CHECK_INTERVAL))
done

log "[ERROR] $SERVER_NAME не сообщил о готовности за ${TIMEOUT}с"
log "[INFO] Последние строки лога:"
[[ -f "$LOG_FILE" ]] && tail -n 20 "$LOG_FILE"
exit 1
