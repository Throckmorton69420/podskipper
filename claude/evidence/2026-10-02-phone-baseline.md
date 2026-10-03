> **Historical observation; access claim superseded.** C011 says the actual Feather-installed app/data cannot be accessed. The copied records below do not prove the current installed identity, container/debug access, signed capabilities or Build301 behavior. Current Handoff/Evidence Audit govern those claims.

# Read-only phone baseline — 2 October 2026

The paired iPhone 16 Pro is reachable. `devicectl device info apps` reports installed bundle `app.ivory2951.coral5096`, version 1.0/build 1, developer-built and container-accessible, with five re-signed app groups. This supersedes the assumption that its data container was unavailable. It does not establish each signed entitlement or that widget/CarPlay/iCloud/background GPU capabilities work.

Copied only the app's existing Diagnostics directory to ignored local `build/phone-diagnostics-20261002` using `devicectl device copy from`. No installation, re-signing, app deletion, live library cleanup or phone data mutation was performed. Current installed processing records identify build `f8a7c4a`, which matches PR 21's synthetic merge revision; an older record identifies `5072122`. The recovery branch has not been installed or phone-tested.

## Observed measurements

Five copied processing records identify `f8a7c4a`. All report battery power and Low Power Mode off. Three ended in serious thermal state: two foreground runs with Core AI window failures falling back to Reader, and one background Reader run with inference deferred until foreground. The two newest foreground Reader records end nominal; they say the selected Core AI model is not downloaded. One of those reuses transcription. These are observed existing jobs, not a controlled thermal comparison.

The 1–2 October daily MetricKit report (version 1/build 1, exact source revision not encoded in that aggregate) records:

- Peak memory 5674888 kB; cumulative CPU 2325 s and GPU 439 s.
- Cumulative logical writes 2233880 kB.
- 143 app-hang samples across 250–1089 ms buckets; maximum bucket 1080–1089 ms.
- Processing signposts include detection and transcription. Aggregate/signpost values alone cannot identify the responsible function or model.

Three older exception reports contain two CPU exceptions (90 s CPU over 90 s and 147 s sampled intervals) and one disk-write exception reporting 1074 MB writes. The copied payloads contain unsymbolicated call stacks. Attribution requires the matching binary/dSYM; these reports must not be presented as measured improvements or as defects caused by the new branch.

## Next phone verification

Preserve the installed bundle identity and available rollback. Inspect the actual signed IPA/capabilities, then test the delivered revision on battery/charger, foreground/background and with/without real playback. Measure launch/scrolling, memory/model lifecycle, checkpoint write volume, resource overlap and thermal transitions separately. Current copied logs establish a baseline; they do not complete P06/P09 or C01.
