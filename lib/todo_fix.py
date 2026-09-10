#!/usr/bin/env python3
"""Apply or revert the task list fix in a Claude Code config directory.

install    sets CLAUDE_CODE_ENABLE_TODO_TOOLS=1 in settings.json and adds the
           rule from snippet/CLAUDE.md to CLAUDE.md
uninstall  removes both again

A file is only rewritten when its content changes, and a timestamped backup is
written next to it first. Symlinked files are updated in place.
"""
import json
import os
import re
import shutil
import sys
import tempfile
import time
from typing import NoReturn

KEY = "CLAUDE_CODE_ENABLE_TODO_TOOLS"
VALUE = "1"
START = "<!-- claude-code-todo-fix:start -->"
END = "<!-- claude-code-todo-fix:end -->"
BLOCK = re.compile(re.escape(START) + r".*?" + re.escape(END) + r"\n?", re.S)
STAMP = time.strftime("%Y%m%d-%H%M%S")


def fail(message) -> NoReturn:
    sys.exit("error: " + message)


def read(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    if os.path.exists(path):
        shutil.copy2(path, "{}.bak-{}".format(path, STAMP))
    target = os.path.realpath(path)
    directory = os.path.dirname(target)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".todo-fix-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        if os.path.exists(target):
            shutil.copymode(target, tmp)
        else:
            umask = os.umask(0)
            os.umask(umask)
            os.chmod(tmp, 0o666 & ~umask)
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def load_settings(path):
    raw = read(path)
    if raw is None or not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except ValueError as error:
        fail("{} is not valid JSON ({}). Fix it or follow the manual steps "
             "in README.md.".format(path, error))
    if not isinstance(data, dict):
        fail("{} must contain a JSON object.".format(path))
    return data


def dump(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def remove_blocks(text):
    while True:
        match = BLOCK.search(text)
        if not match:
            return text
        before, after = text[:match.start()], text[match.end():]
        if not after and before.endswith("\n\n"):
            # Drop the blank line that install put in front of the block.
            before = before[:-1]
        text = before + after


def install(config_dir, snippet_path):
    settings_path = os.path.join(config_dir, "settings.json")
    memory_path = os.path.join(config_dir, "CLAUDE.md")

    snippet = read(snippet_path)
    if snippet is None or START not in snippet or END not in snippet:
        fail("snippet missing or without markers: " + snippet_path)
    block = snippet.strip() + "\n"

    changed = False
    data = load_settings(settings_path)
    env = data.setdefault("env", {})
    if not isinstance(env, dict):
        fail('"env" in {} must be an object.'.format(settings_path))
    if env.get(KEY) == VALUE:
        print("settings.json  {} already set".format(KEY))
    else:
        env[KEY] = VALUE
        write(settings_path, dump(data))
        changed = True
        print("settings.json  set {}={}".format(KEY, VALUE))

    text = read(memory_path) or ""
    if BLOCK.search(text):
        updated = BLOCK.sub(lambda _: block, text, count=1)
        action = "updated"
    else:
        separator = "" if not text else ("\n" if text.endswith("\n") else "\n\n")
        updated = text + separator + block
        action = "added"
    if updated == text:
        print("CLAUDE.md      task list rule already present")
    else:
        write(memory_path, updated)
        changed = True
        print("CLAUDE.md      task list rule " + action)
    return changed


def uninstall(config_dir):
    settings_path = os.path.join(config_dir, "settings.json")
    memory_path = os.path.join(config_dir, "CLAUDE.md")

    changed = False
    data = load_settings(settings_path)
    env = data.get("env")
    if isinstance(env, dict) and KEY in env:
        del env[KEY]
        if not env:
            del data["env"]
        write(settings_path, dump(data))
        changed = True
        print("settings.json  removed " + KEY)
    else:
        print("settings.json  {} not set".format(KEY))

    text = read(memory_path)
    if text is None or not BLOCK.search(text):
        print("CLAUDE.md      no task list rule found")
    else:
        write(memory_path, remove_blocks(text))
        changed = True
        print("CLAUDE.md      task list rule removed")
    return changed


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("install", "uninstall"):
        sys.exit("usage: todo_fix.py install|uninstall")
    config_dir = os.path.expanduser(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join("~", ".claude"))
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    print("Config directory: {}\n".format(config_dir))
    if sys.argv[1] == "install":
        changed = install(config_dir, os.path.join(root, "snippet", "CLAUDE.md"))
    else:
        changed = uninstall(config_dir)
    if changed:
        print("\nRestart Claude Code to apply the change.")


if __name__ == "__main__":
    main()
