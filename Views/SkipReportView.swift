import SwiftUI
import SwiftData
import UIKit

/// What the app decided to cut out of this episode, and a way to argue with it.
///
/// Everything else in the app tells you an ad was skipped *after* it happens,
/// in a coloured stripe two points tall. This is the other direction: the whole
/// list, before or after, with the words that were actually spoken in each one
/// — so a bad call is obvious rather than something you half-noticed while
/// driving and could never find again.
///
/// The corrections are the point. Confirming a cut, rejecting one, or dragging
/// its edges in or out is the only signal the detector will ever get about
/// whether it was right, and it is signal that costs the listener nothing to
/// give: they are already annoyed, and now there is somewhere to put it. Those
/// corrections go to the *show*, not just this episode — see `Episode.apply`.
struct SkipReportView: View {
    let episode: Episode

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared
    @State private var expanded: PersistentIdentifier?

    private var segments: [AdSegment] {
        episode.adSegments.sorted { $0.start < $1.start }
    }

    private var skipped: [AdSegment] {
        segments.filter {
            $0.userVerdict != .notAnAd && episode.skips($0.kind, settings: settings)
        }
    }

    private var totalSkipped: Double {
        skipped.reduce(0) { $0 + $1.duration }
    }

    /// The ones the detector was not sure about.
    private var unsure: [AdSegment] { segments.filter(\.needsReview) }

