#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

LAST_GOOD_SHA_FILE="$PROJECT_ROOT/.last-good-deploy-sha"
STATE_FILE="$PROJECT_ROOT/.scheduled-prod-restart-state"
NOTIFY_FILE="$PROJECT_ROOT/.scheduled-prod-restart-notify"
NOTIFY_SUCCESS_FILE="$PROJECT_ROOT/.scheduled-prod-restart-notify-success"
RUN_DATE="$(date -u +%F)"
STAGE="${1:-}"
STATE_DATE=""
TARGET_SHA=""
LAST_GOOD_SHA=""
ADJUSTMENT_OK=0
PLAYWORLD_OK=0
VELOCITY_OK=0
FAILED=0
STAGE_INDEX=0
STAGE_NAME=""
NEXT_STAGES=""
TARGET_DISPLAY=""
LAST_GOOD_DISPLAY=""
VALIDATE_ERROR=""
VELOCITY_SKIPPED=0

usage() {
    echo "Использование: bash scripts/scheduled-restart.sh <adjustment|playworld|velocity>" >&2
}

if (( $# != 1 )); then
    usage
    exit 2
fi
case "$STAGE" in
    adjustment|playworld|velocity) ;;
    *) usage; exit 2 ;;
esac
case "$STAGE" in
    adjustment) STAGE_INDEX=1; STAGE_NAME="лобби"; NEXT_STAGES="playworld, velocity" ;;
    playworld) STAGE_INDEX=2; STAGE_NAME="основной мир"; NEXT_STAGES="velocity" ;;
    velocity) STAGE_INDEX=3; STAGE_NAME="прокси"; NEXT_STAGES="" ;;
esac

load_state() {
    local key value
    [[ -f "$STATE_FILE" ]] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            date) STATE_DATE="$value" ;;
            target_sha) TARGET_SHA="$value" ;;
            last_good_sha) LAST_GOOD_SHA="$value" ;;
            adjustment_ok) ADJUSTMENT_OK="$value" ;;
            playworld_ok) PLAYWORLD_OK="$value" ;;
            velocity_ok) VELOCITY_OK="$value" ;;
            failed) FAILED="$value" ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    {
        printf 'date=%s\n' "$STATE_DATE"
        printf 'target_sha=%s\n' "$TARGET_SHA"
        printf 'last_good_sha=%s\n' "$LAST_GOOD_SHA"
        printf 'adjustment_ok=%s\n' "$ADJUSTMENT_OK"
        printf 'playworld_ok=%s\n' "$PLAYWORLD_OK"
        printf 'velocity_ok=%s\n' "$VELOCITY_OK"
        printf 'failed=%s\n' "$FAILED"
    } > "${STATE_FILE}.tmp" && mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
}

read_sha_file() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    tr -d '[:space:]' < "$file"
}

