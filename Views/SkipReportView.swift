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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        // Leaving the page must not leave an ad playing.
        .onDisappear { player.endPreview() }
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

            Text("Open one to hear exactly what was cut and read along. "
                 + "Drag the handles to change where it starts and stops. "
                 + "A thumbs-up or thumbs-down is what this show's detection learns from.")
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

/// The trimmer, the preview player and the transcript.
///
/// Its own `View` rather than a computed property of the row, because it reads
/// the playhead. Read from the row's body, five updates a second would rebuild
/// every other row in the list along with it.
private struct SegmentDetail: View {
    let segment: AdSegment
    let episode: Episode
    let onChange: () -> Void

    @State private var player = PlayerEngine.shared

    /// The edges being dragged, kept apart from the model.
    ///
    /// Writing straight to `segment.start` on every drag frame would be a
    /// SwiftData mutation sixty times a second, each one invalidating every
    /// view that reads the episode. These hold the gesture; the model is
    /// written once, on release.
    @State private var draftStart: Double?
    @State private var draftEnd: Double?

    private var start: Double { draftStart ?? segment.start }
    private var end: Double { draftEnd ?? segment.end }

    /// A little of the episode either side, so an edge can be dragged outward
    /// as well as inward and you can see what is just outside the cut.
    private var window: ClosedRange<Double> {
        let pad = max(6, (segment.end - segment.start) * 0.35)
        let lower = max(0, segment.start - pad)
        let upper = episode.duration > 0
            ? min(episode.duration, segment.end + pad)
            : segment.end + pad
        return lower...max(lower + 1, upper)
    }

