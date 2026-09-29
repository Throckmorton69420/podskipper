#!/usr/bin/env python3
"""Pass 26: Gemini as the ad finder, on the lab fixtures, scored like the reader.

    gemini_bench.py <run name> [key…]        (env GEMINI_MODEL, default gemini-3.8-flash)

One request per episode: the whole transcript, one numbered line per recognizer
line, plus the show notes. Gemini answers with line ranges and a label; edges
are the lines' own times (the app will refine them). Replies are cached in
build/gemini/<run>/<key>.reply.json, so a rerun costs no requests. The key is
read from ~/.config/podskipper/gemini-key and never printed.
"""
import json, os, re, ssl, subprocess, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAB = os.path.join(ROOT, "build", "lab")
KEYS = "stav199 stavb199 mssp633 mssp636 los952 los956 los957 ymh1 bears1 bears2 badf1 theo1 wg1 afs2 ct262 ct284 chaos1".split()
SHOWS = {"stav": "Stavvy's World", "mssp": "Matt and Shane's Secret Podcast", "los": "Legion of Skanks",
         "ymh": "Your Mom's House with Christina P. and Tom Segura", "bears": "2 Bears, 1 Cave with Tom Segura & Bert Kreischer",
         "badf": "Bad Friends", "theo": "This Past Weekend w/ Theo Von", "wg": "Whiskey Ginger with Andrew Santino",
         "afs": "The Adam Friedland Show", "ct": "CumTown", "chaos": "Chris Distefano Presents: Chrissy Chaos"}
# Label → the app's segment kind (None = keep).
KIND = {"PAID_AD": "ad", "HOST_READ_AD": "ad", "NETWORK_PROMO": "crossPromo", "SELF_PROMO": "selfPromo",
        "GUEST_PLUG": "selfPromo", "INTRO": "intro", "OUTRO": "outro", "CREDITS": "credits",
        "RECURRING_SEGMENT": None, "MOCK_AD": None}
CTX = ssl.create_default_context(cafile="/etc/ssl/cert.pem")