validate_last_good() {
    LAST_GOOD_SHA="$(read_sha_file "$LAST_GOOD_SHA_FILE")" || {
        VALIDATE_ERROR="Не найден SHA последней успешной версии: $LAST_GOOD_SHA_FILE"
        log "[ERROR] $VALIDATE_ERROR"
        return 1
    }
    if [[ ! "$LAST_GOOD_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
        || ! git -C "$PROJECT_ROOT" cat-file -e "${LAST_GOOD_SHA}^{commit}" 2>/dev/null; then
        VALIDATE_ERROR="SHA последней успешной версии некорректен или отсутствует в checkout"
        log "[ERROR] $VALIDATE_ERROR"
        return 1
    fi
}

atomic_write() {
    local file="$1"
    local value="$2"
    printf '%s\n' "$value" > "${file}.tmp" && mv -f "${file}.tmp" "$file"
}

short_sha() {
    local sha="${1:-}"
    if [[ -n "$sha" ]]; then
        printf '%s\n' "${sha:0:7}"
    else
        printf 'неизвестно\n'
    fi
}

build_display() {
    local sha="${1:-}"
    local desc=""

    if [[ -z "$sha" ]]; then
        printf 'неизвестно\n'
        return 0
    fi
    desc="$(git -C "$PROJECT_ROOT" describe --tags --always "$sha" 2>/dev/null)" || desc=""
    if [[ -z "$desc" ]]; then
        printf '%s\n' "$(short_sha "$sha")"
        return 0
    fi
    if [[ "$desc" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s (%s)\n' "$desc" "$(short_sha "$sha")"
    else
        # describe already contains the short SHA (v1.1.10-1-g6174477).
        printf '%s\n' "$desc"
    fi
}

sanitize_text() {
    tr '\n\r' '  ' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
}

write_notify_payload() {
    local level="$1"
    local reason="$2"
    local rollback="$3"
    local detail="${4:-}"
    local target_display
    local last_good_display
    local reason_line
    local detail_line

    target_display="${TARGET_DISPLAY:-$(build_display "$TARGET_SHA")}"
    last_good_display="${LAST_GOOD_DISPLAY:-$(build_display "$LAST_GOOD_SHA")}"
    reason_line="$(printf '%s' "$reason" | sanitize_text)"
    detail_line="$(printf '%s' "$detail" | sanitize_text)"

    {
        printf 'level=%s\n' "$level"
        printf 'stage=%s\n' "$STAGE"
        printf 'stage_index=%s\n' "$STAGE_INDEX"
        printf 'stage_total=3\n'
        printf 'stage_name=%s\n' "$STAGE_NAME"
        printf 'target_sha=%s\n' "$TARGET_SHA"
        printf 'target_display=%s\n' "$target_display"
        printf 'last_good_sha=%s\n' "$LAST_GOOD_SHA"
        printf 'last_good_display=%s\n' "$last_good_display"
        printf 'reason=%s\n' "$reason_line"
        printf 'rollback=%s\n' "$rollback"
        printf 'rollback_detail=%s\n' "$detail_line"
        printf 'run_date=%s\n' "$RUN_DATE"
        printf 'timestamp=%s\n' "$(TZ=Europe/Moscow date '+%d.%m.%Y %H:%M MSK')"
        printf 'host=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
        printf 'next_stages=%s\n' "$NEXT_STAGES"
    } > "${NOTIFY_FILE}.tmp" 2>/dev/null \
        && mv -f "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE" 2>/dev/null
}

notify_failure() {
    local level="$1"
    local reason="$2"
    local rollback="$3"
    local detail="${4:-}"
    local notifier="/usr/local/lib/minequest/notify-discord.py"

    write_notify_payload "$level" "$reason" "$rollback" "$detail" \
        || log "[WARN] Не удалось подготовить данные уведомления"

    if [[ ! -f "$notifier" ]]; then
        notifier="$SCRIPT_DIR/notify-discord.py"
    fi
    if [[ ! -f "$notifier" ]]; then
        log "[WARN] Уведомление не отправлено: notify-discord.py не найден"
        return 0
    fi
    if ! python3 "$notifier" --project-root "$PROJECT_ROOT" --stage "$STAGE"; then
        log "[WARN] Уведомление о падении этапа $STAGE не отправлено"
    fi
    return 0
}

write_success_payload() {
    local proxy_status="✅"
    (( VELOCITY_SKIPPED )) && proxy_status="⏭ (без изменений)"

    {
        printf 'kind=success\n'
        printf 'stage=velocity\n'
        printf 'target_sha=%s\n' "$TARGET_SHA"
        printf 'target_display=%s\n' "${TARGET_DISPLAY:-$(build_display "$TARGET_SHA")}"
        printf 'previous_sha=%s\n' "$LAST_GOOD_SHA"
        printf 'previous_display=%s\n' "${LAST_GOOD_DISPLAY:-$(build_display "$LAST_GOOD_SHA")}"
        printf 'stages=лобби ✅ · основной мир ✅ · прокси %s\n' "$proxy_status"
        printf 'run_date=%s\n' "$RUN_DATE"
        printf 'timestamp=%s\n' "$(TZ=Europe/Moscow date '+%d.%m.%Y %H:%M MSK')"
        printf 'host=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    } > "${NOTIFY_SUCCESS_FILE}.tmp" 2>/dev/null \
        && mv -f "${NOTIFY_SUCCESS_FILE}.tmp" "$NOTIFY_SUCCESS_FILE" 2>/dev/null
}

notify_success() {
    # A successful cycle never rolls back, so the notifier next to the running
    # script is the version that matches this checkout. Prefer it over the
    # installed copy, which may be older until install.sh is re-run.
    local notifier="$SCRIPT_DIR/notify-discord.py"

    write_success_payload \
        || log "[WARN] Не удалось подготовить данные уведомления об успехе"

    if [[ ! -f "$notifier" ]]; then
        notifier="/usr/local/lib/minequest/notify-discord.py"
    fi
    if [[ ! -f "$notifier" ]]; then
        log "[WARN] Уведомление об успехе не отправлено: notify-discord.py не найден"
        return 0
    fi
    if ! python3 "$notifier" --project-root "$PROJECT_ROOT" --mode success; then
        log "[WARN] Уведомление об успехе не отправлено"
    fi
    return 0
}

save_state_or_fail() {
    save_state && return 0
    log "[CRITICAL] Не удалось сохранить состояние этапа $STAGE"
    notify_failure warning "Не удалось сохранить состояние этапа $STAGE" skipped \
        "рестарт сервера выполнен, состояние не зафиксировано"
    exit 1
}

render_secrets() {
    log "[INFO] Подстановка локальных секретов перед этапом $STAGE"
    if ! python3 "$SCRIPT_DIR/render-secrets/render-secrets.py"; then
        log "[ERROR] Не удалось подставить локальные секреты; этап $STAGE не выполняется"
        return 1
    fi
}

fail_and_rollback() {
    local reason="$1"
    local rollback_result="failed"
    local rollback_detail=""

    log "[ERROR] $reason; откат PROD на $LAST_GOOD_SHA"
    if bash "$SCRIPT_DIR/rollback-prod.sh"; then
        rollback_result="success"
        log "[WARN] PROD откачен на $LAST_GOOD_SHA и перезапущен"
    else
        rollback_detail="rollback-prod.sh завершился ошибкой"
        log "[CRITICAL] Откат PROD завершился ошибкой; повторный откат не выполняется"
    fi

    FAILED=1
    save_state || log "[CRITICAL] Не удалось сохранить состояние ошибки"
    if [[ "$rollback_result" == success ]]; then
        notify_failure error "$reason" success ""
    else
        notify_failure critical "$reason" failed "$rollback_detail"
    fi
    exit 1
}

restart_stage_server() {
    local server="$1"
    local output=""
    local rc=0
    local reason=""
    local last_error=""

    output="$(mktemp "${TMPDIR:-/tmp}/minequest-restart-output.XXXXXX" 2>/dev/null)" || output=""

    if [[ -n "$output" ]]; then
        bash "$SCRIPT_DIR/restart-server.sh" "$server" 2>&1 | tee "$output"
        rc=${PIPESTATUS[0]}
    else
        bash "$SCRIPT_DIR/restart-server.sh" "$server"
        rc=$?
    fi

    if (( rc == 0 )); then
        [[ -n "$output" ]] && rm -f "$output"
        return 0
    fi

    reason="Рестарт $server не прошёл проверку"
    if [[ -n "$output" ]]; then
        last_error="$(grep -F '[ERROR]' "$output" 2>/dev/null | tail -n 1 | sed 's/^.*\[ERROR\] //')"
        if [[ -n "$last_error" ]]; then
            reason="$last_error"
        fi
        rm -f "$output"
    fi

    fail_and_rollback "$reason"
}

load_state

CURRENT_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)" || {
    log "[ERROR] Не удалось определить текущий HEAD PROD"
    notify_failure warning "Не удалось определить текущий HEAD PROD" skipped \
        "состояние PROD не изменялось"
    exit 1
}

if [[ "$STATE_DATE" == "$RUN_DATE" && "$FAILED" == 1 ]]; then
    log "[ERROR] Ежедневный рестарт уже помечен неуспешным; этап $STAGE не запускается"
    exit 1
fi

STAGE_ALREADY_DONE=false
if [[ "$STATE_DATE" == "$RUN_DATE" && -n "$TARGET_SHA" && "$CURRENT_HEAD" == "$TARGET_SHA" ]]; then
    case "$STAGE" in
        adjustment) [[ "$ADJUSTMENT_OK" == 1 ]] && STAGE_ALREADY_DONE=true ;;
        playworld) [[ "$PLAYWORLD_OK" == 1 ]] && STAGE_ALREADY_DONE=true ;;
        velocity) [[ "$VELOCITY_OK" == 1 ]] && STAGE_ALREADY_DONE=true ;;
    esac
