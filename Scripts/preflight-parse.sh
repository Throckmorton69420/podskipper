#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SWIFT_COMPILER="${SWIFT_COMPILER:-$(xcrun --find swiftc 2>/dev/null || command -v swiftc)}"
[ -n "$SWIFT_COMPILER" ] || { echo "✗ swiftc not found"; exit 1; }

echo "▸ Parsing Swift sources"
count=0
while IFS= read -r -d "" file; do
  "$SWIFT_COMPILER" -parse "$file" >/dev/null
  count=$((count + 1))
done < <(find Models Services Views -name "*.swift" -print0 | sort -z)

echo "✓ Swift syntax OK ($count files)"
