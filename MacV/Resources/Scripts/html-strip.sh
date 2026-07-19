#!/bin/zsh
# Strip tags from HTML-ish stdin using python3 (stdlib html.parser).
set -euo pipefail
python3 - <<'PY'
import sys
from html.parser import HTMLParser

class Stripper(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
    def handle_data(self, data):
        self.parts.append(data)

raw = sys.stdin.read()
p = Stripper()
try:
    p.feed(raw)
    p.close()
except Exception as e:
    sys.stderr.write(f"html parse error: {e}\n")
    sys.exit(1)
print("".join(p.parts))
PY
