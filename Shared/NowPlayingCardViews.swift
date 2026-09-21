import AppIntents
import SwiftUI
import UIKit

// The Lock Screen card's parts. In the shared folder so the app can draw the
// same card in Settings as a preview of what the Lock Screen shows.

func nowPlayingMetaLine(_ state: NowPlayingAttributes.ContentState) -> String {
    var parts = [state.show]
    if let published = state.published {
        parts.append(published.formatted(.dateTime.month(.abbreviated).day()))
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
}

func nowPlayingSkippedLine(_ state: NowPlayingAttributes.ContentState) -> String? {
    let seconds = Int(state.secondsSkipped.rounded())
    guard seconds > 0 else { return nil }
    return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s of ads removed" : "\(seconds)s of ads removed"
}

struct NowPlayingCover: View {
    let data: Data?
    var size: CGFloat
    var corner: CGFloat = 10

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "waveform").foregroundStyle(.black.opacity(0.7)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Moves by itself while playing: the system animates a progress view
/// between two dates, so the app never has to update the card to move it.
struct NowPlayingProgressRow: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        let rate = max(0.5, state.rate)
        let start = Date().addingTimeInterval(-state.elapsed / rate)
        let end = start.addingTimeInterval(max(1, state.duration) / rate)
        VStack(spacing: 3) {
            if state.isPlaying, state.duration > 0 {
                ProgressView(timerInterval: start...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(.pink)
            } else {
                ProgressView(value: min(state.elapsed, max(1, state.duration)), total: max(1, state.duration))
                    .tint(.pink)
            }
            HStack {
                if let line = nowPlayingSkippedLine(state) {
                    Label(line, systemImage: "scissors")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if state.isPlaying, let endsAt = state.endsAt {
                    Text(endsAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 60, alignment: .trailing)
                } else if state.duration > 0 {
                    Text("-" + clock(max(0, state.duration - state.elapsed)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct NowPlayingControls: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 28) {
            Button(intent: CardSkipBackIntent()) {
                Image(systemName: "gobackward.15").font(.title3)
            }
            Button(intent: CardPlayPauseIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Button(intent: CardSkipForwardIntent()) {
                Image(systemName: "goforward.30").font(.title3)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct NowPlayingCard: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                NowPlayingCover(data: state.artwork, size: 56, corner: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlayingMetaLine(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                NowPlayingControls(isPlaying: state.isPlaying)
                    .scaleEffect(0.9)
            }
            NowPlayingProgressRow(state: state)
        }
        .padding(14)
    }
}
