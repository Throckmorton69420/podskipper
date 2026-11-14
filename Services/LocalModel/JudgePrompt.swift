import Foundation

// The ad-finding prompt, ported from Tools/DetectionLab/gemini_bench.py.
//
// RULES, the labels (KIND), the answer schema, the line format and the
// edge-snapping (`anchor`) are copied, not paraphrased: that wording is what
// was benchmarked, and a model's answers move when the words do. The schema
// is the plain JSON Schema the bench sends to open models (its
// `lower_schema(SCHEMA)`), and the system prompt is built the way the bench
// builds it for them: RULES, then "Answer with JSON only, matching this
// schema: " and the schema.

/// A label the model may give a part. Raw values are the bench's KIND keys.
enum JudgeLabel: String, CaseIterable, Codable, Sendable {
    case paidAd = "PAID_AD"
    case hostReadAd = "HOST_READ_AD"
    case networkPromo = "NETWORK_PROMO"
    case selfPromo = "SELF_PROMO"
    case guestPlug = "GUEST_PLUG"
    case intro = "INTRO"
    case outro = "OUTRO"
    case credits = "CREDITS"
    case recurringSegment = "RECURRING_SEGMENT"
    case mockAd = "MOCK_AD"
    /// Pass 31: "this is the show". Never asked for, but allowed by the
    /// short answer's grammar: in the Mac lab, models that judged a whole
    /// stretch to be the show wrote it as one part labelled SHOW (or with
    /// no label). Held to a list of cut labels, the grammar would have made
    /// them pick one — a whole stretch cut. It is ignored, not a veto.
    case show = "SHOW"

    /// The bench's KIND value: the app's segment kind by name, or nil for
    /// parts that are the show and must be kept.
    var kindName: String? {
        switch self {
        case .paidAd, .hostReadAd: return "ad"
        case .networkPromo:        return "crossPromo"
        case .selfPromo, .guestPlug: return "selfPromo"
        case .intro:               return "intro"
        case .outro:               return "outro"
        case .credits:             return "credits"
        case .recurringSegment, .mockAd, .show: return nil
        }
    }

    /// The app's own kind. nil for the kept labels, and for CREDITS, which
    /// the bench names "credits" and the app has no kind for yet.
    var segmentKind: SegmentKind? { kindName.flatMap(SegmentKind.init(rawValue:)) }
}

/// Audio evidence the phone already has for a stretch of the episode.
struct EvidenceSpan: Sendable, Hashable {
    enum Kind: String, Sendable {
        /// Inserted by the host's ad server (not in the ad-free copy). «I»
        case inserted = "I"
        /// The same recording plays elsewhere. «R»
        case repeated = "R"
    }
    var start: Double
    var end: Double
    var kind: Kind
}

/// One part the model found, on the app's transcript lines.
struct JudgedPart: Sendable, Hashable {
    /// Indexes into the `lines` given to `judge`, inclusive.
    var firstLine: Int
    var lastLine: Int
    var label: JudgeLabel
    var sponsor: String
    var funny: Bool
    /// 0–100, as the model gave it.
    var confidence: Int
    var why: String

    /// Whether this is something to cut (an ad, promo, intro…) rather than a
    /// part that is the show and marked so it is kept.
    var isCut: Bool { label.kindName != nil }
}

enum JudgePrompt {
    static let rules = #"""
You mark the commercial and structural parts of one podcast episode for an ad-skipping app.
The transcript comes from speech recognition (spelling of names and brands can be wrong), one numbered line per
recognized sentence: "<line> <text>", with the time "[h:mm:ss]" shown on every 15th line. Read the whole episode first; judge every part by what it is doing
in context, never by keywords alone.

Labels (list only these; everything not listed is the show and is kept):
- PAID_AD: a sponsor's advertisement that is produced or pre-recorded: announcer or scripted copy, often inserted
  into the file (abrupt change of topic, voice or sound, back-to-back spots, the same copy replayed), pre-rolls at
  the very start, post-rolls at the very end.
- HOST_READ_AD: a host (or guest) reading or riffing a paid sponsorship in their own voice. It starts at the
  hand-off ("let's take a quick break", "this episode is brought to you by", "our friends at", "speaking of…")
  and ends at the last line about the product, its offer, code or web address, before the conversation truly
  returns. Riffs and jokes about the sponsor's product inside the read belong to the ad.
- NETWORK_PROMO: a promotion or trailer for another podcast or program that is not this show's own (network
  cross-promos, "if you like this show you'll love…", produced trailers).
- SELF_PROMO: the hosts promoting their own things: tour dates, tickets, specials, Patreon or bonus/premium feed,
  merch, their YouTube/socials, their other shows, "rate and review", live-show plugs.
- GUEST_PLUG: the guest's own work promoted: the guest's tour dates, special, book, podcast, socials, website
  (commonly at the start when introduced or at the end before goodbye).
- INTRO: the produced opening: theme music, stock opener or announcer intro. The hosts simply saying hello and
  starting to talk is the show, not INTRO.
- OUTRO: the produced closing: sign-off lines and theme after the conversation has ended.
- CREDITS: production credits (produced by, edited by, music by, executive producers).
- RECURRING_SEGMENT: a recurring produced bit of the show itself (a named segment, a jingle for a regular bit).
- MOCK_AD: a joke that imitates an ad, a fake or parody sponsor, or a bit about a brand that nobody is paying
  for. These are the show.

Hard rules:
1. Talking about a company, product, brand, price or website is NOT an ad by itself. People discuss brands
   constantly (restaurants, apps, drinks, cars, stores). An ad needs affirmative evidence of a paid relationship:
   a sponsorship hand-off, an offer or promo code, "go to …com/<show>", "use code", "terms apply", "sponsored by",
   copy that sells rather than converses, or a produced spot. When in doubt between an ad and the show, it is the show.
2. A story that mentions tickets, a show, a tour or a book in passing is the show. SELF_PROMO/GUEST_PLUG needs an
   actual ask or plug: dates and cities, "get tickets", "go see him", "link in the description", "subscribe to…".
3. A real paid read that is funny is still HOST_READ_AD; set funny=true when the hosts turn the read into a
   genuinely comedic bit. A fake sponsor or a parody is MOCK_AD.
4. Be exhaustive: check the very first and very last lines, every mid-roll break, and back-to-back sponsors.
   Give each sponsor its own entry, and each distinct plug its own entry.
5. Be tight: first_line is the first line of the part, last_line its last line. Don't swallow the conversation
   before or after. Paid spots rarely exceed 3 minutes each; a plug is usually under a minute.
6. Sponsors named in the show notes probably advertise in this episode; use that as a hint, not as proof.
8. Audio evidence marks: «I» = the podcast host's ad server inserted this audio (measured exactly: it is not in
   the ad-free copy) — almost always PAID_AD or NETWORK_PROMO. «R» = this exact recording also plays elsewhere
   (in another episode or twice in this one) — typical of produced ads, promos, intros and outros, but a cold-open
   tease that replays a later moment of the show is also «R» and is the show. Unmarked lines have no audio
   evidence either way; host-read ads are usually unmarked.
