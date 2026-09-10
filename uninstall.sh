#!/usr/bin/env bash
# Reverts install.sh: removes the todo tools flag and the CLAUDE.md rule.
set -euo pipefail

# shellcheck source=lib/todo_fix.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/todo_fix.sh"
todo_fix uninstall "On Windows, run uninstall.ps1 instead. Otherwise remove the flag and the marked CLAUDE.md block by hand."
