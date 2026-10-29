#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

LAST_GOOD_SHA_FILE="$PROJECT_ROOT/.last-good-deploy-sha"
LAST_GOOD_SHA=""

usage() {
    echo "Использование: bash scripts/rollback-prod.sh" >&2
}

if (( $# != 0 )); then
    usage
    exit 2
fi

log "[INFO] PROJECT_ROOT: $PROJECT_ROOT"

load_last_good_sha() {
    if [[ ! -s "$LAST_GOOD_SHA_FILE" ]]; then
        log "[CRITICAL] Не найден SHA последней успешной версии: $LAST_GOOD_SHA_FILE"
        return 1
    fi
    LAST_GOOD_SHA="$(tr -d '[:space:]' < "$LAST_GOOD_SHA_FILE")"
    if [[ ! "$LAST_GOOD_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
        log "[CRITICAL] Некорректный SHA последней успешной версии в $LAST_GOOD_SHA_FILE"
        return 1
    fi
    if ! git -C "$PROJECT_ROOT" cat-file -e "${LAST_GOOD_SHA}^{commit}" 2>/dev/null; then
        log "[CRITICAL] Коммит $LAST_GOOD_SHA отсутствует в репозитории PROD"
        return 1
    fi
}

load_last_good_sha || exit 1

# The checkout below may restore a tree where the current restart pipeline does
# not exist yet (last-good can predate these scripts). Keep a snapshot of the
# current scripts next to the project root: SCRIPT_DIR/.. stays equal to
# PROJECT_ROOT, so the copied scripts resolve the same stand.
RESCUE_SCRIPTS_DIR="$PROJECT_ROOT/.rollback-scripts.$$"
cleanup_rescue_scripts() {
    rm -rf -- "$RESCUE_SCRIPTS_DIR"
}
trap cleanup_rescue_scripts EXIT

if ! cp -a -- "$SCRIPT_DIR" "$RESCUE_SCRIPTS_DIR"; then
    log "[CRITICAL] Не удалось подготовить копию скриптов для отката"
    exit 1
fi
RESCUE_RESTART="$RESCUE_SCRIPTS_DIR/restart.sh"
RESCUE_RENDER="$RESCUE_SCRIPTS_DIR/render-secrets/render-secrets.py"
if [[ ! -f "$RESCUE_RESTART" || ! -f "$RESCUE_RENDER" ]]; then
    log "[CRITICAL] Копия скриптов для отката неполная"
    exit 1
fi

log "[INFO] Возврат PROD к последней успешной версии $LAST_GOOD_SHA"
if ! git -C "$PROJECT_ROOT" checkout -f -B main "$LAST_GOOD_SHA"; then
    log "[CRITICAL] Не удалось переключить PROD на $LAST_GOOD_SHA"
    exit 1
fi
if ! git -C "$PROJECT_ROOT" reset --hard "$LAST_GOOD_SHA"; then
    log "[CRITICAL] Не удалось сбросить рабочее дерево PROD на $LAST_GOOD_SHA"
    exit 1
fi

log "[INFO] Подстановка локальных секретов после отката"
if ! python3 "$RESCUE_RENDER"; then
    log "[CRITICAL] Не удалось подставить секреты после отката; серверы не перезапущены"
    exit 1
fi

log "[INFO] Перезапуск всех серверов PROD на версии $LAST_GOOD_SHA"
if ! bash "$RESCUE_RESTART" prod --no-rollback; then
    log "[CRITICAL] Откатный рестарт PROD не прошёл проверку; повторный откат не выполняется"
    exit 1
fi

log "[OK] PROD откачен на $LAST_GOOD_SHA; все серверы перезапущены и проверены"
