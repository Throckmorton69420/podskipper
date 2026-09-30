import SwiftUI
import UIKit

/// Player "…" → Share Clip (task 07).
///
/// A strip of the episode around where you are, with the same handles as the
/// "What was skipped" editor: thirty seconds either side to start with, up to
/// three minutes. Play hears it as it will sound — ads left out — and Share
/// makes a small audio file of it for the share sheet.
struct ClipShareView: View {
    let episode: Episode
    /// Where the playhead was when the sheet opened.
    let around: Double

    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var includeTranscript = false
    @State private var exporting = false
    @State private var progress: Double = 0
    @State private var problem: String?
    @State private var shared: SharedClip?

    private var length: Double {
        let known = player.duration > 0 ? player.duration : episode.duration
        return max(known, around + 1)
    }

    /// What the strip shows: two and a half minutes either side, so a clip
    /// of the longest length fits with room to move.
    private var window: ClosedRange<Double> {
        let lower = max(0, around - 150)
        let upper = min(length, around + 150)
        return lower...max(lower + 1, upper)
    }

    /// The cuts inside the window, as they are skipped now.
    private var cuts: [ClosedRange<Double>] {
        player.currentEpisode === episode ? player.skippedRanges.filter { $0.overlaps(window) } : []
    }

    /// Length once the cuts inside it are left out.
    private var clipSeconds: Double {
        ClipExporter.pieces(of: start...max(start, end), removing: cuts)
            .reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    private var hasTranscript: Bool { !episode.lines(in: window).isEmpty }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ClipExporter.title(show: episode.podcast?.title ?? "", episode: episode.title,
                                            range: start...max(start, end)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    strip
                    HStack {
                        Text(ClipExporter.stamp(start))
                        Spacer()
                        Text(summary)
                            .foregroundStyle(end - start > ClipExporter.maxLength - 0.5 ? Theme.accentHot : .secondary)
                        Spacer()
                        Text(ClipExporter.stamp(end))
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)

                previewButton
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Drag the handles to choose the clip, up to three minutes. Ads PodSkipper skips are left out of it.")
            }

            Section {
                Toggle("Include transcript text", isOn: $includeTranscript)
                    .disabled(!hasTranscript)
            } footer: {
                if !hasTranscript {
                    Text("There's no transcript for this part yet. Find Ads makes one.")
                }
            }
            .listRowBackground(Color.clear)

            Section {
                if exporting {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                            .tint(Theme.accentHot)
                        Text("Making the clip…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button(action: share) {
                        GlassButtonLabel(title: "Share", systemImage: "square.and.arrow.up", font: .headline)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentHot)
                    .disabled(clipSeconds < 1)
                    .accessibilityIdentifier("ShareClipButton")
                }
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Share Clip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: setUp)
        // Leaving must not leave the preview playing, nor strand the
        // listener in it.
        .onDisappear { player.endPreview() }
        .sheet(item: $shared) { clip in
            ActivitySheet(items: clip.items)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Pieces

    private var summary: String {
        let seconds = Int(clipSeconds.rounded())
        let text = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) sec" : "\(seconds) sec"
        return clipSeconds < (end - start) - 0.5 ? "\(text), ads left out" : text
    }

    private var strip: some View {
        ClipStrip(episode: episode, window: window, cuts: cuts,
                  start: Binding(get: { start },
                                 set: { start = max($0, end - ClipExporter.maxLength) }),
                  end: Binding(get: { end },
                               set: { end = min($0, start + ClipExporter.maxLength) }))
            .accessibilityLabel("Clip from \(ClipExporter.stamp(start)) to \(ClipExporter.stamp(end))")
    }

    private var previewButton: some View {
        let playing = player.previewRange != nil
        return Button {
            if playing {
                player.endPreview()
            } else {
                player.startPreview(start...end, of: episode, skippingCuts: true)
            }
            Haptics.select()
        } label: {
            Label(playing ? "Stop" : "Play Clip", systemImage: playing ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("PlayClipButton")
    }

    // MARK: Actions

    private func setUp() {
        guard end == 0 else { return }
        start = max(0, around - 30)
        end = min(length, around + 30)
        // Paused while choosing, as the cut editor does: the episode playing
        // on underneath would move away from the clip.
        if player.isPlaying { player.pause() }
    }

    private func share() {
        player.endPreview()
        problem = nil
        // The audio on the phone (a video's copied-out sound track), or, not
        // downloaded yet, the feed's address: the export then fetches only
        // the part it needs.
        let onPhone = episode.analysableFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let source = onPhone ?? URL(string: episode.audioURL)
        guard let source else {
            problem = ClipExporter.ExportError.noAudio.localizedDescription
            return
        }
        let range = start...end
        let cuts = self.cuts
        let transcript = includeTranscript ? transcriptText(range: range, cuts: cuts) : nil
        let artworkURL = episode.artworkURL ?? episode.podcast?.artworkURL
        let show = episode.podcast?.title ?? ""
        let title = episode.title
        exporting = true
        progress = 0
        Task {
            var artwork: Data?
            if let artworkURL, let bytes = await ArtworkStore.shared.data(for: artworkURL) {
                artwork = ArtworkStore.downsample(bytes, to: 600)?.jpegData(compressionQuality: 0.85)
            }
            let request = ClipExporter.Request(source: source, range: range, cuts: cuts,
                                               showTitle: show, episodeTitle: title, artwork: artwork)
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try await ClipExporter.export(request) { value in
                        Task { @MainActor in progress = value }
                    }
                }.value
                exporting = false
                var items: [Any] = [file]
                if let transcript, !transcript.isEmpty { items.append(transcript) }
                shared = SharedClip(items: items)
                Haptics.success()
            } catch {
                exporting = false
                problem = error.localizedDescription
            }
        }
    }

    /// What was said in the clip, the cut parts left out, with the title
    /// on top so it reads on its own in a message.
    private func transcriptText(range: ClosedRange<Double>, cuts: [ClosedRange<Double>]) -> String {
        let words = ClipExporter.pieces(of: range, removing: cuts)
            .map { episode.words(in: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " … ")
        guard !words.isEmpty else { return "" }
        let heading = ClipExporter.title(show: episode.podcast?.title ?? "", episode: episode.title, range: range)
        return "\(heading)\n\n“\(words)”"
    }
}

/// The strip, in its own view because it reads the playhead while the clip
/// plays: read from the sheet's body, the whole list would rebuild five
/// times a second.
private struct ClipStrip: View {
    let episode: Episode
    let window: ClosedRange<Double>
    let cuts: [ClosedRange<Double>]
    @Binding var start: Double
    @Binding var end: Double
    @State private var player = PlayerEngine.shared

    var body: some View {
        TrimStrip(episode: episode,
                  window: window,
                  limits: window,
                  start: $start,
                  end: $end,
                  original: nil,
                  tint: Theme.accentHot,
                  playhead: player.previewRange != nil ? player.currentTime : nil,
                  locked: false,
                  // Moving an edge stops the clip playing, as in the editor.
                  onGrab: { _ in player.endPreview() },
                  onScrub: { _ in },
                  onZoom: { _ in },
                  zoom: 1,
                  onCommit: {})
            .overlay { CutShading(window: window, cuts: cuts).allowsHitTesting(false) }
    }
}

/// The finished clip for the share sheet.
private struct SharedClip: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// The system share sheet with any mix of items — the clip file and,
/// optionally, its words.
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The cuts inside the strip, faintly striped, so it's clear which parts
/// the clip will leave out.
private struct CutShading: View {
    let window: ClosedRange<Double>
    let cuts: [ClosedRange<Double>]

    var body: some View {
        Canvas { context, size in
            let span = max(0.001, window.upperBound - window.lowerBound)
            for cut in cuts {
                let lower = max(window.lowerBound, cut.lowerBound)
                let upper = min(window.upperBound, cut.upperBound)
                guard upper > lower else { continue }
                let x = size.width * CGFloat((lower - window.lowerBound) / span)
                let width = max(2, size.width * CGFloat((upper - lower) / span))
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                             with: .color(Theme.tint(for: .ad).opacity(0.28)))
            }
        }
    }
}
