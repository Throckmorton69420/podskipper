# Distilled reference

The parts of Apple Podcasts 3.9 (iOS 27.0 RC, build 24A435) that are worth
consulting, in formats that can be searched with `grep` rather than parsed.

- `en-strings.tsv` — all 2,157 English strings as `KEY<TAB>VALUE`. This is the
  single most useful artefact in the bundle: Apple's own vocabulary, its
  metadata format strings (including which dash and which space it uses where),
  its sort and filter options, its accessibility labels, and its section titles.
  One `grep` answers most "what does Apple call this" questions.
- `Info.plist.json` — the app's Info.plist as JSON.

Everything else lives in `../METADATA` (and a byte-identical copy in
`../ORIGINAL`, which can be deleted — `diff -rq` shows no difference beyond
.DS_Store files).

Findings already extracted from all of this are written up in
`/.research/apple-podcasts-findings.md` at the repository root. Read that first;
come back to these files when it does not cover the question.
