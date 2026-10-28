#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PYTHON="$PROJECT_ROOT/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    echo "[ERROR] Не найден Python с зависимостями overrides: $PYTHON" >&2
    echo "       Установите их: python3 -m venv .venv && .venv/bin/python -m pip install -r scripts/requirements-overrides.txt" >&2
    exit 1
fi

exec "$PYTHON" "$SCRIPT_DIR/apply-overrides.py"
