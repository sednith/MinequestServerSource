#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

SERVER_START_ORDER=(playworld adjustment velocity)
START_TIMEOUT=300
CHECK_INTERVAL=2

usage() {
    echo "Использование: bash scripts/start-all.sh" >&2
}

if (( $# != 0 )); then
    usage
    exit 2
fi

if ! command -v screen >/dev/null 2>&1; then
    log "[ERROR] GNU Screen не найден в PATH"
    exit 1
fi
if ! command -v ss >/dev/null 2>&1; then
    log "[ERROR] Утилита ss не найдена в PATH (обычно пакет iproute2)"
    exit 1
fi

# DEV and PROD can run on the same Unix account. Separate Screen socket
# directories let both environments use the required session names (e.g. playworld).
SCREEN_SOCKET_DIR="$PROJECT_ROOT/.screen"
mkdir -p "$SCREEN_SOCKET_DIR"
chmod 700 "$SCREEN_SOCKET_DIR"
export SCREENDIR="$SCREEN_SOCKET_DIR"

for server in "${SERVER_START_ORDER[@]}"; do
    resolve_server "$server" || exit $?
    resolve_server_jar || exit 1
    if [[ ! -r "$SERVER_DIR/java-args" ]]; then
        log "[ERROR] Не найден файл аргументов Java: $SERVER_DIR/java-args"
        exit 1
    fi
done

screen_session_exists() {
    local server="$1"
    screen -list 2>/dev/null | grep -Eq "^[[:space:]]*[0-9]+\\.${server}[[:space:]]+\\("
}

server_listens_on_configured_port() {
    local server="$1"
    local port

    if [[ "$server" == velocity ]]; then
        port="$(sed -nE 's/^[[:space:]]*bind[[:space:]]*=[[:space:]]*"[^":]*:([0-9]+)".*/\1/p' "$PROJECT_ROOT/$server/velocity.toml" | head -n 1)"
    else
        port="$(sed -nE 's/^[[:space:]]*server-port=([0-9]+).*/\1/p' "$PROJECT_ROOT/$server/server.properties" | tail -n 1)"
    fi

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ss -H -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$" ) { found=1 } END { exit !found }'
}

wait_for_existing_server() {
    local server="$1"
    local server_dir="$2"
    local pid="$3"
    local elapsed=0

    while (( elapsed < START_TIMEOUT )); do
        if ! screen_session_exists "$server" || ! server_pid_is_valid "$pid" "$server_dir"; then
            log "[ERROR] Существующая сессия $server пропала или её PID больше не соответствует ядру"
            return 1
        fi
        if server_listens_on_configured_port "$server"; then
            log "[OK] $server уже запущен: Screen-сессия и PID $pid активны, порт слушается"
            return 0
        fi
        sleep "$CHECK_INTERVAL"
        ((elapsed += CHECK_INTERVAL))
    done

    log "[ERROR] Существующий сервер $server не начал слушать настроенный порт за ${START_TIMEOUT}с; ничего не останавливалось"
    return 1
}

start_and_wait() {
    local server="$1"
    local server_dir="$PROJECT_ROOT/$server"
    local log_file="$server_dir/logs/latest.log"
    local log_size_before=0
    local ready_pattern
    local pid=""
    local elapsed=0

    resolve_server "$server" || return $?
    resolve_server_jar || return 1

    if screen_session_exists "$server"; then
        if [[ ! -s "$server_dir/.server.pid" ]]; then
            log "[ERROR] Screen-сессия $server уже существует, но валидного PID-файла нет; требуется ручная проверка"
            return 1
        fi
        pid="$(cat "$server_dir/.server.pid")"
        if ! server_pid_is_valid "$pid" "$server_dir"; then
            log "[ERROR] Screen-сессия $server существует, но PID не соответствует серверу; ничего не останавливалось"
            return 1
        fi
        wait_for_existing_server "$server" "$server_dir" "$pid"
        return $?
    fi

    if [[ -s "$server_dir/.server.pid" ]]; then
        pid="$(cat "$server_dir/.server.pid")"
        if server_pid_is_valid "$pid" "$server_dir"; then
            log "[ERROR] $server уже работает (PID $pid) без Screen-сессии с именем $server; второй экземпляр не запускаю"
            return 1
        fi
    fi

    if [[ -f "$log_file" ]]; then
        log_size_before="$(wc -c < "$log_file")"
    fi

    log "[INFO] Запуск $server в Screen-сессии '$server'"
    if ! screen -dmS "$server" bash "$SCRIPT_DIR/startserver.sh" "$server"; then
        log "[ERROR] Не удалось создать Screen-сессию $server"
        return 1
    fi

    if [[ "$SERVER_KIND" == velocity ]]; then
        ready_pattern='Done \([0-9.]+s\)!'
    else
        ready_pattern='Done.*For help'
    fi

    while (( elapsed < START_TIMEOUT )); do
        if ! screen_session_exists "$server"; then
            log "[ERROR] Screen-сессия $server завершилась до подтверждения готовности"
            [[ -f "$log_file" ]] && tail -n 30 "$log_file"
            return 1
        fi

        if [[ -s "$server_dir/.server.pid" ]]; then
            pid="$(cat "$server_dir/.server.pid")"
            if ! server_pid_is_valid "$pid" "$server_dir"; then
                log "[ERROR] PID сервера $server не соответствует ожидаемому процессу"
                [[ -f "$log_file" ]] && tail -n 30 "$log_file"
                return 1
            fi
        fi

        if [[ -f "$log_file" ]]; then
            local log_size_now
            local start_byte
            log_size_now="$(wc -c < "$log_file")"
            if (( log_size_now < log_size_before )); then
                log_size_before=0
            fi
            start_byte=$((log_size_before + 1))
            if tail -c "+$start_byte" "$log_file" 2>/dev/null | grep -qE "$ready_pattern"; then
                if [[ -z "$pid" || ! server_pid_is_valid "$pid" "$server_dir" ]]; then
                    log "[ERROR] Найден маркер готовности $server, но PID не подтверждён"
                    return 1
                fi
                log "[OK] $server успешно запущен и готов (PID $pid)"
                return 0
            fi
        fi

        sleep "$CHECK_INTERVAL"
        ((elapsed += CHECK_INTERVAL))
    done

    log "[ERROR] $server не сообщил о готовности за ${START_TIMEOUT}с; следующие серверы запускаться не будут"
    [[ -f "$log_file" ]] && tail -n 30 "$log_file"
    return 1
}

log "[INFO] Последовательный запуск серверов: ${SERVER_START_ORDER[*]}"
for server in "${SERVER_START_ORDER[@]}"; do
    if ! start_and_wait "$server"; then
        exit 1
    fi
done

log "[OK] Все серверы запущены или уже работают и прошли проверки"
