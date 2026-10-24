#!/bin/bash
# Build all seven eXo ScummVM versions as universal macOS 11+ bundles.
set -euo pipefail
cd "$(dirname "$0")"

while read -r name ref; do
    [ -z "$name" ] && continue
    echo "=================================================================="
    echo "== $name  ($ref)"
    echo "=================================================================="
    ./build-one.sh "$name" "$ref"
done <<'EOF'
scummvm-2-3-0-git18903-g313a824fb9 313a824fb91c88b9d8cfe6234c73608c3a55dfa4
scummvm-2-5-0 v2.5.0
scummvm-2-8-0 v2.8.0
scummvm-2-8-0-git9335-g00e72a17004 00e72a17004d393d8f44e4c54aa51c0a7efe75cc
scummvm-2-9-0 v2.9.0
scummvm-3-0-0-git20192-g3ca9da6a1c3 3ca9da6a1c36ed1450ec5c5f08d48a225c7699df
scummvm-2026-1-0 v2026.1.0
EOF

echo
echo "All bundles built:"
ls -d out/*.app
