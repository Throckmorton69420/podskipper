import Foundation

/// Small checks for where video is found, with sample feed snippets.
///
/// The project has no unit-test target (only UI tests), so these live in
/// the app. They are compiled in every build — so CI catches them breaking —
/// and run only in Debug builds, at launch, where a failure is printed and
/// stops the debugger. A Release build never runs them.
enum VideoSelfCheck {

    static func runInDebugBuilds() {
        #if DEBUG
        let problems = failures()
        for problem in problems { print("VideoSelfCheck: \(problem)") }
        assert(problems.isEmpty, "VideoSelfCheck failed: \(problems.joined(separator: "; "))")
        #endif
    }

    /// Every check that doesn't hold, in words. Empty when all is well.
    static func failures() -> [String] {
        var out: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { out.append(what) } }

        // 1. podcast:alternateEnclosure: every source read, HLS chosen even
        //    when the mp4 alternate is listed first and taller, and a source
        //    that is IPFS skipped.
        let alternate = video(in: item("""
            <enclosure url="https://example.com/ep.mp3" type="audio/mpeg" length="1"/>
            <podcast:alternateEnclosure type="video/mp4" height="1080" bitrate="4000000">
              <podcast:source uri="ipfs://abc"/>
              <podcast:source uri="https://example.com/ep-1080.mp4"/>
            </podcast:alternateEnclosure>
            <podcast:alternateEnclosure type="application/x-mpegURL" height="720">
              <podcast:source uri="https://example.com/ep/master.m3u8"/>
            </podcast:alternateEnclosure>
            <podcast:alternateEnclosure type="audio/opus">
              <podcast:source uri="https://example.com/ep.opus"/>
            </podcast:alternateEnclosure>
            """))
        expect(alternate.video == "https://example.com/ep/master.m3u8",
               "alternateEnclosure: expected the HLS source, got \(alternate.video ?? "nothing")")
        expect(alternate.audio == "https://example.com/ep.mp3", "alternateEnclosure: the audio should stay the episode")

        // 2. A source's own contentType wins over the enclosure's type.
        let sourceType = video(in: item("""
            <enclosure url="https://example.com/ep.mp3" type="audio/mpeg"/>
            <podcast:alternateEnclosure type="video/mp4" height="1080">
              <podcast:source uri="https://example.com/ep.mp4"/>
              <podcast:source uri="https://cdn.example.com/hls/index" contentType="application/vnd.apple.mpegurl"/>
            </podcast:alternateEnclosure>
            """))
        expect(sourceType.video == "https://cdn.example.com/hls/index",
               "podcast:source contentType: expected the HLS source, got \(sourceType.video ?? "nothing")")

