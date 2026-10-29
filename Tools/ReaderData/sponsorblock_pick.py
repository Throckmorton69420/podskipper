#!/usr/bin/env python3
"""Pass 53: pick YouTube podcast episodes that SponsorBlock users have
segmented, for the Reader's external training data.

    sponsorblock_pick.py <out dir> [per-channel]

SponsorBlock (sponsor.ajay.app) segment data is CC BY-NC-SA 4.0
(https://wiki.sponsor.ajay.app/w/Database_and_API_License); used here
offline, non-commercially, with attribution, to train a personal app's
reader. Each pick records its source, votes and license in picks.json.
Only episodes ≥ 30 min with at least one sponsor segment are kept, and
only segments that aren't hidden or voted down.
"""
import json, os, subprocess, sys, time, urllib.parse, urllib.request

YTDLP = os.path.expanduser("~/Developer/pk-ml/bin/yt-dlp")
# Diverse genres; none of his own shows, so his labelled episodes stay a
# held-out set of shows for anything trained on these.
CHANNELS = {
    "lexfridman": "interview/tech", "hubermanlab": "science/health", "TheDiaryOfACEO": "business/interview",
    "flagrant": "comedy", "WaveformPodcast": "tech", "MyFirstMillionPod": "business",
    "PardonMyTake": "sports", "RottenMango": "true crime", "h3podcast": "pop culture",
    "ColdOnes": "comedy/gaming", "breakingpoints": "news/politics", "PodSaveAmerica": "news/politics",
    "SmartLess": "comedy/interview", "allin": "business/tech", "theofficialpodcast": "comedy",
    "ShawnRyanShow": "interview", "mrballen": "storytelling", "Fullsendpodcast": "pop culture",
}
CATS = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "filler"]


def listing(channel, n):
    out = subprocess.run([YTDLP, "--flat-playlist", "--playlist-end", str(n), "--print",
                          "%(id)s|%(duration)s|%(title)s", f"https://www.youtube.com/@{channel}/videos"],
                         capture_output=True, text=True, timeout=180).stdout
    for line in out.splitlines():
        vid, dur, title = (line.split("|", 2) + ["", ""])[:3]
        try: dur = float(dur)
        except ValueError: continue
        yield vid, dur, title


def segments(vid):
    q = urllib.parse.urlencode({"videoID": vid, "categories": json.dumps(CATS), "actionTypes": json.dumps(["skip", "full"])})
    try:
        with urllib.request.urlopen(f"https://sponsor.ajay.app/api/skipSegments?{q}", timeout=20) as r:
            return json.load(r)
    except Exception:
        return []


def main():
    out, per = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "picks.json")
    picks = json.load(open(path)) if os.path.exists(path) else {}
    for channel, genre in CHANNELS.items():
        have = sum(1 for p in picks.values() if p["channel"] == channel)
        for vid, dur, title in listing(channel, 25):
            if have >= per: break
            if vid in picks or dur < 1800: continue
            segs = [s for s in segments(vid) if s.get("votes", 0) >= 0]
            time.sleep(0.3)
            if not any(s["category"] == "sponsor" for s in segs): continue
            picks[vid] = {"channel": channel, "genre": genre, "title": title, "duration": dur,
                          "segments": [{"start": s["segment"][0], "end": s["segment"][1], "category": s["category"],
                                        "votes": s.get("votes", 0), "locked": s.get("locked", 0), "uuid": s.get("UUID")}
                                       for s in segs],
                          "source": f"https://www.youtube.com/watch?v={vid}",
                          "labels": "SponsorBlock, CC BY-NC-SA 4.0", "fetched": time.strftime("%Y-%m-%d")}
            have += 1
            print(channel, vid, int(dur // 60), "min", len(segs), "segments", title[:50], flush=True)
            json.dump(picks, open(path, "w"), indent=1)
    print(len(picks), "picks")


if __name__ == "__main__":
    main()
