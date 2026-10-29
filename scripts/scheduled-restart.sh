#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

LAST_GOOD_SHA_FILE="$PROJECT_ROOT/.last-good-deploy-sha"
STATE_FILE="$PROJECT_ROOT/.scheduled-prod-restart-state"
RUN_DATE="$(date -u +%F)"
STAGE="${1:-}"
STATE_DATE=""
TARGET_SHA=""
LAST_GOOD_SHA=""
ADJUSTMENT_OK=0
PLAYWORLD_OK=0
VELOCITY_OK=0
FAILED=0

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
        log "[ERROR] Не найден SHA последней успешной версии: $LAST_GOOD_SHA_FILE"
        return 1
    }
    if [[ ! "$LAST_GOOD_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
        || ! git -C "$PROJECT_ROOT" cat-file -e "${LAST_GOOD_SHA}^{commit}" 2>/dev/null; then
        log "[ERROR] SHA последней успешной версии некорректен или отсутствует в checkout"
        return 1
    fi
}

atomic_write() {
    local file="$1"
    local value="$2"
    printf '%s\n' "$value" > "${file}.tmp" && mv -f "${file}.tmp" "$file"
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

    log "[ERROR] $reason; откат PROD на $LAST_GOOD_SHA"
    if bash "$SCRIPT_DIR/rollback-prod.sh"; then
        log "[WARN] PROD откачен на $LAST_GOOD_SHA и перезапущен"
    else
        log "[CRITICAL] Откат PROD завершился ошибкой; повторный откат не выполняется"
    fi

    FAILED=1
    save_state || log "[CRITICAL] Не удалось сохранить состояние ошибки"
    exit 1
}

restart_stage_server() {
    local server="$1"
    if ! bash "$SCRIPT_DIR/restart-server.sh" "$server"; then
        fail_and_rollback "Рестарт $server не прошёл проверку"
    fi
}

load_state

CURRENT_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)" || {
    log "[ERROR] Не удалось определить текущий HEAD PROD"
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
    validate_last_good || exit 1
    TARGET_SHA="$CURRENT_HEAD"
    STATE_DATE="$RUN_DATE"
    ADJUSTMENT_OK=0
    PLAYWORLD_OK=0
    VELOCITY_OK=0
    FAILED=0
    save_state || exit 1
else
    if [[ "$STATE_DATE" != "$RUN_DATE" || -z "$TARGET_SHA" || -z "$LAST_GOOD_SHA" ]]; then
        log "[ERROR] Нет состояния этапа лобби за сегодня; этап $STAGE не запускается"
        exit 1
    fi
    if [[ "$CURRENT_HEAD" != "$TARGET_SHA" ]] \
        || [[ "$(read_sha_file "$LAST_GOOD_SHA_FILE")" != "$LAST_GOOD_SHA" ]]; then
        log "[ERROR] PROD изменился между этапами; прекращаю расписанный рестарт без отката постороннего обновления"
        FAILED=1
        save_state || log "[ERROR] Не удалось сохранить состояние ошибки"
        exit 1
    fi
fi

render_secrets || exit 1

log "[INFO] Этап $STAGE: target=$TARGET_SHA, last-good=$LAST_GOOD_SHA"

case "$STAGE" in
    adjustment)
        restart_stage_server adjustment
        ADJUSTMENT_OK=1
        save_state || exit 1
        log "[OK] Лобби успешно перезапущено и проверено"
        ;;
    playworld)
        if [[ "$ADJUSTMENT_OK" != 1 ]]; then
            log "[ERROR] Лобби не прошло проверку; основной мир не будет перезапущен"
            exit 1
        fi
        restart_stage_server playworld
        PLAYWORLD_OK=1
        save_state || exit 1
        log "[OK] Основной мир успешно перезапущен и проверен"
        ;;
    velocity)
        if [[ "$ADJUSTMENT_OK" != 1 || "$PLAYWORLD_OK" != 1 ]]; then
            log "[ERROR] Лобби и основной мир должны пройти проверку до этапа Velocity"
            exit 1
        fi
        if git -C "$PROJECT_ROOT" diff --quiet "$LAST_GOOD_SHA" "$TARGET_SHA" -- velocity/; then
            log "[INFO] В velocity/ нет изменений; рестарт Velocity пропускается"
        else
            log "[INFO] В velocity/ есть изменения; выполняю рестарт"
            restart_stage_server velocity
        fi
        atomic_write "$LAST_GOOD_SHA_FILE" "$TARGET_SHA" || exit 1
        VELOCITY_OK=1
        save_state || exit 1
        log "[OK] Все этапы завершены; SHA подтверждён: $TARGET_SHA"
        ;;
esac