    private var previewing: Bool {
        guard let range = player.previewRange else { return false }
        return abs(range.lowerBound - start) < 0.5 && abs(range.upperBound - end) < 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            trimmer
            transport
            TranscriptPane(episode: episode,
                           range: start...end,
                           following: previewing)
            verdicts
        }
    }

    // MARK: Trimmer

    private var trimmer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrimStrip(episode: episode,
                      window: window,
                      start: Binding(get: { start }, set: { draftStart = $0 }),
                      end: Binding(get: { end }, set: { draftEnd = $0 }),
                      tint: Theme.tint(for: segment.kind),
                      playhead: previewing ? player.currentTime : nil,
                      onCommit: commitEdges)

            HStack {
                Text(formatDuration(start))
                Spacer()
                Text(lengthLabel)
                Spacer()
                Text(formatDuration(end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var lengthLabel: String {
        let seconds = Int((end - start).rounded())
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private func commitEdges() {
        var changed = false
        if let draftStart, abs(draftStart - segment.start) > 0.01 {
            segment.start = draftStart
            changed = true
        }
        if let draftEnd, abs(draftEnd - segment.end) > 0.01 {
            segment.end = draftEnd
            changed = true
        }
        draftStart = nil
        draftEnd = nil
        guard changed else { return }
        Haptics.select()
        onChange()
    }

    // MARK: Preview transport

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                if previewing {
                    player.endPreview()
                } else {
                    // Everything is suspended for the length of this stretch —
                    // ad skipping, Smart Speed, the outro trim — so what plays
                    // is the cut itself. No switches to flip first, and the
                    // playhead goes back where it was afterwards.
                    player.startPreview(start...end, of: episode)
                }
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
                Text(previewing ? "Playing what was cut" : "Hear what was cut")
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                Text(previewing
                     ? "\(formatDuration(max(0, player.currentTime - start))) of \(lengthLabel) · skipping is off while this plays"
                     : "Plays this stretch only, then puts you back where you were.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
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
        // accent, so both thumbs rendered blue whether they were on or not —
        // which is exactly the wrong thing for a control whose entire job is to
        // show which of two states it is in.
        .foregroundStyle(on ? Theme.accentHot : Color.primary)
    }

    private func set(_ verdict: UserVerdict) {
        // Tapping the one that is already on turns it back off, so a mis-tap is
        // one tap to undo rather than a state you cannot leave.
        //
        // Through `Episode.apply`, not by assigning `userVerdict` directly:
        // that is what files the passage against the show so the next episode
        // is judged differently. The difference between a thumb that changes
        // one episode and a thumb that teaches.
        episode.apply(segment.userVerdict == verdict ? .unreviewed : verdict, to: segment)
        Haptics.success()
        onChange()
    }
}

// MARK: - Trim strip

/// Two draggable handles over a strip of the episode, the way trimming works in
/// Photos and Voice Memos.
///
/// The plus and minus buttons this replaces moved a boundary two seconds at a
/// time and told you the result as a timestamp. Nudging a cut four seconds
/// earlier was four taps and no picture of what you were doing.
///
/// There is no waveform available — the audio is not decoded here and often is
/// not on disk at all — so the texture behind the handles is how densely words
/// were spoken, taken from the transcript. That is not a waveform but it is the
/// same information you actually need: where the talking is, and where the
/// gaps between it are, which is exactly where a cut should land.
private struct TrimStrip: View {
    let episode: Episode
    let window: ClosedRange<Double>
    @Binding var start: Double
    @Binding var end: Double
    let tint: Color
    var playhead: Double?
    let onCommit: () -> Void

    /// Cached so a drag does not re-walk the transcript on every frame.
    @State private var bars: [CGFloat] = []

    // Peek and snap, the same as the player's bar: a touch on a handle that
    // neither moves nor lingers puts the edge back where it was, so brushing
    // a handle cannot move a cut. Dragging commits on release; holding still
    // until the ring fills commits on the spot.
    @State private var grabbed: (start: Double, end: Double)?
    @State private var dragged = false
    @State private var tension: Double = 0
    @State private var tensionLeading = true
    @State private var tensionTask: Task<Void, Never>?
    @State private var broke = false

    private static let height: CGFloat = 58
    private static let handleWidth: CGFloat = 16
    /// Nothing shorter than this can be made by dragging. A one-frame cut is
    /// not a thing anyone means to create.
    private static let minimumLength: Double = 1

    private var span: Double { max(0.001, window.upperBound - window.lowerBound) }

    var body: some View {
        // An explicit height on the reader, not an open-ended one.
        //
        // A `GeometryReader` in a `List` row has no intrinsic height: it fills
        // whatever it is given and reports nothing back, which leaves the row
        // sized wrongly and ghost frames behind after a navigation transition.
        GeometryReader { geo in
            let width = geo.size.width
            let startX = x(for: start, width: width)
            let endX = x(for: end, width: width)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))

                speechTexture(width: width)

                // Everything outside the selection is dimmed, so the selection
                // reads as the bright part rather than as a box drawn on top.
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, startX))
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)

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
                }

                handle(at: startX, leading: true, width: width)
                handle(at: endX, leading: false, width: width)
            }
            .frame(width: width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: Self.height)
        // Keyed on the window as well as the episode: dragging an edge far
        // enough changes the window, and `.task(id:)` does not re-run on its
        // own — the bars would keep describing a stretch that is no longer the
        // one on screen.
        .task(id: "\(episode.guid)|\(Int(window.lowerBound))|\(Int(window.upperBound))") {
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

    private func handle(at position: CGFloat, leading: Bool, width: CGFloat) -> some View {
        let centre = leading
            ? position + Self.handleWidth / 2
            : position - Self.handleWidth / 2
        // A 16pt bar is not a touch target, so the visible handle sits inside a
        // 44pt clear one and the gesture is attached to that.
        return ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint)
                .frame(width: Self.handleWidth, height: Self.height)
                .overlay {
                    Capsule()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 2, height: 18)
                }
        }
            .frame(width: 44, height: Self.height)
            .contentShape(Rectangle())
            .position(x: centre, y: Self.height / 2)
            .overlay {
                if tension > 0, tensionLeading == leading {
                    Circle()
                        .trim(from: 0, to: tension)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 34, height: 34)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if grabbed == nil {
                            grabbed = (start, end)
                            dragged = false
                            broke = false
                            Haptics.select()
                        }
                        if abs(value.translation.width) > 8, !dragged {
                            dragged = true
                            cancelTension()
                        }
                        // Relative to where the handle was grabbed, not
                        // where the finger is: touching a handle a few points
                        // off its centre must not move the cut.
                        guard dragged, let original = grabbed else { return }
                        let shift = Double(value.translation.width / max(1, width)) * span
                        if leading {
                            start = min(max(window.lowerBound, original.start + shift), end - Self.minimumLength)
                        } else {
                            end = max(min(window.upperBound, original.end + shift), start + Self.minimumLength)
                        }
                    }
                    .onEnded { _ in
                        let original = grabbed
                        grabbed = nil
                        cancelTension()
                        if dragged {
                            onCommit()
                        } else if !broke, let original {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.52)) {
                                start = original.start
                                end = original.end
                            }
                            Haptics.recoil()
                        }
                    }
            )
    }

    private func beginTension(leading: Bool) {
        tensionTask?.cancel()
        tensionLeading = leading
        tensionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, grabbed != nil, !dragged else { return }
            withAnimation(.linear(duration: 0.62)) { tension = 1 }
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled, grabbed != nil, !dragged else { return }
            broke = true
            onCommit()
            Haptics.commit()
            withAnimation(.easeOut(duration: 0.18)) { tension = 0 }
        }
    }

    private func cancelTension() {
        tensionTask?.cancel()
        tensionTask = nil
        if tension > 0 { withAnimation(.easeOut(duration: 0.15)) { tension = 0 } }
    }

    /// Speech density, drawn as bars. Empty when there is no transcript, which
    /// leaves a plain strip rather than a misleading one.
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

    /// Words per slice, normalised to 0...1.
    private static func speechBars(episode: Episode,
                                   window: ClosedRange<Double>) -> [CGFloat] {
        let lines = episode.lines(in: window)
        guard !lines.isEmpty else { return [] }
        let count = 64
        let span = max(0.001, window.upperBound - window.lowerBound)
        var slots = [Double](repeating: 0, count: count)
        for line in lines {
            let words = Double(max(1, line.text.split(separator: " ").count))
            let lineSpan = max(0.2, line.end - line.start)
            let rate = words / lineSpan
            let from = Int(((line.start - window.lowerBound) / span) * Double(count))
            let to = Int(((line.end - window.lowerBound) / span) * Double(count))
            // Both clamped into the array *before* the range is formed. Built
            // the obvious way — `max(0, from)...min(count - 1, to)` — a line
            // that starts just past the last slot produces `64...63`, and an
            // inverted ClosedRange is a crash, not an empty loop.
            let lower = min(max(0, from), count - 1)
            let upper = min(max(0, to), count - 1)
            for index in min(lower, upper)...max(lower, upper) {
                slots[index] = max(slots[index], rate)
            }
        }
        let peak = slots.max() ?? 0
        guard peak > 0 else { return [] }
        return slots.map { CGFloat($0 / peak) }
    }
}