7. Include MOCK_AD and RECURRING_SEGMENT entries only when a reasonable listener might have mistaken them for an
   ad; they tell the app what NOT to cut.

"""#

    static let schema = #"{"type": "object", "properties": {"parts": {"type": "array", "items": {"type": "object", "properties": {"first_line": {"type": "integer"}, "last_line": {"type": "integer"}, "first_words": {"type": "string", "description": "the first 8 words of first_line, copied exactly"}, "last_words": {"type": "string", "description": "the first 8 words of last_line, copied exactly"}, "label": {"type": "string", "enum": ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "RECURRING_SEGMENT", "MOCK_AD"]}, "sponsor": {"type": "string", "description": "brand or thing promoted, empty if none"}, "funny": {"type": "boolean"}, "confidence": {"type": "integer", "description": "0-100"}, "why": {"type": "string", "description": "one short sentence of evidence"}}, "required": ["first_line", "first_words", "last_line", "last_words", "label", "sponsor", "funny", "confidence", "why"], "additionalProperties": false}}}, "required": ["parts"], "additionalProperties": false}"#

    /// The system prompt, as the bench sends it to open models.
    static var system: String { rules + "\nAnswer with JSON only, matching this schema: " + schema }

    // MARK: Pass 30 — prompts sized for phone models

    /// How much prompt a model gets (pass 30, his 5 Oct question about
    /// per-model prompts). The benchmarked prompt is ~1,100 tokens before
    /// any transcript, and its answer format costs ~90 tokens a part (two
    /// eight-word quotes and a sentence of reasons); on his iPhone Core AI
    /// Qwen3 4B wrote at ~8 tokens/s and spent ~23 of its 25 minutes on Bad
    /// Friends writing answers. Most Core AI models on iPhone get only
    /// 1,024 tokens in all (an iOS compiler bug caps their memory).
    enum Profile: String, Sendable {
        /// The benchmarked rules and answer, word for word (MLX).
        case full
        /// The benchmarked rules; a short answer (five fields a part, no
        /// quotes, no reasons, at most eight parts) written without spaces.
        case lean
        /// A short version of the rules and the short answer, for models
        /// that hold ~1,000 tokens in all.
        case compact
        /// Pass 31: the short answer with a few words of evidence written
        /// before the label. In the Mac lab Gemma 4 E4B scored 89 % on the
        /// Hard test this way against 78 % without it; Qwen3.5 4B did no
        /// better with it. Chosen per model family (`ModelPromptPlan`).
        case leanReasoned
        /// Pass 38: for a model that holds ~1,000 tokens in all (Core AI's
        /// GPU-pipelined engine on iPhone, apple/coreai-models#124). Rules
        /// under 140 tokens and a three-part answer without "funny", so a
        /// part holds 650–700 tokens of transcript — a whole host read, from
        /// the hand-off to the code, instead of half of one.
        case candidate
        /// Pass 43: the labels as a listener hears them (`listenerRules`),
        /// the lean answer, and the task said again after the stretch
        /// (`reminder`). Mac lab, Qwen3.5 4B 4-bit on 14 of his episodes
        /// hand-labelled from his 19 Oct export, the app's own focus:
        /// ad time heard 57.9 → 48.3 s an hour, show cut 4.1 → 3.6 s an
        /// hour, breaks missed 26 → 21 of 128, wrong kinds 17 → 11, edges
        /// within 5.5 s / 3.3 s (were 7.1 / 5.8). Measured for that family
        /// only (`ModelPromptPlan`).
        case listener
        /// Pass 44: `listener` plus the two places his labelled episodes show
        /// every model losing time — the episode's edges (theme, network
        /// ident, the plugs given while saying goodbye, the closing music)
        /// and a round of plugs (`edgeRules`).
        case listenerEdges
        /// Pass 44: for models held to ~2,000 tokens (Core AI on his iPhone):
        /// the listener's labels and the rules that matter most, in about 230
        /// tokens (`compactListenerRules`), a four-part answer, and the task
        /// said again after the stretch.
        case compactListener
        /// Pass 45: Core AI MiniCPM5 2B at ~2,000 tokens (measured with its
        /// own Core AI build on the Mac): the listener's short labels, and
        /// that a part is short — it marked whole stretches as one read.
        case compactTight

        /// Pass 63: for small models that find where a break starts but
        /// not where it ends (Liquid's LFM3 1.7B in the Mac lab marked the
        /// first line of each ad as a whole part): how to go through the
        /// lines is spelled out — one entry each time something to skip
        /// begins, its last line where the conversation comes back, entries
        /// that never overlap — and the empty answer isn't quoted, which
        /// small models copy. LFM3 1.7B on the Basic sample, its own answer:
        /// 6–36 % with the other rules, 94 % with these; on Hard it finds half the breaks (27 %) and cuts none of the show.
        case guided

        /// Prompt context below this gets the compact rules (and below
        /// ~1,200 tokens the candidate rules).
        static func forContext(_ tokens: Int) -> Profile {
            guard tokens > 0 else { return .lean }
            if tokens <= 1_200 { return .candidate }
            return tokens < 3_000 ? .compact : .lean
        }

        var system: String {
            switch self {
            case .full: return JudgePrompt.system
            case .lean: return JudgePrompt.leanRules + JudgePrompt.answerFormat
            case .compact: return JudgePrompt.compactRules + JudgePrompt.answerFormat
            case .leanReasoned: return JudgePrompt.leanRules + JudgePrompt.answerFormatReasoned
            case .candidate: return JudgePrompt.candidateRules
            case .listener: return JudgePrompt.listenerRules + JudgePrompt.answerFormat
            case .listenerEdges: return JudgePrompt.listenerRules + JudgePrompt.edgeRules + JudgePrompt.answerFormat
            case .compactListener: return JudgePrompt.compactListenerRules + JudgePrompt.answerFormat
            case .compactTight: return JudgePrompt.compactTightRules + JudgePrompt.answerFormat
            // As measured, word for word: no answer format after it (the
            // answer is held to the form by the grammar), no MOCK_AD label —
            // with either added it found fewer breaks in the lab.
            case .guided: return JudgePrompt.guidedRules
            }
        }
        /// Pass 43: said after the stretch, where a small model reads it last.
        var reminder: String? {
            if self == .compactTight { return JudgePrompt.tightReminder }
            if self == .guided { return JudgePrompt.guidedReminder }
            return [.listener, .listenerEdges, .compactListener].contains(self) ? JudgePrompt.listenerReminder : nil
        }
        var schema: String {
            switch self {
            case .full: return JudgePrompt.schema
            case .lean, .listener, .listenerEdges, .guided: return JudgePrompt.leanSchema(maxParts: 8)
            case .compact, .compactListener, .compactTight: return JudgePrompt.leanSchema(maxParts: 4)
            case .leanReasoned: return JudgePrompt.reasonedSchema(maxParts: 8)
            case .candidate: return JudgePrompt.candidateSchema(maxParts: 3)
            }
        }
        /// Tokens kept free for the answer.
        var answerTokens: Int {
            switch self {
            case .full: return 640
            case .lean, .listener, .listenerEdges, .guided: return 320
            // Pass 64 (his 13 Nov export: Core AI Mistral 7B v0.3 and LFM2.5
            // 1.2B stopped on Hard at "its 170-token answer limit"): room
            // for a whole list. Core AI's 1,024-token bundles take less
            // (`CoreAIAnswerRoom`), so their stretches don't shrink to nothing.
            case .compact, .compactListener, .compactTight: return 512
            case .leanReasoned: return 480
            case .candidate: return 110
            }
        }
        var notesLimit: Int {
            switch self {
            case .candidate: return 0
            case .compact, .compactListener, .compactTight: return 300
            default: return 900
            }
        }
        var correctionsLimit: Int {
            switch self {
            case .candidate: return 160
            case .compact, .compactListener, .compactTight: return 300
            default: return 1_200
            }
        }
    }

    /// The benchmarked rules without the keep-labels that invite a model to
    /// label every line (Qwen3 4B marked whole windows RECURRING_SEGMENT),
    /// plus the one thing small models most need told: most of an episode is
    /// the show.
    static var leanRules: String {
        rules
            .replacingOccurrences(of: "- RECURRING_SEGMENT: a recurring produced bit of the show itself (a named segment, a jingle for a regular bit).\n", with: "")
            .replacingOccurrences(of: "7. Include MOCK_AD and RECURRING_SEGMENT entries only when a reasonable listener might have mistaken them for an\n   ad; they tell the app what NOT to cut.\n",
                                  with: "7. Include MOCK_AD entries only when a reasonable listener might have mistaken them for an ad; they tell the app\n   what NOT to cut.\n")
            + "9. Most of any stretch of an episode is the show. When these lines hold no ad, promo, intro or outro, answer {\"parts\":[]}.\n"
    }

    /// Pass 43: the rules of `Profile.listener` — labels by what a listener
    /// would skip, the confusions his exports show spelled out (a produced
    /// spot for a film or a bank called a network promo; a guest's special or
    /// the hosts' dates at the goodbye left in; theme songs and credits left
    /// in), as measured in the Mac lab (`Tools/MLXLab` LabPrompts `v2r`),
    /// plus the audio marks the app adds and the lab's stretches didn't carry.
    static let listenerRules = #"""
