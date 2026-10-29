#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
cd "$PROJECT_ROOT"

CHECKER_BASELINE_DIR=""
CHECKER_EXIT_CODE=0
TEMP_COMMIT_CREATED=false
TEMP_COMMIT_HASH=""
TEMP_COMMIT_PARENT=""
cleanup_temporary_commit() {
    [[ "$TEMP_COMMIT_CREATED" == true ]] || return 0
    local current_hash current_root current_branch
    current_hash=$(git rev-parse HEAD 2>/dev/null || true)
    current_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    current_branch=$(git branch --show-current 2>/dev/null || true)
    if [[ "$current_root" == "/home/server/dev" && "$current_branch" == "dev" && "$current_hash" == "$TEMP_COMMIT_HASH" ]]; then
        echo "[INFO] Удаление только временного коммита B..."
        if git reset --mixed "$TEMP_COMMIT_PARENT"; then
            TEMP_COMMIT_CREATED=false
        else
            echo "[ERROR] Не удалось удалить временный commit B" >&2
            return 1
        fi
    else
        echo "[ERROR] Не удаляю commit: HEAD/ветка/корень изменились после создания B" >&2
        return 1
    fi
}
cleanup_on_exit() {
    local exit_code=$?
    trap - EXIT

    cleanup_temporary_commit || exit_code=1
    if [[ -n "$CHECKER_BASELINE_DIR" && -d "$CHECKER_BASELINE_DIR" ]]; then
        rm -rf -- "$CHECKER_BASELINE_DIR"
    fi
    exit "$exit_code"
}
trap cleanup_on_exit EXIT

