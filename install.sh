#!/usr/bin/env bash
# Brings the task list back: enables the todo tools and adds the CLAUDE.md rule.
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required. Use the Quickstart prompt or the manual steps in README.md instead." >&2
  exit 1
fi

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/todo_fix.py" install
