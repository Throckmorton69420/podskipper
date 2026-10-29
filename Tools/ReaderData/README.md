# Reader training data beyond his exports (Pass 53)

Everything here is for training PodSkipper's own Reader offline on this Mac. Nothing downloaded is committed or redistributed: audio, transcripts and episode files live in `~/Developer/pk-data/` (outside the repo). The app ships only the trained weights.

## Sources considered

| Source | What it gives | License / terms | Used |
|---|---|---|---|
| **SponsorBlock** (sponsor.ajay.app API) | Human-set start/end times of sponsor reads, self-promotion, "like and subscribe", intros, outros, previews and filler on YouTube videos | Database and API: **CC BY-NC-SA 4.0** (attribution, non-commercial, share-alike) | **Yes** — labels for YouTube podcast episodes, per segment UUID and votes in `picks.json` |
| YouTube audio of those episodes | The words, transcribed here by the app's own `TranscriptionService` (same sentences the phone makes) | YouTube's terms restrict downloading; fetched once at lowest bitrate for local transcription, never kept in the repo or shared | Yes, local only |
| **SPoRC** (Structured Podcast Research Corpus, Litterer, Jurgens & Card, ACL 2025; `huggingface.co/datasets/blitt/SPoRC`) | ~1.1 M English podcast transcripts (Whisper), speaker turns, audio features; 94 GB | Research terms on its Hugging Face page | Not yet: no ad labels; Whisper transcripts differ from the phone's; would need a teacher to label — a candidate for unlabelled-data distillation |
| Spotify Podcast Dataset (TREC 2020) | 100 k episodes, audio + transcripts | No longer distributed by Spotify | No |
| His exports (`build/phone-*`) | 71 episodes labelled from transcripts (`Tools/DetectionLab/phone-labels/`), his own corrections | His data | Yes (as before) |

## Pipeline

1. `sponsorblock_pick.py <dir> [per-channel]` — recent ≥ 30-min episodes from 18 podcast channels in different genres (none of his shows, so his labelled episodes stay a held-out set of *shows*), kept only if SponsorBlock has a sponsor segment not voted down. Writes `picks.json` (source URL, segment UUIDs, votes, license, date).
2. `~/Developer/pk-data/sponsorblock/fetch.sh` — lowest-bitrate audio (yt-dlp in `~/Developer/pk-ml`).
3. `~/Developer/pk-data/sponsorblock/tx.sh` — `lab-transcribe` (built from `Tools/DetectionLab/LabTranscribe.swift` + `Services/TranscriptionService.swift`), ~1 min per audio hour.
4. `sponsorblock_episodes.py <dir>` — sentences (`tagger.sentences`, as the app makes them) labelled from the segments: sponsor → ad, selfpromo/interaction → own plug, intro, outro; preview/filler left out; sentences straddling an edge left out; unmarked sentences that sell are left out (SponsorBlock users mark what they skip, not everything).
5. `Tools/DetectionLab/reader_distill.py showfolds … ` with `EXTERNAL=<dir>/episodes.json EXT_W=…` — each fold holds out whole shows of his labelled episodes; the external episodes are extra training data only, never scored.

Python HTTPS from `~/Developer/pk-ml` needs `SSL_CERT_FILE=$(~/Developer/pk-ml/bin/python -c 'import certifi;print(certifi.where())')`.
