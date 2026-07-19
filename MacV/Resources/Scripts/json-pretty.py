#!/usr/bin/env python3
"""Pretty-print JSON from stdin. Can be bound directly (shebang)."""
import json
import sys

try:
    obj = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.stderr.write("not JSON\n")
    sys.exit(1)
print(json.dumps(obj, indent=2, ensure_ascii=False))
