import Foundation

// MARK: - Why a cut is there, in plain English
//
// Cheap, deterministic facts about each sentence, shown on What Was Skipped as
// the reason for a cut. Never a decision by themselves.
//
// This used to live in StructureDetector.swift, the pass-14 "one question per
// stretch" detector. The lab measured that detector worse than the sentence
// detector on every reference episode (DETECTION-AUDIT §11), it was never
// wired in, and only these facts were used; pass 17 kept them and removed the
// rest (D5).

enum SegmentEvidence: String, Sendable {
    case webAddress = "a web address"
    case promoCode = "a discount code"
    case smallPrint = "small print or terms"
    case sponsorOpener = "an ad opener (\"brought to you by\")"
    case knownSponsor = "a sponsor this show has used before"
    case notesSponsor = "a sponsor named in the show notes"
    case brandRepeated = "one product named again and again"
    case tourDates = "tour dates, tickets or merch"
    case patreon = "Patreon or a bonus feed"
    case otherShow = "another show or network named"
    case signOff = "a goodbye or credits"
    case welcome = "a welcome or theme"
    case silenceAtEdges = "a pause at both edges"
    case bothReadingsAgree = "two readings agreed"
    case readingsDisagreed = "two readings disagreed"
    case sponsorBlock = "SponsorBlock viewers marked this"
    case listenerConfirmed = "like a cut you confirmed"
    /// Pass 17: not in the host's ad-free copy of the episode.
    case insertedAtDownload = "added by the ad server when you downloaded it (the host's ad-free copy doesn't have it)"
    /// Pass 18: the same recording plays in another episode, or twice here.
    case repeatedAudio = "the same recording plays in another episode or elsewhere in this one"

    private static let addresses = [".com", ".co", ".net", ".org", "dot com", " slash ", ".edu", ".io"]
    private static let codes = ["promo code", "use code", "code word", "offer code", "discount code", "coupon"]
    private static let terms = ["terms apply", "restrictions apply", "offer details", "drink responsibly",
                                "must be 21", "21 plus", "safety information", "see site for", "while supplies",
                                "not available in", "individual results"]
    private static let openers = ["brought to you by", "sponsored by", "support for this", "this episode is",
                                  "today's episode is", "this message is", "take a quick moment and",
                                  "for supporting the show", "our awesome sponsors", "one of our sponsors",
                                  "thanks to our sponsor", "let's talk about"]
    private static let tour = ["tickets", "on tour", "tour dates", "live show", "merch", "tour", "stand up",
                               "on sale", "get your tickets", "see me live"]
    private static let patreonWords = ["patreon", "bonus episode", "bonus feed", "subscribers", "members only",
                                  "ad free version", "ad-free version", "early access", "supercast", "substack"]
    private static let shows = ["podcast network", "wherever you get your podcasts", "new episodes of",
                                "follow the show", "another show", "spotify", "apple podcasts", "youtube channel",
                                "download the", "app store"]
    private static let goodbyes = ["thanks for listening", "see you next", "goodbye everybody", "until next time",
                                   "produced by", "engineering by", "you've been listening to", "edited by"]
    private static let welcomes = ["welcome to", "you are listening to", "this is the", "coming up on"]

    /// The facts about each sentence, in order.
    static func facts(_ sentences: [Sentence], knownSponsors: [String], notesSponsors: [String],
                      duration: Double) -> [Set<SegmentEvidence>] {
        sentences.map { sentence in
            let lower = sentence.text.lowercased()
            let plain = AdDetector.normalise(lower)
            var found: Set<SegmentEvidence> = []
            if addresses.contains(where: { lower.contains($0) }) { found.insert(.webAddress) }
            if codes.contains(where: { lower.contains($0) }) { found.insert(.promoCode) }
            if terms.contains(where: { lower.contains($0) }) { found.insert(.smallPrint) }
            if openers.contains(where: { lower.contains($0) }) { found.insert(.sponsorOpener) }
            if knownSponsors.contains(where: { plain.contains($0) }) { found.insert(.knownSponsor) }
            if notesSponsors.contains(where: { plain.contains($0) }) { found.insert(.notesSponsor) }
            if tour.contains(where: { lower.contains($0) }) { found.insert(.tourDates) }
            if patreonWords.contains(where: { lower.contains($0) }) { found.insert(.patreon) }
            if shows.contains(where: { lower.contains($0) }) { found.insert(.otherShow) }
            if goodbyes.contains(where: { lower.contains($0) }), sentence.start > duration * 0.5 { found.insert(.signOff) }
            if welcomes.contains(where: { lower.contains($0) }), sentence.start < 300 { found.insert(.welcome) }
            return found
        }
    }
}
