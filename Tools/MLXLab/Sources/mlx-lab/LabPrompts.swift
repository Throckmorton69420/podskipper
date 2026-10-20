import Foundation

/// Pass 43 lab: instruction variants tried against the app's lean prompt on
/// his labelled episodes (Tools/DetectionLab/phone-labels). Only the winner
/// goes into the app (JudgePrompt).
enum LabPrompts {
    /// v2: the labels by what listeners hear, the confusions his exports show
    /// (a produced spot for a film or a bank called a "network promo"; a
    /// guest's special or the hosts' dates at the goodbye left in; theme songs
    /// and credits left in), and the same answer.
    static let v2Rules = #"""
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
- MOCK_AD: a joke ad, a parody sponsor, or a bit about a brand nobody paid for. It is the show; list it only when it could be mistaken for an ad.

Rules:
1. Naming a brand, a restaurant, an app, a film or a website in conversation is NOT an ad. An ad needs a hand-off, an offer, a code, a "go to …com", "terms apply", or copy that sells rather than converses. When unsure between an ad and the show, it is the show.
2. A story that mentions a tour or a special in passing is the show. SELF_PROMO and GUEST_PLUG need an actual plug: dates, cities, "get tickets", "go see", "check out", a web address.
3. Be exhaustive: give each sponsor, each spot and each plug its own entry, including short ones (a five-second plug counts), and check the first and last lines of the stretch.
4. Be tight: first_line is where the part begins and last_line where it ends. Do not swallow the conversation before or after it.
5. Most of any stretch is the show. When these lines hold nothing to skip, answer {"parts":[]}.

"""#

    /// Pass 44 v3: the listener rules plus the two places his labels show
    /// every model losing time — the episode's edges (theme, network ident,
    /// the plugs given while saying goodbye, the closing music) and a round
    /// of plugs, read as one part per person.
    static let v3Extra = #"""
7. The episode's edges. Before the hosts start talking, a theme song, an announcer or a network ident ("you're listening to the … network") is INTRO, and any ad before or after it is PAID_AD. When the hosts say goodbye, the goodbye itself is the show, but the plugs given while signing off (their dates, the guest's special, book, podcast or website, "follow us", "subscribe") are SELF_PROMO or GUEST_PLUG, the closing theme or music is OUTRO, and any ad after it is PAID_AD.
8. A round of plugs ("let's do some plugs", "what are you plugging?", "where can people find you?") is one SELF_PROMO or GUEST_PLUG entry per person, from their first plug to their last, with the short asides between them.

"""#

    /// Pass 44 cplus: for models held to ~2,000 tokens (Core AI on his
    /// iPhone): the listener's labels and the rules that matter most, in
    /// about 230 tokens, so a stretch still holds a whole break.
    static let cplusRules = #"""
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

    static let reminderText = "List every paid ad, plug, intro, outro or credits in the lines above as JSON, one entry each. Brands named in conversation are not ads. If there are none, answer {\"parts\":[]}."

    /// `p-<name>` is one of the app's own profiles (`JudgePrompt.Profile`).
    static func appProfile(_ variant: String) -> JudgePrompt.Profile? {
        guard variant.hasPrefix("p-") else { return nil }
        return JudgePrompt.Profile(rawValue: String(variant.dropFirst(2)))
    }

    static func system(_ variant: String) -> String {
        if let profile = appProfile(variant) { return profile.system }
        switch variant {
        case "v2", "v2r": return v2Rules + JudgePrompt.answerFormat
        case "v3": return JudgePrompt.listenerRules + v3Extra + JudgePrompt.answerFormat
        case "cplus": return cplusRules + JudgePrompt.answerFormat
        default: return JudgePrompt.Profile.lean.system
        }
    }

    /// v2r: the task restated after the stretch, where a small model reads it last.
    static func reminder(_ variant: String) -> String? {
        if let profile = appProfile(variant) { return profile.reminder }
        switch variant {
        case "v2r", "v3", "cplus": return reminderText
        default: return nil
        }
    }

    static func schema(_ variant: String) -> String {
        if let profile = appProfile(variant) { return profile.schema }
        return variant == "cplus" ? JudgePrompt.leanSchema(maxParts: 4) : JudgePrompt.Profile.lean.schema
    }
}
