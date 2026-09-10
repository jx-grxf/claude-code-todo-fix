#!/usr/bin/env python3
"""Apply or revert the task list fix in a Claude Code config directory.

install    sets CLAUDE_CODE_ENABLE_TODO_TOOLS=1 in settings.json and adds the
           rule from snippet/CLAUDE.md to CLAUDE.md
uninstall  removes both again

Both files are checked before either is written. A file is only rewritten when
its content changes, and a timestamped backup is written next to it first.
Symlinked files are updated in place, and line endings (LF or CRLF) and a UTF-8
byte order mark are kept as they were.

lib/todo_fix.ps1 does the same for Windows PowerShell. Keep the two in sync.
"""
import codecs
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


class Document:
    """Text of a file with its line endings normalized to LF."""

    def __init__(self, path):
        self.path = path
        self.exists = os.path.exists(path)
        self.bom = False
        self.eol = "\n"
        self.text = ""
        if not self.exists:
            return
        with open(path, "rb") as f:
            raw = f.read()
        if raw.startswith(codecs.BOM_UTF8):
            self.bom = True
            raw = raw[len(codecs.BOM_UTF8):]
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            fail("{} is not UTF-8 text. Save it as UTF-8 or follow the manual "
                 "steps in README.md.".format(path))
        if "\r\n" in text:
            self.eol = "\r\n"
        self.text = text.replace("\r\n", "\n")

    def save(self, text):
        data = text.replace("\n", self.eol).encode("utf-8")
        if self.bom:
            data = codecs.BOM_UTF8 + data
        if self.exists:
            shutil.copy2(self.path, "{}.bak-{}".format(self.path, STAMP))
        target = os.path.realpath(self.path)
        directory = os.path.dirname(target)
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".todo-fix-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
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


def reject_constant(name):
    raise ValueError("{} is not valid JSON".format(name))


def load_settings(document):
    if not document.text.strip():
        return {}
    try:
        data = json.loads(document.text, parse_constant=reject_constant)
    except ValueError as error:
        fail("{} is not valid JSON ({}). Fix it or follow the manual steps "
             "in README.md.".format(document.path, error))
    if not isinstance(data, dict):
        fail("{} must contain a JSON object.".format(document.path))
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
    snippet = Document(snippet_path)
    if not snippet.exists or START not in snippet.text or END not in snippet.text:
        fail("snippet missing or without markers: " + snippet_path)
    block = snippet.text.strip() + "\n"

    settings = Document(os.path.join(config_dir, "settings.json"))
    memory = Document(os.path.join(config_dir, "CLAUDE.md"))
    data = load_settings(settings)
    env = data.setdefault("env", {})
    if not isinstance(env, dict):
        fail('"env" in {} must be an object.'.format(settings.path))

    changed = False
    if env.get(KEY) == VALUE:
        print("settings.json  {} already set".format(KEY))
    else:
        env[KEY] = VALUE
        settings.save(dump(data))
        changed = True
        print("settings.json  set {}={}".format(KEY, VALUE))

    text = memory.text
    match = BLOCK.search(text)
    if match:
        updated = text[:match.start()] + block + remove_blocks(text[match.end():])
        action = "updated"
    else:
        separator = "" if not text else ("\n" if text.endswith("\n") else "\n\n")
        updated = text + separator + block
        action = "added"
    if updated == text:
        print("CLAUDE.md      task list rule already present")
    else:
        memory.save(updated)
        changed = True
        print("CLAUDE.md      task list rule " + action)
    return changed


def uninstall(config_dir):
    settings = Document(os.path.join(config_dir, "settings.json"))
    memory = Document(os.path.join(config_dir, "CLAUDE.md"))
    data = load_settings(settings)

    changed = False
    env = data.get("env")
    if isinstance(env, dict) and KEY in env:
        del env[KEY]
        if not env:
            del data["env"]
        settings.save(dump(data))
        changed = True
        print("settings.json  removed " + KEY)
    else:
        print("settings.json  {} not set".format(KEY))

    if not BLOCK.search(memory.text):
        print("CLAUDE.md      no task list rule found")
    else:
        memory.save(remove_blocks(memory.text))
        changed = True
        print("CLAUDE.md      task list rule removed")
    return changed


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("install", "uninstall"):
        sys.exit("usage: todo_fix.py install|uninstall")
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if reconfigure:
        # A config path the console encoding can't show must not abort the run.
        reconfigure(errors="replace")
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
