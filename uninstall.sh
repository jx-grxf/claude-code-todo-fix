#!/usr/bin/env bash
# Reverts install.sh: removes the todo tools flag and the CLAUDE.md rule.
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required. Remove the flag and the marked CLAUDE.md block by hand instead." >&2
  exit 1
fi

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/todo_fix.py" uninstall
