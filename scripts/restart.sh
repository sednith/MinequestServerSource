#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

SERVER_RESTART_ORDER=(playworld adjustment velocity)
TARGET_ENV="${1:-}"
NO_ROLLBACK=false
ROLLBACK_AVAILABLE=false
LAST_GOOD_SHA_FILE="$PROJECT_ROOT/.last-good-deploy-sha"

usage() {
    echo "Использование: bash scripts/restart.sh <dev|prod> [--no-rollback]" >&2
}

if (( $# < 1 || $# > 2 )); then
    usage
    exit 2
fi
case "$TARGET_ENV" in
    dev|prod) ;;
    *) usage; exit 2 ;;
esac
if (( $# == 2 )); then
    if [[ "$2" != "--no-rollback" ]]; then
        usage
        exit 2
    fi
    NO_ROLLBACK=true
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
log "[INFO] PROJECT_ROOT: $PROJECT_ROOT"
log "[INFO] Последовательный рестарт серверов: ${SERVER_RESTART_ORDER[*]}"

rollback_sha_is_valid() {
    local sha
    [[ -s "$LAST_GOOD_SHA_FILE" ]] || return 1
    sha="$(tr -d '[:space:]' < "$LAST_GOOD_SHA_FILE")"
    [[ "$sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
    git -C "$PROJECT_ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null
}

# A single restart per stand at a time: the second run must not fight over the
# same FIFO/PID. The lock lives outside the worktree so git status stays clean.
if [[ "${MINQUEST_RESTART_LOCK_HELD:-0}" != 1 ]]; then
    if command -v flock >/dev/null 2>&1 && command -v sha1sum >/dev/null 2>&1; then
        RESTART_LOCK_FILE="${TMPDIR:-/tmp}/minequest-restart-$(printf '%s' "$PROJECT_ROOT" | sha1sum | cut -c1-16).lock"
        if ! exec 9>"$RESTART_LOCK_FILE"; then
            log "[ERROR] Не удалось открыть файл блокировки: $RESTART_LOCK_FILE"
            exit 1
        fi
        if ! flock -n 9; then
            log "[ERROR] Рестарт $PROJECT_ROOT уже выполняется другим процессом"
            exit 1
        fi
        MINQUEST_RESTART_LOCK_HELD=1
        export MINQUEST_RESTART_LOCK_HELD
    else
        log "[WARN] flock/sha1sum недоступны; блокировка параллельных рестартов отключена"
    fi
fi

if [[ "$TARGET_ENV" == prod && "$NO_ROLLBACK" != true ]]; then
    if rollback_sha_is_valid; then
        ROLLBACK_AVAILABLE=true
    else
        log "[WARN] Откат недоступен: $LAST_GOOD_SHA_FILE отсутствует или содержит недействительный SHA; при неудаче PROD останется на развёрнутой версии"
    fi
fi

# Secrets are rendered before any server is stopped; the same is true for DEV
# overrides. A failure here leaves the running stand untouched.
log "[INFO] Подстановка локальных секретов перед остановкой серверов"
if ! python3 "$SCRIPT_DIR/render-secrets/render-secrets.py"; then
    log "[ERROR] Не удалось подставить локальные секреты; ни один сервер не остановлен"
    exit 1
fi

if [[ "$TARGET_ENV" == dev ]]; then
    log "[INFO] DEV: применение локальных overrides перед остановкой серверов"
    if ! bash "$SCRIPT_DIR/apply-overrides.sh"; then
        log "[ERROR] Не удалось применить overrides; ни один сервер не остановлен"
        exit 1
    fi
else
    log "[INFO] PROD: overrides не применяются (они существуют только для DEV)"
fi

for server in "${SERVER_RESTART_ORDER[@]}"; do
    log "[INFO] Рестарт сервера '$server' с проверкой готовности..."
    if bash "$SCRIPT_DIR/restart-server.sh" "$server"; then
        continue
    fi

    log "[ERROR] Рестарт '$server' завершился ошибкой"
    if [[ "$TARGET_ENV" != prod ]]; then
        log "[ERROR] Остальные серверы не перезапускаются; для DEV откат не предусмотрен"
        exit 1
    fi
    if [[ "$NO_ROLLBACK" == true ]]; then
        log "[ERROR] Остальные серверы не перезапускаются; откат отключён (--no-rollback)"
        exit 1
    fi
    if [[ "$ROLLBACK_AVAILABLE" != true ]]; then
        log "[ERROR] Остальные серверы не перезапускаются; откат невозможен без подтверждённого SHA"
        exit 1
    fi

    log "[WARN] Откат PROD на последнюю успешную версию"
    if bash "$SCRIPT_DIR/rollback-prod.sh"; then
        log "[ERROR] PROD откачен на последнюю успешную версию и перезапущен"
    else
        log "[CRITICAL] Откат PROD завершился ошибкой; требуется ручное вмешательство"
    fi
    exit 1
done

log "[OK] Все серверы стенда $TARGET_ENV успешно перезапущены и проверены"
