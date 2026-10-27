#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
cd "$PROJECT_ROOT"

CHECKERIGNORE_FILE="$PROJECT_ROOT/.checkerignore"
REPORT_DIR="$PROJECT_ROOT/checker-report"
mkdir -p "$REPORT_DIR"

echo "========================================="
echo "  Checker: Сравнение состояния B и C"
echo "========================================="

# 1. Сохраняем артефакты
git status --porcelain > "$REPORT_DIR/git-status.txt"
git diff HEAD > "$REPORT_DIR/git-diff.txt"

# 2. Если изменений нет — всё отлично
if [ ! -s "$REPORT_DIR/git-status.txt" ]; then
    echo "[INFO] Изменений после запуска сервера не обнаружено."
    exit 0
fi

echo "[WARN] Обнаружены изменения в рабочей директории. Начинаем анализ..."

# 3. Парсинг .checkerignore
declare -a GLOB_RULES=()
declare -A KEY_RULES=()
declare -A REGEX_RULES=()

if [ -f "$CHECKERIGNORE_FILE" ]; then
    echo "[INFO] Загрузка правил игнорирования из: $CHECKERIGNORE_FILE"
    # || [ -n "$rule" ] гарантирует чтение последней строки, даже если нет переноса \n
    while IFS= read -r rule || [ -n "$rule" ]; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$rule" || "$rule" =~ ^[[:space:]]*# ]] && continue
        
        # Убираем пробелы и скрытые \r по краям
        rule=$(echo "$rule" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
        [[ -z "$rule" ]] && continue
        
        if [[ "$rule" == *:* ]]; then
            file_pattern="${rule%%:*}"
            inner_rule="${rule#*:}"
            
            if [[ "$inner_rule" == \#* ]]; then
                # REGEX (убираем первый символ #)
                regex="${inner_rule:1}"
                REGEX_RULES["$file_pattern"]+="$regex"$'\n'
            else
                # KEY (точное совпадение)
                KEY_RULES["$file_pattern"]+="$inner_rule"$'\n'
            fi
        else
            # GLOB (файлы и папки)
            GLOB_RULES+=("$rule")
        fi
    done < "$CHECKERIGNORE_FILE"
else
    echo "[WARN] Файл $CHECKERIGNORE_FILE не найден. Работаем в строгом режиме без правил игнорирования."
fi

# 4. Функция проверки glob-паттернов
matches_glob() {
    local file="$1"
    shift
    
    # Убираем / на конце (git status добавляет его для папок)
    file="${file%/}"
    
    for pattern in "$@"; do
        pattern="${pattern%/}"
        
        if [[ "$file" == "$pattern"/* || "$file" == "$pattern" ]]; then
            return 0
        fi
        
        if [[ "$file" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# 5. Функция проверки ключа против KEY_RULES
is_key_allowed() {
    local file="$1"
    local key="$2"
    
    if [[ -n "${KEY_RULES[$file]+x}" ]]; then
        if echo "${KEY_RULES[$file]}" | grep -qFx "$key"; then
            return 0
        fi
    fi
    return 1
}

# 6. Функция проверки строки против REGEX_RULES
is_line_allowed_by_regex() {
    local file="$1"
    local line="$2"
    
    if [[ -n "${REGEX_RULES[$file]+x}" ]]; then
        while IFS= read -r regex; do
            [[ -z "$regex" ]] && continue
            if echo "$line" | grep -qE "$regex"; then
                return 0
            fi
        done <<< "${REGEX_RULES[$file]}"
    fi
    return 1
}

HAS_UNKNOWN_CHANGES=false

# 7. Читаем git status построчно
while IFS= read -r status_line || [ -n "$status_line" ]; do
    [ -z "$status_line" ] && continue
    
    file_status="${status_line:0:2}"
    file_path="${status_line:3}"
    
    # Новые файлы (??)
    if [[ "$file_status" == "??" ]]; then
        if matches_glob "$file_path" "${GLOB_RULES[@]+"${GLOB_RULES[@]}"}"; then
            echo "[INFO] Игнор нового файла (glob): $file_path"
            continue
        fi
        echo "[ERROR] Неизвестный новый файл: $file_path"
        HAS_UNKNOWN_CHANGES=true
        continue
    fi
    
    # Измененные файлы (M, A, R, C)
    if [[ "$file_status" =~ ^[M\ A\ R\ C] ]]; then
        echo "[INFO] Анализ файла: $file_path"
        
        # Проверяем glob-правила (игнор файла целиком)
        if matches_glob "$file_path" "${GLOB_RULES[@]+"${GLOB_RULES[@]}"}"; then
            echo "       [INFO] Игнор файла целиком (glob)"
            continue
        fi
        
        if [[ "$file_path" == *.properties ]]; then
            # Извлекаем ТОЛЬКО добавленные строки (^+), чтобы не проверять удаленные (-)
            changed_lines=$(git diff HEAD -- "$file_path" | grep '^+[^+]' | sed 's/^+//' | tr -d '\r')
            
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                
                if [[ "$line" == *=* ]]; then
                    key=$(echo "$line" | cut -d'=' -f1 | tr -d ' ')
                    
                    if is_key_allowed "$file_path" "$key"; then
                        echo "       [INFO] Разрешенное изменение ключа: $key"
                        continue
                    fi
                    
                    if is_line_allowed_by_regex "$file_path" "$line"; then
                        echo "       [INFO] Разрешенное изменение (regex): $key"
                        continue
                    fi
                    
                    echo "       [ERROR] Неизвестное изменение ключа: $key"
                    HAS_UNKNOWN_CHANGES=true
                else
                    if is_line_allowed_by_regex "$file_path" "$line"; then
                        echo "       [INFO] Разрешенное изменение (regex): $line"
                        continue
                    fi
                    
                    echo "       [ERROR] Неизвестное изменение строки: $line"
                    HAS_UNKNOWN_CHANGES=true
                fi
            done <<< "$changed_lines"
            
        elif [[ "$file_path" == *.yml ]] || [[ "$file_path" == *.yaml ]] || [[ "$file_path" == *.json ]]; then
            changed_lines=$(git diff HEAD -- "$file_path" | grep '^+[^+]' | sed 's/^+//' | tr -d '\r')
            
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                
                if is_line_allowed_by_regex "$file_path" "$line"; then
                    echo "       [INFO] Разрешенное изменение (regex): $line"
                    continue
                fi
                
                echo "       [ERROR] Неизвестное изменение в конфиге: $line"
                HAS_UNKNOWN_CHANGES=true
            done <<< "$changed_lines"
            
        else
            echo "       [ERROR] Неожиданное изменение файла: $file_path"
            HAS_UNKNOWN_CHANGES=true
        fi
    fi
done < "$REPORT_DIR/git-status.txt"

echo "========================================="
if [ "$HAS_UNKNOWN_CHANGES" = true ]; then
    echo "[ERROR] CHECKER FAILED: Обнаружены неизвестные изменения!"
    echo "[INFO] Артефакты для диагностики сохранены в: $REPORT_DIR/"
    echo "       - $REPORT_DIR/git-status.txt"
    echo "       - $REPORT_DIR/git-diff.txt"
    exit 1
else
    echo "[INFO] CHECKER PASSED: Все изменения соответствуют правилам."
    exit 0
fi
