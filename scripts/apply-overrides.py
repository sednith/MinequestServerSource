#!/usr/bin/env python3
"""Apply partial overrides while preserving untouched configuration text."""
import json
import os
import re
import stat
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path

from ruamel.yaml import YAML
import tomlkit

ROOT = Path(__file__).resolve().parent.parent
OVERRIDES = ROOT / "overrides"


def log(message):
    print(message)


def fail(message):
    print(f"[ERROR] Overrides: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_text_preserving_newlines(path):
    with path.open("r", encoding="utf-8", newline="") as stream:
        return stream.read()


def server_roots():
    roots = []
    for directory in ROOT.iterdir():
        if not directory.is_dir() or not (directory / "java-args").is_file():
            continue
        if any(directory.glob("*.jar")):
            roots.append(directory.resolve())
    return roots


def load_yaml(path):
    parser = YAML(typ="rt")
    parser.preserve_quotes = True
    try:
        with path.open("r", encoding="utf-8", newline="") as stream:
            return parser.load(stream), parser
    except Exception:
        fail(f"ошибка чтения YAML файла: {path.relative_to(ROOT)}")


def is_mapping(value):
    if isinstance(value, Mapping):
        return True
    return (
        value.__class__.__module__.startswith("tomlkit")
        and callable(getattr(value, "items", None))
        and hasattr(value, "__getitem__")
        and hasattr(value, "__setitem__")
    )


def merge_mapping(target, patch):
    if not is_mapping(target) or not is_mapping(patch):
        return patch
    for key, value in patch.items():
        if key in target and is_mapping(target[key]) and is_mapping(value):
            merge_mapping(target[key], value)
        else:
            target[key] = value
    return target


def parse_json_spans(text):
    decoder = json.JSONDecoder()

    def whitespace(index):
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        return index

    def parse_string(index):
        value, end = decoder.raw_decode(text, index)
        if not isinstance(value, str):
            raise ValueError("expected JSON string")
        return value, end

    def parse_value(index):
        index = whitespace(index)
        start = index
        if index >= len(text):
            raise ValueError("unexpected end")
        if text[index] == "{":
            index = whitespace(index + 1)
            members = {}
            if index < len(text) and text[index] == "}":
                return {"kind": "object", "start": start, "end": index + 1, "members": members}, index + 1
            while True:
                index = whitespace(index)
                key, key_end = parse_string(index)
                if key in members:
                    raise ValueError("duplicate JSON key")
                index = whitespace(key_end)
                if index >= len(text) or text[index] != ":":
                    raise ValueError("expected colon")
                child, index = parse_value(index + 1)
                members[key] = child
                index = whitespace(index)
                if index < len(text) and text[index] == "}":
                    return {"kind": "object", "start": start, "end": index + 1, "members": members}, index + 1
                if index >= len(text) or text[index] != ",":
                    raise ValueError("expected comma")
                index += 1
        if text[index] == "[":
            index = whitespace(index + 1)
            if index < len(text) and text[index] == "]":
                return {"kind": "array", "start": start, "end": index + 1}, index + 1
            while True:
                _, index = parse_value(index)
                index = whitespace(index)
                if index < len(text) and text[index] == "]":
                    return {"kind": "array", "start": start, "end": index + 1}, index + 1
                if index >= len(text) or text[index] != ",":
                    raise ValueError("expected comma")
                index += 1
        _, end = decoder.raw_decode(text, index)
        return {"kind": "scalar", "start": start, "end": end}, end

    root, end = parse_value(0)
    if whitespace(end) != len(text):
        raise ValueError("trailing content")
    return root


def json_replacements(text, node, patch, replacements):
    if isinstance(patch, Mapping):
        if node["kind"] != "object":
            raise ValueError("nested override does not match JSON object")
        for key, value in patch.items():
            if key not in node["members"]:
                raise ValueError(f"JSON key is missing: {key}")
            child = node["members"][key]
            if isinstance(value, Mapping):
                json_replacements(text, child, value, replacements)
            else:
                replacements.append((child["start"], child["end"], json.dumps(value, ensure_ascii=False)))
    else:
        raise ValueError("JSON override root must be an object")


def apply_json(target_text, patch):
    root = parse_json_spans(target_text)
    replacements = []
    json_replacements(target_text, root, patch, replacements)
    for start, end, replacement in sorted(replacements, reverse=True):
        target_text = target_text[:start] + replacement + target_text[end:]
    return target_text


def property_string(value):
    if isinstance(value, (Mapping, list, tuple)) or value is None:
        raise ValueError("properties overrides must use scalar values")
    if isinstance(value, bool):
        value = str(value).lower()
    else:
        value = str(value)
    result = []
    for index, char in enumerate(value):
        if char == "\\":
            result.append("\\\\")
        elif char in "=:#!" or (char == " " and (index == 0 or index == len(value) - 1)):
            result.append("\\" + char)
        elif char == "\t":
            result.append("\\t")
        elif char == "\n":
            result.append("\\n")
        elif char == "\r":
            result.append("\\r")
        else:
            result.append(char)
    return "".join(result)


def apply_properties(target_text, patch):
    if not isinstance(patch, Mapping):
        raise ValueError("properties override must be a flat mapping")
    if any(not isinstance(key, str) for key in patch):
        raise ValueError("properties override keys must be strings")
    lines = target_text.splitlines(keepends=True)
    occurrences = {key: [] for key in patch}
    for index, line in enumerate(lines):
        content = line.rstrip("\r\n")
        stripped = content.lstrip()
        if not stripped or stripped.startswith(("#", "!")):
            continue
        separator_positions = [p for p in (content.find("="), content.find(":")) if p >= 0]
        if not separator_positions:
            continue
        separator = min(separator_positions)
        key = content[:separator].strip()
        if key in occurrences:
            prefix = content[:separator + 1]
            old_value = content[separator + 1:]
            leading_space = old_value[:len(old_value) - len(old_value.lstrip())]
            trailing_space = old_value[len(old_value.rstrip()):] if old_value.strip() else ""
            value = property_string(patch[key])
            ending = line[len(content):]
            lines[index] = prefix + leading_space + value + trailing_space + ending
            occurrences[key].append(index)
    missing = [key for key, matches in occurrences.items() if len(matches) != 1]
    if missing:
        raise ValueError("properties key must exist exactly once: " + ", ".join(missing))
    return "".join(lines)


def apply_java_args(target_text, override_text):
    values = [line.strip() for line in override_text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if len(values) != 1 or not re.fullmatch(r"-Xmx[0-9]+([kKmMgG])?", values[0]):
        raise ValueError("java-args override must contain exactly one -Xmx<size>")
    matches = []
    offset = 0
    for line in target_text.splitlines(keepends=True):
        if line.lstrip().startswith("#"):
            offset += len(line)
            continue
        for match in re.finditer(r"(?<!\S)-Xmx[^\s]+", line):
            matches.append((offset + match.start(), offset + match.end(), match.group()))
        offset += len(line)
    if len(matches) != 1:
        raise ValueError("base java-args must contain exactly one -Xmx<size>")
    start, end, token = matches[0]
    if not re.fullmatch(r"-Xmx[0-9]+([kKmMgG])?", token):
        raise ValueError("base java-args contains invalid -Xmx")
    return target_text[:start] + values[0] + target_text[end:]


def atomic_write(path, text):
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def apply_one(target, override):
    suffix = target.suffix.lower()
    if target.name == "java-args":
        return apply_java_args(read_text_preserving_newlines(target), read_text_preserving_newlines(override))
    if suffix in (".yml", ".yaml"):
        patch, _ = load_yaml(override)
        current, parser = load_yaml(target)
        if not isinstance(current, Mapping) or not isinstance(patch, Mapping):
            raise ValueError("YAML target and override roots must be mappings")
        merge_mapping(current, patch)
        from io import StringIO
        output = StringIO()
        parser.dump(current, output)
        return output.getvalue()
    if suffix == ".toml":
        current = tomlkit.parse(read_text_preserving_newlines(target))
        patch = tomlkit.parse(read_text_preserving_newlines(override))
        merge_mapping(current, patch)
        return tomlkit.dumps(current)
    if suffix == ".json":
        patch = json.loads(read_text_preserving_newlines(override))
        return apply_json(read_text_preserving_newlines(target), patch)
    if suffix == ".properties":
        patch, _ = load_yaml(override)
        return apply_properties(read_text_preserving_newlines(target), patch)
    raise ValueError(f"unsupported target format: {suffix or target.name}")


def main():
    if not OVERRIDES.is_dir():
        log(f"[WARN] Локальная папка {OVERRIDES} не найдена. Нечего применять.")
        return
    roots = server_roots()
    if not roots:
        fail("не найдены серверные папки с java-args и JAR-файлом")
    files = sorted(path for path in OVERRIDES.rglob("*") if path.is_file())
    applied = skipped = errors = 0
    for override in files:
        relative = override.relative_to(OVERRIDES)
        target = (ROOT / relative).resolve()
        owners = [root for root in roots if root in target.parents]
        if len(owners) != 1:
            log(f"[WARN] Override не относится ровно к одному серверу, пропуск: {relative.as_posix()}")
            skipped += 1
            continue
        if not target.is_file():
            log(f"[WARN] Базовый файл не найден, пропуск: {relative.as_posix()}")
            skipped += 1
            continue
        log(f"[INFO] Обработка {owners[0].name}: {relative.as_posix()}")
        try:
            updated = apply_one(target, override)
            if updated != read_text_preserving_newlines(target):
                atomic_write(target, updated)
            log("       [OK] Override применён; остальные строки сохранены")
            applied += 1
        except Exception as error:
            # Do not echo parser diagnostics: they can contain source values.
            log(f"       [ERROR] Не удалось применить override ({type(error).__name__})")
            errors += 1
    log(f"[INFO] Итого: применено={applied}, пропущено={skipped}, ошибок={errors}")
    if errors:
        fail("Overrides применены с ошибками")
    log("[OK] Локальные overrides обработаны")


if __name__ == "__main__":
    main()
