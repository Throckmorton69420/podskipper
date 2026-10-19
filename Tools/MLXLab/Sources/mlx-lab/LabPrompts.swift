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

    static func system(_ variant: String) -> String {
        switch variant {
        case "v2", "v2r": return v2Rules + JudgePrompt.answerFormat
        default: return JudgePrompt.Profile.lean.system
        }
    }

    /// v2r: the task restated after the stretch, where a small model reads it last.
    static func reminder(_ variant: String) -> String? {
        switch variant {
        case "v2r":
            return "List every paid ad, plug, intro, outro or credits in the lines above as JSON, one entry each. Brands named in conversation are not ads. If there are none, answer {\"parts\":[]}."
        default: return nil
        }
    }

    static func schema(_ variant: String) -> String { JudgePrompt.Profile.lean.schema }
}
