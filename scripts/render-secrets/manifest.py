"""Shared parser for the explicit secret-rendering file manifest."""
from pathlib import Path, PurePosixPath

FORMATS = {"yaml", "toml", "json", "properties", "raw"}
ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).resolve().with_name("render-secrets.properties")


def load_manifest():
    entries = []
    seen = set()
    for number, row in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        row = row.strip()
        if not row or row.startswith("#"):
            continue
        key, sep, value = row.partition("=")
        if not sep:
            raise ValueError(f"некорректная запись в манифесте (строка {number})")
        relative = key.strip()
        format_name = value.strip()
        posix_path = PurePosixPath(relative)
        if (not relative or posix_path.is_absolute() or ".." in posix_path.parts
                or "\\" in relative or "\x00" in relative):
            raise ValueError(f"некорректный путь в манифесте (строка {number})")
        if format_name not in FORMATS:
            raise ValueError(f"неподдерживаемый формат в манифесте (строка {number})")
        if relative in seen:
            raise ValueError(f"повторный путь в манифесте (строка {number})")
        seen.add(relative)
        entries.append((relative, format_name))
    if not entries:
        raise ValueError("манифест не содержит путей конфигураций")
    return entries
