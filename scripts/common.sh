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

server_pid_is_valid() {
    local pid="$1"
    local expected_dir="$2"
    local actual_dir
    local cmdline

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    actual_dir="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || return 1
    [[ "$actual_dir" == "$expected_dir" ]] || return 1
    cmdline="$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null )" || return 1
    [[ "$cmdline" == *"-jar"* && "$cmdline" == *"$(basename -- "$SERVER_JAR")"* ]]
}

server_stop_command() {
    case "$SERVER_KIND" in
        velocity) printf '%s\n' shutdown ;;
        *) printf '%s\n' stop ;;
    esac
}
