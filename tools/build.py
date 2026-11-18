#!/usr/bin/env python3
"""Собирает один самодостаточный файл dist/vless-setup.sh из исходников в src/.

  src/wizard.sh          — мастер, который запускается на компьютере пользователя
  src/server/*.sh        — скрипты, которые мастер передаёт на серверы по SSH
  src/lib/*              — общие куски, вставляются через  @@INCLUDE lib/<файл>@@

Запуск:  python3 tools/build.py   (или  make build)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
DIST = os.path.join(ROOT, "dist")

SERVER_SCRIPTS = {          # плейсхолдер в wizard.sh -> файл
    "RU_SCRIPT": "server/entry.sh",
    "RELAY_SCRIPT": "server/relay.sh",
    "SINGLE_SCRIPT": "server/single.sh",
}
HEREDOC_ENDS = ["__RU_SCRIPT_END__", "__RELAY_SCRIPT_END__", "__SINGLE_SCRIPT_END__", "__PF_END__", "__PANEL_PY_END__"]


def read(rel):
    with open(os.path.join(SRC, rel), encoding="utf-8") as f:
        return f.read()


def expand_includes(text, depth=0):
    if depth > 5:
        sys.exit("build: слишком глубокая вложенность @@INCLUDE")
    out = re.sub(r"@@INCLUDE ([\w./\-]+)@@", lambda m: expand_includes(read(m.group(1)).rstrip("\n"), depth + 1), text)
    return out


def version():
    try:
        with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return "dev"


def main():
    parts = {}
    for key, rel in SERVER_SCRIPTS.items():
        body = expand_includes(read(rel))
        if "@@INCLUDE" in body:
            sys.exit("build: в %s остался нераскрытый @@INCLUDE" % rel)
        for marker in HEREDOC_ENDS:
            if marker == "__PANEL_PY_END__":
                continue
            if marker in body:
                sys.exit("build: в %s встречается служебная метка %s" % (rel, marker))
        parts[key] = body

    wizard = read("wizard.sh").replace("@@VERSION@@", version())
    for key, body in parts.items():
        placeholder = "@@%s@@" % key
        if wizard.count(placeholder) != 1:
            sys.exit("build: в wizard.sh должен быть ровно один %s" % placeholder)
        wizard = wizard.replace(placeholder, body.rstrip("\n"))

    leftovers = [m for m in re.findall(r"@@[A-Z_]+@@", wizard)]
    if leftovers:
        sys.exit("build: остались плейсхолдеры: %s" % ", ".join(sorted(set(leftovers))))

    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, "vless-setup.sh")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(wizard)
    os.chmod(out, 0o755)
    # отдельные серверные скрипты — только для тестов и отладки
    for key, rel in SERVER_SCRIPTS.items():
        with open(os.path.join(DIST, os.path.basename(rel)), "w", encoding="utf-8", newline="\n") as f:
            f.write(parts[key])
    print("build: %s (%d байт, версия %s)" % (os.path.relpath(out, ROOT), len(wizard.encode("utf-8")), version()))


if __name__ == "__main__":
    main()
