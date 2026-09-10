# shellcheck shell=bash
# Sourced by install.sh and uninstall.sh.

# Runs lib/todo_fix.py with the first Python 3.7+ it finds: python3 on macOS and
# Linux, python or the py launcher in Git Bash on Windows. Each candidate is
# actually run, which skips the Microsoft Store placeholders that Windows puts
# on PATH.
todo_fix() {
  local action="$1" hint="$2" lib check
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  check='import sys; sys.exit(sys.version_info < (3, 7))'
  if python3 -c "$check" >/dev/null 2>&1; then
    exec python3 "$lib/todo_fix.py" "$action"
  elif python -c "$check" >/dev/null 2>&1; then
    exec python "$lib/todo_fix.py" "$action"
  elif py -3 -c "$check" >/dev/null 2>&1; then
    exec py -3 "$lib/todo_fix.py" "$action"
  fi
  echo "error: Python 3.7 or newer is required. $hint" >&2
  exit 1
}