// MARK: - Transcript

/// The words in a stretch, large enough to read, following the playhead.
///
/// The old version was eight lines of grey caption text in a box. What was
/// wanted is the thing the player already does with the live transcript: the
/// line being spoken, big, with the rest of it dimmed around it — so you can
/// see the sponsor read arrive rather than squinting at a paragraph.
private struct TranscriptPane: View {
    let episode: Episode
    let range: ClosedRange<Double>
    /// Whether to track the playhead. False when nothing is playing, so the
    /// whole passage sits still and readable.
    let following: Bool

    @State private var player = PlayerEngine.shared

    private var lines: [TimedLine] { episode.lines(in: range) }

    /// Roughly how tall the passage wants to be.
    ///
    /// Counting entries is not enough: a sentence of a sponsor read wraps to
    /// two or three lines at 17pt, so four entries can be nine lines. Sized by
    /// entries alone the pane showed three and a half of them and the last one
    /// was sliced through the middle, which reads as a bug rather than as
    /// something you can scroll. Thirty-eight characters to a line is measured
    /// off a phone at the default text size; the cap is what stops a
    /// four-minute ad read pushing the thumbs off the screen.
    private var estimatedHeight: CGFloat {
        let rows = lines.reduce(0) { $0 + max(1, ($1.text.count + 37) / 38) }
        return min(240, max(84, CGFloat(rows) * 24 + CGFloat(lines.count) * 10 + 24))
    }

    private var currentIndex: Int? {
        guard following else { return nil }
        let now = player.currentTime
        return lines.firstIndex { $0.start <= now && $0.end >= now }
            ?? lines.lastIndex { $0.start <= now }
    }

    var body: some View {
        if lines.isEmpty {
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .font(.system(size: UIScale.pt(17),
                                              weight: index == currentIndex ? .semibold : .regular))
                                .foregroundStyle(index == currentIndex
                                                 ? Color.primary
                                                 : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                // A fixed height, not a maximum.
                //
                // `maxHeight` on a `ScrollView` inside a `List` row is a
                // negotiation, and it lost: the row was sized by something
                // else and the scroll view was squeezed to about forty points,
                // which clipped a single line of transcript top and bottom.
                .frame(height: estimatedHeight)
                .scrollBounceBehavior(.basedOnSize)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
                .onChange(of: currentIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
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
