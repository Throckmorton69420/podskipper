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

# What "played" means in this database, worked out against what the Podcasts
# app shows rather than assumed.
#
# The first version counted every ZPLAYSTATE 0 episode with a "manually set"
# flag as played — 11,963 of them. But Apple gives the back catalogue of a
# followed show state 0 with that flag and ZPLAYSTATESOURCE 6 and no play
# date at all: 590 Cum Town episodes the app shows as unplayed were imported
# as played. An episode is played here only with evidence of a play: a play
# count, a date the listener marked it played, or a last-played date that
# did not come from that back-catalogue source.
PLAYED="(e.ZPLAYSTATE = 0 AND (e.ZPLAYCOUNT > 0 OR e.ZLASTUSERMARKEDASPLAYEDDATE IS NOT NULL OR (e.ZLASTDATEPLAYED IS NOT NULL AND COALESCE(e.ZPLAYSTATESOURCE, 0) <> 6)))"

# Every episode, played or not, so an import can also put right an episode an
# earlier import got wrong. Each carries its own show's feed, because the
# same episode can sit in several shows (Cum Town episodes are reposted in
# MYCTP and on The Adam Friedland Show) with different histories.
EPISODES=$(sqlite3 -json "$WORK/lib.sqlite" "
  SELECT COALESCE(NULLIF(p.ZUPDATEDFEEDURL,''), p.ZFEEDURL) AS feedURL,
         p.ZFEEDURL AS originalFeedURL,
         e.ZGUID AS guid,
         e.ZTITLE AS title,
         CASE WHEN $PLAYED THEN 1 ELSE 0 END AS played,
         CASE WHEN e.ZPLAYSTATE = 1 THEN e.ZPLAYHEAD ELSE 0 END AS playhead,
         CASE WHEN e.ZLASTDATEPLAYED IS NOT NULL THEN CAST(e.ZLASTDATEPLAYED + $EPOCH AS INTEGER) END AS lastPlayed,
         CASE WHEN e.ZPUBDATE IS NOT NULL THEN CAST(e.ZPUBDATE + $EPOCH AS INTEGER) END AS published,
         COALESCE(e.ZSAVED, 0) AS saved
  FROM ZMTEPISODE e JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
  WHERE p.ZFEEDURL IS NOT NULL;")

mkdir -p "$(dirname "$OUT")"
printf '{"format":"podskipper-apple-podcasts-history","version":2,"exportedAt":%d,"shows":%s,"episodes":%s}\n' \
  "$(date +%s)" "${SHOWS:-[]}" "${EPISODES:-[]}" > "$OUT"

PLAYED_COUNT=$(sqlite3 "$WORK/lib.sqlite" "SELECT count(*) FROM ZMTEPISODE e WHERE $PLAYED;")
PARTIAL=$(sqlite3 "$WORK/lib.sqlite" "SELECT count(*) FROM ZMTEPISODE WHERE ZPLAYSTATE = 1;")
FOLLOWED=$(sqlite3 "$WORK/lib.sqlite" "SELECT count(*) FROM ZMTPODCAST WHERE ZSUBSCRIBED = 1;")
echo "Saved $OUT"
echo "$FOLLOWED followed shows, $PLAYED_COUNT played episodes, $PARTIAL in progress."
echo "On your iPhone: PodSkipper → Settings → Import Apple Podcasts History, then choose this file in iCloud Drive → PodSkipper."
