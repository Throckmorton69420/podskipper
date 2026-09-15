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
/// give: they are already annoyed, and now there is somewhere to put it.
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
                            active: episode.skips(segment.kind, settings: settings),
                            isOpen: expanded == segment.persistentModelID,
                            onToggle: {
                                withAnimation(.snappy(duration: 0.22)) {
                                    expanded = expanded == segment.persistentModelID
                                        ? nil : segment.persistentModelID
                                }
                            },
                            onSeek: { time in
                                player.seek(to: max(0, time - 1))
                                dismiss()
                            },
                            onChange: {
                                try? context.save()
                                player.refreshSkipRanges()
                            })
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("What was skipped")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(totalSkipped >= 60
                 ? "\(Int(totalSkipped / 60)) min \(Int(totalSkipped.truncatingRemainder(dividingBy: 60))) sec cut"
                 : "\(Int(totalSkipped)) sec cut")
                .font(.system(size: 26, weight: .bold))

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

            Text("Tap one to hear what was in it. If it was wrong, say so — "
                 + "corrections are what the detector learns this show from.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing found yet")
                .font(.system(size: 22, weight: .semibold))
            Text(episode.processingState == .ready
                 ? "This episode was searched and nothing was marked. That is either a clean show or a miss — if you heard an ad, the detector did not."
                 : "Ads have not been looked for in this episode yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 20)
        .listRowSeparator(.hidden)
    }
}

// MARK: - One segment

private struct SkipRow: View {
    let segment: AdSegment
    let episode: Episode
    let active: Bool
    let isOpen: Bool
    let onToggle: () -> Void
    let onSeek: (Double) -> Void
    let onChange: () -> Void

    /// How far one press of an edge control moves a boundary.
    ///
    /// Two seconds rather than one: the complaint is always a word or two of
    /// the show lost at the front, or a beat of sponsor left at the back, and
    /// a second at a time makes fixing that a dozen taps.
    private static let nudge: Double = 2

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
                                .font(.system(size: 15, weight: .semibold))
                            if !segment.sponsor.isEmpty {
                                Text("· \(segment.sponsor)")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(range)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if verdictLine != nil || !active {
                            Text(verdictLine ?? "Kept — this kind is switched off")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { detail.padding(.top, 12) }
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

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            transcript

            // Edges first, verdict second: most of the time the cut is right
            // and only its boundary is wrong, and fixing that is the more
            // common correction by a wide margin.
            VStack(alignment: .leading, spacing: 7) {
                edgeRow(title: "Start",
                        value: segment.start,
                        earlier: { move(startBy: -Self.nudge) },
                        later: { move(startBy: Self.nudge) })
                edgeRow(title: "End",
                        value: segment.end,
                        earlier: { move(endBy: -Self.nudge) },
                        later: { move(endBy: Self.nudge) })
            }

            HStack(spacing: 8) {
                verdictButton("Right call", symbol: "hand.thumbsup",
                              on: segment.userVerdict == .confirmed) {
                    set(.confirmed)
                }
                verdictButton("Not an ad", symbol: "hand.thumbsdown",
                              on: segment.userVerdict == .notAnAd) {
                    set(.notAnAd)
                }
                Spacer(minLength: 0)
                Button {
                    onSeek(segment.start)
                } label: {
                    Label("Listen", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// The words inside this stretch, if the episode has a transcript.
    @ViewBuilder
    private var transcript: some View {
        let lines = episode.timedTranscript.filter {
            $0.start < segment.end && $0.end > segment.start
        }
        if lines.isEmpty {
            Text(episode.timedTranscript.isEmpty
                 ? "No transcript was kept for this episode."
                 : "No words fall inside this stretch — it is probably music or silence.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            Text(lines.map(\.text).joined(separator: " "))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
        }
    }

    private func edgeRow(title: String,
                         value: Double,
                         earlier: @escaping () -> Void,
                         later: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(formatDuration(value))
                .font(.footnote.monospacedDigit().weight(.medium))
                .frame(width: 58, alignment: .leading)
            Button(action: earlier) {
                Image(systemName: "minus")
                    .frame(width: 34, height: 28)
            }
            Button(action: later) {
                Image(systemName: "plus")
                    .frame(width: 34, height: 28)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    private func verdictButton(_ title: String,
                               symbol: String,
                               on: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(on ? Theme.accentHot : .secondary)
    }

    // MARK: Edits

    private func move(startBy delta: Double) {
        // Never past its own end, never before the episode begins.
        segment.start = min(max(0, segment.start + delta), segment.end - 1)
        Haptics.select()
        onChange()
    }

    private func move(endBy delta: Double) {
        let ceiling = episode.duration > 0 ? episode.duration : segment.end + delta
        segment.end = max(min(ceiling, segment.end + delta), segment.start + 1)
        Haptics.select()
        onChange()
    }

    private func set(_ verdict: UserVerdict) {
        // Tapping the one that is already on turns it back off, so a
        // mis-tap is one tap to undo rather than a state you cannot leave.
        segment.userVerdict = segment.userVerdict == verdict ? .unreviewed : verdict
        Haptics.success()
        onChange()
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
