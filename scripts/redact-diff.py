#!/usr/bin/env python3
"""Preserve a readable unified diff while masking sensitive config values."""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "render-secrets"))
from manifest import load_manifest

# Match common credential-bearing fields in YAML/TOML/JSON/properties lines.
SENSITIVE = re.compile(
    r"(?i)(\b(?:[\w.-]*(?:secret|password|passwd|token|api[-_]?key)[\w.-]*)\b"
    r"\s*[:=]\s*)(.*)$"
)

raw_files = {path for path, format_name in load_manifest() if format_name == "raw"}
raw_file_diff = False
for line in sys.stdin:
    ending = "\n" if line.endswith("\n") else ""
    body = line[:-1] if ending else line
    if body.startswith("+++ b/"):
        raw_file_diff = body[6:] in raw_files
    # Diff metadata and hunk headers are not config content. For context/add/delete
    # lines, preserve the diff marker and field name but never the assigned value.
    if raw_file_diff and len(body) > 1 and body[0] in " +-" and not body.startswith(("+++", "---")):
        body = body[0] + "<REDACTED>"
    elif len(body) > 1 and body[0] in " +-" and not body.startswith(("+++", "---")):
        marker, content = body[0], body[1:]
        match = SENSITIVE.search(content)
        if match:
            content = content[:match.start(2)] + "<REDACTED>"
            body = marker + content
    sys.stdout.write(body + ending)