You mark the parts of a podcast episode that a listener would want to skip: paid advertising, plugs, and the show's produced opening and closing. The transcript comes from speech recognition (names and brands may be misspelled), one numbered line per sentence. Judge each part by what it is doing in context, never by a single word.

Labels (list only these; everything not listed is the show and is kept):
- PAID_AD: an advertisement for any product or service (apps, banks, insurance, food, drinks, medicine, films, TV series, games), produced or recorded: announcer copy, a jingle, back-to-back spots, "support for this podcast comes from", "this episode is brought to you by", pre-rolls at the very start and post-rolls at the very end.
- HOST_READ_AD: a host (or guest) reading or riffing a paid sponsorship in their own voice, from the hand-off ("let's take a quick break", "our friends at", "speaking of…") to the last line about the product, its offer, code or web address. Jokes inside the read belong to the read.
- NETWORK_PROMO: a trailer or promo for another podcast or radio show ("check out my show…", "listen wherever you get your podcasts"). An ad for a film, TV series or app is PAID_AD, not this.
- SELF_PROMO: the hosts promoting their own things: tour dates, cities, tickets, their website, merch, Patreon, a paid or premium subscription, bonus episodes, their other shows, their socials or YouTube, "rate and review", "subscribe".
- GUEST_PLUG: the guest's own work plugged: their special, tour dates, book, podcast, website or socials — usually when they are introduced or at the goodbye ("check out his new special", "where can people find you?").
- INTRO: the produced opening: a theme song or jingle, an announcer, "you're listening to the … network".
- OUTRO: the produced closing: the closing theme song or music, a sign-off announcer after the conversation has ended.
- CREDITS: production credits read out: produced by, edited by, mixed by, music by, executive producer, thanks to.
- MOCK_AD: a joke ad, a parody sponsor, or a bit about a brand nobody paid for. It is the show; list it only when it could be mistaken for an ad. A made-up product, an offer of nothing ("use code OUCH for nothing off"), or the hosts wishing they had a sponsor is MOCK_AD, never HOST_READ_AD.

Rules:
1. Naming a brand, a restaurant, an app, a film or a website in conversation is NOT an ad. An ad needs a hand-off, an offer, a code, a "go to …com", "terms apply", or copy that sells rather than converses. When unsure between an ad and the show, it is the show.
2. A story that mentions a tour or a special in passing is the show. SELF_PROMO and GUEST_PLUG need an actual plug: dates, cities, "get tickets", "go see", "check out", a web address.
3. Be exhaustive: give each sponsor, each spot and each plug its own entry, including short ones (a five-second plug counts), and check the first and last lines of the stretch.
4. Be tight: first_line is where the part begins and last_line where it ends. Do not swallow the conversation before or after it.
5. Most of any stretch is the show. When these lines hold nothing to skip, answer {"parts":[]}.
6. A line marked «I» is audio the host's ad server inserted (it is not in the ad-free copy): almost always PAID_AD or NETWORK_PROMO. «R» is a recording that also plays elsewhere: typical of produced ads, promos, intros and outros, but a cold open that replays a later moment is the show. Most lines carry no mark either way.

"""#

    /// Pass 44: `Profile.listenerEdges`' rules after the listener's (Mac lab
    /// `v3`).
    static let edgeRules = #"""
7. The episode's edges. Before the hosts start talking, a theme song, an announcer or a network ident ("you're listening to the … network") is INTRO, and any ad before or after it is PAID_AD. When the hosts say goodbye, the goodbye itself is the show, but the plugs given while signing off (their dates, the guest's special, book, podcast or website, "follow us", "subscribe") are SELF_PROMO or GUEST_PLUG, the closing theme or music is OUTRO, and any ad after it is PAID_AD.
8. A round of plugs ("let's do some plugs", "what are you plugging?", "where can people find you?") is one SELF_PROMO or GUEST_PLUG entry per person, from their first plug to their last, with the short asides between them.

"""#

    /// Pass 44: `Profile.compactListener`'s rules (Mac lab `cplus`).
    static let compactListenerRules = #"""
Mark what a listener of this podcast would skip, in part of its transcript ("<number> <text>").
Labels:
- PAID_AD: any advertisement: a produced spot, a jingle, "brought to you by", "support for this podcast comes from", ads for apps, banks, films or TV series, pre-rolls and post-rolls.
- HOST_READ_AD: a host reading a sponsor, from the hand-off ("let's take a break", "our friends at") to the last line of its offer, code or web address; jokes inside it belong to it.
- NETWORK_PROMO: a promo for another podcast or radio show.
- SELF_PROMO: the hosts' own tour dates, tickets, website, merch, Patreon, subscription or socials.
- GUEST_PLUG: the guest's own special, tour, book, podcast or website.
- INTRO, OUTRO: the produced opening or closing: theme song, announcer, network ident. CREDITS: "produced by…".
Rules: a brand named in conversation is not an ad; an ad needs a hand-off, an offer, a code or a web address. Plugs given at the goodbye are SELF_PROMO or GUEST_PLUG; the goodbye itself is the show. Give each spot and each plug its own entry, tight to its first and last line. Most stretches are the show: then answer {"parts":[]}.