    var body: some View {
        List {
            if segments.isEmpty {
                emptyState
            } else {
                summary
                ForEach(segments) { segment in
                    SkipRow(segment: segment,
                            episode: episode,
                            active: episode.skips(segment.kind, settings: settings) && !segment.keptByDelivery(settings),
                            isOpen: expanded == segment.persistentModelID,
                            onToggle: {
                                // Opening a different one stops whatever was
                                // playing: two previews at once is nonsense,
                                // and a preview left running behind a collapsed
                                // row is how you end up with an ad playing and
                                // nowhere obvious to stop it.
                                player.endPreview()
                                // Opening one pauses the episode, as Photos
                                // does when you start trimming: an editor
                                // whose episode plays on underneath it ends,
                                // moves to the next in the queue, and takes
                                // the open cut with it.
                                if expanded != segment.persistentModelID, player.isPlaying { player.pause() }
                                withAnimation(.snappy(duration: 0.22)) {
                                    expanded = expanded == segment.persistentModelID
                                        ? nil : segment.persistentModelID
                                }
                            },
                            onChange: {
                                try? context.save()
                                player.refreshSkipRanges()
                            })
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("What was skipped")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { addCut() } label: { Label("Add a cut", systemImage: "plus") }
                    .accessibilityIdentifier("AddCut")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        // Leaving the page must not leave an ad playing.
        .onDisappear { player.endPreview() }
    }

    /// A cut the detector missed: thirty seconds at the playhead (or the
    /// start), opened for trimming. Filed as feedback once its edges are set.
    private func addCut() {
        let here = player.currentEpisode === episode ? player.currentTime : 0
        let limit = episode.duration > 0 ? episode.duration : here + 30
        let lower = max(0, min(here, limit - 30))
        let segment = AdSegment(start: lower, end: min(limit, lower + 30), kind: .ad)
        segment.origin = "added"
        segment.userVerdict = .confirmed
        segment.episode = episode
        context.insert(segment)
        try? context.save()
        player.refreshSkipRanges()
        player.endPreview()
        withAnimation(.snappy(duration: 0.22)) { expanded = segment.persistentModelID }
        Haptics.select()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(totalSkipped >= 60
                 ? "\(Int(totalSkipped / 60)) min \(Int(totalSkipped.truncatingRemainder(dividingBy: 60))) sec cut"
                 : "\(Int(totalSkipped)) sec cut")
                .font(.system(size: UIScale.pt(26), weight: .bold))

            // One line per kind that actually occurs, rather than five rows of
            // zeroes. A show with no cross-promotion should not be told so.
            let counts = Dictionary(grouping: segments, by: \.kind)
                .mapValues { $0.count }
                .sorted { $0.key.rawValue < $1.key.rawValue }
            HStack(spacing: 12) {
                ForEach(counts, id: \.key) { kind, count in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.tint(for: kind))
                            .frame(width: 7, height: 7)
                        Text("\(count) \(kind.label.lowercased())\(count == 1 ? "" : "s")")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if !unsure.isEmpty {
                Label(unsure.count == 1
                      ? "1 cut is worth a look — the detector wasn't sure"
                      : "\(unsure.count) cuts are worth a look — the detector wasn't sure",
                      systemImage: "questionmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accentHot)
                    .accessibilityIdentifier("NeedsReviewSummary")
            }

            Text("Open one to hear it and read along. Drag the handles, or use the nudge buttons, "
                 + "to change where it starts and stops; the dashed box is what was found originally. "
                 + "Every change — edges, type, thumbs — is what this show's detection learns from. "
                 + "Lock a cut to keep it exactly as it is when ads are found again.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing found yet")
                .font(.system(size: UIScale.pt(22), weight: .semibold))
            Text(episode.processingState == .ready
                 ? "This episode was searched and nothing was marked. That is either a clean show or a miss — if you heard an ad, the detector did not."
                 : "Ads have not been looked for in this episode yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 20)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// MARK: - One segment

private struct SkipRow: View {
    let segment: AdSegment
    let episode: Episode
    let active: Bool
    let isOpen: Bool
    let onToggle: () -> Void
    let onChange: () -> Void

    private var delivery: String {
        var parts: [String] = []
        if segment.deliveryRaw == "host" { parts.append("host-read") }
        if segment.deliveryRaw == "produced" { parts.append("produced spot") }
        if segment.isComedyBit { parts.append("played for laughs") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: ", ")
    }

    @Environment(AppSettings.self) private var rowSettings

    private var keptReason: String {
        if segment.keptByDelivery(rowSettings) {
            return segment.isComedyBit && rowSettings.keepComedyBitAds
                ? "Kept — ads played for laughs are kept in Settings"
                : "Kept — host-read ads are kept in Settings"
        }
        return "Kept — this kind is switched off"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(Theme.tint(for: segment.kind).opacity(active ? 1 : 0.3))
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(segment.kind.label)
                                .font(.system(size: UIScale.pt(15), weight: .semibold))
                            if !segment.sponsor.isEmpty {
                                Text("· \(segment.sponsor)")
                                    .font(.system(size: UIScale.pt(15)))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(range + delivery)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if segment.isLocked || segment.isEdited || segment.isAdded || segment.needsReview {
                            Label(segment.status,
                                  systemImage: segment.isLocked ? "lock.fill"
                                    : segment.needsReview ? "questionmark.circle" : "pencil")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accentHot)
                        }
                        if verdictLine != nil || !active {
                            Text(verdictLine ?? keptReason)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                // Without this the header is greedy and swallows the row.
                //
                // The coloured spine is `.frame(maxHeight: .infinity)` so it
                // matches the height of the text beside it. That makes the
                // whole header greedy in height too, and in an expanded row it
                // took about three hundred points of the space the transcript
                // needed — a screenshot showed a long orange bar next to
                // nothing, and one clipped line of transcript underneath.
                // `fixedSize` vertically pins the header to its text; the spine
                // still fills, but fills only that.
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                SegmentDetail(segment: segment, episode: episode, onChange: onChange)
                    .padding(.top, 14)
            }
        }
        .padding(.vertical, 6)
    }

    private var range: String {
        let length = Int(segment.duration.rounded())
        let readable = length >= 60 ? "\(length / 60)m \(length % 60)s" : "\(length)s"
        return "\(formatDuration(segment.start)) – \(formatDuration(segment.end))  ·  \(readable)"
    }

    private var verdictLine: String? {
        switch segment.userVerdict {
        case .confirmed:  return "You confirmed this one"
        case .notAnAd:    return "You said this was not an ad — it is being kept"
        case .unreviewed: return nil
        }
    }
}

// MARK: - The opened segment

/// The editor for one cut, built the way trimming works in Photos and Voice
/// Memos: a strip of the episode with two handles, a playhead of its own that
/// plays from wherever you put it, the words underneath following along, and
/// what the detector originally found drawn faintly behind your changes.
///
/// Its own `View` rather than a computed property of the row, because it reads
/// the playhead. Read from the row's body, five updates a second would rebuild
/// every other row in the list along with it.
private struct SegmentDetail: View {
    let segment: AdSegment
    let episode: Episode
    let onChange: () -> Void

    @Environment(\.modelContext) private var context
    @State private var player = PlayerEngine.shared

    /// The edges being dragged, kept apart from the model: written once, on
    /// release, rather than sixty SwiftData mutations a second.
    @State private var draftStart: Double?
    @State private var draftEnd: Double?
    /// The editor's own playhead. Play starts here, not at the cut's start.
    @State private var cursor: Double?
    /// Which edge the nudge buttons move: the last one touched.
    @State private var activeStart = true
    /// 1, 2, 4 or 8. Pinch on the strip, or the magnifier.
    @State private var zoom: Double = 1
    @State private var undo: [(start: Double, end: Double, kind: SegmentKind)] = []

    private var start: Double { draftStart ?? segment.start }
    private var end: Double { draftEnd ?? segment.end }
    private var playFrom: Double { cursor ?? start }

    /// Everything the editor can reach: the cut and some of the episode
    /// either side, so an edge can be dragged outward and the ghost of the
    /// original is in view.
    private var reach: ClosedRange<Double> {
        let lo = min(segment.start, segment.originalStart)
        let hi = max(segment.end, segment.originalEnd)
        let pad = max(6, (hi - lo) * 0.35)
        let lower = max(0, lo - pad)
        let upper = episode.duration > 0 ? min(episode.duration, hi + pad) : hi + pad
        return lower...max(lower + 1, upper)
    }

    /// What the strip shows: all of `reach`, or a zoomed part of it centred
    /// on the edge being worked on.
    private var window: ClosedRange<Double> {
        guard zoom > 1 else { return reach }
        let span = (reach.upperBound - reach.lowerBound) / zoom
        let centre = activeStart ? start : end
        var lower = centre - span / 2
        lower = min(max(reach.lowerBound, lower), reach.upperBound - span)
        return lower...(lower + span)
    }

    private var previewing: Bool { player.previewRange != nil && player.currentEpisode === episode }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorPicture(episode: episode)
            trimmer
            nudges
            transport
            TranscriptPane(episode: episode,
                           range: reach,
                           selection: start...end,
                           following: previewing,
                           cursor: playFrom,
                           onTap: { moveCursor(to: $0) })
            kindAndState
            verdicts
        }
    }

    // MARK: Trimmer

    private var trimmer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The playhead is read inside `PlayheadReader`, not here: read
            // here, this whole editor — transcript, buttons and all — was
            // rebuilt five times a second while a cut played.
            PlayheadReader(episode: episode, fallback: playFrom) { now in
                TrimStrip(episode: episode,
                          window: window,
                          limits: reach,
                          start: Binding(get: { start }, set: { draftStart = $0 }),
                          end: Binding(get: { end }, set: { draftEnd = $0 }),
                          original: segment.isEdited ? segment.originalStart...max(segment.originalStart + 0.1, segment.originalEnd) : nil,
                          tint: Theme.tint(for: segment.kind),
                          playhead: now,
                          locked: segment.isLocked,
                          onGrab: { activeStart = $0 },
                          onScrub: { moveCursor(to: $0) },
                          onZoom: { zoom = $0 },
                          zoom: zoom,
                          onCommit: commitEdges)
            }

            HStack {
                Text(formatPrecise(start))
                Spacer()
                Text(lengthLabel)
                Spacer()
                Text(formatPrecise(end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            // The playhead has a bar of its own, under the strip. Scrubbing
            // on the strip itself meant a finger that landed near a handle
            // moved the cut instead of the playhead.
            PlayheadReader(episode: episode, fallback: playFrom) { now in
                ScrubBar(window: window,
                         playhead: now,
                         selection: start...end,
                         tint: Theme.tint(for: segment.kind),
                         onScrub: { moveCursor(to: $0) })
            }
        }
    }

    private var lengthLabel: String {
        let seconds = Int((end - start).rounded())
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    /// Tenths of a second, so a nudge shows.
    private func formatPrecise(_ t: Double) -> String {
        let tenths = Int((t * 10).rounded()) % 10
        return formatDuration(t) + ".\(tenths)"
    }

    // MARK: Nudges and zoom

    private var nudges: some View {
        HStack(spacing: 6) {
            nudge("-1", by: -1, id: activeStart ? "NudgeStartEarlierMore" : "NudgeEndEarlierMore")
            nudge("-0.1", by: -0.1, id: activeStart ? "NudgeStartEarlier" : "NudgeEndEarlier")
            Picker("Edge", selection: $activeStart) {
                Text("Start").tag(true)
                Text("End").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 130)
            .accessibilityIdentifier("TrimEdge")
            nudge("+0.1", by: 0.1, id: activeStart ? "NudgeStartLater" : "NudgeEndLater")
            nudge("+1", by: 1, id: activeStart ? "NudgeStartLaterMore" : "NudgeEndLaterMore")
            Button {
                zoom = zoom >= 8 ? 1 : zoom * 2
                Haptics.select()
            } label: {
                Image(systemName: zoom > 1 ? "plus.magnifyingglass" : "magnifyingglass")
                    .overlay(alignment: .bottomTrailing) {
                        if zoom > 1 {
                            Text("\(Int(zoom))×").font(.system(size: 8, weight: .bold)).offset(x: 8, y: 6)
                        }
                    }
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityLabel(zoom > 1 ? "Zoom \(Int(zoom)) times" : "Zoom in")
            .accessibilityIdentifier("TrimZoom")
        }
        .disabled(segment.isLocked)
        .font(.system(size: UIScale.pt(12), weight: .semibold).monospacedDigit())
    }

    private func nudge(_ title: String, by delta: Double, id: String) -> some View {
        Button {
            if activeStart {
                draftStart = min(max(reach.lowerBound, start + delta), end - 0.5)
            } else {
                draftEnd = max(min(reach.upperBound, end + delta), start + 0.5)
            }
            Haptics.select()
            commitEdges(snap: false)
        } label: {
            Text(title).frame(minWidth: 26)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityIdentifier(id)
    }

    // MARK: Committing

    private func commitEdges() { commitEdges(snap: true) }

    /// Writes the dragged or nudged edges, snapped to the nearest word when
    /// dragged (a nudge is a deliberate tenth of a second and stays put), and
    /// files what changed as a lesson for this show.
    private func commitEdges(snap: Bool) {
        let old = segment.start...segment.end
        var newStart = draftStart ?? segment.start
        var newEnd = draftEnd ?? segment.end
        if snap {
            if draftStart != nil { newStart = episode.snapToWord(newStart, start: true) }
            if draftEnd != nil { newEnd = episode.snapToWord(newEnd, start: false) }
        }
        draftStart = nil
        draftEnd = nil
        guard abs(newStart - old.lowerBound) > 0.01 || abs(newEnd - old.upperBound) > 0.01,
              newEnd > newStart + 0.5 else { return }
        undo.append((old.lowerBound, old.upperBound, segment.kind))
        segment.start = newStart
        segment.end = newEnd
        episode.recordEdit(segment, from: old)
        // A different click when an edge snapped onto a word than when it
        // landed where the finger left it.
        if snap { Haptics.detent() } else { Haptics.select() }
        onChange()
    }

    private func setKind(_ kind: SegmentKind) {
        guard kind != segment.kind else { return }
        undo.append((segment.start, segment.end, segment.kind))
        segment.kind = kind
        if !segment.isAdded { segment.sponsor = kind == .ad ? segment.sponsor : "" }
        episode.recordEdit(segment, from: segment.start...segment.end)
        Haptics.select()
        onChange()
    }

    private func undoLast() {
        guard let last = undo.popLast() else { return }
        segment.start = last.start
        segment.end = last.end
        segment.kind = last.kind
        Haptics.select()
        onChange()
    }

    // MARK: Transport

    /// Five seconds either way from wherever the playhead is now.
    private func step(_ seconds: Double) {
        moveCursor(to: (previewing ? player.currentTime : playFrom) + seconds)
        Haptics.select()
    }

    private func moveCursor(to time: Double) {
        let t = min(max(reach.lowerBound, time), reach.upperBound)
        cursor = t
        if previewing { play(from: t) }
    }

    /// From the playhead to a few seconds past the cut's end, with skipping
    /// suspended, so you hear the edge and what follows it.
    private func play(from t: Double) {
        let upper = min(reach.upperBound, max(end + 3, t + 3))
        player.startPreview(t...upper, of: episode, from: t)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                if previewing { player.endPreview() } else { play(from: playFrom) }
                Haptics.select()
            } label: {
                Image(systemName: previewing ? "pause.fill" : "play.fill")
                    .font(.system(size: UIScale.pt(16), weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.tint(for: segment.kind).opacity(0.22)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(previewing ? "Stop preview" : "Hear what was cut")

            VStack(alignment: .leading, spacing: 2) {
                Text(previewing ? "Playing from the playhead" : "Hear what was cut")
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                PlayheadReader(episode: episode, fallback: playFrom) { now in
                    Text(previewing
                         ? "\(formatDuration(now)) · skipping is off while this plays"
                         : "Plays from the playhead (\(formatPrecise(playFrom))). Tap the strip or a line to move it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button { step(-5) } label: {
                Image(systemName: "gobackward.5").frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.small)
            .accessibilityLabel("Back five seconds")
            .accessibilityIdentifier("EditorBack5")
            Button { step(5) } label: {
                Image(systemName: "goforward.5").frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.small)
            .accessibilityLabel("Forward five seconds")
            .accessibilityIdentifier("EditorForward5")
            Button {
                cursor = start
                Haptics.select()
                if previewing { play(from: start) }
            } label: {
                Image(systemName: "backward.end.fill").frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .accessibilityLabel("Playhead to the start of the cut")
        }
    }

    // MARK: Kind, status, undo

    private var kindAndState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SegmentKind.allCases) { kind in
                        Button { setKind(kind) } label: {
                            if kind == segment.kind { Label(kind.label, systemImage: "checkmark") } else { Text(kind.label) }
                        }
                    }
                } label: {
                    Label(segment.kind.label, systemImage: "tag")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(segment.isLocked)
                .accessibilityIdentifier("CutKind")

                Button {
                    segment.isLocked.toggle()
                    Haptics.select()
                    onChange()
                } label: {
                    Label(segment.isLocked ? "Locked" : "Lock", systemImage: segment.isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(segment.isLocked ? Theme.accentHot : .secondary)
                .accessibilityIdentifier("LockCut")

                if !undo.isEmpty {
                    Button { undoLast() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward").font(.system(size: UIScale.pt(13), weight: .semibold))
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .disabled(segment.isLocked)
                    .accessibilityIdentifier("UndoCut")
                }
                Spacer(minLength: 0)
            }
            if !segment.evidenceText.isEmpty {
                Text((segment.needsReview ? "Not sure. What's there: " : "Why: ") + segment.evidenceText)
                    .font(.caption)
                    .foregroundStyle(segment.needsReview ? Theme.accentHot : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CutEvidence")
            }
            HStack(spacing: 8) {
                Text(segment.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(segment.isEdited || segment.isAdded ? Theme.accentHot : Color.secondary)
                    .accessibilityIdentifier("EditorStatus")
                if segment.isEdited {
                    Text("· found \(formatDuration(segment.originalStart))–\(formatDuration(segment.originalEnd))\(segment.originalKind != segment.kind ? " as \(segment.originalKind.label.lowercased())" : "")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Revert") {
                        undo.append((segment.start, segment.end, segment.kind))
                        segment.revertToDetected()
                        onChange()
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(segment.isLocked)
                    .accessibilityIdentifier("RevertCut")
                }
                if segment.isAdded {
                    Button("Remove", role: .destructive) {
                        player.endPreview()
                        context.delete(segment)
                        onChange()
                    }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("RemoveCut")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Verdicts

    private var verdicts: some View {
        HStack(spacing: 8) {
            verdictButton("Right call", symbol: "hand.thumbsup",
                          on: segment.userVerdict == .confirmed) { set(.confirmed) }
            verdictButton("Not an ad", symbol: "hand.thumbsdown",
                          on: segment.userVerdict == .notAnAd) { set(.notAnAd) }
            Spacer(minLength: 0)
        }
    }

    private func verdictButton(_ title: String,
                               symbol: String,
                               on: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: on ? symbol + ".fill" : symbol)
                .font(.system(size: UIScale.pt(14), weight: .semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(on ? Theme.accentHot : .secondary)
        // `.tint` colours the capsule but leaves the symbol on the system
        // accent, so both thumbs rendered blue whether they were on or not.
        .foregroundStyle(on ? Theme.accentHot : Color.primary)
    }

    private func set(_ verdict: UserVerdict) {
        // Tapping the one that is already on turns it back off. Through
        // `Episode.apply`, never by assigning `userVerdict`: that is what files
        // the passage against the show so the next episode is judged
        // differently.
        episode.apply(segment.userVerdict == verdict ? .unreviewed : verdict, to: segment)
        Haptics.success()
        onChange()
    }
}

/// The picture, for a video episode that is loaded and showing video.
private struct EditorPicture: View {
    let episode: Episode
    @State private var player = PlayerEngine.shared
    @State private var pip = false

    var body: some View {
        if player.currentEpisode === episode, let output = player.videoOutput {
            // Small: it is there to see which shot an edge lands on, and at
            // full width it pushed the strip and controls off the screen.
            VideoSurface(player: output, pictureInPictureActive: $pip)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Trim strip

/// Two draggable handles over a strip of the episode, as in Photos and Voice
/// Memos, with a playhead of its own.
///
/// - Tap or drag the strip itself to move the playhead.
/// - Drag a handle to move an edge. Move the finger down, away from the strip,
///   to drag more finely — half speed, a quarter, a tenth — the way iOS's own
///   scrubbers work.
/// - Pinch, or the magnifier, to zoom in on the edge you touched last.
/// - The faint dashed box is what the detector originally found.
///
/// There is no waveform — the audio is not decoded here and often isn't on
/// disk — so the texture is how densely words were spoken, which is the same
/// information: where the talking is, and the gaps where a cut should land.
private struct TrimStrip: View {
    let episode: Episode
    let window: ClosedRange<Double>
    /// How far a handle may go.
    let limits: ClosedRange<Double>
    @Binding var start: Double
    @Binding var end: Double
    var original: ClosedRange<Double>?
    let tint: Color
    var playhead: Double?
    var locked: Bool
    var onGrab: (Bool) -> Void
    var onScrub: (Double) -> Void
    var onZoom: (Double) -> Void
    var zoom: Double
    let onCommit: () -> Void

    @State private var bars: [CGFloat] = []
    @State private var grabbed: (start: Double, end: Double)?
    @State private var lastX: CGFloat?
    @State private var dragged = false
    @State private var pinchBase: Double?

    private static let height: CGFloat = 58
    private static let handleWidth: CGFloat = 16
    private static let minimumLength: Double = 1

    private var span: Double { max(0.001, window.upperBound - window.lowerBound) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let startX = x(for: start, width: width)
            let endX = x(for: end, width: width)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))

                speechTexture(width: width)

                Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, startX))
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, width - endX)).offset(x: endX)

                if let original {
                    let ox = x(for: original.lowerBound, width: width)
                    let ow = max(2, x(for: original.upperBound, width: width) - ox)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: ow, height: Self.height - 12)
                        .offset(x: ox, y: 6)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("OriginalGhost")
                }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint, lineWidth: 2.5)
                    .frame(width: max(4, endX - startX))
                    .offset(x: startX)

                if let playhead, playhead >= window.lowerBound, playhead <= window.upperBound {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: x(for: playhead, width: width) - 1)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .allowsHitTesting(false)
                }

                if !locked {
                    handle(at: startX, leading: true, width: width)
                    handle(at: endX, leading: false, width: width)
                }
            }
            .frame(width: width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            // A tap on the strip moves the playhead, but not within a
            // thumb's width of either handle: that space belongs to the
            // handles, and the playhead has its own bar underneath.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = value.location.x
                        guard abs(x - startX) > 26, abs(x - endX) > 26 else { return }
                        onScrub(time(atX: x, width: width))
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = zoom }
                        let next = min(8, max(1, (pinchBase ?? 1) * value.magnification))
                        onZoom(next)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .frame(height: Self.height)
        .accessibilityIdentifier("TrimStrip")
        .task(id: "\(episode.guid)|\(Int(window.lowerBound * 10))|\(Int(window.upperBound * 10))") {
            bars = Self.speechBars(episode: episode, window: window)
        }
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        let fraction = (time - window.lowerBound) / span
        return min(width, max(0, width * CGFloat(fraction)))
    }

    private func time(atX value: CGFloat, width: CGFloat) -> Double {
        let fraction = Double(min(max(0, value), width) / max(1, width))
        return window.lowerBound + fraction * span
    }

    /// Finer the further the finger has moved down, off the strip.
    private static func rate(forDrop dy: CGFloat) -> Double {
        switch abs(dy) {
        case ..<40: 1
        case ..<90: 0.5
        case ..<150: 0.25
        default: 0.1
        }
    }

    private func handle(at position: CGFloat, leading: Bool, width: CGFloat) -> some View {
        let centre = leading ? position + Self.handleWidth / 2 : position - Self.handleWidth / 2
        return ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint)
                .frame(width: Self.handleWidth, height: Self.height)
                .overlay { Capsule().fill(Color.black.opacity(0.45)).frame(width: 2, height: 18) }
        }
        .frame(width: 44, height: Self.height)
        .contentShape(Rectangle())
        .position(x: centre, y: Self.height / 2)
        .accessibilityIdentifier(leading ? "TrimStartHandle" : "TrimEndHandle")
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if grabbed == nil {
                        grabbed = (start, end)
                        lastX = value.location.x
                        dragged = false
                        onGrab(leading)
                        Haptics.select()
                    }
                    guard let previous = lastX else { return }
                    let dx = value.location.x - previous
                    lastX = value.location.x
                    if abs(value.translation.width) > 6 { dragged = true }
                    guard dragged else { return }
                    let shift = Double(dx / max(1, width)) * span * Self.rate(forDrop: value.translation.height)
                    if leading {
                        start = min(max(limits.lowerBound, start + shift), end - Self.minimumLength)
                    } else {
                        end = max(min(limits.upperBound, end + shift), start + Self.minimumLength)
                    }
                }
                .onEnded { _ in
                    let original = grabbed
                    grabbed = nil
                    lastX = nil
                    if dragged {
                        onCommit()
                    } else if let original {
                        // A touch that didn't move leaves the cut as it was.
                        start = original.start
                        end = original.end
                    }
                }
        )
    }

    private func speechTexture(width: CGFloat) -> some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let slot = size.width / CGFloat(bars.count)
            for (index, value) in bars.enumerated() {
                let barHeight = max(2, size.height * 0.72 * value)
                let rect = CGRect(x: CGFloat(index) * slot + slot * 0.2,
                                  y: (size.height - barHeight) / 2,
                                  width: max(1, slot * 0.6),
                                  height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, slot * 0.3)),
                             with: .color(.white.opacity(0.35)))
            }
        }
        .frame(width: width, height: Self.height)
        .allowsHitTesting(false)
    }

    /// Words per slice, normalised to 0...1. Uses each word's own time when
    /// the transcript has it, so zooming in shows the real gaps.
    private static func speechBars(episode: Episode, window: ClosedRange<Double>) -> [CGFloat] {
        let lines = episode.lines(in: window)
        guard !lines.isEmpty else { return [] }
        let count = 64
        let span = max(0.001, window.upperBound - window.lowerBound)
        var slots = [Double](repeating: 0, count: count)
        func mark(_ from: Double, _ to: Double, _ value: Double) {
            let a = Int(((from - window.lowerBound) / span) * Double(count))
            let b = Int(((to - window.lowerBound) / span) * Double(count))
            // Both clamped before the range is formed: an inverted
            // ClosedRange is a crash, not an empty loop.
            let lower = min(max(0, a), count - 1)
            let upper = min(max(0, b), count - 1)
            for index in min(lower, upper)...max(lower, upper) { slots[index] = max(slots[index], value) }
        }
        for line in lines {
            if let words = line.words, !words.isEmpty {
                for w in words where w.end > window.lowerBound && w.start < window.upperBound {
                    mark(w.start, w.end, 1)
                }
            } else {
                let words = Double(max(1, line.text.split(separator: " ").count))
                mark(line.start, line.end, words / max(0.2, line.end - line.start))
            }
        }
        let peak = slots.max() ?? 0
        guard peak > 0 else { return [] }
        return slots.map { CGFloat($0 / peak) }
    }
}

// MARK: - Transcript

/// The words around a cut, large enough to read. Lines inside the cut are
/// bright, lines outside it dim; the line at the playhead is bold and kept
/// in view. Tap a line to put the playhead at its start.
private struct TranscriptPane: View {
    let episode: Episode
    let range: ClosedRange<Double>
    let selection: ClosedRange<Double>
    let following: Bool
    let cursor: Double
    var onTap: (Double) -> Void

    /// Read once per stretch, not once per use: `lines(in:)` filters the
    /// whole transcript, and this view used it four times per body.
    @State private var lines: [TimedLine] = []
    @State private var loaded = false
    @State private var activeIndex: Int?

    private var estimatedHeight: CGFloat {
        let rows = lines.reduce(0) { $0 + max(1, ($1.text.count + 37) / 38) }
        return min(260, max(84, CGFloat(rows) * 24 + CGFloat(lines.count) * 10 + 24))
    }

    private var currentIndex: Int? {
        following ? activeIndex : (PlayheadLineWatcher.line(at: cursor, in: lines)
                                   ?? lines.lastIndex { $0.start <= cursor })
    }

    var body: some View {
        content
            .task(id: "\(Int(range.lowerBound * 10))-\(Int(range.upperBound * 10))") {
                lines = episode.lines(in: range)
                loaded = true
            }
            .background {
                if following {
                    PlayheadLineWatcher(episode: episode, lines: lines, activeIndex: $activeIndex)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Color.clear.frame(height: 84)
        } else if lines.isEmpty {
            Text(episode.timedTranscript.isEmpty
                 ? "No transcript was kept for this episode, so there are no words to show."
                 : "Nothing was said here — this stretch is music, a sting or silence.")
                .font(.system(size: UIScale.pt(15)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
        } else {
            let current = currentIndex
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            let inside = line.end > selection.lowerBound + 0.2 && line.start < selection.upperBound - 0.2
                            Button { onTap(line.start) } label: {
                                Text(line.text)
                                    .font(.system(size: UIScale.pt(17), weight: index == current ? .semibold : .regular))
                                    .foregroundStyle(index == current ? Color.primary
                                                     : inside ? Color.secondary : Color.secondary.opacity(0.45))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("TranscriptLine\(index)")
                            .id(index)
                        }
                    }
                    .padding(12)
                }
                // A fixed height, not a maximum: `maxHeight` on a ScrollView in
                // a List row is a negotiation it loses.
                .frame(height: estimatedHeight)
                .scrollBounceBehavior(.basedOnSize)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
                .onAppear {
                    if let first = lines.firstIndex(where: { $0.end > selection.lowerBound }) {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
                .onChange(of: current) { _, index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Share

/// The system share sheet.
///
/// Wrapped rather than using `ShareLink`, because the thing being shared is a
/// timestamp read at the moment of tapping — and a `ShareLink` needs its item
/// up front, which meant reading the playhead while building a menu. That is
/// what made the player's menu render itself twice.
struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Scrub bar

/// The playhead's own bar, under the trim strip.
///
/// The handles and the playhead were sharing one surface, so a finger that
/// landed near an edge moved the cut when it meant to move the playhead. This
/// is a separate control: a thin track with a knob, the cut's stretch drawn
/// brighter on it, and nothing on it can change the cut.
private struct ScrubBar: View {
    let window: ClosedRange<Double>
    var playhead: Double
    let selection: ClosedRange<Double>
    let tint: Color
    var onScrub: (Double) -> Void

    @State private var dragging = false

    private var span: Double { max(0.001, window.upperBound - window.lowerBound) }

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        min(width, max(0, width * CGFloat((t - window.lowerBound) / span)))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let headX = x(playhead, width)
            let fromX = x(selection.lowerBound, width)
            let toX = x(selection.upperBound, width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: dragging ? 8 : 5)
                Capsule().fill(tint.opacity(0.55))
                    .frame(width: max(2, toX - fromX), height: dragging ? 8 : 5)
                    .offset(x: fromX)
                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 20 : 15, height: dragging ? 20 : 15)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: headX - (dragging ? 10 : 7.5))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            Haptics.select()
                        }
                        onScrub(window.lowerBound + Double(min(max(0, value.location.x), width) / max(1, width)) * span)
                    }
                    .onEnded { _ in
                        dragging = false
                        Haptics.commit()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 30)
        .accessibilityIdentifier("ScrubBar")
        .accessibilityLabel("Playhead")
    }
}

// MARK: - Playhead reader

/// Reads the playhead for one small piece of the editor.
///
/// The playhead changes five times a second while a cut plays. Whatever body
/// reads it is rebuilt at that rate, so it is read here, around the few
/// things that draw it, and nowhere else in the editor.
private struct PlayheadReader<Content: View>: View {
    let episode: Episode
    let fallback: Double
    @ViewBuilder let content: (Double) -> Content
    @State private var player = PlayerEngine.shared

    var body: some View {
        let live = player.previewRange != nil && player.currentEpisode === episode
        content(live ? player.currentTime : fallback)
    }
}
