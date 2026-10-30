#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DIR=/etc/systemd/system
STAGES=(adjustment playworld velocity)
TIMERS=(prod-restart-adjustment.timer prod-restart-playworld.timer prod-restart-velocity.timer)
TIME_RE='^([01][0-9]|2[0-3]):[0-5][0-9]$'
TIMES=()

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

usage() {
    cat <<'EOF'
Использование:
  set-schedule.sh                            показать текущее расписание и NEXT
  set-schedule.sh HH:MM HH:MM HH:MM          показать план и проверить (ничего не меняет)
  set-schedule.sh --apply HH:MM HH:MM HH:MM  записать drop-in'ы и применить

Времена задаются по MSK (Europe/Moscow) в порядке adjustment -> playworld -> velocity.
Зазор между этапами — не меньше 5 минут, окно — 03:00–02:59 MSK.
EOF
}

window_minutes() {
    local time="$1"
    local hh="${time%%:*}"
    local mm="${time##*:}"
    printf '%s\n' "$(( (10#$hh * 60 + 10#$mm - 180 + 1440) % 1440 ))"
}

validate_order_and_gaps() {
    local m1 m2 m3
    m1="$(window_minutes "$1")"
    m2="$(window_minutes "$2")"
    m3="$(window_minutes "$3")"

    if (( ! (m1 < m2 && m2 < m3) )); then
        log "[ERROR] Этапы должны идти в порядке adjustment -> playworld -> velocity внутри окна 03:00–02:59 MSK"
        return 1
    fi

    if (( m2 - m1 < 5 || m3 - m2 < 5 )); then
        log "[ERROR] Минимальный зазор между этапами — 5 минут"
        return 1
    fi
}

show_current() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log "[ERROR] systemd не найден — нечего показывать"
        return 1
    fi

    if ! systemctl cat "${TIMERS[@]}" >/dev/null 2>&1; then
        log "[ERROR] Таймеры prod-restart* не установлены. Установите: sudo bash deploy/systemd/install.sh"
        return 1
    fi

    systemctl list-timers 'prod-restart*' --all --no-pager || true

    local stage dropin
    for stage in "${STAGES[@]}"; do
        dropin="$SYSTEMD_DIR/prod-restart-${stage}.timer.d/10-schedule.conf"
        if [[ -f "$dropin" ]]; then
            printf -- '--- %s ---\n' "$dropin"
            cat "$dropin"
        fi
    done
}

print_plan() {
    local i
    printf 'План:\n'
    for i in 0 1 2; do
        printf '  %-12s %s MSK\n' "${STAGES[$i]}" "${TIMES[$i]}"
    done
}

check_calendar() {
    command -v systemd-analyze >/dev/null 2>&1 || return 0

    local time
    for time in "${TIMES[@]}"; do
        systemd-analyze calendar "*-*-* ${time}:00 Europe/Moscow" || return 1
    done
}

apply_schedule() {
    local i stage dir
    for i in 0 1 2; do
        stage="${STAGES[$i]}"
        dir="$SYSTEMD_DIR/prod-restart-${stage}.timer.d"
        mkdir -p "$dir"
        printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00 Europe/Moscow\n' "${TIMES[$i]}" > "$dir/10-schedule.conf"
        log "[OK] Записан $dir/10-schedule.conf"
    done

    systemctl daemon-reload
    systemctl restart "${TIMERS[@]}"
    systemctl list-timers 'prod-restart*' --all --no-pager || true

    log "[OK] Расписание применено"
}

APPLY=false
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        --apply)
            APPLY=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            log "[ERROR] Неизвестный флаг: $arg"
            usage >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$arg")
            ;;
    esac
done

if (( EUID != 0 )); then
    log "[ERROR] Запустите от root"
    exit 1
fi

if (( ${#POSITIONAL[@]} == 0 )); then
    if [[ "$APPLY" == "true" ]]; then
        log "[ERROR] Для --apply нужны три времени: HH:MM HH:MM HH:MM"
        usage >&2
        exit 2
    fi

    show_current
    exit 0
fi

if (( ${#POSITIONAL[@]} != 3 )); then
    log "[ERROR] Нужно ровно три времени: HH:MM HH:MM HH:MM"
    usage >&2
    exit 2
fi

for time in "${POSITIONAL[@]}"; do
    if [[ ! "$time" =~ $TIME_RE ]]; then
        log "[ERROR] Неверный формат времени: $time (ожидается HH:MM, 24 часа)"
        usage >&2
        exit 2
    fi
done

TIMES=("${POSITIONAL[@]}")

validate_order_and_gaps "${TIMES[0]}" "${TIMES[1]}" "${TIMES[2]}"

if [[ "$APPLY" == "true" ]]; then
    apply_schedule
    exit 0
fi

show_current
print_plan
check_calendar
exit 0
