#!/usr/bin/env python3
"""Copy rendered config files to a private temporary checker baseline."""
import os
import shutil
import sys
from pathlib import Path
from manifest import ROOT, load_manifest


def fail():
    print("[ERROR] Не удалось подготовить временный baseline Checker", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 2:
    fail()
target = Path(sys.argv[1]).resolve()
try:
    if target == ROOT or ROOT in target.parents:
        fail()
    target.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(target, 0o700)
    for relative, _format_name in load_manifest():
        source = (ROOT / relative).resolve()
        if ROOT not in source.parents or not source.is_file():
            fail()
        destination = target / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copy2(source, destination)
except (OSError, UnicodeError, ValueError):
    fail()