if (( $# != 0 )); then
    echo "Использование: bash scripts/deploy-dev.sh" >&2
    exit 2
fi

SERVER_START_ORDER=(
    "playworld"
    "adjustment"
    "velocity"
)

validate_server_order() {
    local server
    local server_dir
    local found
    local existing
    local i
    local j

    if (( ${#SERVER_START_ORDER[@]} == 0 )); then
        log "[ERROR] Массив SERVER_START_ORDER пуст"
        return 1
    fi

    for ((i = 0; i < ${#SERVER_START_ORDER[@]}; i++)); do
        for ((j = i + 1; j < ${#SERVER_START_ORDER[@]}; j++)); do
            if [[ "${SERVER_START_ORDER[i]}" == "${SERVER_START_ORDER[j]}" ]]; then
                log "[ERROR] Сервер '${SERVER_START_ORDER[i]}' повторяется в SERVER_START_ORDER"
                return 1
            fi
        done
    done

    discover_server_dirs
    if (( ${#SERVER_DIRS[@]} == 0 )); then
        log "[ERROR] Не найдены серверные папки с java-args и JAR-файлом"
        return 1
    fi

    for server in "${SERVER_START_ORDER[@]}"; do
        resolve_server "$server" || return $?
        resolve_server_jar || return 1
        if [[ ! -r "$SERVER_DIR/java-args" ]]; then
            log "[ERROR] Не найден файл аргументов Java: $SERVER_DIR/java-args"
            return 1
        fi

    done

    for server_dir in "${SERVER_DIRS[@]}"; do
        server="$(basename -- "$server_dir")"
        found=false
        for existing in "${SERVER_START_ORDER[@]}"; do
            if [[ "$existing" == "$server" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" != true ]]; then
            log "[ERROR] Сервер '$server' обнаружен, но отсутствует в массиве SERVER_START_ORDER"
            return 1
        fi
    done
}

echo "========================================="
echo "  Deploy Dev Environment"
echo "========================================="

echo ""
echo "[STAGE 1/4] Sync git & Apply Overrides"
echo "-----------------------------------------"

echo "[INFO] Синхронизация с origin/dev..."
PRE_SYNC_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
git fetch origin dev
git checkout -f -B dev origin/dev
git reset --hard origin/dev

# Сценарий читается из рабочего дерева, которое сам же и обновляет: если в этом
# пуше изменился deploy-dev.sh, работающий bash дочитает старый файл и выполнит
# устаревший код поверх новых скриптов. Перезапускаемся на актуальной версии.
if [[ -n "$PRE_SYNC_HEAD" && "$PRE_SYNC_HEAD" != "$(git rev-parse HEAD 2>/dev/null || true)" && "${DEPLOY_DEV_REEXEC:-0}" != 1 ]]; then
    echo "[INFO] Рабочее дерево обновилось; перезапуск deploy-dev.sh на актуальной версии"
    export DEPLOY_DEV_REEXEC=1
    exec bash "$SCRIPT_DIR/deploy-dev.sh"
fi

echo "[INFO] Проверка заданного порядка рестарта серверов..."
validate_server_order
echo "[INFO] Порядок рестарта: ${SERVER_START_ORDER[*]}"

echo "[INFO] Применение overrides..."
bash "$SCRIPT_DIR/apply-overrides.sh"

echo "[INFO] Фиксация Состояния B без secret-rendered файлов..."
if ! python3 -c 'import sys; sys.path.insert(0, "scripts/render-secrets"); from manifest import load_manifest; load_manifest()' >/dev/null 2>&1; then
    echo "[ERROR] Не удалось проверить манифест секретных файлов; commit B не создаётся" >&2
    exit 1
fi
mapfile -d '' -t SECRET_PATHS < <(python3 -c 'import sys; sys.path.insert(0, "scripts/render-secrets"); from manifest import load_manifest; [sys.stdout.buffer.write(path.encode() + b"\0") for path, _ in load_manifest()]')
if (( ${#SECRET_PATHS[@]} == 0 )); then
    echo "[ERROR] Манифест не содержит путей; commit B не создаётся" >&2
    exit 1
fi
EXCLUDED_PATHS=()
for secret_path in "${SECRET_PATHS[@]}"; do
    EXCLUDED_PATHS+=(":(exclude)$secret_path")
done
git add -A -- . "${EXCLUDED_PATHS[@]}"
if ! git diff --cached --quiet; then
    TEMP_COMMIT_PARENT=$(git rev-parse HEAD)
    git commit -m "ci: temporary state B for checker"
    TEMP_COMMIT_HASH=$(git rev-parse HEAD)
    TEMP_COMMIT_CREATED=true
    echo "[INFO] Commit B создан; manifest secret-файлы исключены из индекса"
else
    echo "[INFO] Изменений для временного commit B нет"
fi

echo "[INFO] Подстановка локальных секретов после фиксации B..."
python3 "$SCRIPT_DIR/render-secrets/render-secrets.py"
CHECKER_BASELINE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minequest-checker.XXXXXX")"
chmod 700 "$CHECKER_BASELINE_DIR"
export CHECKER_BASELINE_DIR
python3 "$SCRIPT_DIR/render-secrets/snapshot-configs.py" "$CHECKER_BASELINE_DIR"

echo "[OK] Stage 1 завершена"

echo ""
echo "[STAGE 2/4] Restart Servers In Configured Order"
echo "-----------------------------------------"

bash "$SCRIPT_DIR/restart.sh" dev

echo "[OK] Stage 2 завершена: все серверы готовы"

echo ""
echo "[STAGE 3/4] Check Changes"
echo "-----------------------------------------"

echo "[INFO] Запуск Checker'а..."
if bash "$SCRIPT_DIR/checker.sh"; then
    :
else
    CHECKER_EXIT_CODE=$?
    REPORT_DIR="$PROJECT_ROOT/checker-report"
    echo "[ERROR] Checker завершился с ошибкой. Отчёты для диагностики:"
    for report_file in "$REPORT_DIR/git-status.txt" "$REPORT_DIR/git-diff.txt"; do
        if [[ -f "$report_file" ]]; then
            echo "----- $(basename -- "$report_file") -----"
            cat -- "$report_file"
            echo "----- конец $(basename -- "$report_file") -----"
        else
            echo "[WARN] Файл отчёта не создан: $(basename -- "$report_file")"
        fi
    done
fi

if (( CHECKER_EXIT_CODE == 0 )); then
    echo "[OK] Stage 3 завершена"
else
    echo "[ERROR] Stage 3 завершена с ошибкой; перехожу к обязательной очистке B"
fi

echo ""
echo "[STAGE 4/4] Cleanup"
echo "-----------------------------------------"

echo "[INFO] Очистка временного коммита..."
if [[ "$TEMP_COMMIT_CREATED" == true ]]; then
    cleanup_temporary_commit
else
    echo "[INFO] Временный коммит не создавался."
fi

echo "[OK] Stage 4 завершена"
echo ""
echo "========================================="
if (( CHECKER_EXIT_CODE != 0 )); then
    echo "[ERROR] DEV DEPLOY FAILED: Checker обнаружил неизвестные изменения"
    echo "========================================="
    exit "$CHECKER_EXIT_CODE"
fi
echo "[OK] DEV DEPLOY COMPLETED SUCCESSFULLY"
echo "========================================="
