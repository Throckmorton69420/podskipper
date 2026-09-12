import SwiftUI

/// Shown once, on first launch.
///
/// This app works differently from every other podcast player: episodes have
/// to be processed before ads can be skipped, and that takes real time. A
/// person who doesn't know that will hit Play, hear an ad, and conclude the
/// app is broken. Three screens is cheaper than that.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(symbol: "waveform",
             title: "Ads removed, not muted",
             body: "PodSkipper transcribes each episode on your iPhone, works out where the advertising is — including host-read sponsor segments — and jumps them during playback."),
        Page(symbol: "iphone.gen3",
             title: "Nothing leaves your phone",
             body: "Transcription and ad detection both run on-device using Apple Intelligence. No account, no server, no listening history sitting on someone else's computer."),
        Page(symbol: "moon.zzz",
             title: "It works while you sleep",
             body: "Processing an hour of audio takes a few minutes of real work. Plug your iPhone in overnight and it handles the queue on its own. New episodes are ready by morning.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: pages[index].symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.accentGradient)
                        Text(pages[index].title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(pages[index].body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 34)
                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page)

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    UserDefaults.standard.set(true, forKey: "seenOnboarding")
                    dismiss()
                }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accentGradient, in: Capsule())
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 26)

            Button("Skip") {
                UserDefaults.standard.set(true, forKey: "seenOnboarding")
                dismiss()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 18)
        }
        .background(Theme.background.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    static var hasBeenSeen: Bool {
        UserDefaults.standard.bool(forKey: "seenOnboarding")
    }
}
