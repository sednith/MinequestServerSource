#!/usr/bin/env python3
"""Copy rendered config files to a private temporary checker baseline."""
import os
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
manifest = Path(__file__).resolve().with_name("render-secrets.properties")


def fail():
    print("[ERROR] Не удалось подготовить временный baseline Checker", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 2:
    fail()
target = Path(sys.argv[1]).resolve()
try:
    if target == root or root in target.parents:
        fail()
    target.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(target, 0o700)
    files = []
    for row in manifest.read_text(encoding="utf-8").splitlines():
        row = row.strip()
        if row.startswith("files="):
            files.extend(p.strip() for p in row.partition("=")[2].split(",") if p.strip())
    if not files:
        fail()
    for relative in files:
        source = (root / relative).resolve()
        if root not in source.parents or not source.is_file():
            fail()
        destination = target / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copy2(source, destination)
except (OSError, UnicodeError):
    fail()
