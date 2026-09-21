import SwiftUI
import WebKit

/// Finds this episode's video on the show's YouTube channel, and offers it.
/// Shown in the player only when there is a match.
struct YouTubeWatchButton: View {
    let episode: Episode
    var onWatch: (YouTubeVideo) -> Void

    @State private var video: YouTubeVideo?

    var body: some View {
        // A ZStack with a zero-size clear view, not a `Group`: a Group with
        // nothing in it never appears, so its `.task` never ran and the
        // button could never find anything to show.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let video {
                Button { onWatch(video) } label: {
                    Label("Watch on YouTube", systemImage: "play.rectangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("WatchOnYouTube")
                .transition(.opacity)
            }
        }
        .task(id: episode.guid) { await find() }
    }

    private func find() async {
        video = nil
        guard let show = episode.podcast, !show.youtubeChannel.isEmpty else { return }
        let videos = await YouTubeLink.recentVideos(channelID: show.youtubeChannel)
        let found = YouTubeLink.match(episodeTitle: episode.title, episodeNumber: episode.episodeNumber,
                                      isBonus: episode.isBonus, showTitle: show.title,
                                      published: episode.publishedAt, in: videos)
        withAnimation { video = found }
    }
}

/// YouTube's own embedded player, full screen in a sheet.
///
/// PodSkipper's audio is paused while it is open. Closing it reads where the
/// video had got to and puts PodSkipper's ad-free audio at the same moment
/// (allowing for the ads the audio has and the video doesn't), then carries on
/// playing if it was playing before.
struct YouTubeWatchView: View {
    let episode: Episode
    let video: YouTubeVideo
    /// Where the video should start, in the video's own time.
    let startAt: Double
    var onClose: (Double?) -> Void

    @State private var web = YouTubeWeb()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                YouTubePlayerView(web: web, videoID: video.id, start: Int(startAt))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("YouTubePlayer")
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .font(.headline)
                    Text("Playing in YouTube's own player, from the show's channel. YouTube's ads play here and PodSkipper can't skip them; Smart Speed and the other audio settings don't apply. Close to go back to the ad-free audio at the same moment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
                }
            }
        }
        .presentationBackground(.black)
        .interactiveDismissDisabled(false)
        .onDisappear { onCloseOnce(nil) }
    }

    @State private var closed = false

    private func close() {
        Task {
            let at = await web.currentTime()
            onCloseOnce(at)
            dismiss()
        }
    }

    private func onCloseOnce(_ time: Double?) {
        guard !closed else { return }
        closed = true
        onClose(time)
    }
}

/// Holds the web view so the sheet can ask it the time.
@MainActor
@Observable
final class YouTubeWeb {
    fileprivate var view: WKWebView?

    func currentTime() async -> Double? {
        guard let view else { return nil }
        let value = try? await view.evaluateJavaScript("now()")
        if let seconds = value as? Double, seconds >= 0 { return seconds }
        return nil
    }
}

struct YouTubePlayerView: UIViewRepresentable {
    let web: YouTubeWeb
    let videoID: String
    let start: Int

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        web.view = view
        // YouTube's documented IFrame Player API. The page is given an https
        // origin because YouTube refuses to play embeds that arrive with no
        // referring site at all.
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#p{position:absolute;top:0;left:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('p', {
            width: '100%', height: '100%', videoId: '\(videoID)',
            playerVars: { playsinline: 1, start: \(max(0, start)), autoplay: 1, rel: 0, origin: 'https://podskipper.app' }
          });
        }
        function now() { return (player && player.getCurrentTime) ? player.getCurrentTime() : -1; }
        </script></body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://podskipper.app/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
