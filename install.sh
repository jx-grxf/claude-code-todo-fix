#!/usr/bin/env bash
# Brings the task list back: enables the todo tools and adds the CLAUDE.md rule.
set -euo pipefail

# shellcheck source=lib/todo_fix.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/todo_fix.sh"
todo_fix install "On Windows, run install.ps1 instead. Otherwise use the Quickstart prompt or the manual steps in README.md."
