#!/usr/bin/env bash
# Runs install.sh and uninstall.sh against throwaway config directories.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

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
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("env", {}).get("CLAUDE_CODE_ENABLE_TODO_TOOLS", ""))' "$1"
}
json_is() {
  python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.loads(sys.argv[2]) else 1)' "$1" "$2"
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

echo "outdated rule block"
dir="$work/outdated"
mkdir -p "$dir"
printf '# Rules\n\n<!-- claude-code-todo-fix:start -->\nold rule\n<!-- claude-code-todo-fix:end -->\n\n- Other rule.\n' >"$dir/CLAUDE.md"
run_install "$dir"
check "old rule replaced" fails grep -q 'old rule' "$dir/CLAUDE.md"
check "still one block" same "$(blocks "$dir/CLAUDE.md")" 1
check "text after block kept" grep -qF -- '- Other rule.' "$dir/CLAUDE.md"

echo "symlinked settings.json"
dir="$work/symlink"
mkdir -p "$dir" "$work/dotfiles"
printf '{"model": "opus"}\n' >"$work/dotfiles/settings.json"
ln -s "$work/dotfiles/settings.json" "$dir/settings.json"
run_install "$dir"
check "symlink kept" test -L "$dir/settings.json"
check "link target updated" same "$(flag "$work/dotfiles/settings.json")" 1
check "no backup inside dotfiles" same "$(backups "$work/dotfiles")" 0

echo "invalid settings.json"
dir="$work/invalid"
mkdir -p "$dir"
printf '{ "model": "opus", }\n' >"$dir/settings.json"
cp "$dir/settings.json" "$work/invalid.json"
check "install refuses" fails run_install "$dir" 2>/dev/null
check "settings.json untouched" cmp -s "$dir/settings.json" "$work/invalid.json"
check "CLAUDE.md not created" test ! -e "$dir/CLAUDE.md"

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
