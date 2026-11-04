# Reader label policy (version 2, Pass 57)

What each stretch of an episode is labelled, for the phone labels (`Tools/DetectionLab/phone-labels/`), the lab fixtures and any teacher-assisted label. Version 1 was the labelling brief (`Tools/DetectionLab/LABEL-BRIEF.md`, passes 25–53); version 2 writes down the rules those labels already mostly followed and fixes where they didn't. His own corrections on the phone always win over any label.

Labels are line ranges of the export the file names. Everything not inside a region is the show.

## Kinds (all five are skipped by his default settings)

| Label | What it is |
|---|---|
| `AD` | Any paid sponsor message: host read, produced spot, trailer for another company's product, "support for this podcast comes from…", a dynamically inserted spot. |
| `SELF` | The show's own promotion: the hosts' tour dates, specials, Patreon / premium / bonus feeds, merch, YouTube, "subscribe / rate / follow us", membership pitches (e.g. Peter Attia's opening member pitch). **A guest's plug** — the host or guest telling listeners to go see the guest's tour, special, book, podcast or website. |
| `NETWORK` | Another show or the network: "check out <other podcast>", network idents, "we're part of the SiriusXM podcast family". |
| `INTRO` | The produced theme / cold-open bumper / network ident at the start. |
| `OUTRO` | The produced end theme and the credits ("produced by…, edited by…, music by…"). |
| `EITHER` | Cutting or keeping are both acceptable — not scored either way. |

## Rules

1. **Plug rounds.** When the host opens a round of plugs ("do you want to plug any dates?", "what are you plugging?", "let's do plugs", "where can people find you?"), the round is `SELF` from that question through the guest's last date, address or handle. Short asides inside the round (under ~20 s) stay inside it. A longer digression inside the round (a story, banter about something else) is `EITHER`. When the round turns into conversation and doesn't come back to plugging, the conversation is the show.
2. **A guest's work in conversation** — answering questions about their special, tour or book as part of the interview, mid-episode — is the show. The host's one-line introduction of a guest's work ("go watch his new special") is `EITHER` at most.
3. **The host's episode preview** ("My guest this week is…", "we talk about…", "so without further delay…") is the show, even when scripted.
4. **Disclaimers** (medical, legal or financial boilerplate read at the start or end: "this podcast is for general informational purposes only…") are `EITHER`: skipping them is fine, keeping them is fine. A membership pitch before or after a disclaimer is `SELF`.
5. **Ad edges.** A read starts at the host's hand-off ("let's take a moment and thank…", "this episode is brought to you by…") and ends at the last line of the offer (code, URL, terms) or at "anyway / let's get back into it". Banter before the hand-off is the show; a joke leading straight into the read is `EITHER`. Back-to-back spots are separate regions of the same break.
6. **Comedy inside a read** (a riff in the middle of a sponsor read) belongs to the read; a host joking about a brand without selling anything is the show (or `EITHER` if it sounds like an ad).
7. **Credits and the show's sign-off.** "Produced by…" is `OUTRO`; "find us on social media / our website / subscribe" lines next to the credits are `SELF`; the host's own goodbye to the guest ("thanks for coming on") is the show.
8. **Inserted audio** (between the ad-free comparison's markers) is labelled by what it is, normally `AD` with `delivery: inserted`.

## How labels are checked and changed

- `Tools/ReaderData/label_audit.py` finds, by words alone, every line where a rule above could apply but the label says the show (plug-round questions, credits, network and disclaimer words, selling words, plug words). It never looks at what a reader or model predicted, so fixing what it finds can't bend the labels toward any engine.
- `Tools/ReaderData/relabel.py` applies a fix: the file gets `"policy": 2` and a `revisions` entry with the rule, the lines and the regions that were there before. Git keeps version 1.
- Evaluations report which label version they used.

## Pass 57 audit

All 71 labelled episodes: 176 candidate lines (149 plug words, 12 selling words, 7 credit words, 5 plug-round questions, 3 network words, 0 disclaimer words). Read one by one, all but two were conversation (comedians talking about tours, tickets and merch; "sponsored by" in anecdotes; "our producer"). Two plug rounds the host opened had been left as the show and were fixed under rule 1:

- Whiskey Ginger, *Caitlin Peluffo loves a short king* — lines 2666–2703 → `SELF` (host: "Do you want to plug any dates?", then her tour and website).
- Legion of Skanks #958, *Pete Lee & Jeremiah Watkins* — lines 1145–1159 `SELF`, 1160–1174 `EITHER` (banter about the network inside the round), 1175–1178 `SELF`; the stories after it stay the show (the same episode's later rounds were already labelled this way).

No disclaimer, network or credit line was mislabelled. The held-out readers' biggest show cuts (Peter Attia's episode preview, 99% Invisible narration next to produced breaks, a CumTown bit inside a read) are labelled by these rules already: they are reader errors, not label errors.
