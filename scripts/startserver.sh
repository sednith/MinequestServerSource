#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
    echo "Использование: bash scripts/startserver.sh <имя-папки-сервера>" >&2
}

if (( $# != 1 )); then
    usage
    exit 2
fi

resolve_server "$1" || exit $?
resolve_server_jar || exit 1

JAVA_ARGS_FILE="$SERVER_DIR/java-args"
FIFO="$SERVER_DIR/server_console"
PID_FILE="$SERVER_DIR/.server.pid"
RESTART_WAIT=5
STOP_TIMEOUT=10
SERVER_PID=""
FIFO_CREATED=false

if [[ ! -r "$JAVA_ARGS_FILE" ]]; then
    log "[ERROR] Не найден файл аргументов Java: $JAVA_ARGS_FILE"
    exit 1
fi
if ! command -v java >/dev/null 2>&1; then
    log "[ERROR] Java не найдена в PATH"
    exit 1
fi

if [[ -s "$PID_FILE" ]]; then
    EXISTING_PID="$(cat "$PID_FILE")"
    if server_pid_is_valid "$EXISTING_PID" "$SERVER_DIR"; then
        log "[ERROR] Сервер $SERVER_NAME уже запущен (PID $EXISTING_PID)"
        exit 1
    fi
    rm -f "$PID_FILE"
fi

cleanup() {
    trap '' INT TERM
    log "[INFO] Остановка супервизора для $SERVER_NAME"

    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log "[INFO] Отправляю штатную команду остановки серверу $SERVER_NAME"
        printf '%s\n' "$(server_stop_command)" > "$FIFO" 2>/dev/null || true

        local waited=0
        while (( waited < STOP_TIMEOUT )); do
            local state
            state="$(ps -o stat= -p "$SERVER_PID" 2>/dev/null || true)"
            [[ "$state" == *Z* ]] && break
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 1
            ((waited += 1))
        done

        local state
        state="$(ps -o stat= -p "$SERVER_PID" 2>/dev/null || true)"
        if [[ "$state" != *Z* ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
            log "[WARN] Штатная остановка не завершилась за ${STOP_TIMEOUT}с; посылаю TERM только PID $SERVER_PID"
            kill -TERM "$SERVER_PID" 2>/dev/null || true
            sleep 2
            state="$(ps -o stat= -p "$SERVER_PID" 2>/dev/null || true)"
            if [[ "$state" != *Z* ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
                log "[WARN] PID $SERVER_PID не завершился после TERM; посылаю KILL"
                kill -KILL "$SERVER_PID" 2>/dev/null || true
            fi
        fi

        wait "$SERVER_PID" 2>/dev/null || true
    fi

    if [[ -n "$SERVER_PID" && -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE")" == "$SERVER_PID" ]]; then
        rm -f "$PID_FILE"
    fi
    SERVER_PID=""
    exec 3>&- 2>/dev/null || true
    if [[ "$FIFO_CREATED" == true ]]; then
        rm -f "$FIFO"
    fi
    exit 0
}

trap cleanup INT TERM

if [[ -e "$FIFO" && ! -p "$FIFO" ]]; then
    log "[ERROR] Путь FIFO занят не-каналом: $FIFO"
    exit 1
fi
rm -f "$FIFO"
mkfifo "$FIFO"
FIFO_CREATED=true
exec 3<> "$FIFO"

cd "$SERVER_DIR"

LAST_JAR_NAME=""
while true; do
    # Деплой мог заменить ядро (переименовать JAR), пока супервизор жив.
    # Перечитываем каталог на каждой итерации, иначе после stop будет
    # предпринята попытка запустить уже удалённый файл.
    if ! resolve_server_jar; then
        log "[WARN] Не удалось определить JAR ядра в $SERVER_DIR; повтор через ${RESTART_WAIT}с"
        sleep "$RESTART_WAIT"
        continue
    fi

    JAR_NAME="$(basename -- "$SERVER_JAR")"
    if [[ -n "$LAST_JAR_NAME" && "$JAR_NAME" != "$LAST_JAR_NAME" ]]; then
        log "[INFO] Ядро $SERVER_NAME изменилось: $LAST_JAR_NAME -> $JAR_NAME"
    fi
    LAST_JAR_NAME="$JAR_NAME"

    log "[INFO] Запуск $SERVER_NAME: $JAR_NAME"
    if [[ "$SERVER_KIND" == paper ]]; then
        java @java-args -jar "$JAR_NAME" --nogui < "$FIFO" &
    else
        java @java-args -jar "$JAR_NAME" < "$FIFO" &
    fi
    SERVER_PID=$!
    printf '%s\n' "$SERVER_PID" > "$PID_FILE"
    log "[INFO] Процесс $SERVER_NAME запущен, PID $SERVER_PID"

    wait "$SERVER_PID"
    EXIT_CODE=$?
    if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE")" == "$SERVER_PID" ]]; then
        rm -f "$PID_FILE"
    fi
    SERVER_PID=""

    log "[WARN] $SERVER_NAME завершился с кодом $EXIT_CODE"
    log "[INFO] Автоперезапуск через ${RESTART_WAIT} секунд; Ctrl+C остановит супервизор"
    sleep "$RESTART_WAIT"
done