        // 3. A namespace spelled with another prefix still counts.
        let aliased = video(in: item("""
            <enclosure url="https://example.com/ep.mp3" type="audio/mpeg"/>
            <pc:alternateEnclosure type="application/x-mpegURL">
              <pc:source uri="https://example.com/alias.m3u8"/>
            </pc:alternateEnclosure>
            """, namespaces: #"xmlns:pc="https://podcastindex.org/namespace/1.0""#))
        expect(aliased.video == "https://example.com/alias.m3u8", "aliased namespace: video not found")

        // 4. Two enclosures, video first: the audio is the episode, the
        //    video its picture.
        let twoEnclosures = video(in: item("""
            <enclosure url="https://example.com/ep.mp4" type="video/mp4"/>
            <enclosure url="https://example.com/ep.mp3" type="audio/mpeg"/>
            """))
        expect(twoEnclosures.audio == "https://example.com/ep.mp3" && twoEnclosures.video == "https://example.com/ep.mp4",
               "two enclosures: got audio \(twoEnclosures.audio), video \(twoEnclosures.video ?? "nothing")")

        // 5. A video-only episode stays a video episode, with no separate
        //    picture (its own file is the picture).
        let videoOnly = video(in: item(#"<enclosure url="https://example.com/ep.mp4" type="video/mp4"/>"#))
        expect(videoOnly.audio == "https://example.com/ep.mp4" && videoOnly.video == nil,
               "video enclosure: should be the episode itself")

        // 6. Media RSS: media:content video inside a media:group; an image
        //    and an audio copy are not pictures.
        let media = video(in: item("""
            <enclosure url="https://example.com/ep.mp3" type="audio/mpeg"/>
            <media:content url="https://example.com/ep.mp3" type="audio/mpeg"/>
            <media:content url="https://example.com/cover.jpg" medium="image"/>
            <media:group>
              <media:content url="https://example.com/ep-480.mp4" type="video/mp4" height="480"/>
              <media:content url="https://example.com/ep-720.mp4" medium="video" height="720"/>
            </media:group>
            """, namespaces: #"xmlns:media="http://search.yahoo.com/mrss/""#))
        expect(media.video == "https://example.com/ep-720.mp4",
               "media:content: expected the 720p file, got \(media.video ?? "nothing")")

        // 7. An audio-only feed (Stavvy's World and Megaphone's Bill Simmons
        //    feed as of 29 Sep 2026) has no picture.
        let audioOnly = video(in: item(#"<enclosure url="https://example.com/ep.mp3" type="audio/mpeg"/>"#))
        expect(audioOnly.video == nil, "audio-only item: should have no video")

        // 8. YouTube: Stavvy's World's uploads, as titled on its channel.
        let day: TimeInterval = 86_400
        let aired = Date(timeIntervalSince1970: 1_789_984_800)  // 21 Sep 2026, 10:00 UTC
        let uploads = [
            YouTubeVideo(id: "clip0000001", title: "Scared of strippers | Ep #198 - Nikki Glaser and JP McDade",
                         published: aired, duration: 58),
            YouTubeVideo(id: "full0000198", title: "Stavvy's World #198 - Nikki Glaser and JP McDade | Full Episode",
                         published: aired - 7 * day, duration: 6_200),
            YouTubeVideo(id: "full0000199", title: "Stavvy's World #199 - Are You Garbage? | Full Episode",
                         published: aired, duration: 5_800),
            YouTubeVideo(id: "clip0000199", title: "Kevin Ryan's worst gig | Are You Garbage? #199",
                         published: aired + day, duration: 600),
            YouTubeVideo(id: "vol13000000", title: "BONUS: McDade's Maniacs Vol. 13 w/ Someone",
                         published: aired - 7 * day, duration: 3_000),
        ]
        func youtube(_ title: String, number: Int = 0, bonus: Bool = false, duration: Double = 0, published: Date = aired) -> String? {
            YouTubeLink.match(episodeTitle: title, episodeNumber: number, isBonus: bonus, showTitle: "Stavvy's World",
                              published: published, duration: duration, in: uploads)?.id
        }
        expect(youtube("#199 - Are You Garbage?", number: 199, duration: 5_682) == "full0000199",
               "YouTube #199: \(youtube("#199 - Are You Garbage?", number: 199, duration: 5_682) ?? "no match")")
        expect(youtube("#198 - Nikki Glaser and JP McDade", number: 198, duration: 6_130, published: aired - 7 * day) == "full0000198",
               "YouTube #198: should be the full episode, not the clip")
        // Without a length the full episode still wins on "Full Episode".
        expect(youtube("#198 - Nikki Glaser and JP McDade", published: aired - 7 * day) == "full0000198",
               "YouTube #198 without a length: should be the full episode")
        expect(youtube("Bonus #199 - McDade's Maniacs Vol. 14 w/ Noah Savage [PATREON PREVIEW]", bonus: true) == nil,
               "YouTube bonus: Vol. 14 must not match Vol. 13")
        expect(youtube("#199", number: 199) == "full0000199", "YouTube: a number-only title should match on the number")
        expect(YouTubeLink.numberIn("Episode 42: Hello") == 42 && YouTubeLink.numberIn("Ep. #7 - x") == 7,
               "YouTube: episode numbers not read")

        return out
    }

    // MARK: Helpers

    private static func item(_ body: String, namespaces: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" \
        xmlns:podcast="https://podcastindex.org/namespace/1.0" \(namespaces)>
          <channel><title>Sample</title>
            <item><title>Sample episode</title><guid>sample-1</guid>
              \(body)
            </item>
          </channel>
        </rss>
        """
    }

    private static func video(in xml: String) -> (audio: String, video: String?) {
        guard let feed = try? FeedParser.parse(Data(xml.utf8)), let first = feed.items.first else { return ("", nil) }
        return (first.audioURL, first.videoURL)
    }
}