fi
if [[ "$STAGE_ALREADY_DONE" == true ]]; then
    log "[INFO] Этап $STAGE уже выполнен сегодня для $TARGET_SHA; повторный рестарт не требуется"
    exit 0
fi

if [[ "$STAGE" == adjustment ]]; then
    rm -f "$NOTIFY_FILE" "${NOTIFY_FILE}.tmp" \
        "$NOTIFY_SUCCESS_FILE" "${NOTIFY_SUCCESS_FILE}.tmp"
    TARGET_SHA="$CURRENT_HEAD"
    TARGET_DISPLAY="$(build_display "$TARGET_SHA")"
    if ! validate_last_good; then
        notify_failure warning "${VALIDATE_ERROR:-Не найден SHA последней успешной версии}" skipped \
            "PROD не изменялся"
        exit 1
    fi
    LAST_GOOD_DISPLAY="$(build_display "$LAST_GOOD_SHA")"
    STATE_DATE="$RUN_DATE"
    ADJUSTMENT_OK=0
    PLAYWORLD_OK=0
    VELOCITY_OK=0
    FAILED=0
    save_state_or_fail
else
    if [[ "$STATE_DATE" != "$RUN_DATE" || -z "$TARGET_SHA" || -z "$LAST_GOOD_SHA" ]]; then
        log "[ERROR] Нет состояния этапа лобби за сегодня; этап $STAGE не запускается"
        notify_failure warning "Нет состояния этапа лобби за сегодня" skipped \
            "PROD не изменялся"
        exit 1
    fi
    if [[ "$CURRENT_HEAD" != "$TARGET_SHA" ]] \
        || [[ "$(read_sha_file "$LAST_GOOD_SHA_FILE")" != "$LAST_GOOD_SHA" ]]; then
        log "[ERROR] PROD изменился между этапами; прекращаю расписанный рестарт без отката постороннего обновления"
        FAILED=1
        save_state || log "[ERROR] Не удалось сохранить состояние ошибки"
        notify_failure warning "PROD изменился между этапами; расписанный рестарт остановлен" skipped \
            "постороннее обновление не откатывается"
        exit 1
    fi
    TARGET_DISPLAY="$(build_display "$TARGET_SHA")"
    LAST_GOOD_DISPLAY="$(build_display "$LAST_GOOD_SHA")"
