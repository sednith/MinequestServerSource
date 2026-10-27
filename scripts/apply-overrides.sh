#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

OVERRIDES_DIR="$PROJECT_ROOT/overrides"

echo "========================================="
echo "  Применение локальных overrides ко всем серверам"
echo "========================================="

if ! command -v yq >/dev/null 2>&1; then
    echo "[ERROR] Утилита yq не найдена. Установите mikefarah/yq." >&2
    exit 1
fi

if [[ ! -d "$OVERRIDES_DIR" ]]; then
    echo "[WARN] Локальная папка $OVERRIDES_DIR не найдена. Нечего применять."
    exit 0
fi

discover_server_dirs

if (( ${#SERVER_DIRS[@]} == 0 )); then
    echo "[ERROR] Не найдены серверные папки с java-args и JAR-файлом; overrides не применены." >&2
    exit 1
fi

applied=0
skipped=0
errors=0

while IFS= read -r -d '' override_file; do
    relative_path="${override_file#"$OVERRIDES_DIR"/}"

    for server_dir in "${SERVER_DIRS[@]}"; do
        base_file="$server_dir/$relative_path"

        echo ""
        echo "[INFO] Обработка $(basename -- "$server_dir"): $relative_path"
        if [[ ! -f "$base_file" ]]; then
            echo "       [WARN] Базовый файл не найден, пропуск"
            ((skipped += 1))
            continue
        fi

        if [[ "$base_file" == *.yml || "$base_file" == *.yaml || "$base_file" == *.json ]]; then
            if yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$base_file" "$override_file" > "${base_file}.tmp" 2>/dev/null; then
                mv -- "${base_file}.tmp" "$base_file"
                echo "       [OK] YAML/JSON override применён"
                ((applied += 1))
            else
                rm -f -- "${base_file}.tmp"
                echo "       [ERROR] Ошибка применения YAML/JSON override"
                ((errors += 1))
            fi
        elif [[ "$base_file" == *.properties ]]; then
            prop_ok=true
            for key in $(yq e 'keys | .[]' "$override_file" 2>/dev/null); do
                value=$(yq e ".\"$key\"" "$override_file" 2>/dev/null)
                if ! yq -i ".\"$key\" = \"$value\"" "$base_file" 2>/dev/null; then
                    echo "       [ERROR] Ошибка применения ключа: $key"
                    prop_ok=false
                fi
            done
            if [[ "$prop_ok" == true ]]; then
                echo "       [OK] Properties override применён"
                ((applied += 1))
            else
                ((errors += 1))
            fi
        else
            echo "       [WARN] Неизвестный формат файла, пропуск"
            ((skipped += 1))
        fi
    done
done < <(find "$OVERRIDES_DIR" -type f -print0 | sort -z)

echo ""
echo "========================================="
echo "  Итого: применено=$applied, пропущено=$skipped, ошибок=$errors"
echo "========================================="

if (( errors > 0 )); then
    echo "[ERROR] Overrides применены с ошибками." >&2
    exit 1
fi

echo "[OK] Локальные overrides обработаны"