def clock(s):
    s = max(0.0, s); h = int(s // 3600); m = int(s % 3600 // 60)
    return "%d:%02d:%05.2f" % (h, m, s - h * 3600 - m * 60)

def short(s):
    s = int(s); return "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)

RULES = """You mark the commercial and structural parts of one podcast episode for an ad-skipping app.
The transcript comes from speech recognition (spelling of names and brands can be wrong), one numbered line per
recognized sentence: "<line> <text>", with the time "[h:mm:ss]" shown on every 15th line. Read the whole episode first; judge every part by what it is doing
in context, never by keywords alone.

Labels (list only these; everything not listed is the show and is kept):
- PAID_AD: a sponsor's advertisement that is produced or pre-recorded: announcer or scripted copy, often inserted
  into the file (abrupt change of topic, voice or sound, back-to-back spots, the same copy replayed), pre-rolls at
  the very start, post-rolls at the very end.
- HOST_READ_AD: a host (or guest) reading or riffing a paid sponsorship in their own voice. It starts at the
  hand-off ("let's take a quick break", "this episode is brought to you by", "our friends at", "speaking of…")
  and ends at the last line about the product, its offer, code or web address, before the conversation truly
  returns. Riffs and jokes about the sponsor's product inside the read belong to the ad.
- NETWORK_PROMO: a promotion or trailer for another podcast or program that is not this show's own (network
  cross-promos, "if you like this show you'll love…", produced trailers).
- SELF_PROMO: the hosts promoting their own things: tour dates, tickets, specials, Patreon or bonus/premium feed,
  merch, their YouTube/socials, their other shows, "rate and review", live-show plugs.
- GUEST_PLUG: the guest's own work promoted: the guest's tour dates, special, book, podcast, socials, website
  (commonly at the start when introduced or at the end before goodbye).
- INTRO: the produced opening: theme music, stock opener or announcer intro. The hosts simply saying hello and
  starting to talk is the show, not INTRO.
- OUTRO: the produced closing: sign-off lines and theme after the conversation has ended.
- CREDITS: production credits (produced by, edited by, music by, executive producers).
- RECURRING_SEGMENT: a recurring produced bit of the show itself (a named segment, a jingle for a regular bit).
- MOCK_AD: a joke that imitates an ad, a fake or parody sponsor, or a bit about a brand that nobody is paying
  for. These are the show.

Hard rules:
1. Talking about a company, product, brand, price or website is NOT an ad by itself. People discuss brands
   constantly (restaurants, apps, drinks, cars, stores). An ad needs affirmative evidence of a paid relationship:
   a sponsorship hand-off, an offer or promo code, "go to …com/<show>", "use code", "terms apply", "sponsored by",
   copy that sells rather than converses, or a produced spot. When in doubt between an ad and the show, it is the show.
2. A story that mentions tickets, a show, a tour or a book in passing is the show. SELF_PROMO/GUEST_PLUG needs an
   actual ask or plug: dates and cities, "get tickets", "go see him", "link in the description", "subscribe to…".
3. A real paid read that is funny is still HOST_READ_AD; set funny=true when the hosts turn the read into a
   genuinely comedic bit. A fake sponsor or a parody is MOCK_AD.
4. Be exhaustive: check the very first and very last lines, every mid-roll break, and back-to-back sponsors.
   Give each sponsor its own entry, and each distinct plug its own entry.
5. Be tight: first_line is the first line of the part, last_line its last line. Don't swallow the conversation
   before or after. Paid spots rarely exceed 3 minutes each; a plug is usually under a minute.
6. Sponsors named in the show notes probably advertise in this episode; use that as a hint, not as proof.
8. Audio evidence marks: «I» = the podcast host's ad server inserted this audio (measured exactly: it is not in
   the ad-free copy) — almost always PAID_AD or NETWORK_PROMO. «R» = this exact recording also plays elsewhere
   (in another episode or twice in this one) — typical of produced ads, promos, intros and outros, but a cold-open
   tease that replays a later moment of the show is also «R» and is the show. Unmarked lines have no audio
   evidence either way; host-read ads are usually unmarked.
7. Include MOCK_AD and RECURRING_SEGMENT entries only when a reasonable listener might have mistaken them for an
   ad; they tell the app what NOT to cut.
"""

SCHEMA = {"type": "OBJECT", "properties": {"parts": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
    "first_line": {"type": "INTEGER"}, "last_line": {"type": "INTEGER"},
    "first_words": {"type": "STRING", "description": "the first 8 words of first_line, copied exactly"},
    "last_words": {"type": "STRING", "description": "the first 8 words of last_line, copied exactly"},
    "label": {"type": "STRING", "enum": list(KIND)},
    "sponsor": {"type": "STRING", "description": "brand or thing promoted, empty if none"},
    "funny": {"type": "BOOLEAN"},
    "confidence": {"type": "INTEGER", "description": "0-100"},
    "why": {"type": "STRING", "description": "one short sentence of evidence"}},
    "required": ["first_line", "first_words", "last_line", "last_words", "label", "sponsor", "funny", "confidence", "why"]}}},
    "required": ["parts"]}

CHAIN = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3-flash-preview", "gemini-3.6-flash", "gemini-3.5-flash"]

def lower_schema(s):
    """Gemini's OpenAPI-style schema → standard JSON Schema (for Mistral)."""
    if isinstance(s, dict):
        out = {k: lower_schema(v) for k, v in s.items()}
        if isinstance(out.get("type"), str): out["type"] = out["type"].lower()
        if out.get("type") == "object": out["additionalProperties"] = False
        return out
    if isinstance(s, list): return [lower_schema(x) for x in s]
    return s

