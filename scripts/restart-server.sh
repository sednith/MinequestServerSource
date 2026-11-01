#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if ! declare -F log_reports_ready >/dev/null 2>&1; then
    log "[ERROR] scripts/common.sh не содержит log_reports_ready; обновите скрипты репозитория целиком"
    exit 1
fi

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
TIMEOUT_VELOCITY=120
TIMEOUT_PAPER=300
CHECK_INTERVAL=2
STOP_TIMEOUT=30
RESTART_WAIT=7

if [[ "$SERVER_KIND" == velocity ]]; then
    TIMEOUT="$TIMEOUT_VELOCITY"
else
    TIMEOUT="$TIMEOUT_PAPER"
fi

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
    LOG_SIZE_BEFORE="${LOG_SIZE_BEFORE//[[:space:]]/}"
    LOG_INODE_BEFORE=$(stat -c '%i' -- "$LOG_FILE")
    LOG_HEAD_BEFORE=$(log_head_fingerprint "$LOG_FILE" "$(log_head_probe_len "$LOG_SIZE_BEFORE")")
else
    LOG_SIZE_BEFORE=0
    LOG_INODE_BEFORE=""
    LOG_HEAD_BEFORE=""
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
    BOOT_PATTERN='Booting up Velocity'
    READY_PATTERN='Done \([0-9.]+s\)!'
    log "[INFO] Ожидание готовности Velocity по сообщению 'Done (...)!' в логе (таймаут ${TIMEOUT}с)"
else
    BOOT_PATTERN='Starting minecraft server version'
    READY_PATTERN='Done.*For help'
    log "[INFO] Ожидание готовности Paper по сообщению 'Done ... For help' в логе (таймаут ${TIMEOUT}с)"
fi

ELAPSED=0
LOG_CHECK_REGION=unknown
LOG_CHANGE_LOGGED=false
while (( ELAPSED < TIMEOUT )); do
    if ! server_pid_is_valid "$NEW_PID" "$SERVER_DIR"; then
        log "[ERROR] Процесс $SERVER_NAME завершился до подтверждения готовности"
        [[ -f "$LOG_FILE" ]] && tail -n 20 "$LOG_FILE"
        exit 1
    fi

    LOG_CHANGE_DETECTED=false
    if [[ -f "$LOG_FILE" ]]; then
        LOG_SIZE_NOW=$(wc -c < "$LOG_FILE")
        LOG_SIZE_NOW="${LOG_SIZE_NOW//[[:space:]]/}"
        LOG_INODE_NOW=$(stat -c '%i' -- "$LOG_FILE")
        if [[ "$LOG_SIZE_NOW" != "$LOG_SIZE_BEFORE" ]] || [[ "$LOG_INODE_NOW" != "$LOG_INODE_BEFORE" ]]; then
            LOG_CHANGE_DETECTED=true
        fi
    fi

    READY_NOW=false
    if log_reports_ready "$LOG_FILE" "$BOOT_PATTERN" "$READY_PATTERN" "$LOG_SIZE_BEFORE" "$LOG_HEAD_BEFORE"; then
        READY_NOW=true
    fi

    if [[ "$LOG_CHANGE_DETECTED" == true && "$LOG_CHANGE_LOGGED" != true ]]; then
        log "[INFO] Лог $SERVER_NAME изменился: size $LOG_SIZE_BEFORE -> $LOG_SIZE_NOW, inode $LOG_INODE_BEFORE -> $LOG_INODE_NOW; режим проверки: $LOG_CHECK_REGION"
        LOG_CHANGE_LOGGED=true
    fi

    if [[ "$READY_NOW" == true ]]; then
        log "[OK] $SERVER_NAME успешно загружен за ${ELAPSED}с (PID $NEW_PID, режим проверки: $LOG_CHECK_REGION)"
        exit 0
    fi

    sleep "$CHECK_INTERVAL"
    ((ELAPSED += CHECK_INTERVAL))
done

log "[ERROR] $SERVER_NAME не сообщил о готовности за ${TIMEOUT}с (режим проверки: $LOG_CHECK_REGION)"
log "[INFO] Последние строки лога:"
[[ -f "$LOG_FILE" ]] && tail -n 20 "$LOG_FILE"
exit 1
