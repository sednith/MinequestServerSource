#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SERVER_DIRS=()

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

resolve_server() {
    local name="${1:-}"

    if [[ -z "$name" || "$name" == "." || "$name" == ".." || "$name" == */* ]]; then
        log "[ERROR] Укажите имя непосредственной папки сервера в корне репозитория (без пути)"
        return 2
    fi

    SERVER_NAME="$name"
    if [[ ! -d "$PROJECT_ROOT/$SERVER_NAME" ]]; then
        log "[ERROR] Папка сервера не найдена: $PROJECT_ROOT/$SERVER_NAME"
        return 1
    fi
    SERVER_DIR="$(cd -- "$PROJECT_ROOT/$SERVER_NAME" && pwd -P)"
}

discover_server_dirs() {
    local candidate
    local jar
    local jars=()
    SERVER_DIRS=()
    shopt -s nullglob

    for candidate in "$PROJECT_ROOT"/*/; do
        [[ -d "$candidate" && -f "$candidate/java-args" ]] || continue
        jars=("$candidate"/*.jar)
        (( ${#jars[@]} > 0 )) || continue
        for jar in "${jars[@]}"; do
            if [[ -f "$jar" ]]; then
                SERVER_DIRS+=("${candidate%/}")
                break
            fi
        done
    done
}

resolve_server_jar() {
    local candidate
    local candidates=()
    shopt -s nullglob

    for candidate in "$SERVER_DIR"/*.jar; do
        [[ -f "$candidate" ]] && candidates+=("$candidate")
    done

    if (( ${#candidates[@]} != 1 )); then
        log "[ERROR] В $SERVER_DIR должен быть ровно один JAR-файл ядра; найдено: ${#candidates[@]}"
        return 1
    fi

    SERVER_JAR="${candidates[0]}"
    case "$(basename -- "$SERVER_JAR")" in
        velocity*.jar) SERVER_KIND=velocity ;;
        *) SERVER_KIND=paper ;;
    esac
}

# Возвращает JAR, с которым процесс реально запущен (аргумент после -jar).
# Имя берётся из /proc, а не из каталога на диске: при обновлении ядра файл
# уже переименован, а работающий процесс ещё держит старое имя.
server_process_jar() {
    local pid="$1"
    local -a args=()
    local i

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || return 1
    for ((i = 0; i + 1 < ${#args[@]}; i++)); do
        if [[ "${args[i]}" == "-jar" ]]; then
            printf '%s\n' "${args[i + 1]}"
            return 0
        fi
    done
    return 1
}

# PID считается процессом сервера, если это java с -jar из каталога сервера.
# Проверка намеренно не зависит от текущего имени JAR на диске, иначе любое
# обновление ядра делает живой процесс «чужим» для restart/start-all.
server_pid_is_valid() {
    local pid="$1"
    local expected_dir="$2"
    local actual_dir
    local jar_arg
    local jar_dir

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    actual_dir="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || return 1
    [[ "$actual_dir" == "$expected_dir" ]] || return 1
    jar_arg="$(server_process_jar "$pid")" || return 1
    [[ "$jar_arg" == *.jar ]] || return 1

    if [[ "$jar_arg" == */* ]]; then
        if [[ "$jar_arg" == /* ]]; then
            jar_dir="$(dirname -- "$jar_arg")"
        else
            jar_dir="$expected_dir/$(dirname -- "$jar_arg")"
        fi
        jar_dir="$(cd -- "$jar_dir" 2>/dev/null && pwd -P)" || return 1
        [[ "$jar_dir" == "$expected_dir" ]] || return 1
    fi
    return 0
}

server_stop_command() {
    case "$SERVER_KIND" in
        velocity) printf '%s\n' shutdown ;;
        *) printf '%s\n' stop ;;
    esac
}

# Длина префикса для отпечатка: не больше 4096 байт и не больше offset_before.
log_head_probe_len() {
    local offset_before="${1:-0}"
    local digits

    if [[ ! "$offset_before" =~ ^[0-9]+$ ]]; then
        printf '0\n'
        return 0
    fi

    digits="${offset_before#"${offset_before%%[!0]*}"}"
    if [[ -z "$digits" ]]; then
        printf '0\n'
        return 0
    fi
    if (( ${#digits} > 4 )); then
        printf '4096\n'
        return 0
    fi
    if (( ${#digits} == 4 )) && [[ "$digits" > "4096" ]]; then
        printf '4096\n'
        return 0
    fi

    printf '%s\n' "$digits"
}

log_head_fingerprint() {
    local file="${1:-}"
    local bytes="${2:-4096}"
    local raw
    local crc
    local size

    if [[ ! "$bytes" =~ ^[0-9]+$ ]] || (( bytes <= 0 )); then
        bytes=4096
    fi

    if [[ ! -f "$file" || ! -s "$file" || ! -r "$file" ]]; then
        printf '\n'
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        raw="$(head -c "$bytes" -- "$file" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)" || raw=""
        if [[ -n "$raw" ]]; then
            printf 'sha256:%s\n' "$raw"
        else
            printf '\n'
        fi
        return 0
    fi

    if command -v cksum >/dev/null 2>&1; then
        raw="$(head -c "$bytes" -- "$file" 2>/dev/null | cksum 2>/dev/null)" || raw=""
        crc=""
        size=""
        if [[ -n "$raw" ]]; then
            read -r crc size <<<"$raw" || true
        fi
        if [[ -n "$crc" && -n "$size" ]]; then
            printf 'cksum:%s:%s\n' "$crc" "$size"
        else
            printf '\n'
        fi
        return 0
    fi

    printf 'unavailable\n'
    return 0
}

log_reports_ready() {
    local log_file="${1:-}"
    local boot_re="${2:-}"
    local ready_re="${3:-}"
    local offset_before="${4:-0}"
    local head_fp_before="${5:-}"
    local size_now
    local head_len
    local head_fp_now
    local start_byte
    local fresh
    local ready_nr
    local boot_nr

    LOG_CHECK_REGION=absent
    if [[ ! -f "$log_file" ]]; then
        return 1
    fi

    size_now="$(wc -c < "$log_file" 2>/dev/null)" || size_now=0
    size_now="${size_now//[[:space:]]/}"
    if [[ ! "$size_now" =~ ^[0-9]+$ ]] || (( size_now == 0 )); then
        LOG_CHECK_REGION=absent
        return 1
    fi

    if [[ ! "$offset_before" =~ ^[0-9]+$ ]]; then
        offset_before=0
    else
        offset_before="${offset_before#"${offset_before%%[!0]*}"}"
        offset_before="${offset_before:-0}"
    fi

    # Отпечаток снимается по первым min(offset_before, 4096) байтам;
    # вызывающая сторона обязана снимать его с той же длиной.
    head_len="$(log_head_probe_len "$offset_before")"
    head_fp_now="$(log_head_fingerprint "$log_file" "$head_len")"

    fresh=false
    if (( offset_before <= 0 )); then
        # Префикса до рестарта не было — читаем лог с начала.
        fresh=true
    elif [[ "$head_fp_before" == unavailable || "$head_fp_now" == unavailable ]]; then
        # Хеш-утилиты недоступны: отпечаток недостоверен, читаем только дописанное,
        # если файл не стал короче прежнего offset.
        if (( size_now < offset_before )); then
            fresh=true
        fi
    elif [[ -z "$head_fp_before" || "$head_fp_now" != "$head_fp_before" ]]; then
        # Лог пересоздан: прежнего префикса больше нет, читаем с начала.
        fresh=true
    elif (( size_now < offset_before )); then
        # Лог стал короче прежнего offset — файл пересоздан, читаем с начала.
        fresh=true
    fi

    if [[ "$fresh" == true ]]; then
        start_byte=1
        LOG_CHECK_REGION=fresh
    else
        start_byte=$((offset_before + 1))
        LOG_CHECK_REGION=append
    fi

    if (( start_byte > size_now )); then
        return 1
    fi

    ready_nr=$(tail -c "+$start_byte" "$log_file" 2>/dev/null | grep -nE -- "$ready_re" | tail -n1 | cut -d: -f1)
    boot_nr=$(tail -c "+$start_byte" "$log_file" 2>/dev/null | grep -nE -- "$boot_re" | tail -n1 | cut -d: -f1)

    if [[ -n "$ready_nr" ]] && { [[ -z "$boot_nr" ]] || (( ready_nr > boot_nr )); }; then
        return 0
    fi
    return 1
}
