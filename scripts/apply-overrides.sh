#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

OVERRIDES_DIR="$PROJECT_ROOT/overrides"

echo "========================================="
echo "  Применение локальных overrides по путям из корня репозитория"
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

    # Override paths mirror repository paths (e.g. playworld/plugins/...).
    # Resolve each file once from the repository root, then ensure it belongs
    # to exactly one discovered server instead of appending it to every server.
    base_file="$PROJECT_ROOT/$relative_path"
    server_dir=""
    for candidate_server_dir in "${SERVER_DIRS[@]}"; do
        if [[ "$base_file" == "$candidate_server_dir"/* ]]; then
            if [[ -n "$server_dir" ]]; then
                echo "[ERROR] Путь override соответствует нескольким серверам: $relative_path"
                ((errors += 1))
                server_dir=""
                break
            fi
            server_dir="$candidate_server_dir"
        fi
    done

    if [[ -z "$server_dir" ]]; then
        echo "[WARN] Override не относится к каталогу найденного сервера, пропуск: $relative_path"
        ((skipped += 1))
        continue
    fi

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
    elif [[ "$base_file" == *.toml ]]; then
        if yq eval-all --input-format toml --output-format toml 'select(fileIndex == 0) * select(fileIndex == 1)' "$base_file" "$override_file" > "${base_file}.tmp" 2>/dev/null; then
            mv -- "${base_file}.tmp" "$base_file"
            echo "       [OK] TOML override применён"
            ((applied += 1))
        else
            rm -f -- "${base_file}.tmp"
            echo "       [ERROR] Ошибка применения TOML override"
            ((errors += 1))
        fi
    elif [[ "$(basename -- "$base_file")" == java-args ]]; then
        override_xmx=""
        override_count=0
        override_invalid=false
        while IFS= read -r arg || [[ -n "$arg" ]]; do
            arg="${arg//$'\r'/}"
            arg="${arg#"${arg%%[![:space:]]*}"}"
            arg="${arg%"${arg##*[![:space:]]}"}"
            [[ -z "$arg" || "$arg" == \#* ]] && continue

            if [[ "$arg" =~ ^-Xmx[0-9]+([kKmMgG])?$ ]]; then
                override_xmx="$arg"
                ((override_count += 1))
            else
                echo "       [ERROR] Override java-args должен содержать только один параметр -Xmx<размер>; некорректная строка: $arg"
                override_invalid=true
            fi
        done < "$override_file"

        if [[ "$override_invalid" == true ]]; then
            ((errors += 1))
            continue
        fi
        if (( override_count == 0 )); then
            echo "       [ERROR] В override java-args не найден параметр -Xmx"
            ((errors += 1))
            continue
        elif (( override_count > 1 )); then
            echo "       [ERROR] В override java-args указано несколько параметров -Xmx ($override_count)"
            ((errors += 1))
            continue
        fi

        read -r base_xmx_count base_xmx_malformed < <(
            awk '
                /^[[:space:]]*#/ { next }
                {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^-Xmx/) {
                            if ($i ~ /^-Xmx[0-9]+([kKmMgG])?$/) count++
                            else malformed++
                        }
                    }
                }
                END { print count + 0, malformed + 0 }
            ' "$base_file"
        )
        if (( base_xmx_malformed > 0 )); then
            echo "       [ERROR] В базовом java-args найден некорректный параметр -Xmx"
            ((errors += 1))
            continue
        elif (( base_xmx_count == 0 )); then
            echo "       [ERROR] В базовом java-args отсутствует параметр -Xmx; override не добавляет новые параметры"
            ((errors += 1))
            continue
        elif (( base_xmx_count > 1 )); then
            echo "       [ERROR] В базовом java-args найдено несколько параметров -Xmx ($base_xmx_count); замена неоднозначна"
            ((errors += 1))
            continue
        fi

        tmp_file="$(mktemp "${base_file}.tmp.XXXXXX")"
        if sed -E '/^[[:space:]]*#/! s/(^|[[:space:]])-Xmx[^[:space:]]*/\1'"$override_xmx"'/' "$base_file" > "$tmp_file" \
            && chmod --reference="$base_file" "$tmp_file" \
            && mv -- "$tmp_file" "$base_file"; then
            echo "       [OK] Параметр -Xmx заменён на $override_xmx; остальные аргументы сохранены"
            ((applied += 1))
        else
            rm -f -- "$tmp_file"
            echo "       [ERROR] Ошибка обновления параметра -Xmx"
            ((errors += 1))
        fi
    elif [[ "$base_file" == *.properties ]]; then
        prop_ok=true
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            value=$(yq e ".\"$key\"" "$override_file" 2>/dev/null)
            if ! yq -i ".\"$key\" = \"$value\"" "$base_file" 2>/dev/null; then
                echo "       [ERROR] Ошибка применения ключа: $key"
                prop_ok=false
            fi
        done < <(yq e 'keys | .[]' "$override_file" 2>/dev/null)
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
