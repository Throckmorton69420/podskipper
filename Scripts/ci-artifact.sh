#!/bin/bash
#
# List the CI runs for a commit and the artifacts each produced.
#
#   ./Scripts/ci-artifact.sh [sha]      default HEAD
#
# Confirms the IPA actually exists before asking him to sideload.
# Exit 0 only when an artifact named PodSkipper-ipa is present.
# The token is read from the Claude config and never printed.
set -uo pipefail
cd "$(dirname "$0")/.."
SHA=$(git rev-parse "${1:-HEAD}")   # the API needs all 40 characters
python3 - "$SHA" <<'PY'
import json, os, ssl, sys, urllib.request
cfg = json.load(open(os.path.expanduser(
    '~/Library/Application Support/Claude/claude_desktop_config.json')))
tok = cfg['mcpServers']['github']['env']['GITHUB_PERSONAL_ACCESS_TOKEN']
ctx = ssl.create_default_context(cafile="/etc/ssl/cert.pem")
def get(u):
    r = urllib.request.Request(u, headers={'Authorization': 'Bearer ' + tok,
                                           'Accept': 'application/vnd.github+json'})
    return json.load(urllib.request.urlopen(r, context=ctx))
base = 'https://api.github.com/repos/Throckmorton69420/podskipper/actions/runs'
ipa = False
for r in get(base + '?head_sha=' + sys.argv[1])['workflow_runs']:
    print(r['name'], r['status'], r['conclusion'], r['html_url'])
    for a in get(base + '/%d/artifacts' % r['id'])['artifacts']:
        print('   artifact', a['name'], a['size_in_bytes'], 'bytes',
              '(expired)' if a.get('expired') else '')
        ipa |= a['name'] == 'PodSkipper-ipa' and not a.get('expired')
print('IPA present' if ipa else 'NO IPA')
sys.exit(0 if ipa else 1)
PY
