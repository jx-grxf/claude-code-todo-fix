#!/usr/bin/env bash
# Runs install.sh and uninstall.sh against throwaway config directories.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# Git Bash on Windows usually has python, not python3.
python=python3
"$python" -c '' >/dev/null 2>&1 || python=python

check() {
  local name="$1"
  shift
  if "$@"; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s\n' "$name"
    failures=$((failures + 1))
  fi
}
fails() { ! "$@"; }
same() { [ "$1" = "$2" ]; }

run_install() { CLAUDE_CONFIG_DIR="$1" "$root/install.sh" >/dev/null; }
run_uninstall() { CLAUDE_CONFIG_DIR="$1" "$root/uninstall.sh" >/dev/null; }
flag() {
  "$python" -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("env", {}).get("CLAUDE_CODE_ENABLE_TODO_TOOLS", ""))' "$1"
}
json_is() {
  "$python" -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1], encoding="utf-8")) == json.loads(sys.argv[2]) else 1)' "$1" "$2"
}
hex() { od -An -tx1 "$@" | tr -d ' \n'; }
crlf_only() {
  "$python" -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(0 if b"\n" in d and d.count(b"\n") == d.count(b"\r\n") else 1)' "$1"
}
blocks() { grep -c 'claude-code-todo-fix:start' "$1" || true; }
backups() { find "$1" -name '*.bak-*' | wc -l | tr -d ' '; }

echo "fresh config directory"
dir="$work/fresh"
run_install "$dir"
check "flag is set" same "$(flag "$dir/settings.json")" 1
check "rule added once" same "$(blocks "$dir/CLAUDE.md")" 1
check "no backups for new files" same "$(backups "$dir")" 0
settings_before="$(cat "$dir/settings.json")"
memory_before="$(cat "$dir/CLAUDE.md")"
run_install "$dir"
check "rerun leaves settings.json alone" same "$(cat "$dir/settings.json")" "$settings_before"
check "rerun leaves CLAUDE.md alone" same "$(cat "$dir/CLAUDE.md")" "$memory_before"
check "rerun writes no backups" same "$(backups "$dir")" 0
run_uninstall "$dir"
check "uninstall leaves empty settings" json_is "$dir/settings.json" '{}'
check "uninstall empties CLAUDE.md" same "$(cat "$dir/CLAUDE.md")" ""

echo "existing settings and rules"
dir="$work/existing"
mkdir -p "$dir"
cat >"$dir/settings.json" <<'JSON'
{
  "model": "opus",
  "env": { "FOO": "bar" },
  "permissions": { "allow": ["Bash(git status)"] }
}
JSON
printf '# My rules\n\n- Keep answers short.\n' >"$dir/CLAUDE.md"
cp "$dir/CLAUDE.md" "$work/original.md"
run_install "$dir"
check "flag is set" same "$(flag "$dir/settings.json")" 1
check "other settings kept" json_is "$dir/settings.json" \
  '{"model": "opus", "env": {"FOO": "bar", "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}, "permissions": {"allow": ["Bash(git status)"]}}'
check "existing rules kept" grep -qF -- '- Keep answers short.' "$dir/CLAUDE.md"
check "rule added once" same "$(blocks "$dir/CLAUDE.md")" 1
check "both files backed up" same "$(backups "$dir")" 2
run_uninstall "$dir"
check "uninstall restores settings" json_is "$dir/settings.json" \
  '{"model": "opus", "env": {"FOO": "bar"}, "permissions": {"allow": ["Bash(git status)"]}}'
check "uninstall restores CLAUDE.md" cmp -s "$dir/CLAUDE.md" "$work/original.md"

echo "outdated and duplicate rule blocks"
dir="$work/outdated"
mkdir -p "$dir"
old='<!-- claude-code-todo-fix:start -->\nold rule\n<!-- claude-code-todo-fix:end -->\n'
# shellcheck disable=SC2059 # $old holds printf escapes on purpose
printf "# Rules\n\n$old\n- Other rule.\n\n$old" >"$dir/CLAUDE.md"
run_install "$dir"
check "old rule replaced" fails grep -q 'old rule' "$dir/CLAUDE.md"
check "still one block" same "$(blocks "$dir/CLAUDE.md")" 1
check "text after block kept" grep -qF -- '- Other rule.' "$dir/CLAUDE.md"

echo "line endings and byte order mark"
dir="$work/crlf"
mkdir -p "$dir"
printf '\357\273\277{\r\n  "model": "opus"\r\n}\r\n' >"$dir/settings.json"
printf '# Rules\r\n\r\n- Keep answers short.' >"$dir/CLAUDE.md"
run_install "$dir"
check "flag is set" same "$(flag "$dir/settings.json")" 1
check "settings.json keeps BOM" same "$(head -c 3 "$dir/settings.json" | hex)" efbbbf
check "settings.json keeps CRLF" crlf_only "$dir/settings.json"
check "CLAUDE.md keeps CRLF" crlf_only "$dir/CLAUDE.md"
run_uninstall "$dir"
check "uninstall restores CLAUDE.md" same "$(hex "$dir/CLAUDE.md")" "$(printf '# Rules\r\n\r\n- Keep answers short.\r\n' | hex)"

echo "symlinked settings.json"
dir="$work/symlink"
mkdir -p "$dir" "$work/dotfiles"
printf '{"model": "opus"}\n' >"$work/dotfiles/settings.json"
if ln -s "$work/dotfiles/settings.json" "$dir/settings.json" 2>/dev/null && [ -L "$dir/settings.json" ]; then
  run_install "$dir"
  check "symlink kept" test -L "$dir/settings.json"
  check "link target updated" same "$(flag "$work/dotfiles/settings.json")" 1
  check "no backup inside dotfiles" same "$(backups "$work/dotfiles")" 0
else
  echo "  skip  cannot create symlinks here"
fi

echo "invalid files are left alone"
dir="$work/invalid"
mkdir -p "$dir"
printf '{ "model": "opus", }\n' >"$dir/settings.json"
cp "$dir/settings.json" "$work/invalid.json"
check "install refuses" fails run_install "$dir" 2>/dev/null
check "settings.json untouched" cmp -s "$dir/settings.json" "$work/invalid.json"
check "CLAUDE.md not created" test ! -e "$dir/CLAUDE.md"
dir="$work/nan"
mkdir -p "$dir"
printf '{ "n": NaN }\n' >"$dir/settings.json"
check "NaN is refused" fails run_install "$dir" 2>/dev/null
dir="$work/utf16"
mkdir -p "$dir"
printf '{}\n' >"$dir/settings.json"
printf '\377\376#\000\n\000' >"$dir/CLAUDE.md"
check "UTF-16 CLAUDE.md is refused" fails run_install "$dir" 2>/dev/null
check "settings.json untouched before that" same "$(cat "$dir/settings.json")" "{}"

echo "Python lookup"
bin="$work/bin"
mkdir -p "$bin"
# Stands in for the Microsoft Store placeholder: on PATH, but not a real Python.
printf '#!/bin/sh\necho "Python was not found" >&2\nexit 49\n' >"$bin/python3"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$python")" >"$bin/python"
chmod +x "$bin/python3" "$bin/python"
lookup() { PATH="$bin:$PATH" run_install "$work/lookup"; }
check "falls back to python when python3 doesn't work" lookup

echo "README quickstart"
missing=0
while IFS= read -r line; do
  grep -qxF -- "$line" "$root/README.md" || missing=1
done <"$root/snippet/CLAUDE.md"
check "prompt contains the current snippet" same "$missing" 0

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