def ask_mistral(model, prompt):
    key = open(os.path.expanduser("~/.config/podskipper/mistral-key")).read().strip()
    body = {"model": model, "temperature": 0.2,
            "messages": [{"role": "system", "content": RULES}, {"role": "user", "content": prompt}],
            "response_format": {"type": "json_schema", "json_schema": {"name": "parts", "strict": True,
                                                                       "schema": lower_schema(SCHEMA)}}}
    for attempt in range(5):
        req = urllib.request.Request("https://api.mistral.ai/v1/chat/completions", data=json.dumps(body).encode(),
                                     method="POST", headers={"Authorization": "Bearer " + key,
                                                             "Content-Type": "application/json"})
        t0 = time.time()
        try:
            r = json.load(urllib.request.urlopen(req, timeout=600, context=CTX))
            return {"text": r["choices"][0]["message"]["content"], "_seconds": round(time.time() - t0, 1),
                    "_model": model, "usageMetadata": {"promptTokenCount": r.get("usage", {}).get("prompt_tokens", 0),
                                                       "candidatesTokenCount": r.get("usage", {}).get("completion_tokens", 0)}}
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:300]
            print("  HTTP %d (%s) try %d: %s" % (e.code, model, attempt + 1, msg.replace("\n", " ")[:200]), flush=True)
            if e.code in (429, 500, 502, 503, 504): time.sleep(15 * (attempt + 1)); continue
            raise
    raise RuntimeError("no answer from " + model)

def cf_async(account, token, model, body):
    """The async queue: submit, get a request id, poll until done. The same path
    the app would use, so the phone can go away after submitting."""
    url = "https://api.cloudflare.com/client/v4/accounts/%s/ai/run/%s?queueRequest=true" % (account, model)
    def post(payload):
        req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            return json.load(urllib.request.urlopen(req, timeout=120, context=CTX))
        except urllib.error.HTTPError as e:
            raise RuntimeError("HTTP %d: %s" % (e.code, e.read().decode()[:300]))
    item = {k: v for k, v in body.items() if k != "model"}
    if "gpt-oss" in model:   # its queue takes the Responses-API shape only
        item = {"input": body["messages"], "reasoning": {"effort": body.get("reasoning_effort", "medium")},
                "max_output_tokens": body["max_tokens"]}
    t0 = time.time()
    rid = os.environ.get("CF_RID")   # resume polling a request already queued
    if not rid:
        sub = post({"requests": [item]})
        rid = sub["result"]["request_id"]
        print("  queued %s (%s)" % (rid, sub["result"].get("status")), flush=True)
    while time.time() - t0 < 3600:
        time.sleep(15)
        r = post({"request_id": rid})
        res = r.get("result", {})
        if "responses" in res or "results" in res:
            one = (res.get("responses") or res.get("results"))[0]
            if not one.get("success", True):
                raise RuntimeError("failed: %s" % json.dumps(one)[:300])
            out = one.get("result", {})
            if "choices" in out:
                text = out["choices"][0]["message"].get("content") or ""
            elif "output" in out:
                text = "".join(c.get("text", "") for o in out["output"] if o.get("type") == "message"
                               for c in o.get("content", []))
            else:
                text = out.get("response") if isinstance(out.get("response"), str) else json.dumps(out.get("response"))
            m = re.search(r"\{.*\}", text or "", re.S)
            usage = res.get("usage") or out.get("usage") or {}
            return {"text": m.group(0) if m else text, "_seconds": round(time.time() - t0, 1), "_model": model,
                    "usageMetadata": {"promptTokenCount": usage.get("prompt_tokens", 0),
                                      "candidatesTokenCount": usage.get("completion_tokens", 0)}}
    raise RuntimeError("async request %s not done after an hour" % rid)

