#!/bin/bash
#
# Watch the GitHub Actions runs for a commit and report what they did.
#
# This exists because a local build passing is not the same as CI passing — the
# workflows do their own setup, and a mistake in that setup fails the IPA while
# every local build stays green. Asking someone to sideload a build that never
# got built is a waste of their time, and it has happened.
#
#   ./Scripts/watch-ci.sh                 # HEAD
#   ./Scripts/watch-ci.sh <sha>
#
set -uo pipefail
# The API matches head_sha on the full forty characters and silently returns an
# empty list for an abbreviated one — which looks exactly like a run that has
# not been queued yet, so the script waits forever for a build that finished
# ten minutes ago. Expand whatever was passed in.
SHA=$(git rev-parse "${1:-HEAD}")
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
TOKEN=$(python3 -c "import json;c=json.load(open('$CFG'));print(c['mcpServers']['github']['env']['GITHUB_PERSONAL_ACCESS_TOKEN'])")
REPO="Throckmorton69420/podskipper"

for attempt in $(seq 1 40); do
  curl -sS -o /tmp/ci-runs.json \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/actions/runs?head_sha=$SHA&per_page=10"

  python3 - "$SHA" <<'PY' > /tmp/ci-state.txt
import json, sys
runs = json.load(open('/tmp/ci-runs.json')).get('workflow_runs', [])
if not runs:
    print("  (no runs queued for this commit yet)")
    print("PENDING none"); raise SystemExit
done = all(r['status'] == 'completed' for r in runs)
bad  = [r for r in runs if r['conclusion'] not in (None, 'success')]
for r in runs:
    print(f"  {r['name'][:26]:<28} {r['status']:<11} {str(r['conclusion'])}")
print(("FAILED " if bad else "OK ") if done else "PENDING ",
      " ".join(str(r['id']) for r in bad))
PY
  STATE=$(tail -1 /tmp/ci-state.txt | awk '{print $1}')
  # Everything except the last line, which is the machine-readable verdict.
  # `head -n -1` is GNU-only and this runs on a Mac.
  sed '$d' /tmp/ci-state.txt
  [ "$STATE" = "PENDING" ] || break
  sleep 15
done

if [ "$STATE" = "FAILED" ]; then
  for id in $(tail -1 /tmp/ci-state.txt | cut -d' ' -f2-); do
    echo "──── errors from run $id ────"
    curl -sSL -o /tmp/ci-log.zip \
      -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/actions/runs/$id/logs"
    rm -rf /tmp/ci-log && mkdir -p /tmp/ci-log
    unzip -qo /tmp/ci-log.zip -d /tmp/ci-log 2>/dev/null
    grep -rhE "error:|##\[error\]" /tmp/ci-log 2>/dev/null \
      | sed 's|/Users/runner/work/podskipper/podskipper/||' | sort -u | head -25
  done
  exit 1
fi
echo "✓ CI green for ${SHA:0:7}"
