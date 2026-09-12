import Foundation
import NaturalLanguage

/// What this listener actually likes, worked out on the device.
///
/// Every recommendation the app makes runs through Apple's on-device sentence
/// embedding — a Core ML model that ships with the OS — so nothing about what
/// you listen to has to leave the phone. That is the whole point. A
/// recommendation engine that needs a server needs your listening history on
/// that server, and an app whose reason to exist is stripping surveillance out
/// of podcasts should not ship one.
///
/// The model is a 512-dimension embedding of meaning rather than words, so a
/// show described as "two friends take the slowest possible route" lands near
/// one about "a walk across the country", without either one containing the
/// other's vocabulary. That is the part a keyword match cannot do.
enum TasteProfile {

    // MARK: - Types

    /// A direction in embedding space: the average of what you listen to,
    /// weighted by how much you actually listen to it.
    struct Vector: Sendable, Equatable {
        var values: [Double]

        var isEmpty: Bool { values.isEmpty }

        static func cosine(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return 0 }
            var dot = 0.0, normA = 0.0, normB = 0.0
            for i in a.indices {
                dot += a[i] * b[i]
                normA += a[i] * a[i]
                normB += b[i] * b[i]
            }
            guard normA > 0, normB > 0 else { return 0 }
            return dot / (normA.squareRoot() * normB.squareRoot())
        }
    }

    /// One show in your library, with the weight it carries and where it sits.
    struct Anchor: Sendable {
        var title: String
        var vector: [Double]
        var weight: Double
        /// Words from this show, for the fallback path.
        var tokens: Set<String>
    }

    /// The whole profile: the direction, and the shows that define it.
    struct Profile: Sendable {
        var vector: Vector
        var anchors: [Anchor]
        /// Genres you subscribe to, most common first. Used to decide which
        /// charts are worth fetching in the first place.
        var genres: [String]
        /// True when the embedding model was unavailable and everything here
        /// came from the word-overlap fallback.
        var usedFallback: Bool

        var isUsable: Bool { !anchors.isEmpty }
    }

    /// A candidate with its score and the reason for it.
    struct Suggestion: Sendable, Identifiable {
        var show: PodcastSearchResult
        var score: Double
        /// The show in your library this is closest to — what makes the
        /// recommendation explainable rather than magic.
        var becauseOf: String

        var id: Int { show.id }
    }

    // MARK: - Building the profile

    /// Embeds each subscribed show and averages them.
    ///
    /// Weighting is the difference between "shows you subscribed to once" and
    /// "shows you listen to". A show you have played for ten hours pulls the
    /// profile ten times harder than one you followed and never opened, and a
    /// brand-new subscription still counts for something so the profile can
    /// move.
    static func build(shows: [ShowSeed]) -> Profile {
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        var anchors: [Anchor] = []

        for show in shows {
            let text = describe(show)
            let vector = embedding?.vector(for: text) ?? []
            // Base weight of one hour, so a new subscription is not invisible
            // and a heavily played one does not swamp everything else. Square
            // root, because the tenth hour of a show says much less about you
            // than the first.
            let weight = (3600 + max(0, show.secondsListened)).squareRoot()
            anchors.append(Anchor(title: show.title,
                                  vector: vector,
                                  weight: weight,
                                  tokens: tokenise(text)))
        }

        let usedFallback = embedding == nil || anchors.allSatisfy { $0.vector.isEmpty }

        var mean: [Double] = []
        let usable = anchors.filter { !$0.vector.isEmpty }
        if let width = usable.first?.vector.count, width > 0 {
            mean = Array(repeating: 0, count: width)
            var total = 0.0
            for anchor in usable where anchor.vector.count == width {
                for i in 0..<width { mean[i] += anchor.vector[i] * anchor.weight }
                total += anchor.weight
            }
            if total > 0 {
                for i in 0..<width { mean[i] /= total }
            } else {
                mean = []
            }
        }

        // Genres by how much you listen, not how many you follow.
        var genreWeight: [String: Double] = [:]
        for show in shows where !show.category.isEmpty {
            genreWeight[show.category, default: 0] += 3600 + max(0, show.secondsListened)
        }
        let genres = genreWeight.sorted { $0.value > $1.value }.map(\.key)

        return Profile(vector: Vector(values: mean),
                       anchors: anchors,
                       genres: genres,
                       usedFallback: usedFallback)
    }

    // MARK: - Ranking

    /// Scores candidates and returns the best, with a reason attached.
    ///
    /// - Parameters:
    ///   - candidates: shows from the directory.
    ///   - profile: what this listener likes.
    ///   - excluding: feed addresses already subscribed to.
    ///   - limit: how many to return.
    static func rank(_ candidates: [PodcastSearchResult],
                     against profile: Profile,
                     excluding subscribed: Set<String>,
                     limit: Int = 12) -> [Suggestion] {
        guard profile.isUsable else { return [] }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)

        var seenFeeds = subscribed
        var scored: [Suggestion] = []

        for candidate in candidates {
            guard !seenFeeds.contains(candidate.feedURL) else { continue }
            seenFeeds.insert(candidate.feedURL)

            let text = describe(candidate)
            let vector = embedding?.vector(for: text) ?? []
            let tokens = tokenise(text)

            // Nearest anchor, not just the overall direction. The average of
            // a comedy show and a history show is a point that resembles
            // neither, so scoring only against the mean recommends bland
            // middles. Both terms count: the mean keeps it broadly right, the
            // nearest anchor keeps it specific, and the anchor is what the
            // reason line names.
            var bestAnchorScore = 0.0
            var bestAnchorTitle = ""
            for anchor in profile.anchors {
                let similarity: Double
                if !vector.isEmpty, !anchor.vector.isEmpty {
                    similarity = Vector.cosine(vector, anchor.vector)
                } else {
                    similarity = overlap(tokens, anchor.tokens)
                }
                if similarity > bestAnchorScore {
                    bestAnchorScore = similarity
                    bestAnchorTitle = anchor.title
                }
            }

            let meanScore: Double
            if !vector.isEmpty, !profile.vector.isEmpty {
                meanScore = Vector.cosine(vector, profile.vector.values)
            } else {
                meanScore = 0
            }

            var score = (bestAnchorScore * 0.65) + (meanScore * 0.35)

            // A small nudge for a genre you already listen to, and a smaller
            // one for an author you already follow. Not enough to override
            // the text, enough to break ties the way you would.
            if let genre = candidate.genre, profile.genres.contains(genre) {
                score += 0.05
            }
            if profile.anchors.contains(where: { $0.title.caseInsensitiveCompare(candidate.author) == .orderedSame }) {
                score += 0.03
            }

            guard score > 0 else { continue }
            scored.append(Suggestion(show: candidate,
                                     score: score,
                                     becauseOf: bestAnchorTitle))
        }

        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Input

    /// What the ranker needs from a subscribed show. A plain struct rather
    /// than the model object, so the work can leave the main actor.
    struct ShowSeed: Sendable {
        var title: String
        var author: String
        var category: String
        var summary: String
        var secondsListened: Double
    }

    // MARK: - Text

    private static func describe(_ show: ShowSeed) -> String {
        // Title first and summary last, trimmed. The embedding is a fixed
        // budget of attention; a 2,000-word show description spends all of it
        // on boilerplate about where to leave a review.
        [show.title, show.author, show.category, String(show.summary.prefix(400))]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    private static func describe(_ show: PodcastSearchResult) -> String {
        [show.title, show.author, show.genre ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// Words worth comparing, for when the embedding model is not there.
    ///
    /// Not a tokeniser in any interesting sense — it drops punctuation, case
    /// and the hundred words every podcast description contains.
    private static func tokenise(_ text: String) -> Set<String> {
        let stripped = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.components(separatedBy: .whitespacesAndNewlines)
        return Set(words.filter { $0.count > 3 && !stopWords.contains($0) })
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = Double(a.intersection(b).count)
        return shared / Double(min(a.count, b.count))
    }

    private static let stopWords: Set<String> = [
        "podcast", "podcasts", "episode", "episodes", "show", "shows", "with",
        "from", "each", "week", "weekly", "every", "your", "you", "this",
        "that", "they", "their", "about", "into", "more", "hosted", "host",
        "hosts", "join", "listen", "listening", "series", "audio", "talk",
        "talks", "conversation", "conversations", "available", "wherever",
        "subscribe", "follow", "instagram", "twitter", "http", "https", "www"
    ]
}