def ask_cloudflare(model, prompt):
    """Workers AI through its OpenAI-compatible endpoint. ~/.config/podskipper/cloudflare-ai
    holds two lines: the account ID, then an API token with Workers AI permission."""
    account, token = [l.strip() for l in open(os.path.expanduser("~/.config/podskipper/cloudflare-ai")).read().split("\n")[:2]]
    body = {"model": model, "temperature": 0.2, "max_tokens": 40000,
            "messages": [{"role": "system", "content": RULES + "\nAnswer with JSON only, matching this schema: "
                          + json.dumps(lower_schema(SCHEMA))},
                         {"role": "user", "content": prompt}],
            "response_format": {"type": "json_schema", "json_schema": {"name": "parts", "schema": lower_schema(SCHEMA)}}}
    if "gpt-oss" in model: body["reasoning_effort"] = os.environ.get("EFFORT", "medium")
    if os.environ.get("CF_ASYNC", "1") == "1":
        try:
            return cf_async(account, token, model, body)
        except RuntimeError as e:
            if "does not support request queuing" not in str(e): raise
            print("  %s has no queue; asking directly" % model, flush=True)
    url = "https://api.cloudflare.com/client/v4/accounts/%s/ai/v1/chat/completions" % account
    for attempt in range(4):
        req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        t0 = time.time()
        try:
            r = json.load(urllib.request.urlopen(req, timeout=900, context=CTX))
            text = r["choices"][0]["message"].get("content") or ""
            m = re.search(r"\{.*\}", text, re.S)
            return {"text": m.group(0) if m else text, "_seconds": round(time.time() - t0, 1), "_model": model,
                    "usageMetadata": {"promptTokenCount": r.get("usage", {}).get("prompt_tokens", 0),
                                      "candidatesTokenCount": r.get("usage", {}).get("completion_tokens", 0)}}
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:300]
            print("  HTTP %d (%s) try %d: %s" % (e.code, model, attempt + 1, msg.replace("\n", " ")[:200]), flush=True)
            if e.code in (429, 500, 502, 503, 504): time.sleep(20 * (attempt + 1)); continue
            raise
    raise RuntimeError("no answer from " + model)

def ask(model, prompt):
    if model.startswith("@cf/"):
        return ask_cloudflare(model, prompt)
    """Tries the chosen model, then the rest of the free Flash chain: a busy (503)
    or out-of-quota (429 per day) model hands over to the next one."""
    if model.startswith("mistral") or model.startswith("magistral"):
        return ask_mistral(model, prompt)
    chain = [model] + [m for m in CHAIN if m != model]
    for round_ in range(int(os.environ.get("ROUNDS", "6"))):
        for m in chain:
            try:
                return ask_one(m, prompt)
            except RuntimeError as e:
                print("  %s" % e, flush=True)
        print("  whole chain busy; waiting 60 s (round %d)" % (round_ + 1), flush=True); time.sleep(60)
    raise RuntimeError("every model in the chain failed")

def ask_one(model, prompt):
    key = open(os.path.expanduser("~/.config/podskipper/gemini-key")).read().strip()
    body = {"systemInstruction": {"parts": [{"text": RULES}]},
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json", "responseSchema": SCHEMA}}
    url = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % model
    for attempt in range(3):
        req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={"x-goog-api-key": key, "Content-Type": "application/json"})
        t0 = time.time()
        try:
            r = json.load(urllib.request.urlopen(req, timeout=600, context=CTX))
            r["_seconds"] = round(time.time() - t0, 1); r["_model"] = model
            return r
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:400]
            print("  HTTP %d (%s) try %d: %s" % (e.code, model, attempt + 1, msg.replace("\n", " ")[:200]), flush=True)
            if (e.code == 429 and ("PerDay" in msg or "limit: 0" in msg)) or e.code in (400, 403, 404):
                raise RuntimeError("%s: not usable (%d)" % (model, e.code))
            if e.code in (429, 500, 502, 503, 504):
                m = re.search(r'"retryDelay":\s*"(\d+)', msg)
                time.sleep(min(90, int(m.group(1)) + 2) if m else 10 * (attempt + 1)); continue
            raise
        except Exception as e:
            print("  error try %d: %s" % (attempt + 1, e), flush=True); time.sleep(15)
    raise RuntimeError("no answer from " + model)

