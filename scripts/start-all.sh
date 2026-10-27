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

# Use the account's normal Screen socket so sessions created by previous runs
# are visible and cannot be accidentally duplicated in an isolated socket dir.
unset SCREENDIR

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

legacy_isolated_session_exists() {
    local server="$1"
    SCREENDIR="$PROJECT_ROOT/.screen" screen -list 2>/dev/null \
        | grep -Eq "^[[:space:]]*[0-9]+\\.${server}[[:space:]]+\\("
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

server_listener_pid() {
    local server="$1"
    local port

    if [[ "$server" == velocity ]]; then
        port="$(sed -nE 's/^[[:space:]]*bind[[:space:]]*=[[:space:]]*"[^":]*:([0-9]+)".*/\1/p' "$PROJECT_ROOT/$server/velocity.toml" | head -n 1)"
    else
        port="$(sed -nE 's/^[[:space:]]*server-port=([0-9]+).*/\1/p' "$PROJECT_ROOT/$server/server.properties" | tail -n 1)"
    fi

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ss -H -ltnp 2>/dev/null \
        | awk -v suffix=":$port" '$4 ~ (suffix "$" )' \
        | grep -oE 'pid=[0-9]+' \
        | head -n 1 \
        | cut -d= -f2
}

wait_for_existing_server() {
    local server="$1"
    local server_dir="$2"
    local pid="$3"
    local elapsed=0

    while (( elapsed < START_TIMEOUT )); do
        if ! screen_session_exists "$server"; then
            log "[ERROR] Существующая Screen-сессия $server пропала"
            return 1
        fi
        if server_listens_on_configured_port "$server"; then
            pid="$(server_listener_pid "$server")"
            if [[ -n "$pid" ]] && server_pid_is_valid "$pid" "$server_dir"; then
                log "[OK] $server уже запущен: Screen-сессия активна, PID $pid соответствует ядру и порт слушается"
                return 0
            fi
            log "[ERROR] Порт $server слушается, но PID процесса не удалось подтвердить; ничего не останавливалось"
            return 1
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

    if legacy_isolated_session_exists "$server"; then
        log "[ERROR] Найдена старая изолированная Screen-сессия $server в $PROJECT_ROOT/.screen; проверьте её вручную перед повторным запуском"
        return 1
    fi

    if screen_session_exists "$server"; then
        wait_for_existing_server "$server" "$server_dir" ""
        return $?
    fi

    if server_listens_on_configured_port "$server"; then
        pid="$(server_listener_pid "$server")"
        if server_pid_is_valid "$pid" "$server_dir"; then
            log "[ERROR] $server уже работает (PID $pid), но Screen-сессии '$server' нет; второй экземпляр не запускаю"
        elif [[ -z "$pid" ]]; then
            log "[ERROR] Порт $server уже занят, но PID не удалось определить; второй экземпляр не запускаю"
        else
            log "[ERROR] Порт $server уже занят процессом PID $pid; второй экземпляр не запускаю"
        fi
        return 1
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
                if [[ -z "$pid" ]] || ! server_pid_is_valid "$pid" "$server_dir"; then
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
