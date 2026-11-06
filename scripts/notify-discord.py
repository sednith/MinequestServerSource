#!/usr/bin/env python3
"""Send nightly PROD restart results to a Discord webhook.

Failure alerts are the default. ``--mode success`` sends a positive message for
a nightly restart that applied a new build. The script is intentionally
fail-safe: it never raises an unhandled exception into the restart pipeline and
exits with 0 when the alert was sent, skipped as a duplicate, or rendered in
--dry-run mode.
"""
import argparse
import datetime
import json
import os
import platform
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_PROJECT_ROOT = "/home/server/prod"
DEFAULT_ENV_FILE = "/etc/minequest/notify.env"
USER_AGENT = "MinequestNotifier/1.0"
MAX_CONTENT = 1900
STAGES = {
    "adjustment": ("лобби", 1),
    "playworld": ("основной мир", 2),
    "velocity": ("прокси", 3),
}
HEADERS = {
    "error": "🔴 Ночной рестарт PROD упал",
    "critical": "🚨 Ночной рестарт PROD: ОТКАТ НЕ УДАЛСЯ",
    "warning": "🟠 Ночной рестарт PROD остановлен",
}
ROLLBACK_LINES = {
    "success": "Откат: ✅ выполнен на {target}, серверы перезапущены и проверены",
    "failed": "Откат: ❌ ошибка — PROD в неизвестном состоянии, нужно ручное вмешательство",
    "skipped": "Откат: не выполнялся — {detail}",
    "unknown": "Откат: ⚠️ не подтверждён (этап прерван), проверь вручную",
}
SUCCESS_HEADER = "✅ Ночной рестарт PROD выполнен"


def msk_now():
    # Moscow is UTC+3 all year round, no DST.
    return datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=3)


def run_date_utc():
    # scheduled-restart.sh identifies a nightly cycle by the UTC date.
    return datetime.datetime.now(datetime.timezone.utc).date().isoformat()


def parse_kv(path):
    data = {}
    try:
        text = Path(path).read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return data
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if sep:
            data[key.strip()] = value.strip()
    return data


def read_marker(path):
    try:
        return Path(path).read_text(encoding="utf-8-sig").strip()
    except (OSError, UnicodeError):
        return ""


def write_marker(path, value):
    try:
        target = Path(path)
        tmp = target.with_name(target.name + ".tmp")
        tmp.write_text(value + "\n", encoding="utf-8")
        tmp.replace(target)
        return True
    except OSError:
        return False


def shorten(value, limit=7):
    return value[:limit] if value else "неизвестно"


def display(payload, state, key_sha, key_display):
    value = payload.get(key_display, "").strip()
    if value:
        return value
    sha = payload.get(key_sha, "").strip() or state.get(key_sha, "").strip()
    return shorten(sha)


def one_line(value, limit=500):
    value = re.sub(r"\s+", " ", value or "").strip()
    return value[:limit]


def build_message(args, payload, state):
    stage = args.stage or payload.get("stage", "") or state.get("stage", "")
    stage_key = stage if stage in STAGES else ""
    default_name, default_index = STAGES.get(stage_key, ("", 0))

    stage_name = payload.get("stage_name", "").strip() or default_name
    try:
        index = int(payload.get("stage_index", "") or default_index)
    except ValueError:
        index = default_index
    try:
        total = int(payload.get("stage_total", "") or 3)
    except ValueError:
        total = 3

    target = display(payload, state, "target_sha", "target_display")
    last_good = display(payload, state, "last_good_sha", "last_good_display")

    level = args.level or payload.get("level", "") or "critical"
    rollback = args.rollback or payload.get("rollback", "") or "unknown"
    if rollback in ("failed", "unknown"):
        level = "critical"
    if level not in HEADERS:
        level = "critical"
    header = HEADERS[level]

    reason = one_line(args.reason or payload.get("reason", ""))
    detail = one_line(args.detail or payload.get("rollback_detail", ""))
    if not reason:
        reason = "этап прерван (таймаут или сигнал), откат не подтверждён"

    rollback_line = ROLLBACK_LINES.get(rollback, ROLLBACK_LINES["unknown"])
    rollback_line = rollback_line.format(
        target=last_good or "предыдущую успешную версию",
        detail=detail or "причина не зафиксирована",
    )

    timestamp = payload.get("timestamp", "").strip() or (
        msk_now().strftime("%d.%m.%Y %H:%M MSK")
    )
    host = payload.get("host", "").strip() or platform.node() or "unknown"
    next_stages = payload.get("next_stages", "").strip()

    stage_line = f"Этап: {index}/{total} · {stage}" if stage else "Этап: неизвестен"
    if stage_name:
        stage_line += f" ({stage_name})"

    lines = [header, f"Сборка: {target}", stage_line, f"Причина: {reason}", rollback_line]
    if next_stages:
        lines.append(f"Дальше: этапы {next_stages} не выполняются")
    lines.append(f"{timestamp} · {host}")

    message = "\n".join(lines)
    if len(message) > MAX_CONTENT:
        message = message[: MAX_CONTENT - 1] + "…"
    return message