def build_prompt(key, lines):
    show = SHOWS[re.sub(r"\d.*", "", key).rstrip("b")] if re.sub(r"\d.*", "", key).rstrip("b") in SHOWS else ""
    title = open(os.path.join(LAB, key + ".title")).read().strip() if os.path.exists(os.path.join(LAB, key + ".title")) else ""
    notes = open(os.path.join(LAB, key + ".notes.txt")).read()[:4000] if os.path.exists(os.path.join(LAB, key + ".notes.txt")) else ""
    # A time on every 15th line only: answers are line numbers, so times are
    # just orientation, and they cost ~20 % of the tokens.
    # Exact audio evidence the phone already has, marked on each line it covers:
    # «R» the same recording plays elsewhere (this episode or another one),
    # «I» the host's ad server inserted it (byte comparison with an ad-free copy).
    spans = []
    if os.environ.get("EVIDENCE", "1") == "1":
        pj = os.path.join(LAB, key + ".produced.json")
        if os.path.exists(pj): spans += [(s["start"], s["end"], "R") for s in json.load(open(pj))]
        dj = os.path.join(LAB, key + ".dai.json")
        if os.path.exists(dj):
            for s in json.load(open(dj)).get("inserted") or []:
                if isinstance(s, dict) and "start" in s: spans.append((s["start"], s["end"], "I"))
    def tag(l):
        t = sorted({k for a, b, k in spans if min(b, l["end"]) - max(a, l["start"]) > 0.5 * max(0.1, l["end"] - l["start"])})
        return ("«%s» " % "".join(t)) if t else ""
    body = "\n".join(("%d [%s] %s%s" % (i, short(l["start"]), tag(l), l["text"].strip())) if i % 15 == 0
                     else ("%d %s%s" % (i, tag(l), l["text"].strip())) for i, l in enumerate(lines))
    return ("Show: %s\nEpisode: %s\nShow notes:\n%s\n\nTranscript (%d lines, %s long):\n%s"
            % (show, title, notes, len(lines), short(lines[-1]["end"]), body))

def anchor(lines, guess, words, window=250):
    """The line whose opening words match the model's quote, nearest its line
    number: models copy text reliably but count lines badly in long input."""
    import difflib
    want = " ".join(re.sub(r"[^a-z0-9 ]", "", (words or "").lower()).split()[:8])
    if not want: return guess
    best, score = guess, 0.0
    for i in range(max(0, guess - window), min(len(lines), guess + window + 1)):
        have = " ".join(re.sub(r"[^a-z0-9 ]", "", lines[i]["text"].lower()).split()[:8])
        s = difflib.SequenceMatcher(None, want, have).ratio() - abs(i - guess) * 0.0005
        if s > score: best, score = i, s
    return best if score >= 0.6 else guess

def to_detect(reply, lines):
    text = reply["text"] if "text" in reply else reply["candidates"][0]["content"]["parts"][-1]["text"]
    parts = json.loads(text)["parts"]
    out, kept = [], []
    for p in parts:
        a, b = max(0, p["first_line"]), min(len(lines) - 1, p["last_line"])
        if os.environ.get("ANCHOR", "1") == "1":
            a = anchor(lines, a, p.get("first_words")); b = anchor(lines, b, p.get("last_words"))
        if b < a: continue
        kind = KIND.get(p["label"])
        rec = (lines[a]["start"], lines[b]["end"], p)
        (out if kind else kept).append((kind,) + rec)
    s = "detection seconds: 0 segments: %d (gemini)\n\n" % len(out)
    for kind, st, en, p in sorted(out, key=lambda x: x[1]):
        s += "[%s] %s–%s (%ds) conf %d sponsor '%s' funny %s\n   %s\n\n" % (kind, clock(st), clock(en), en - st,
              p["confidence"], p["sponsor"], p["funny"], p["why"])
    for kind, st, en, p in kept:
        s += "# kept %s %s–%s %s: %s\n" % (p["label"], short(st), short(en), p["sponsor"], p["why"])
    return s

