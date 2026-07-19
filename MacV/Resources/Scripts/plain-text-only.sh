#!/bin/zsh
# Pass through stdin as plain text (identity / force plain-text pipeline stage).
# Usage: bound to Paste to paste clipboard as plain text after any prior rich copy.
set -euo pipefail
cat
