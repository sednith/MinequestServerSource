#!/usr/bin/env python3
"""Safely render ${NAME} placeholders using the local, non-executable secrets file."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).resolve().with_name("render-secrets.properties")
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


def load_manifest():
    """Read only the file allowlist; values remain in the local secrets file."""
    try:
        rows = MANIFEST.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        fail("не удалось прочитать render-secrets.properties")
    files = []
    for number, row in enumerate(rows, 1):
        row = row.strip()
        if not row or row.startswith("#"):
            continue
        key, sep, value = row.partition("=")
        if not sep or not value.strip():
            fail(f"некорректная строка {number} в render-secrets.properties")
        value = value.strip()
        if key.strip() == "files":
            files.extend(item.strip() for item in value.split(",") if item.strip())
        else:
            fail(f"неизвестное или повторное свойство в render-secrets.properties (строка {number})")
    if not files:
        fail("в render-secrets.properties не заданы files")
    return files


def render(path, values):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        fail(f"не удалось прочитать конфиг {path.relative_to(ROOT)}")
    if re.search(r"\$\{[^}]*\}|\$\{", text):
        # Validate every syntactically complete token and reject malformed forms.
        masked = TOKEN.sub("", text)
        if "${" in masked:
            fail(f"некорректный placeholder в {path.relative_to(ROOT)}")
    ext = path.suffix.lower()

    def replace(match):
        key = match.group(1)
        if key not in values:
            fail(f"переменная {key} отсутствует в secrets")
        value = values[key]
        if ext in (".yml", ".yaml", ".toml", ".json"):
            # Placeholders are expected inside quoted scalar strings.
            return json.dumps(value, ensure_ascii=False)[1:-1]
        if ext == ".properties":
            return "".join("\\" + c if c in "\\:=#!" else "\\u%04x" % ord(c) if c in "\n\r\t" else c for c in value)
        if ext == "":
            # Velocity's forwarding.secret is a raw single-value file.
            return value
        fail(f"неподдерживаемый формат конфига {path.relative_to(ROOT)}")

    output = TOKEN.sub(replace, text)
    if "${" in output:
        fail(f"неизвестный placeholder в {path.relative_to(ROOT)}")
    if path.relative_to(ROOT).as_posix() == "velocity/forwarding.secret":
        output = output.rstrip("\r\n")
    if output != text:
        try:
            path.write_text(output, encoding="utf-8", newline="")
        except OSError:
            fail(f"не удалось обновить конфиг {path.relative_to(ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) != 1:
        fail("запускайте без аргументов; список конфигов задаётся в render-secrets.properties")
    files = load_manifest()
    secrets = load_secrets()
    for arg in files:
        candidate = (ROOT / arg).resolve()
        if ROOT not in candidate.parents or not candidate.is_file():
            fail("некорректный путь конфигурации")
        render(candidate, secrets)
    print("[OK] Конфиги обработаны; значения не выводятся")