"""#

    /// Pass 45: `Profile.compactTight`'s rules (Core AI lab `mc1`).
    static let compactTightRules = #"""
Mark what a listener of this podcast would skip, in part of its transcript ("<number> <text>").
Labels:
- PAID_AD: any advertisement: a produced spot, a jingle, "brought to you by", "support for this podcast comes from", ads for apps, banks, films or TV series, pre-rolls and post-rolls.
- HOST_READ_AD: a host reading a sponsor, from the hand-off ("let's take a break", "our friends at") to the last line of its offer, code or web address; jokes inside it belong to it.
- NETWORK_PROMO: a promo for another podcast or radio show.
- SELF_PROMO: the hosts' own tour dates, tickets, website, merch, Patreon, subscription or socials.
- GUEST_PLUG: the guest's own special, tour, book, podcast or website.
- INTRO, OUTRO: the produced opening or closing: theme song, announcer, network ident. CREDITS: "produced by…".
Rules: a brand named in conversation is not an ad; an ad needs a hand-off, an offer, a code or a web address. A part is short: a spot or a read is usually 3 to 40 lines. Never mark the whole stretch as one part. Start each part at its hand-off or first selling line and end it at its last line about the offer, code or web address; the talk before and after is the show. Plugs given at the goodbye are SELF_PROMO or GUEST_PLUG; the goodbye itself is the show. Give each spot and each plug its own entry. Most stretches are the show: then answer {"parts":[]}.

"""#

    /// Pass 63: `Profile.guided`'s rules (Mac lab `small1`, LFM3 1.7B).
    static let guidedRules = #"""
You find what a listener would skip in part of a podcast transcript: advertising, plugs, and the produced opening and closing. Lines are numbered: "<number> <text>".

Labels:
- PAID_AD: a recorded advertisement: announcer copy, a jingle, a web address, small print ("terms apply", "member FDIC"). Usually 3 to 8 lines.
- HOST_READ_AD: a host reading a sponsor's ad. It starts at "this episode is brought to you by" or "supported by" and runs to the last line with the offer, code or web address. Usually 8 to 40 lines.
- NETWORK_PROMO: a promo for another podcast.
- SELF_PROMO: the hosts' own tour dates, tickets, Patreon, merch or socials.
- GUEST_PLUG: the guest's own special, tour, book, podcast or website.
- INTRO, OUTRO: the produced opening or closing. CREDITS: "produced by…", "edited by…".

How to answer: go through the lines from the first to the last. Each time something to skip begins, write one entry with first_line (where it begins) and last_line (its LAST line, where the conversation comes back). An ad or plug is several lines long: last_line is larger than first_line. Entries never overlap, and each line belongs to at most one entry. The hosts talking to each other is the show: leave it out. A brand named in conversation with no offer, code or web address is the show.

"""#

    static let guidedReminder = "Now list every ad, plug, intro, outro or credits in the lines above, in order, one entry each from its first line to its last line. Leave the conversation out."

    static let tightReminder = #"List each ad, plug, intro or outro in the lines above, from its first to its last line only; the conversation around it is the show. If there are none, answer {"parts":[]}."#

    /// Pass 43: `Profile.listener`'s words after the stretch.
    static let listenerReminder = #"List every paid ad, plug, intro, outro or credits in the lines above as JSON, one entry each. Brands named in conversation are not ads. If there are none, answer {"parts":[]}."#

    static let compactRules = #"""
Mark the ads and promos in part of a podcast transcript, for an ad-skipping app. Lines are "<number> <text>".
Labels:
- PAID_AD: a produced or pre-recorded sponsor spot.
- HOST_READ_AD: a host reading a paid sponsorship, from the hand-off ("brought to you by", "let's take a break") to the last line of its offer, code or web address.
- NETWORK_PROMO: a trailer or promo for another podcast.
- SELF_PROMO: the hosts plugging their own tour, tickets, Patreon, merch or socials.
- GUEST_PLUG: the guest plugging their own show, special, book or tour.
- INTRO, OUTRO, CREDITS: the produced opening, closing or credits.
- MOCK_AD: a joke or fake ad nobody paid for (it is kept).
Talking about a brand is not an ad without a sponsorship hand-off, an offer, a code or a web address. Most stretches of a podcast are the show: then answer {"parts":[]}. Give each sponsor its own entry.

"""#

    /// Pass 38: the candidate rules, about 140 tokens: 125 with the Qwen3 tokenizer, 140 with Gemma 4's, 147 with LFM2.5's.
    /// The labels that matter for cutting, the one rule small models most
    /// often break (a brand mentioned is not an ad), and the answer's shape.
    static let candidateRules = #"""
Mark ads in this podcast stretch ("<line> <text>"). Labels:
PAID_AD: produced sponsor spot. HOST_READ_AD: host reads a sponsor, hand-off to last code or URL. SELF_PROMO: hosts' tour, Patreon, merch. GUEST_PLUG: guest's own work. NETWORK_PROMO: another podcast. INTRO, OUTRO: produced theme.
Naming a brand without a hand-off, offer, code or URL is the show. Never list the show. Usually: {"parts":[]}.
JSON: {"parts":[{"first_line":n,"last_line":n,"label":"…","sponsor":"…"}]}
"""#

    static func candidateSchema(maxParts: Int) -> String {
        #"{"type": "object", "properties": {"parts": {"type": "array", "maxItems": "#
            + "\(maxParts)"
            + #", "items": {"type": "object", "properties": {"first_line": {"type": "integer"}, "last_line": {"type": "integer"}, "label": {"type": "string", "enum": ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO"]}, "sponsor": {"type": "string", "maxLength": 32}}, "required": ["first_line", "last_line", "label", "sponsor"], "additionalProperties": false}}}, "required": ["parts"], "additionalProperties": false}"#
    }

    // No worked example: Qwen3 0.6B copied one word for word (lines 12–30,
    // sponsor "Brand") into every answer in the pass-30 Mac lab.
    static let answerFormat = #"""
