import Foundation
import FoundationModels

// MARK: - What we ask the model for

/// Guided generation: the framework constrains decoding so the model
/// physically cannot return malformed JSON. This is why on-device
/// classification with a 3B model is usable at all.
@Generable
struct AdVerdict {
    @Guide(description: "true if this passage is an advertisement, sponsor read, promo code offer, or cross-promotion for another show")
    let isAd: Bool

    @Guide(description: "The brand or sponsor being advertised. Empty string if not an ad.")
    let sponsor: String

    @Guide(description: "How certain you are, from 0 to 100")
    let confidence: Int
}

struct DetectedAd {
    var start: Double
    var end: Double
    var sponsor: String
    var confidence: Int
}

enum AdDetectorError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "On-device AI isn't available: \(reason)"
        }
    }
}

actor AdDetector {

    private static let instructions = """
    You classify passages from podcast transcripts.

    Mark a passage as an ad if it is any of these:
    - a read-out advertisement for a product or service
    - a host reading a sponsor script, even in a casual conversational voice
    - a promo code, discount offer, or "go to brand dot com slash showname"
    - a cross-promotion for another podcast
    - a plug for the show's own membership, merchandise, or Patreon

    Do NOT mark a passage as an ad if it is:
    - the hosts discussing a company as part of the actual topic
    - news about a business
    - a guest describing their own work
    - the show's normal intro, outro, or credits

    Host-read ads are the hard case. The tell is usually a second-person
    pitch, a call to action, or a URL with a discount code — not the mere
    mention of a brand name.
    """

    /// Cheap keyword pass. Anything that looks nothing like an ad never
    /// reaches the model, which cuts inference calls by roughly an order of
    /// magnitude on a typical episode. Neighbours of a hit are kept too, so
    /// the run-up and tail of a sponsor read still get classified.
    private static let cues = [
        "sponsor", "sponsored", "promo code", "discount code", "coupon",
        "dot com slash", ".com/", "offer code", "free trial", "sign up at",
        "go to", "use code", "this episode is brought to you",
        "supported by", "our partners at", "check out", "terms apply",
        "percent off", "% off", "visit", "download the app"
    ]

    static func availability() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        @unknown default:
            return "unknown"
        }
    }

    /// Classify an episode's transcript windows and return merged ad ranges.
    func detect(windows: [TranscriptWindow],
                minimumConfidence: Int = 60,
                padding: Double = 0.4,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> [DetectedAd] {

        if let reason = Self.availability() {
            throw AdDetectorError.modelUnavailable(reason)
        }

        let candidates = Self.prefilter(windows)
        guard !candidates.isEmpty else { return [] }

        let session = LanguageModelSession(instructions: Self.instructions)
        var hits: [DetectedAd] = []

        for (n, index) in candidates.enumerated() {
            let window = windows[index]
            let prompt = """
            Passage from \(Int(window.start))s to \(Int(window.end))s:

            \(window.text)
            """

            do {
                // A fresh session per window keeps us far away from the
                // 4K context limit — these are independent classifications,
                // not a conversation, so there's nothing to carry forward.
                let reply = try await session.respond(to: prompt, generating: AdVerdict.self)
                let verdict = reply.content
                if verdict.isAd && verdict.confidence >= minimumConfidence {
                    hits.append(DetectedAd(start: window.start,
                                           end: window.end,
                                           sponsor: verdict.sponsor,
                                           confidence: verdict.confidence))
                }
            } catch {
                // One bad window shouldn't sink the episode. Skip it.
                continue
            }
            progress?(Double(n + 1) / Double(candidates.count))
        }

        return Self.merge(hits, padding: padding)
    }

    // MARK: - Prefilter

    private static func prefilter(_ windows: [TranscriptWindow]) -> [Int] {
        var keep = Set<Int>()
        for (i, w) in windows.enumerated() {
            let lower = w.text.lowercased()
            if cues.contains(where: { lower.contains($0) }) {
                keep.insert(i)
                if i > 0 { keep.insert(i - 1) }
                if i + 1 < windows.count { keep.insert(i + 1) }
            }
        }
        // Pre-roll and post-roll are ads far more often than not, so always
        // check the first and last 90 seconds regardless of keywords.
        for (i, w) in windows.enumerated() where w.start < 90 {
            keep.insert(i)
        }
        if let last = windows.last {
            for (i, w) in windows.enumerated() where w.end > last.end - 90 {
                keep.insert(i)
            }
        }
        return keep.sorted()
    }

    // MARK: - Merging

    /// Overlapping windows produce overlapping hits. Fuse anything that
    /// touches or nearly touches into one continuous cut.
    private static func merge(_ ads: [DetectedAd], padding: Double, gapTolerance: Double = 6) -> [DetectedAd] {
        guard !ads.isEmpty else { return [] }
        let sorted = ads.sorted { $0.start < $1.start }
        var out: [DetectedAd] = [sorted[0]]

        for ad in sorted.dropFirst() {
            let lastIndex = out.count - 1
            if ad.start <= out[lastIndex].end + gapTolerance {
                out[lastIndex].end = Swift.max(out[lastIndex].end, ad.end)
                out[lastIndex].confidence = Swift.max(out[lastIndex].confidence, ad.confidence)
                if out[lastIndex].sponsor.isEmpty { out[lastIndex].sponsor = ad.sponsor }
            } else {
                out.append(ad)
            }
        }

        // Pull the boundaries in slightly. Better to leak half a second of ad
        // than to eat the first word of the thing you actually wanted to hear.
        return out.map {
            var a = $0
            a.start += padding
            a.end -= padding
            return a
        }.filter { $0.end > $0.start + 1 }
    }
}
