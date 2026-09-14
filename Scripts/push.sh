#!/bin/bash
#
# Commit everything in the working tree and push it to main.
#
#   ./Scripts/push.sh "Subject line" [path/to/body.txt]
#
# Three things this does that doing it by hand kept getting wrong:
#
#   `git add -A`, never `commit -a`. The -a flag stages modifications to files
#   git already knows about and silently ignores new ones, so a commit that
#   looked complete shipped without the two files the change was actually made
#   of.
#
#   `git fetch` after the push. The token is passed as a URL rather than
#   configured on the remote, and pushing to a URL does not update
#   refs/remotes/origin/main. The next `git reset --hard origin/main` then
#   quietly rewinds the clone to the commit before the one just pushed, taking
#   the working tree with it. That has already happened once.
#
#   Every byte of git's output goes through sed. The token is read out of the
#   desktop app's config and must never reach a log, a transcript or a
#   terminal.
#
set -uo pipefail

SUBJECT="${1:-}"
BODY_FILE="${2:-}"
[ -z "$SUBJECT" ] && { echo "usage: ./Scripts/push.sh \"Subject\" [body-file]"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
GH_TOKEN=$(python3 -c "
import json, os, sys
try:
    c = json.load(open(os.path.expanduser('''$CFG''')))
    print(c['mcpServers']['github']['env']['GITHUB_PERSONAL_ACCESS_TOKEN'])
except Exception:
    sys.exit(1)
") || { echo "✗ no GitHub token in the desktop app's config"; exit 1; }

redact() { sed "s/${GH_TOKEN}/REDACTED/g"; }

if git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ]; then
  echo "Nothing to commit."
  exit 0
fi

git add -A

{
  echo "$SUBJECT"
  if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
    echo
    cat "$BODY_FILE"
  fi
  echo
  echo "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
} | git commit -q -F - || { echo "✗ commit failed"; exit 1; }

SHA=$(git rev-parse --short HEAD)

git push "https://x-access-token:${GH_TOKEN}@github.com/Throckmorton69420/podskipper.git" \
  HEAD:main 2>&1 | redact
PUSHED=${PIPESTATUS[0]}
[ "$PUSHED" -ne 0 ] && { echo "✗ push failed"; exit 1; }

# The part that is easy to forget and expensive to forget.
git fetch -q origin 2>&1 | redact

echo "✓ pushed $SHA"
echo "  origin/main is now $(git rev-parse --short origin/main)"
echo
echo "Next: ./Scripts/watch-ci.sh $SHA"