Answer with JSON only: {"parts": [...]} with one entry per part, each {"first_line": the number of the part's first line, "last_line": the number of its last line, "label": one of the labels above, "sponsor": the brand or show promoted or "", "funny": true or false}. "parts" holds only what would be skipped: never list the show itself, and never one entry for the whole stretch. When nothing in these lines needs marking, answer {"parts": []}. Write the JSON on one line, with no line breaks or indentation.
"""#

    /// Pass 31: the short answer with a reason written before the label.
    static let answerFormatReasoned = #"""
Answer with JSON only: {"parts": [...]} with one entry per part, each {"first_line": the number of the part's first line, "last_line": the number of its last line, "why": the evidence in at most ten words, "label": one of the labels above, "sponsor": the brand or show promoted or "", "funny": true or false}. "parts" holds only what would be skipped: never list the show itself, and never one entry for the whole stretch. When nothing in these lines needs marking, answer {"parts": []}. Write the JSON on one line, with no line breaks or indentation.
"""#

    static func reasonedSchema(maxParts: Int) -> String {
        #"{"type": "object", "properties": {"parts": {"type": "array", "maxItems": "#
            + "\(maxParts)"
            + #", "items": {"type": "object", "properties": {"first_line": {"type": "integer"}, "last_line": {"type": "integer"}, "why": {"type": "string", "maxLength": 80}, "label": {"type": "string", "enum": ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "MOCK_AD"]}, "sponsor": {"type": "string", "maxLength": 40}, "funny": {"type": "boolean"}}, "required": ["first_line", "last_line", "why", "label", "sponsor", "funny"], "additionalProperties": false}}}, "required": ["parts"], "additionalProperties": false}"#
    }

    /// The short answer: five fields a part, a bounded list.
    static func leanSchema(maxParts: Int) -> String {
        #"{"type": "object", "properties": {"parts": {"type": "array", "maxItems": "#
            + "\(maxParts)"
            + #", "items": {"type": "object", "properties": {"first_line": {"type": "integer"}, "last_line": {"type": "integer"}, "label": {"type": "string", "enum": ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "MOCK_AD"]}, "sponsor": {"type": "string", "maxLength": 40}, "funny": {"type": "boolean"}}, "required": ["first_line", "last_line", "label", "sponsor", "funny"], "additionalProperties": false}}}, "required": ["parts"], "additionalProperties": false}"#
    }

    /// Pass 63: the short answer as a llama.cpp grammar (GBNF), for models
    /// read on the CPU. They wrote free text until now, indented at ~50
    /// tokens a part: on his 10 Nov phone Qwen3.5 2B listed every two lines
    /// of a sample as its own ad, LFM2.5 1.2B wrote overlapping spans, and
    /// the 4B spent most of a test writing at 3–4 tokens a second. Held to
    /// this, an answer is one line of at most `maxParts` parts (about 22
    /// tokens each), always readable, and never lists the show.
    static func leanGrammar(maxParts: Int) -> String { leanGrammar(maxParts: maxParts, lineCount: nil) }

    /// Pass 63's form (no spaces anywhere), kept for the lab's comparison.
    static func leanGrammarPass63(maxParts: Int) -> String {
        let labels = ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "MOCK_AD"]
            .map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
        return """
        root ::= "{\\"parts\\":[" ( part ( "," part ){0,\(max(0, maxParts - 1))} )? "]}"
        part ::= "{\\"first_line\\":" num ",\\"last_line\\":" num ",\\"label\\":" label ",\\"sponsor\\":\\"" text "\\",\\"funny\\":" bool "}"
        num ::= [0-9] [0-9]? [0-9]? [0-9]?
        label ::= \(labels)
        text ::= [^"\\\\\\x00-\\x1F]{0,40}
        bool ::= "true" | "false"
        """
    }

    /// Pass 64 (his 13 Nov export, and the Mac lab on Basic): Qwen3.5 2B on
    /// the CPU found ads in free text (its own answer 47 %) but, held to this
    /// form, closed the list at once — `{"parts":[]}` in 4 tokens, every
    /// time. The form allowed no space anywhere, and the model writes
    /// `{"parts": [{"first_line": 28, …` with one after every colon and
    /// comma; the only path left that it liked was the empty list. A space
    /// or a line break (up to three characters) is allowed where JSON allows
    /// them now.
    ///
    /// With `lineCount` (the stretch's lines, numbered from 0), line numbers
    /// are only those of the stretch, and a part can't span the whole of it —
    /// from its first line (or, in 30 lines or more, its first three) to its
    /// last (or last three): Llama 3.2 3B, Dolphin, Nemotron 3 Nano, MiniCPM5
    /// 1B and Qwen2.5 1.5B answered with exactly that span on his phone, which
    /// is dropped as the stretch restated (`isContainer`), so they scored 0.
    static func leanGrammar(maxParts: Int, lineCount: Int?) -> String {
        let labels = ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "MOCK_AD"]
            .map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
        let key = { (name: String) in "\"\\\"\(name)\\\"\" ws \":\" ws" }
        var spans: String
        var numbers = ""
        if let n = lineCount, n >= 8 {
            let edge = n >= 30 ? 3 : 1
            func list(_ range: Range<Int>) -> String { range.map { "\"\($0)\"" }.joined(separator: " | ") }
            numbers = """

            anyline ::= \(list(0..<n))
            early ::= \(list(0..<edge))
            later ::= \(list(edge..<n))
            notlast ::= \(list(0..<(n - edge)))
            """
            spans = "\(key("first_line")) early ws \",\" ws \(key("last_line")) notlast | \(key("first_line")) later ws \",\" ws \(key("last_line")) anyline"
        } else {
            spans = "\(key("first_line")) num ws \",\" ws \(key("last_line")) num"
        }
        return """
        root ::= "{" ws \(key("parts")) "[" ws ( part ( ws "," ws part ){0,\(max(0, maxParts - 1))} )? ws "]" ws "}"
        part ::= "{" ws ( \(spans) ) ws "," ws \(key("label")) label ws "," ws \(key("sponsor")) "\\"" text "\\"" ws "," ws \(key("funny")) bool ws "}"
        num ::= [0-9] [0-9]? [0-9]? [0-9]?
        label ::= \(labels)
        text ::= [^"\\\\\\x00-\\x1F]{0,40}
        bool ::= "true" | "false"
        ws ::= [ \\n]{0,3}\(numbers)
        """
    }

    /// The bench's `short`: whole seconds as h:mm:ss.
    static func short(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// «I», «R» or «IR» when evidence covers more than half of the line.
    static func tag(_ line: TimedLine, _ spans: [EvidenceSpan]) -> String {
        let length = max(0.1, line.end - line.start)
        let kinds = Set(spans.filter { min($0.end, line.end) - max($0.start, line.start) > 0.5 * length }
            .map(\.kind.rawValue))
        return kinds.isEmpty ? "" : "«" + kinds.sorted().joined() + "» "
    }

    /// One transcript line: its number, a time on every 15th, the evidence
    /// marks, the text. Numbers are the line's index in the whole episode,
    /// so an answer means the same line whichever window it came from.
    static func line(_ index: Int, _ line: TimedLine, spans: [EvidenceSpan]) -> String {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if index % 15 == 0 {
            return "\(index) [\(short(line.start))] \(tag(line, spans))\(text)"
        }
        return "\(index) \(tag(line, spans))\(text)"
    }

    /// The user message for one window. The bench's header, with one added
    /// sentence saying which lines this window holds (it read whole episodes
    /// at once; a phone can't).
    static func user(show: String, title: String, notes: String, lines: [TimedLine],
                     window: Range<Int>, formatted: [String], corrections: String = "") -> String {
        let total = lines.count
        let length = short(lines.last?.end ?? 0)
        var text = "Show: \(show)\nEpisode: \(title)\nShow notes:\n\(String(notes.prefix(4000)))\n\n"
        // The listener's past verdicts on this show (task 05), before the
        // transcript; the rules above are left as benchmarked.
        if !corrections.isEmpty { text += corrections + "\n\n" }
        text += "Transcript (\(total) lines, \(length) long):\n"
        if window.count < total {
            text += "This is part of it: lines \(window.lowerBound)–\(window.upperBound - 1). "
            text += "Mark only parts inside these lines.\n"
        }
        text += formatted[window].joined(separator: "\n")
        return text
    }

    // MARK: Pass 31 — the stretch as a phone model sees it

    /// The user message for one stretch, as the Mac lab found works best
    /// for phone models (`~/Developer/mlxlab`, his real episodes; Qwen3.5 4B:
    /// Hard test 38 % → 74 %, real ad seconds found 76 % → 94 %, same
    /// handful of seconds of show cut):
    ///
    /// - Lines numbered from 0 within the stretch. Given the episode's own
    ///   numbers (lines 866–1051), small models answered "1–8" or ranges
    ///   that ran backwards.
    /// - The sponsors named in the show notes, not 4,000 characters of
    ///   notes: models "found" the guest's book and the hosts' merch listed
    ///   in the notes in stretches where nobody mentioned them.
    /// - Where the stretch sits in the episode ("starts 47 min into a
    ///   106-min episode"): without it, the first stretch of an episode was
    ///   labelled INTRO from top to bottom.
    ///
    /// Pass 43: `reminder` (the profile's) follows the lines.
    static func userLocal(show: String, title: String, notes: String, lines: [TimedLine],
                          window: Range<Int>, spans: [EvidenceSpan], corrections: String = "",
                          reminder: String? = nil) -> String {
        userHeader(show: show, title: title, notes: notes, corrections: corrections)
            + stretch(lines: lines, window: window, spans: spans)
            + (reminder.map { "\n\n" + $0 } ?? "")
    }

    /// Pass 38: what every stretch of an episode is told before its own
    /// lines — the same text each time, so an engine that keeps the prompt
    /// it has already read (Core AI's prefix reuse) reads only the stretch.
    static func userHeader(show: String, title: String, notes: String, corrections: String = "") -> String {
        var text = "Show: \(show)\nEpisode: \(title)\n"
        let named = sponsors(fromNotes: notes)
        if !named.isEmpty {
            text += "Sponsors named in the show notes (they may appear anywhere in the episode, or not at all): "
                + named.joined(separator: ", ") + "\n"
        }
        if !corrections.isEmpty { text += "\n" + corrections + "\n" }
        return text
    }

    /// The stretch's place in the episode and its lines, numbered from 0.
    static func stretch(lines: [TimedLine], window: Range<Int>, spans: [EvidenceSpan]) -> String {
        guard !window.isEmpty, window.upperBound <= lines.count else { return "" }
        let total = lines.last?.end ?? 0
        var text = ""
        let starts = window.lowerBound == 0 ? "the very start"
            : clock(lines[window.lowerBound].start) + " in"
        let toEnd = window.upperBound >= lines.count ? " and runs to the very end" : ""
        text += "\nThis stretch starts at \(starts) of a \(clock(total)) episode\(toEnd). Lines 0–\(window.count - 1):\n"
        text += window.map { i in
            "\(i - window.lowerBound) \(tag(lines[i], spans))\(lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
        return text
    }

    /// "47 min", "1 h 46 min".
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds)), h = s / 3600, m = s % 3600 / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    /// Brand-like names after "sponsored by", "brought to you by", "thanks
    /// to", "go to", "visit", "at", and the names of web addresses — at
    /// most twelve, as the lab's port does.
    static func sponsors(fromNotes notes: String) -> [String] {
        var found: [String] = []
        let lead = #"(?i:sponsored by|brought to you by|thanks to|go to|visit|at)\s+([A-Z][\w&'.-]+(?:\s+[A-Z][\w&'.-]+){0,2})"#
        let site = #"(?i)\b([a-z0-9-]+)\.(?:com|co|net|org|io)\b"#
        for pattern in [lead, site] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = notes as NSString
            for match in regex.matches(in: notes, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
                let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if name.count > 2, !found.contains(where: { $0.lowercased() == name.lowercased() }) { found.append(name) }
            }
        }
        return Array(found.prefix(12))
    }

    /// A part that runs from the stretch's first lines to its last lines is a
    /// "container" answer (the model labelled the whole stretch), not a
    /// located ad: every stretch carries plain conversation around what it
    /// asks about. Pass 32: weak models on the phone did this and the
    /// whole window was cut or scored as found.
    ///
    /// Pass 63 (his 10 Nov phone: Core AI's Granite 4.0-H 1B answered "lines
    /// 0–13: HOST_READ_AD" for a 14-line stretch, Youtu-LLM 2B "0–15", and
    /// each came out as a cut whose edges were the stretch's own): the
    /// models held to ~1,000 tokens read 12–25 lines at a time, under the
    /// 30 this rule began at. From 8 lines up, a part that is exactly the
    /// whole stretch — its first line to its last — is the stretch
    /// restated too. A real read that fills a short stretch is still cut:
    /// the Reader's own cut for it stands when the model's is dropped.
    static func isContainer(_ part: RawPart, windowCount: Int) -> Bool {
        guard part.label != .show else { return false }
        if windowCount >= 30 {
            let covered = Double(part.lastLine - part.firstLine + 1) / Double(windowCount)
            return covered >= 0.9 && part.firstLine <= 2 && part.lastLine >= windowCount - 3
        }
        return windowCount >= 8 && part.firstLine == 0 && part.lastLine == windowCount - 1
    }

    /// Pass 38: one cut covering most of a stretch of several minutes is
    /// the stretch restated, not an ad located (Llama 3.2, Bonsai 8B and
    /// Ternary Bonsai on his phone: "lines 0–212: HOST_READ_AD"). For the
    /// families that do it (`ModelPromptPlan.restatesStretch`), a cut over
    /// `maxShare` of a stretch of at least four minutes is dropped; a real
    /// read in it is still found by the reader and the cut check.
    static func restatesStretch(_ part: RawPart, window: Range<Int>, lines: [TimedLine], maxShare: Double) -> Bool {
        guard part.label != .show, window.upperBound <= lines.count, !window.isEmpty else { return false }
        let span = lines[window.upperBound - 1].end - lines[window.lowerBound].start
        guard span >= 240 else { return false }
        let first = window.lowerBound + part.firstLine, last = window.lowerBound + part.lastLine
        guard first >= window.lowerBound, last < window.upperBound else { return false }
        return (lines[last].end - lines[first].start) / span > maxShare
    }

    /// Pass 63 (his 10 Nov export: 19 models answered "lines 0–92: INTRO",
    /// "0–163: PAID_AD", or one cut after another over the whole sample):
    /// for every family, the most of a stretch of four minutes or more that
    /// one part may cover, and that all its parts together may cover.
    static let universalCutShare = 0.5
    static let universalCoverage = 0.7

    /// Pass 63: the longest one part of each label can plausibly be, in
    /// seconds — well past his labelled episodes' longest (intros ≤ 35 s, a
    /// read ≤ 6 min, a closing song 326 s, a run of plugs 460 s). A part
    /// beyond it is the stretch restated, whatever share of it that is. A
    /// joke ad or a regular bit marked to be kept is short too: a long one
    /// would stop the Reader's real cuts under it.
    static func longestPart(_ label: JudgeLabel) -> Double {
        switch label {
        case .intro: 150
        case .paidAd: 420
        case .hostReadAd: 540
        case .networkPromo: 300
        case .selfPromo, .guestPlug: 600
        case .outro, .credits: 420
        case .mockAd, .recurringSegment: 240
        case .show: .infinity
        }
    }

    /// A part's length in seconds on the episode's lines (window-local numbers).
    static func seconds(_ part: RawPart, window: Range<Int>, lines: [TimedLine]) -> Double? {
        let first = window.lowerBound + part.firstLine, last = window.lowerBound + part.lastLine
        guard first >= 0, first <= last, last < lines.count else { return nil }
        return lines[last].end - lines[first].start
    }

    /// Parts numbered within a stretch, moved onto the episode's own line
    /// numbers; parts outside the stretch, running backwards or covering
    /// the whole stretch are dropped.
    ///
    /// Pass 63: with the episode's lines, every family's answer is also held
    /// to `maxShare` (nil: `universalCutShare`) per part, to `longestPart`,
    /// and — when what is left would still remove more than
    /// `universalCoverage` of a stretch of four minutes or more — dropped
    /// whole: that is the stretch labelled line by line, not ads located.
    /// "SHOW" entries are never parts (the guided answer no longer offers
    /// the label; a free answer that writes it is read and ignored).
    /// Pass 64: the answer named something, and every cut it named was the
    /// stretch restated (`isContainer` / `restatesStretch`), so nothing was
    /// kept — Llama 3.2 3B, Dolphin, Nemotron 3 Nano, MiniCPM5 1B, Qwen2.5
    /// 1.5B on his phone. Read again in halves, such an answer can still
    /// locate what it saw.
    static func restatedOnly(raw: [RawPart]?, kept: [RawPart]?, window: Range<Int>, lines: [TimedLine],
                             maxShare: Double?) -> Bool {
        guard let raw, let kept, kept.allSatisfy({ $0.label.kindName == nil }) else { return false }
        let cuts = raw.filter { $0.label != .show && $0.label.kindName != nil }
        guard !cuts.isEmpty else { return false }
        return cuts.contains { part in
            isContainer(part, windowCount: window.count)
                || (window.upperBound <= lines.count && restatesStretch(part, window: window, lines: lines,
                                                                        maxShare: maxShare ?? universalCutShare))
        }
    }

    static func shifted(_ parts: [RawPart], window: Range<Int>, lines: [TimedLine] = [], maxShare: Double? = nil) -> [RawPart] {
        let measured = !lines.isEmpty && window.upperBound <= lines.count && !window.isEmpty
        var kept: [RawPart] = parts.filter { part in
            guard part.label != .show else { return false }
            guard part.firstLine >= 0, part.firstLine <= part.lastLine, part.lastLine < window.count else { return false }
            guard !isContainer(part, windowCount: window.count) else { return false }
            guard measured else { return true }
            if restatesStretch(part, window: window, lines: lines, maxShare: maxShare ?? universalCutShare) { return false }
            if let length = seconds(part, window: window, lines: lines), length > longestPart(part.label) { return false }
            return true
        }
        // One stretch can't be two kinds of thing: parts of different labels
        // lying mostly over each other ("INTRO 33–60, OUTRO 35–60"; LFM2.5
        // 1.2B and LFM3 in the Mac lab) are the model contradicting itself,
        // and neither is kept. A short part inside a much longer one (a
        // promo inside a break marked whole) is not that.
        var contradicted = Set<Int>()
        for i in kept.indices where kept[i].label.kindName != nil {
            for j in kept.indices where j > i && kept[j].label.kindName != nil && kept[j].label != kept[i].label {
                let a = kept[i].firstLine...kept[i].lastLine, b = kept[j].firstLine...kept[j].lastLine
                guard a.overlaps(b) else { continue }
                let shared = Swift.min(a.upperBound, b.upperBound) - Swift.max(a.lowerBound, b.lowerBound) + 1
                let longer = Swift.max(a.count, b.count)
                if Double(shared) / Double(longer) > 0.5 { contradicted.insert(i); contradicted.insert(j) }
            }
        }
        if !contradicted.isEmpty { kept = kept.indices.filter { !contradicted.contains($0) }.map { kept[$0] } }
        if measured {
            let span = lines[window.upperBound - 1].end - lines[window.lowerBound].start
            if span >= 240 {
                var covered = Set<Int>()
                for part in kept where part.label.kindName != nil { covered.formUnion(part.firstLine...part.lastLine) }
                let seconds = covered.reduce(0.0) { $0 + (lines[window.lowerBound + $1].end - lines[window.lowerBound + $1].start) }
                if seconds / span > universalCoverage { kept.removeAll { $0.label.kindName != nil } }
            }
        }
        return kept.map { part in
            var moved = part
            moved.firstLine += window.lowerBound
            moved.lastLine += window.lowerBound
            return moved
        }
    }

    // MARK: Reading the answer

    /// A part as the model wrote it, before its edges are snapped.
    struct RawPart {
        var firstLine: Int
        var lastLine: Int
        var firstWords: String
        var lastWords: String
        var label: JudgeLabel
        var sponsor: String
        var funny: Bool
        var confidence: Int
        var why: String
    }

    /// The parts in an answer, or nil if it holds no readable JSON object
    /// with a "parts" list. Lenient like the bench's open-model path: any
    /// reasoning is dropped, then the text from the first "{" to the last
    /// "}" is read. A part with an unknown label is skipped, not guessed.
    /// Complete window answers only. Recovery may salvage individual objects
    /// with `parse`, but incomplete output cannot pass a model compatibility test.
    static func parseComplete(_ answer: String) -> [RawPart]? {
        var text = answer
        if let close = text.range(of: "</think>") { text = String(text[close.upperBound...]) }
        // Pass 33 (Phi-4 mini on his phone): the list alone, `[{…}]`, with no
        // {"parts": …} around it, is the same complete answer.
        if let list = bareList(text) {
            let parsed = parse(text)
            return parsed?.count == list.count ? parsed : nil
        }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["parts"] as? [[String: Any]],
              let parsed = parse(text), parsed.count == parts.count else { return nil }
        return parsed
    }

    static func parse(_ answer: String) -> [RawPart]? {
        var text = answer
        if let close = text.range(of: "</think>") { text = String(text[close.upperBound...]) }
        let parts: [Any]
        if let list = bareList(text) {
            parts = list
        } else if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
           let data = String(text[open...close]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let whole = object["parts"] as? [Any] {
            parts = whole
        } else {
            // Pass 27e (his model tests, 30 Sep): MiniCPM5 wrote the right
            // part but the answer as a whole wasn't valid JSON (cut off, or
            // wrapped in a fence), so nothing was read. Take every complete
            // {…} that names a first_line, on its own.
            let found = objects(in: text).filter { $0["first_line"] != nil }
            guard !found.isEmpty else { return nil }
            parts = found
        }
        return parts.compactMap { item -> RawPart? in
            guard let part = item as? [String: Any],
                  let first = int(part["first_line"]), let last = int(part["last_line"]),
                  let label = (part["label"] as? String).flatMap(label(named:)) else { return nil }
            return RawPart(firstLine: first, lastLine: last,
                           firstWords: part["first_words"] as? String ?? "",
                           lastWords: part["last_words"] as? String ?? "",
                           label: label,
                           sponsor: part["sponsor"] as? String ?? "",
                           funny: part["funny"] as? Bool ?? false,
                           // The short answer (pass 30) has no confidence:
                           // the cut check, not this number, guards it.
                           confidence: int(part["confidence"]) ?? (part["confidence"] == nil ? 80 : 0),
                           why: part["why"] as? String ?? "")
        }
    }

    /// A label as written, allowing for case and spaces ("Paid_AD", "show",
    /// "host read ad" — MiniCPM5, Ministral and others on his phone). A name
    /// that isn't one of the labels is still not guessed at.
    static func label(named raw: String) -> JudgeLabel? {
        if let exact = JudgeLabel(rawValue: raw) { return exact }
        let normal = raw.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        return JudgeLabel(rawValue: normal) ?? aliases[normal]
    }

    /// Pass 38: names small models write for a label (MiniCPM5, Ministral,
    /// LFM2.5 and Granite on his phone and in the Mac lab). Only names that
    /// can mean one thing; "PROMO" alone could be the hosts' or another
    /// show's, so it isn't guessed.
    static let aliases: [String: JudgeLabel] = [
        "AD": .paidAd, "ADS": .paidAd, "ADVERTISEMENT": .paidAd, "PAID_ADVERTISEMENT": .paidAd, "SPONSOR": .paidAd,
        "SPONSORSHIP": .paidAd, "SPONSORED": .paidAd, "PRODUCED_AD": .paidAd, "PRE_ROLL": .paidAd, "POST_ROLL": .paidAd,
        "HOST_READ": .hostReadAd, "HOSTREAD_AD": .hostReadAd, "HOST_AD": .hostReadAd, "HOST_READ_ADVERTISEMENT": .hostReadAd,
        "SELF_PROMOTION": .selfPromo, "SELFPROMO": .selfPromo, "PLUG": .selfPromo,
        "NETWORK_PROMOTION": .networkPromo, "CROSS_PROMO": .networkPromo, "CROSS_PROMOTION": .networkPromo,
        "GUEST_PROMO": .guestPlug, "GUEST_PROMOTION": .guestPlug,
        "MOCK": .mockAd, "PARODY_AD": .mockAd, "FAKE_AD": .mockAd,
        "CONTENT": .show, "CONVERSATION": .show, "NORMAL": .show, "NONE": .show, "OTHER": .show,
    ]

    /// The answer when it is a bare JSON list of parts (fences and words
    /// around it allowed), else nil.
    static func bareList(_ text: String) -> [[String: Any]]? {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close else { return nil }
        if let brace = text.firstIndex(of: "{"), brace < open { return nil }
        guard let data = String(text[open...close]).data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else { return nil }
        return list
    }

    /// Every balanced, innermost-level-parsable {…} in `text` (strings and
    /// escapes respected), for answers that aren't valid JSON as a whole.
    static func objects(in text: String) -> [[String: Any]] {
        let chars = Array(text.utf8)
        var result: [[String: Any]] = []
        var starts: [Int] = []
        var inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                continue
            }
            switch c {
            case 0x22: inString = true
            case 0x7B: starts.append(i)
            case 0x7D:
                guard let start = starts.popLast() else { continue }
                let slice = Data(chars[start...i])
                if let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                    result.append(object)
                }
            default: break
            }
        }
        return result
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String:   return Int(s.trimmingCharacters(in: .whitespaces))
        default:                return nil
        }
    }

    /// The bench's `to_detect`, without the formatting: clamp, snap both
    /// edges to the quoted words, drop a part whose end comes before its start.
    static func resolve(_ raw: RawPart, lines: [TimedLine]) -> JudgedPart? {
        guard !lines.isEmpty else { return nil }
        var a = max(0, raw.firstLine), b = min(lines.count - 1, raw.lastLine)
        a = anchor(lines, guess: min(a, lines.count - 1), words: raw.firstWords)
        b = anchor(lines, guess: max(b, 0), words: raw.lastWords)
        guard b >= a else { return nil }
        return JudgedPart(firstLine: a, lastLine: b, label: raw.label, sponsor: raw.sponsor,
                          funny: raw.funny, confidence: raw.confidence, why: raw.why)
    }

    // MARK: anchor()

    /// The bench's `anchor`: the line whose opening words match the model's
    /// quote, nearest its line number. Models copy text reliably but count
    /// lines badly in long input.
    static func anchor(_ lines: [TimedLine], guess: Int, words: String, window: Int = 250) -> Int {
        let want = opening(words)
        guard !want.isEmpty else { return guess }
        var best = guess, score = 0.0
        let low = max(0, guess - window), high = min(lines.count, guess + window + 1)
        guard low < high else { return guess }
        for i in low..<high {
            let have = opening(lines[i].text)
            let s = SequenceMatcher.ratio(want, have) - Double(abs(i - guess)) * 0.0005
            if s > score { best = i; score = s }
        }
        return score >= 0.6 ? best : guess
    }

    /// `" ".join(re.sub(r"[^a-z0-9 ]", "", s.lower()).split()[:8])`
    static func opening(_ text: String) -> [UInt8] {
        let kept = text.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == " "
        }
        let words = String(String.UnicodeScalarView(kept)).split(separator: " ").prefix(8)
        return Array(words.joined(separator: " ").utf8)
    }
}

/// Python's `difflib.SequenceMatcher(None, a, b).ratio()`, for the short
/// ASCII strings `anchor` compares. Same longest-match search and the same
/// tie-breaking, so the same score. difflib's "autojunk" only starts at 200
/// characters, which eight words rarely reach; it isn't ported.
enum SequenceMatcher {
    static func ratio(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1 }
        var b2j: [UInt8: [Int]] = [:]
        for (j, element) in b.enumerated() { b2j[element, default: []].append(j) }

        func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var j2len: [Int: Int] = [:]
            for i in alo..<ahi {
                var next: [Int: Int] = [:]
                for j in b2j[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    next[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
                j2len = next
            }
            return (besti, bestj, bestsize)
        }

        var matches = 0
        var queue = [(0, a.count, 0, b.count)]
        while let range = queue.popLast() {
            let (alo, ahi, blo, bhi) = range
            guard alo < ahi, blo < bhi else { continue }
            let (i, j, k) = longest(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            matches += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return 2.0 * Double(matches) / Double(total)
    }
}