fi

if ! render_secrets; then
    notify_failure warning "Не удалось подставить локальные секреты" skipped \
        "серверы не останавливались"
    exit 1
fi

log "[INFO] Этап $STAGE: target=$TARGET_SHA, last-good=$LAST_GOOD_SHA"

case "$STAGE" in
    adjustment)
        restart_stage_server adjustment
        ADJUSTMENT_OK=1
        save_state_or_fail
        log "[OK] Лобби успешно перезапущено и проверено"
        ;;
    playworld)
        if [[ "$ADJUSTMENT_OK" != 1 ]]; then
            log "[ERROR] Лобби не прошло проверку; основной мир не будет перезапущен"
            notify_failure warning "Лобби не прошло проверку; основной мир не перезапускался" skipped \
                "PROD не изменялся"
            exit 1
        fi
        restart_stage_server playworld
        PLAYWORLD_OK=1
        save_state_or_fail
        log "[OK] Основной мир успешно перезапущен и проверен"
        ;;
    velocity)
        if [[ "$ADJUSTMENT_OK" != 1 || "$PLAYWORLD_OK" != 1 ]]; then
            log "[ERROR] Лобби и основной мир должны пройти проверку до этапа Velocity"
            notify_failure warning "Лобби и основной мир не прошли проверку до этапа Velocity" skipped \
                "PROD не изменялся"
            exit 1
        fi
        if git -C "$PROJECT_ROOT" diff --quiet "$LAST_GOOD_SHA" "$TARGET_SHA" -- velocity/; then
            VELOCITY_SKIPPED=1
            log "[INFO] В velocity/ нет изменений; рестарт Velocity пропускается"
        else
            log "[INFO] В velocity/ есть изменения; выполняю рестарт"
            restart_stage_server velocity
        fi
        if ! atomic_write "$LAST_GOOD_SHA_FILE" "$TARGET_SHA"; then
            log "[CRITICAL] Не удалось обновить SHA последней успешной версии"
            notify_failure warning "Не удалось обновить SHA последней успешной версии" skipped \
                "все серверы перезапущены, last-good не обновлён"
            exit 1
        fi
        VELOCITY_OK=1
        save_state_or_fail
        log "[OK] Все этапы завершены; SHA подтверждён: $TARGET_SHA"
        if [[ "$TARGET_SHA" != "$LAST_GOOD_SHA" ]]; then
            notify_success
        fi
        ;;
esac