def summary(path):
    if not os.path.exists(path): return None
    m = re.search(r"^SUMMARY (.*)$", open(path).read(), re.M)
    return json.loads(m.group(1)) if m else None

def baseline(out_file, key):
    """The reader's numbers from an ownlab.sh log (build/own/<tag>.out)."""
    m = re.search(r"^%s\s+heard\s+([\d.]+) skipped\s+([\d.]+)" % re.escape(key), open(out_file).read(), re.M)
    return {"ad_s_heard_per_h": float(m.group(1)), "content_s_skipped_per_h": float(m.group(2))} if m else None

def main():
    run = sys.argv[1]; keys = sys.argv[2:] or KEYS
    model = os.environ.get("GEMINI_MODEL", "gemini-3.8-flash")
    base = os.environ.get("BASE", os.path.join(ROOT, "build", "own", "sw-ens-LAB_SWITCH-1.out"))
    out = os.path.join(ROOT, "build", "gemini", run); os.makedirs(out, exist_ok=True)
    tot = {"g": [0, 0, 0], "r": [0, 0, 0]}
    rows = []
    for key in keys:
        lines = json.load(open(os.path.join(LAB, key + ".json")))
        for ext in ("json", "dai.json"):
            src = os.path.join(LAB, "%s.%s" % (key, ext))
            if os.path.exists(src): subprocess.run(["cp", src, os.path.join(out, "%s.%s" % (key, ext))])
        cache = os.path.join(out, key + ".reply.json")
        if not os.path.exists(cache):
            print("asking %s for %s (%d lines)…" % (model, key, len(lines)), flush=True)
            try:
                json.dump(ask(model, build_prompt(key, lines)), open(cache, "w"))
            except Exception as e:
                print("%-9s FAILED: %s" % (key, str(e)[:200]), flush=True); continue
        reply = json.load(open(cache))
        open(os.path.join(out, key + ".detect.txt"), "w").write(to_detect(reply, lines))
        fx = os.path.join(ROOT, "Tools", "DetectionLab", "regression", key + ".json")
        sc = os.path.join(out, key + ".score.txt")
        with open(sc, "w") as f:
            subprocess.run([sys.executable, os.path.join(ROOT, "Tools", "DetectionLab", "regression", "score.py"),
                            os.path.join(out, key + ".json"), os.path.join(out, key + ".detect.txt"), fx],
                           stdout=f, stderr=subprocess.STDOUT)
        g, r = summary(sc), baseline(base, key)
        u = reply.get("usageMetadata", {})
        rows.append("%-9s gemini heard %6.1f cut %6.1f | reader heard %6.1f cut %6.1f | %5.0fs %6d tok in %s" % (
            key, g["ad_s_heard_per_h"], g["content_s_skipped_per_h"],
            r["ad_s_heard_per_h"] if r else -1, r["content_s_skipped_per_h"] if r else -1,
            reply.get("_seconds", 0), u.get("promptTokenCount", 0), reply.get("_model", "")))
        print(rows[-1], flush=True)
        h = g["hours"]
        for t, s in (("g", g), ("r", r)):
            if s: tot[t][0] += h; tot[t][1] += s["ad_s_heard_per_h"] * h; tot[t][2] += s["content_s_skipped_per_h"] * h
    for t, name in (("g", "GEMINI"), ("r", "READER")):
        H = tot[t][0]
        if H: print("%s %.1f h: heard %.1f s/h, cut %.1f s/h" % (name, H, tot[t][1] / H, tot[t][2] / H))

if __name__ == "__main__":
    main()