def build_success_message(payload, state):
    target = display(payload, state, "target_sha", "target_display")
    previous = display(payload, state, "previous_sha", "previous_display")
    stages = one_line(payload.get("stages", ""), 300)
    timestamp = payload.get("timestamp", "").strip() or (
        msk_now().strftime("%d.%m.%Y %H:%M MSK")
    )
    host = payload.get("host", "").strip() or platform.node() or "unknown"

    lines = [SUCCESS_HEADER]
    if previous and previous not in ("неизвестно", target):
        lines.append(f"Обновление: {previous} → {target}")
    else:
        lines.append(f"Сборка: {target}")
    if stages:
        lines.append(f"Этапы: {stages}")
    lines.append(f"{timestamp} · {host}")

    message = "\n".join(lines)
    if len(message) > MAX_CONTENT:
        message = message[: MAX_CONTENT - 1] + "…"
    return message


def build_test_message():
    now = msk_now().strftime("%d.%m.%Y %H:%M MSK")
    host = platform.node() or "unknown"
    return (
        "🔔 Minequest PROD — проверка уведомлений\n"
        "Канал настроен, отправка работает.\n"
        f"Отправлено: {now} · {host}"
    )


def send(url, message):
    body = json.dumps(
        {"content": message, "allowed_mentions": {"parse": []}},
        ensure_ascii=False,
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    parser = argparse.ArgumentParser(description="Discord notifier for PROD restarts")
    parser.add_argument("--project-root", default=DEFAULT_PROJECT_ROOT)
    parser.add_argument("--env-file", default=DEFAULT_ENV_FILE)
    parser.add_argument("--mode", choices=("failure", "success"), default="failure")
    parser.add_argument("--stage", default="")
    parser.add_argument("--level", default="")
    parser.add_argument("--reason", default="")
    parser.add_argument("--rollback", default="")
    parser.add_argument("--detail", default="")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()

    env = parse_kv(args.env_file)
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip() or env.get(
        "DISCORD_WEBHOOK_URL", ""
    ).strip()

    if args.test:
        message = build_test_message()
        if args.dry_run:
            print(message)
            return 0
        if not url:
            print("[ERROR] DISCORD_WEBHOOK_URL не задан в " + args.env_file, file=sys.stderr)
            return 2
        try:
            status = send(url, message)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:300]
            print(f"[ERROR] Discord ответил HTTP {error.code}: {detail}", file=sys.stderr)
            return 1
        except Exception as error:  # noqa: BLE001 - fail-safe notifier
            print(f"[ERROR] не удалось отправить уведомление: {error}", file=sys.stderr)
            return 1
        print(f"[OK] тестовое уведомление отправлено (HTTP {status})")
        return 0

    root = Path(args.project_root)
    suffix = "-success" if args.mode == "success" else ""
    payload_file = root / f".scheduled-prod-restart-notify{suffix}"
    state_file = root / ".scheduled-prod-restart-state"
    marker_file = root / f".scheduled-prod-restart-notified{suffix}"

    payload = parse_kv(payload_file)
    state = parse_kv(state_file)
    run_date = run_date_utc()
    payload_date = payload.get("run_date", "").strip()
    # A payload left over from the previous night must not describe today's
    # result: ignore it unless its date is today.
    if payload_date and payload_date != run_date:
        payload = {}

    if not args.dry_run:
        if read_marker(marker_file) == run_date:
            print(f"[INFO] уведомление за {run_date} уже отправлено; пропускаю")
            return 0

    if args.mode == "success" and not payload:
        print(
            "[WARN] нет данных об успешном цикле; уведомление не отправлено",
            file=sys.stderr,
        )
        return 2

    message = (
        build_success_message(payload, state)
        if args.mode == "success"
        else build_message(args, payload, state)
    )

    if args.dry_run:
        print(message)
        return 0

    if not url:
        print("[WARN] DISCORD_WEBHOOK_URL не задан; уведомление не отправлено", file=sys.stderr)
        return 2

    try:
        status = send(url, message)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        print(f"[WARN] Discord ответил HTTP {error.code}: {detail}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - fail-safe notifier
        print(f"[WARN] не удалось отправить уведомление: {error}", file=sys.stderr)
        return 1

    if write_marker(marker_file, run_date):
        print(f"[OK] уведомление отправлено (HTTP {status})")
    else:
        print(f"[WARN] уведомление отправлено (HTTP {status}), но маркер не записан")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - never break the caller
        print(f"[WARN] notifier: непредвиденная ошибка: {error}", file=sys.stderr)
        raise SystemExit(1)
