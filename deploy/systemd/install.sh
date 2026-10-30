#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SYSTEMD_DIR=/etc/systemd/system
PROD_DIR="${PROD_DIR:-/home/server/prod}"
NTP_DROPIN=/etc/systemd/timesyncd.conf.d/50-minequest.conf

UNITS=(prod-restart@.service prod-restart-adjustment.timer prod-restart-playworld.timer prod-restart-velocity.timer)
TIMERS=(prod-restart-adjustment.timer prod-restart-playworld.timer prod-restart-velocity.timer)

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

usage() {
    cat <<'EOF'
Использование: install.sh [ФЛАГИ]

Установка systemd-таймеров ночного рестарта PROD (04:45 / 05:00 / 05:15 MSK).

  (без флагов)  установить или обновить юниты и таймеры
  --ntp         дополнительно настроить синхронизацию времени (NTP)
  --uninstall   удалить таймеры; данные PROD, state-файл и NTP-конфиг не трогаются
  -h, --help    показать эту справку
EOF
}

configure_ntp() {
    mkdir -p /etc/systemd/timesyncd.conf.d

    if [[ ! -e "$NTP_DROPIN" ]]; then
        cat > "$NTP_DROPIN" <<'EOF'
[Time]
NTP=time.cloudflare.com
FallbackNTP=time.cloudflare.com
EOF
        log "[OK] Создан NTP-конфиг: $NTP_DROPIN"
    else
        log "[INFO] NTP-конфиг уже существует, оставляю как есть: $NTP_DROPIN"
    fi

    systemctl restart systemd-timesyncd

    local waited=0
    while (( waited < 60 )); do
        if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == "yes" ]]; then
            log "[OK] Время синхронизировано"
            timedatectl || true
            timedatectl timesync-status 2>/dev/null | head -n 15 || true
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    log "[ERROR] Время не синхронизировалось за 60 секунд. Проверьте: timedatectl timesync-status"
    return 1
}

verify_units() {
    command -v systemd-analyze >/dev/null 2>&1 || return 0

    local output=""
    if ! output="$(systemd-analyze verify "${UNITS[@]}" 2>&1)"; then
        log "[ERROR] systemd-analyze verify нашёл ошибки в юнитах"
        printf '%s\n' "$output"
        return 1
    fi

    if grep -qi 'error' <<<"$output"; then
        log "[ERROR] systemd-analyze verify вернул ошибки в выводе"
        printf '%s\n' "$output"
        return 1
    fi

    if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
    fi
}

install_units() {
    local unit
    for unit in "${UNITS[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$unit" ]]; then
            log "[ERROR] Не найден файл юнита: $SCRIPT_DIR/$unit"
            return 1
        fi
        install -m 0644 "$SCRIPT_DIR/$unit" "$SYSTEMD_DIR/$unit"
        log "[OK] Установлен $SYSTEMD_DIR/$unit"
    done

    systemctl daemon-reload
    systemctl enable "${TIMERS[@]}"
    systemctl restart "${TIMERS[@]}"

    verify_units

    systemctl list-timers 'prod-restart*' --all --no-pager || true

    if [[ "$WITH_NTP" == "true" ]]; then
        configure_ntp
    fi

    log "[OK] Установлено. Проверьте NEXT в списке выше (должно быть 04:45 / 05:00 / 05:15 MSK)."
}

uninstall_units() {
    systemctl disable --now "${TIMERS[@]}" 2>/dev/null || true

    local unit
    for unit in "${UNITS[@]}"; do
        rm -f "$SYSTEMD_DIR/$unit"
        log "[OK] Удалён $SYSTEMD_DIR/$unit"
    done

    systemctl daemon-reload

    if [[ "$WITH_NTP" == "true" && -e "$NTP_DROPIN" ]]; then
        rm -f "$NTP_DROPIN"
        systemctl restart systemd-timesyncd
        log "[OK] Удалён NTP-конфиг: $NTP_DROPIN"
    fi

    log "[OK] Удалено"
}

MODE=install
WITH_NTP=false

for arg in "$@"; do
    case "$arg" in
        --ntp)
            WITH_NTP=true
            ;;
        --uninstall)
            MODE=uninstall
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log "[ERROR] Неизвестный флаг: $arg"
            usage >&2
            exit 2
            ;;
    esac
done

if (( EUID != 0 )); then
    log "[ERROR] Запустите от root"
    exit 1
fi

if [[ ! -r "$PROD_DIR/scripts/scheduled-restart.sh" ]]; then
    log "[ERROR] Не найден или недоступен $PROD_DIR/scripts/scheduled-restart.sh"
    exit 1
fi

if [[ "$MODE" == "uninstall" ]]; then
    uninstall_units
else
    install_units
fi
