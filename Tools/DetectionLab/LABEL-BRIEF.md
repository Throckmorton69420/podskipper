# Label one podcast episode for the PodSkipper detection lab

The brief given to a labelling subagent (Sonnet is enough). Replace `<KEY>` with the fixture key; the episode must come from a show in his library.

You label where the ads and promos are in one episode transcript, so the app's ad detector can be scored against it. Work only through the Desktop Commander tools on the Mac (`mcp__remote-devices__Desktop_Commander__read_file`, `..._write_file`, `..._start_process`). If those tools are not available to you, stop at once and reply "NO MAC TOOLS".

Repo on the Mac: /Users/shashankpandya/Developer/podskipper (call it ROOT). Do not edit any file except the one fixture you create.

## Inputs
- Readable transcript: make it with `cd ROOT/build/lab && python3 ../../Tools/DetectionLab/compact.py <KEY> > /Users/shashankpandya/Documents/GitHub/podskipper/_lab_<KEY>.txt` (the caller usually has), then read /Users/shashankpandya/Documents/GitHub/podskipper/_lab_<KEY>.txt — one recognizer line per row as `H:MM:SS text`. Read it all (in chunks of ~400 lines with offset/length). Lines `==== INSERTED AUDIO STARTS (N s, ends …) ====` / `==== INSERTED AUDIO ENDS ====` mark audio the ad server stitched in at download time, found by comparing with the host's ad-free copy; everything between them is inserted and must be labelled (normally ADVERTISEMENT, `"delivery": "inserted"`).
- The recognizer's JSON (for anchors): ROOT/build/lab/<KEY>.json (array of {start,end,text}).
- Examples of finished fixtures: ROOT/Tools/DetectionLab/regression/stav199.json and los952.json. Copy their style.

## Output
Write ROOT/Tools/DetectionLab/regression/<KEY>.json:
```
{ "show": "...", "episode": "...", "feed": "<contents of ROOT/build/lab/<KEY>.feed>",
  "complete": true,
  "labelled_by": "Claude-labelled (pass N, date) from the lab transcript; replace with his corrections when an exported report exists.",
  "notes": ["how the edges were judged, anything unusual"],
  "tolerance_seconds": 2.0,
  "regions": [ ... in time order ... ] }
```
Each region: `id` (short, unique), `label`, anchors, optional `delivery`, `group`, `alt_labels`, `note`.
- Anchors are exact phrases copied from the transcript text (4–10 words, distinctive, as the recognizer wrote them, typos included): `start_at` (the region starts at the line where this phrase starts), `start_after` (starts after the line where this phrase ends), `end_after` (ends after the line where the phrase ends), `end_before` (ends before the line where it starts). `start_at_episode_start: true` / `end_at_episode_end: true` for pre-/post-rolls. Music with no words has no line of its own: `start_at_end_of` starts the region where the line with that phrase ends, `end_until` ends it where the line with that phrase starts, so a region can cover the gap between two lines.
- Labels: `ADVERTISEMENT` (any paid sponsor message: host-read, produced spot, trailer, "support for this podcast comes from…"); `SELF_PROMOTION` (the show's own tour dates, Patreon/premium/bonus, merch, their YouTube, their other appearances, "subscribe/rate us"); `NETWORK_PROMOTION` (another show or the network, e.g. "check out <other podcast>", SiriusXM/Gas Digital/YMH network plugs); `INTRO` (produced theme/cold-open bumper or network ident at the start); `OUTRO` / `CREDITS` (produced end theme, "produced by … executive producer …"); `NORMAL` (conversation next to an ad, put 1 short NORMAL region right after each break so over-long cuts are caught); `EITHER` (cutting or keeping are both acceptable: a funny riff inside a read, a 2–5 s sponsor name-drop, banter that leads into plugs, a host joking about an ad without selling anything).
- `delivery`: `inserted` (between INSERTED markers), `host` (host reads it inside the recording), `produced` (a produced spot recorded into the file).
- Back-to-back ads in one break: separate regions sharing a `group` (e.g. "break-2").
- Edges: a read starts at the host's hand-off ("let's take a quick moment and thank…", "this episode is brought to you by…", "Support for this podcast comes from…") and ends at the last line of the offer (code/URL/terms) or at "let's get back into it"/"anyway". Do not include the conversation before the hand-off.
- Be complete: read every line. Check every brand name, URL, promo code, "sponsor", "brought to you by", "use code", ".com slash", "Patreon", "tour", "tickets", "merch", "subscribe". Jokes that only mention a brand are NORMAL (or EITHER if they sound like an ad).
- For an INSERTED span, use `start_at` = first words of the first line inside the markers (or `start_at_episode_start` for the pre-roll) and `end_after`/`end_before` accordingly; the scorer replaces inserted edges with the exact frame times anyway.

## Check your anchors
Run (with `..._start_process`, timeout 30000):
`cd ROOT/build/lab && touch /tmp/empty.txt && python3 ../../Tools/DetectionLab/regression/score.py <KEY>.json /tmp/empty.txt ../../Tools/DetectionLab/regression/<KEY>.json 2>&1 | head -80`
It prints each region with the clock times it resolved to (`SCORE_DUMP=/tmp/<KEY>.regions.json` also writes them as JSON). Every region must resolve to the times you intended (compare with the transcript). Fix any anchor that resolves wrongly (use a more distinctive phrase) and rerun until all are right.

## Reply
Reply with: the file path, a table of regions (id, label, start–end clock, delivery), and anything you were unsure about. Keep it under 60 lines.
