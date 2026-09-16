#!/bin/zsh
# Exports your Apple Podcasts listening history for PodSkipper.
#
# Apple Podcasts has no export, but on a Mac signed in to the same Apple
# Account its library — including what you played on your iPhone — is synced
# into a local database. This reads a copy of that database (never the
# original, and never while writing) and saves a small JSON file to iCloud
# Drive, where PodSkipper's "Import Apple Podcasts History" can pick it up.
#
# Usage: ./export-history.sh [output-file]
# Double-click-able as a .command file, too.
set -euo pipefail

SRC="$HOME/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite"
OUT_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/PodSkipper"
OUT="${1:-$OUT_DIR/Apple Podcasts History.json}"

if [[ ! -f "$SRC" ]]; then
  echo "Couldn't find the Apple Podcasts library on this Mac."
  echo "Open the Podcasts app once, signed in to the same Apple Account as your iPhone, and let it sync."
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Copy the database with its write-ahead log so recent plays are included.
cp "$SRC" "$WORK/lib.sqlite"
[[ -f "$SRC-wal" ]] && cp "$SRC-wal" "$WORK/lib.sqlite-wal"
[[ -f "$SRC-shm" ]] && cp "$SRC-shm" "$WORK/lib.sqlite-shm"

# Core Data stores dates as seconds since 2001-01-01.
EPOCH=978307200

SHOWS=$(sqlite3 -json "$WORK/lib.sqlite" "
  SELECT COALESCE(NULLIF(ZUPDATEDFEEDURL,''), ZFEEDURL) AS feedURL,
         ZTITLE AS title,
         ZSUBSCRIBED AS subscribed
  FROM ZMTPODCAST
  WHERE ZFEEDURL IS NOT NULL;")

# playState: 0 played (or never surfaced), 1 in progress, 2 unplayed.
# An episode counts as played only with evidence: a play count, a last-played
# date, or a state someone set by hand.
EPISODES=$(sqlite3 -json "$WORK/lib.sqlite" "
  SELECT COALESCE(NULLIF(p.ZUPDATEDFEEDURL,''), p.ZFEEDURL) AS feedURL,
         e.ZGUID AS guid,
         e.ZTITLE AS title,
         CASE WHEN e.ZPLAYSTATE = 0 AND (e.ZPLAYCOUNT > 0 OR e.ZLASTDATEPLAYED IS NOT NULL OR e.ZPLAYSTATEMANUALLYSET = 1)
              THEN 1 ELSE 0 END AS played,
         CASE WHEN e.ZPLAYSTATE = 1 THEN e.ZPLAYHEAD ELSE 0 END AS playhead,
         CASE WHEN e.ZLASTDATEPLAYED IS NOT NULL THEN CAST(e.ZLASTDATEPLAYED + $EPOCH AS INTEGER) END AS lastPlayed,
         CASE WHEN e.ZPUBDATE IS NOT NULL THEN CAST(e.ZPUBDATE + $EPOCH AS INTEGER) END AS published,
         COALESCE(e.ZSAVED, 0) AS saved
  FROM ZMTEPISODE e JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
  WHERE e.ZPLAYSTATE = 1
     OR e.ZPLAYCOUNT > 0
     OR e.ZLASTDATEPLAYED IS NOT NULL
     OR e.ZPLAYSTATEMANUALLYSET = 1
     OR e.ZSAVED = 1;")

mkdir -p "$(dirname "$OUT")"
printf '{"format":"podskipper-apple-podcasts-history","version":1,"exportedAt":%d,"shows":%s,"episodes":%s}\n' \
  "$(date +%s)" "${SHOWS:-[]}" "${EPISODES:-[]}" > "$OUT"

PLAYED=$(sqlite3 "$WORK/lib.sqlite" "SELECT count(*) FROM ZMTEPISODE WHERE ZPLAYSTATE = 0 AND (ZPLAYCOUNT > 0 OR ZLASTDATEPLAYED IS NOT NULL OR ZPLAYSTATEMANUALLYSET = 1);")
PARTIAL=$(sqlite3 "$WORK/lib.sqlite" "SELECT count(*) FROM ZMTEPISODE WHERE ZPLAYSTATE = 1;")
FOLLOWED=$(sqlite3 "$WORK/lib.sqlite" "SELECT count(*) FROM ZMTPODCAST WHERE ZSUBSCRIBED = 1;")
echo "Saved $OUT"
echo "$FOLLOWED followed shows, $PLAYED played episodes, $PARTIAL in progress."
echo "On your iPhone: PodSkipper → Settings → Import Apple Podcasts History, then choose this file in iCloud Drive → PodSkipper."
