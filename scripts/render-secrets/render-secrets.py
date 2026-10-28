#!/usr/bin/env python3
"""Safely render ${NAME} placeholders using the local, non-executable secrets file."""
import json
import re
import sys
from pathlib import Path
from manifest import ROOT, load_manifest

NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
TOKEN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def fail(message):
    print(f"[ERROR] secrets: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_secrets():
    path = ROOT / "secrets"
    if not path.is_file():
        fail("локальный файл secrets не найден")
    result = {}
    try:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if not sep or not NAME.fullmatch(key) or key in result:
                fail(f"некорректная строка {number} в secrets")
            result[key] = value
    except (OSError, UnicodeError):
        fail("не удалось прочитать secrets")
    return result


def render(path, values, format_name):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        fail(f"не удалось прочитать конфиг {path.relative_to(ROOT)}")
    if re.search(r"\$\{[^}]*\}|\$\{", text):
        # Validate every syntactically complete token and reject malformed forms.
        masked = TOKEN.sub("", text)
        if "${" in masked:
            fail(f"некорректный placeholder в {path.relative_to(ROOT)}")
    def replace(match):
        key = match.group(1)
        if key not in values:
            fail(f"переменная {key} отсутствует в secrets")
        value = values[key]
        if format_name in ("yaml", "toml", "json"):
            # Placeholders are expected inside quoted scalar strings.
            return json.dumps(value, ensure_ascii=False)[1:-1]
        if format_name == "properties":
            return "".join("\\" + c if c in "\\:=#!" else "\\u%04x" % ord(c) if c in "\n\r\t" else c for c in value)
        if format_name == "raw":
            return value
        fail(f"неподдерживаемый формат конфига {path.relative_to(ROOT)}")

    if format_name == "raw" and TOKEN.fullmatch(text.strip()):
        output = replace(TOKEN.fullmatch(text.strip()))
    else:
        output = TOKEN.sub(replace, text)
    if "${" in output:
        fail(f"неизвестный placeholder в {path.relative_to(ROOT)}")
    if output != text:
        try:
            path.write_text(output, encoding="utf-8", newline="")
        except OSError:
            fail(f"не удалось обновить конфиг {path.relative_to(ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) != 1:
        fail("запускайте без аргументов; список конфигов задаётся в render-secrets.properties")
    try:
        entries = load_manifest()
    except (OSError, UnicodeError, ValueError) as error:
        fail(f"ошибка манифеста: {error}")
    secrets = load_secrets()
    for arg, format_name in entries:
        candidate = (ROOT / arg).resolve()
        if ROOT not in candidate.parents or not candidate.is_file():
            fail("некорректный путь конфигурации")
        render(candidate, secrets, format_name)
    print("[OK] Конфиги обработаны; значения не выводятся")
