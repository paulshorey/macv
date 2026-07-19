#!/bin/zsh
# Pretty-print JSON from stdin via python3.
set -euo pipefail
python3 - <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    obj = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write("not JSON\n")
    sys.exit(1)
print(json.dumps(obj, indent=2, ensure_ascii=False))
PY
