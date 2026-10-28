#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

SERVER_RESTART_ORDER=(playworld adjustment velocity)
TARGET_ENV="${1:-}"

usage() {
    echo "Использование: bash scripts/restart.sh <dev|prod>" >&2
}

if (( $# != 1 )) || [[ "$TARGET_ENV" != dev && "$TARGET_ENV" != prod ]]; then
    usage
    exit 2
fi

# Validate every server before stopping any of them, so configuration mistakes
# do not leave the stand partially restarted.
for server in "${SERVER_RESTART_ORDER[@]}"; do
    resolve_server "$server" || exit $?
    resolve_server_jar || exit 1
    if [[ ! -r "$SERVER_DIR/java-args" ]]; then
        log "[ERROR] Не найден файл аргументов Java: $SERVER_DIR/java-args"
        exit 1
    fi
done

log "[INFO] Окружение: $TARGET_ENV"
log "[INFO] Последовательный рестарт серверов: ${SERVER_RESTART_ORDER[*]}"
log "[INFO] Overrides не применяются"

for server in "${SERVER_RESTART_ORDER[@]}"; do
    log "[INFO] Рестарт сервера '$server' с проверкой готовности..."
    if ! bash "$SCRIPT_DIR/restart-server.sh" "$server"; then
        log "[ERROR] Рестарт '$server' завершился ошибкой; остальные серверы не будут перезапущены"
        exit 1
    fi
done

log "[OK] Все серверы стенда $TARGET_ENV успешно перезапущены и проверены"
