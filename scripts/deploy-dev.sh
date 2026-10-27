#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
cd "$PROJECT_ROOT"

if (( $# != 0 )); then
    echo "Использование: bash scripts/deploy-dev.sh" >&2
    exit 2
fi

# Порядок рестарта задаётся здесь. Добавьте имена папок серверов в нужной
# последовательности; каждая папка должна содержать java-args и один JAR.
SERVER_START_ORDER=(
    "__SET_ORDER__"
    # "lobby"
    # "mainworld"
    # "velocity"
)

validate_server_order() {
    local server
    local server_dir
    local found
    local existing
    local i
    local j

    if (( ${#SERVER_START_ORDER[@]} == 1 )) && [[ "${SERVER_START_ORDER[0]}" == "__SET_ORDER__" ]]; then
        log "[ERROR] Массив SERVER_START_ORDER не настроен. Укажите папки серверов в начале deploy-dev.sh"
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
git fetch origin dev
git checkout -f -B dev origin/dev
git reset --hard origin/dev

echo "[INFO] Проверка заданного порядка рестарта серверов..."
validate_server_order
echo "[INFO] Порядок рестарта: ${SERVER_START_ORDER[*]}"

chmod +x "$SCRIPT_DIR/apply-overrides.sh" "$SCRIPT_DIR/restart.sh" "$SCRIPT_DIR/checker.sh"

echo "[INFO] Применение overrides..."
bash "$SCRIPT_DIR/apply-overrides.sh"

echo "[INFO] Фиксация Состояния B..."
git add .
git commit -m "ci: temporary state B for checker" || true

echo "[OK] Stage 1 завершена"

echo ""
echo "[STAGE 2/4] Restart Servers In Configured Order"
echo "-----------------------------------------"

for server in "${SERVER_START_ORDER[@]}"; do
    echo ""
    echo "[INFO] Перезапуск сервера '$server' с проверкой готовности..."
    bash "$SCRIPT_DIR/restart.sh" "$server"
    echo "[OK] Сервер '$server' успешно перезапущен и проверен"
done

echo "[OK] Stage 2 завершена: все серверы готовы"

echo ""
echo "[STAGE 3/4] Check Changes"
echo "-----------------------------------------"

echo "[INFO] Запуск Checker'а..."
bash "$SCRIPT_DIR/checker.sh"

echo "[OK] Stage 3 завершена"

echo ""
echo "[STAGE 4/4] Cleanup"
echo "-----------------------------------------"

echo "[INFO] Очистка временного коммита..."
LAST_COMMIT_MSG=$(git log -1 --pretty=%B | tr -d '\n')

if [[ "$LAST_COMMIT_MSG" == *"ci: temporary state B for checker"* ]]; then
    echo "[INFO] Временный коммит найден. Выполняю откат..."
    git reset --soft HEAD~1
    git reset HEAD
    echo "[INFO] Откат завершён."
else
    echo "[INFO] Временный коммит не создавался (не было изменений). Пропускаю откат, состояние чистое."
fi

echo "[OK] Stage 4 завершена"
echo ""
echo "========================================="
echo "[OK] DEV DEPLOY COMPLETED SUCCESSFULLY"
echo "========================================="
