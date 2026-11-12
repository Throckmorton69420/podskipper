import Foundation

/// Pass 63 (his 10 Nov report: Basic and Hard were two one-window samples of
/// six-second lines that tested different code in different finders, and a
/// score that fell to 0 % for one over-long cut): version 4 of the two
/// samples every finder takes in Compare Models.
///
/// The words are made up (shows, hosts and brands no finder has seen). The
/// timing is real: every line's pause and speaking rate come, line after
/// line, from stretches of the same kind in his labelled episodes
/// (`BenchTimings`, written by `Tools/ReaderData/bench_timing.py`), each word
/// has its own time, and the pauses are handed to the finders as the
/// measured silences of a real episode are.
///
/// - **Basic** — a quick check of the fundamentals, about five minutes: a
///   recorded pre-roll, the show's intro, one host-read ad in the middle, the
///   credits, a recorded post-roll, and one stretch of talk about a brand
///   nobody paid for. A model reads all of it in one go.
/// - **Hard** — a whole episode of about twenty-five minutes, long enough that a
///   model reads it in several parts, taken through the app's own steps
///   (the Reader first, then the model on the stretches Find Ads would show
///   it, then PodSkipper's cut check): back-to-back spots, a short spot, a
///   read of more than two minutes, a read with the hosts wandering off in
///   the middle, three plugs of the show's own, two guest plug rounds (one
///   in conversation), another show's promo inside a break, intro, credits, a
///   plug after them, and four stretches of show talk that only sound like
///   selling (brand chatter, a joke ad, tour stories, a listener's gadget).
struct BenchScript: Sendable {
    /// What kind of speech a line is, for its timing.
    enum Speech: Sendable { case talk, hostRead, spot, plug, promo, intro, credits

        var beats: [BenchTimings.Beat] {
            switch self {
            case .talk: BenchTimings.talk
            case .hostRead: BenchTimings.hostRead
            case .spot: BenchTimings.spot
            case .plug: BenchTimings.plug
            case .promo: BenchTimings.promo
            case .intro: BenchTimings.intro
            case .credits: BenchTimings.credits
            }
        }
    }

    /// The script as it is written: stretches in order.
    enum Part: Sendable {
        case show([String])
        /// Show talk a careless finder cuts.
        case trap(String, situation: String, [String])
        /// A hand-off, a return, or the hosts wandering off inside a read:
        /// cutting or keeping are both right.
        case either([String], speech: Speech = .talk)
        case cut(BenchSample.Category, kind: String, speech: Speech, situations: [String], [String])
    }

    struct Break: Sendable {
        var lines: ClosedRange<Int>
        var category: BenchSample.Category
        /// `PodTestPack.Break.kind` (for the record only).
        var kind: String
        var situations: [String]
    }

    struct Trap: Sendable {
        var name: String
        var lines: ClosedRange<Int>
        var situation: String
    }

    struct Line: Sendable {
        var text: String
        var start: Double
        var end: Double
        var words: [TranscriptWord]
    }

    var show: String
    var episode: String
    var notes: String
    var lines: [Line]
    var breaks: [Break]
    var traps: [Trap]
    /// Lines where cutting or keeping are both right.
    var either: Set<Int>
    /// The pauses a real episode's audio would give (every gap of 0.45 s or more).
    var silences: [ClosedRange<Double>]

    var duration: Double { (lines.last?.end ?? 0) + 0.4 }

    init(show: String, episode: String, notes: String, parts: [Part]) {
        self.show = show
        self.episode = episode
        self.notes = notes
        var lines: [Line] = [], breaks: [Break] = [], traps: [Trap] = [], either = Set<Int>()
        var silences: [ClosedRange<Double>] = []
        var used: [Speech: Int] = [:]
        var edgesIn = 0, edgesOut = 0
        var clock = 0.3
        var afterCut = false

        func add(_ texts: [String], _ speech: Speech, isCut: Bool) -> ClosedRange<Int> {
            let first = lines.count
            for (n, text) in texts.enumerated() {
                let beats = speech.beats
                let beat = beats[(used[speech] ?? 0) % beats.count]
                used[speech, default: 0] += 1
                var gap = beat.gap
                // A break's first line, and the first line after one, take a
                // real break's pause.
                if n == 0, isCut, !lines.isEmpty {
                    gap = BenchTimings.breakStarts[edgesIn % BenchTimings.breakStarts.count]; edgesIn += 1
                } else if n == 0, afterCut {
                    gap = BenchTimings.breakEnds[edgesOut % BenchTimings.breakEnds.count]; edgesOut += 1
                }
                let words = text.split(separator: " ").map(String.init)
                let start = clock + gap
                let seconds = max(0.4, Double(words.count) / beat.rate)
                if gap >= 0.45, !lines.isEmpty { silences.append((clock + 0.05)...(start - 0.05)) }
                // Each word's share of the line by its length.
                let weights = words.map { Double($0.count) + 1.5 }
                let total = weights.reduce(0, +)
                var at = start
                var timed: [TranscriptWord] = []
                for (word, weight) in zip(words, weights) {
                    let length = seconds * weight / total
                    timed.append(TranscriptWord(text: word, start: (at * 100).rounded() / 100,
                                                end: ((at + length * 0.92) * 100).rounded() / 100))
                    at += length
                }
                lines.append(Line(text: text, start: timed.first?.start ?? start, end: timed.last?.end ?? (start + seconds),
                                  words: timed))
                clock = start + seconds
            }
            afterCut = isCut
            return first...(lines.count - 1)
        }

        for part in parts {
            switch part {
            case .show(let texts):
                _ = add(texts, .talk, isCut: false)
            case .trap(let name, let situation, let texts):
                traps.append(Trap(name: name, lines: add(texts, .talk, isCut: false), situation: situation))
            case .either(let texts, let speech):
                either.formUnion(add(texts, speech, isCut: false))
            case .cut(let category, let kind, let speech, let situations, let texts):
                breaks.append(Break(lines: add(texts, speech, isCut: true), category: category, kind: kind,
                                    situations: situations))
            }
        }
        self.lines = lines
        self.breaks = breaks
        self.traps = traps
        self.either = either
        self.silences = silences
    }

    func start(_ line: Int) -> Double { lines[line].start }
    func end(_ line: Int) -> Double { lines[line].end }

    /// The sample as one PodSkipper Test episode.
    var episodeForScoring: PodTestPack.Episode {
        var labelled = breaks.map { [start($0.lines.lowerBound), end($0.lines.upperBound)] }
            + either.sorted().map { [start($0), end($0)] }
        // The pause between two breaks back to back (or a break and its
        // hand-off) is nobody's show: an exact answer lost 2 s there.
        let marked = Set(breaks.flatMap { Array($0.lines) }).union(either)
        for line in marked where marked.contains(line + 1) && start(line + 1) > end(line) {
            labelled.append([end(line), start(line + 1)])
        }
        return PodTestPack.Episode(
            guid: "bench:" + episode, show: show, duration: duration,
            breaks: breaks.map { PodTestPack.Break(start: start($0.lines.lowerBound), end: end($0.lines.upperBound),
                                                   kind: $0.kind, situations: $0.situations) },
            labelled: labelled,
            traps: traps.map { PodTestPack.Trap(start: start($0.lines.lowerBound), end: end($0.lines.upperBound),
                                                situation: $0.situation) })
    }

    /// Cut lines as time spans: each run of consecutive lines is one cut.
    func cuts(_ cut: Set<Int>, kinds: [Int: String] = [:]) -> [PodTestCut] {
        var out: [PodTestCut] = []
        var previous: Int?
        for line in cut.sorted() where lines.indices.contains(line) {
            let kind = kinds[line] ?? "cut"
            if let p = previous, p == line - 1, out.last?.kind == kind {
                out[out.count - 1].end = end(line)
            } else {
                out.append(PodTestCut(start: start(line), end: end(line), kind: kind))
            }
            previous = line
        }
        return out
    }

    /// PodSkipper Test constants (`Resources/Detection/PodTest.json`).
    static let constants = PodTestPack.bundled()?.constants
        ?? PodTestPack.Constants(edge: 2, noticed: 5, noticeCost: 10, showWeight: 2, jump: 2, jumpCost: 10, showMargin: 1)

    // MARK: Basic

    static let basic = BenchScript(
        show: "Kitchen Table",
        episode: "The Great Sourdough Feud",
        notes: "Maya and Jordan settle the sourdough argument once and for all. Sponsored by Freshbox and Harbor Insurance.",
        parts: [
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "pre-roll"], [
                "Switching car insurance shouldn't feel like a second job.",
                "With Harbor Insurance, you can get a quote in about four minutes, right from your phone.",
                "Drivers who switched saved an average of five hundred and twelve dollars a year.",
                "Get your free quote today at harborinsurance dot com.",
                "Harbor Insurance. Savings vary. Underwritten by Harbor Mutual Group.",
            ]),
            .cut(.introOutro, kind: "INTRO", speech: .intro, situations: ["intro"], [
                "From Copperline Audio, this is Kitchen Table.",
                "The show where two friends argue about food so you don't have to.",
            ]),
            .show([
                "Hi everybody, I'm Maya.",
                "And I'm Jordan, and today we are finally settling the sourdough thing.",
                "Okay, so for anyone who missed it, last week Jordan said sourdough is just bread with a publicist.",
                "And I stand by that. It's bread. It's flour, water and salt with an attitude.",
                "It is not just attitude, it's wild yeast, it's fermentation, it's a living thing on my counter.",
                "You named it. You named the jar. What's it called again?",
                "Its name is Doughlores, and she is fourteen months old.",
                "Fourteen months of feeding a jar instead of buying a loaf for four dollars.",
                "The loaf you buy for four dollars is full of things I can't pronounce.",
                "Okay, but here's my real question. Does it actually taste different, or do people just say it does?",
                "It tastes completely different. It's tangy, the crust crackles, the inside is chewy.",
                "I'll give you the crust. The crust is good.",
            ]),
            .trap("the brand chatter", situation: "selling words in the show", [
                "That's the Dutch oven. I bake it in that big orange Lodge pot, best forty dollars I ever spent.",
                "Lodge is not paying us, by the way. I just love that pot, I'd marry that pot.",
            ]),
            .show([
                "I tried making one during the lockdown, like everybody did.",
                "How did that go?",
                "It came out like a hockey puck. A dense, sour hockey puck.",
                "That's because you didn't let it rise long enough. You have to be patient.",
                "We're getting off track. Let's settle this with a blind taste test after the break.",
                "Fine. But I'm picking the store bread.",
            ]),
            .either(["Deal. We'll be right back."]),
            .cut(.ad, kind: "AD", speech: .hostRead, situations: ["host read"], [
                "This episode is brought to you by Freshbox.",
                "So Jordan, you know how I'm always telling you to cook more?",
                "Freshbox makes it actually easy. They send you everything you need for the week, already portioned.",
                "Every box comes with the recipe cards, and you pick your meals from over forty options every week.",
                "I've been doing the Mediterranean plan, and the lemon chicken with orzo is unbelievable.",
                "It takes about twenty-five minutes, start to finish, and there's barely any cleanup.",
                "And no more throwing out half a bunch of cilantro because you only needed two sprigs.",
                "Right now, Kitchen Table listeners get sixty percent off their first box, plus free shipping.",
                "Go to freshbox dot com slash kitchen and use code KITCHEN sixty.",
                "That's freshbox dot com slash kitchen, code KITCHEN sixty, for sixty percent off your first box.",
                "Freshbox. Dinner, figured out.",
                "Thanks to Freshbox for supporting the show.",
            ]),
            .either(["Okay, we're back, and I have two slices in front of me."]),
            .show([
                "One is my sourdough, one is whatever Jordan bought at the gas station.",
                "It wasn't the gas station, it was the grocery store. It has seeds on it.",
                "Okay, I'm closing my eyes. Hand me slice number one.",
                "Hmm. This is soft. This is sweet. This is the store bread, obviously.",
                "Correct. Now slice number two.",
                "Oh. Oh no.",
                "What? What's wrong?",
                "It's really good. It's tangy, and the crust, okay, I hate this.",
                "Ha! Doughlores wins.",
                "I'm saying it's better bread. I'm not saying it's a better life choice.",
                "We got a lot of messages about this last week, by the way.",
                "So many. Someone sent me a photo of their starter, it's named Bread Pitt.",
                "Another listener said her grandmother kept the same starter for forty years.",
                "Forty years? That jar is older than me.",
                "That's the thing, it gets passed down. It's like a family heirloom you can eat.",
                "Okay, that's actually kind of beautiful.",
                "Don't push it. Next week we're doing the hot sauce episode and I'm going to win that one.",
                "You can't handle spice. You put milk in your curry.",
                "I admit the bread is better. I do not admit that I was wrong.",
                "That's literally the same thing.",
                "Alright, that's our show. Thanks for sitting down at the Kitchen Table with us.",
                "Go hug your starter. Or don't. Buy the store bread. I won't judge.",
                "You will judge.",
                "I will a little bit judge.",
            ]),
            .cut(.introOutro, kind: "OUTRO", speech: .credits, situations: ["outro"], [
                "Kitchen Table is produced by Priya Shah and edited by Tom Becker.",
                "Our theme music is by The Lowlights.",
                "Kitchen Table is a Copperline Audio production.",
            ]),
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "post-roll"], [
                "Ever wish your phone plan just worked? With Signal Mobile, it does.",
                "Unlimited talk, text and data on the nation's fastest network, for just twenty-five dollars a month.",
                "No contracts, no hidden fees, and you keep your number.",
                "Switch in minutes at signalmobile dot com.",
                "Signal Mobile. Taxes and fees extra. Speeds may slow after thirty-five gigabytes.",
            ]),
        ])

    // MARK: Hard

    static let hard = BenchScript(
        show: "Late Shift",
        episode: "Loud Neighbors (with Sam Ortiz)",
        notes: "Comedian Sam Ortiz joins Nora and Pete to talk about loud neighbors, Tucson summers and the new special. Supported by Brightnest, Hushwell and Ridgeline Bank.",
        parts: [
            // Act one: the opening, the first break, the long read.
            .cut(.introOutro, kind: "INTRO", speech: .intro, situations: ["intro"], [
                "You're listening to Late Shift with Nora and Pete.",
                "A Wavelength Media podcast.",
                "Here we go.",
            ]),
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "short spot", "pre-roll", "back to back"], [
                "Tired of overdraft fees? Ridgeline Bank has none. Not one.",
                "Open a checking account in five minutes at ridgeline dot com.",
                "Ridgeline Bank. Member FDIC.",
            ]),
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "pre-roll", "back to back"], [
                "This winter, Arcadia Air is flying nonstop to more warm places than ever.",
                "Fares to Cancun, Tucson and Honolulu start at ninety-nine dollars each way.",
                "Book by Friday at arcadia air dot com.",
                "Arcadia Air. Restrictions apply. Fares are one way and include taxes.",
            ]),
            .show([
                "Hey everybody, welcome back to Late Shift. I'm Nora, Pete is here.",
                "Hello, hello.",
                "I went to Costco yesterday and bought forty rolls of paper towels.",
                "Forty. For one person. What's your plan there?",
                "The plan is I never think about paper towels again until 2028.",
                "Did you at least get the hot dog?",
            ]),
            .trap("the brand chatter", situation: "selling words in the show", [
                "Of course I got the hot dog, a dollar fifty, it's the last honest price in America.",
                "That's actually true, Costco is great, I'm not even getting paid to say that.",
            ]),
            .show([
                "Nobody's paying us for anything, look at this microphone.",
                "It's held together with tape.",
                "So we have a great guest today, but first I need to tell you about my weekend.",
                "Oh no.",
                "My upstairs neighbor got a treadmill.",
                "At what time does he use the treadmill?",
                "Four thirty in the morning. Every morning. Thump, thump, thump.",
                "Is he training for something?",
                "He's training to ruin my life.",
                "You should go up there and run with him. Make it a bonding thing.",
                "I'm not running at four thirty in the morning, Pete.",
                "That's fair, nobody should be awake at four thirty.",
                "Did you leave a note? People leave notes.",
                "I wrote a note. I wrote four drafts of a note. The first one just said why.",
                "That's a strong opening.",
                "The second one had a diagram.",
                "A diagram of what?",
                "Of my ceiling. With arrows. Where the thumping is.",
                "You drew the man a map of his own treadmill.",
                "I drew him a map of my suffering, Pete.",
                "Did he write back?",
                "He left a sticky note on my door that said sorry, big race in March.",
                "So you've got until March.",
                "I've got until March, and then I assume he gets a rowing machine.",
                "Honestly a rowing machine is quieter. I had one for a week.",
                "What happened after a week?",
                "It became a place to hang shirts.",
                "Everything becomes a place to hang shirts.",
                "My whole apartment is a place to hang shirts, that's why I sleep on the couch.",
                "We're going to come back to the couch.",
                "We're not.",
                "We are. But first, I did something this week I've never done before. I went to a town hall meeting.",
                "On purpose?",
                "On purpose. There was a vote about a stop sign.",
                "For or against?",
                "I was for the stop sign. A man named Gary was against it, and Gary had charts.",
                "Gary always has charts.",
                "Gary had a laser pointer. For a stop sign. It went two hours.",
                "Who won?",
                "Nobody won. They formed a committee to study the stop sign.",
                "That's the most American sentence I've ever heard.",
                "I volunteered for the committee.",
                "Of course you did.",
            ]),
            .either(["Speaking of being awake, we've got some news."]),
            .cut(.plug, kind: "SELFPROMO", speech: .plug, situations: ["own plug"], [
                "We are going on tour this fall. The Late Shift Live tour.",
                "Denver on the fourth, Austin on the twelfth, Chicago on the twentieth.",
                "Tickets are on sale now at lateshiftlive dot com.",
                "Come say hi, we'll hang out after every show.",
            ]),
            .show([
                "Okay so my back has been killing me all week.",
                "You sleep on a couch, that's why.",
                "I sleep on a very nice couch.",
                "It's a couch, Pete. It's not a bed.",
                "It has a pull-out.",
                "And do you pull it out?",
                "No.",
                "There it is.",
            ]),
            .trap("the joke ad", situation: "selling words in the show", [
                "You know what this show needs? A sponsor for my bad back.",
                "Introducing Pete's Back Brace, now with extra duct tape, use code OUCH for nothing off.",
                "Pete's Back Brace, because you'll never sleep in a real bed. Side effects include sadness.",
            ]),
            .show([
                "Please nobody make that, I'm begging you.",
            ]),
            .trap("the tour stories", situation: "plug words in the show", [
                "Our last tour, though, the hotel in Denver had the worst beds I've ever slept on.",
                "That was the one where the fire alarm went off at three in the morning.",
                "And everyone was in the parking lot in pajamas, and a guy asked us for a picture.",
                "In the parking lot. At three in the morning. And we said yes.",
            ]),
            .show([
                "We always say yes, that's the job.",
                "I'd say yes in a parking lot at three in the morning to anybody, that's just how I was raised.",
                "That's not a good thing, Pete.",
                "It's gotten me into two cults and one timeshare.",
                "Which was worse?",
                "The timeshare. The cults had snacks.",
            ]),
            .either([
                "Anyway, speaking of beds, Pete, I have a recommendation for you.",
                "Is this a real one or another back brace?",
                "This one's real.",
                "Okay, go.",
                "We'll get to Sam in a minute, but first, this.",
            ]),
            .cut(.ad, kind: "AD", speech: .hostRead, situations: ["host read", "long read", "back to back"], [
                "Today's episode is supported by Brightnest, the mattress company.",
                "And Pete, I'm serious, you need to hear this.",
                "I've been sleeping on my Brightnest for three weeks, and my back finally stopped hurting.",
                "It's got these layers of foam with a coil system underneath, so it's firm but it gives a little.",
                "I'm a side sleeper, and they have a whole quiz on the website that tells you which one to get.",
                "I took the quiz, it took about two minutes, and it said I should get the Brightnest Hybrid.",
                "It shows up in a box at your door. You open it, it unrolls, and in a few hours it's a full mattress.",
                "My cat was very confused. She sat on it while it was inflating, it was the best thing I've ever seen.",
                "And here's the part I like: you get a hundred nights to try it at home.",
                "A hundred nights, Pete. That's more than three months.",
                "If you don't love it, they come and pick it up for free and give you all your money back.",
                "And they've got a ten-year warranty, so you're not buying a new one in two years.",
                "They make pillows too, and sheets, and the sheets are the cooling kind.",
                "I run hot at night, and the cooling sheets actually work, I'm not just saying that.",
                "Brightnest has over twenty thousand five-star reviews.",
                "People love these things. My sister bought one after she slept over at my place.",
                "She texted me a picture of the box at seven in the morning, like, it's here.",
                "And the delivery is free, and they'll take your old mattress away if you want.",
                "They have a payment plan too, so you can spread it over a year with no interest.",
                "Every Brightnest is made here, in their own factory, and it ships in about a week.",
                "I've had mine through one heat wave already and I slept like a rock.",
                "It comes in every size, twin up to California king, and there's a firmer one for back sleepers.",
                "That's the one you want, Pete. The firm one. For the back.",
                "So here's the deal for Late Shift listeners.",
                "Go to brightnest dot com slash late and you'll get fifteen percent off your mattress.",
                "Plus they'll throw in two free pillows.",
                "That's brightnest dot com slash late, fifteen percent off and two free pillows.",
                "Brightnest dot com slash late.",
                "Seriously, Pete, get a bed.",
                "Thanks to Brightnest for supporting the show.",
            ]),
            .cut(.ad, kind: "AD", speech: .hostRead, situations: ["host read", "short spot", "back to back"], [
                "And this episode is also brought to you by Ridgeline Bank. No overdraft fees, no minimum balance.",
                "Open an account in five minutes at ridgeline dot com slash late.",
                "Ridgeline Bank, member FDIC.",
            ]),
            .either(["Okay, we're back, and we have a guest today."]),

            // Act two: the guest, the first plug round, the middle break.
            .show([
                "Our guest is the very funny comedian Sam Ortiz.",
                "Thanks for having me, I love this show, I listen in the car.",
                "You listen to this in the car? On purpose?",
                "On purpose, it keeps me awake on long drives.",
                "So Sam, you grew up in Tucson, right?",
                "Tucson, yeah, it's a hundred and ten degrees and everyone is fine with it.",
                "My dad used to fry eggs on the hood of his truck to prove a point.",
                "What was the point?",
                "I don't know, man. I think the point was that it was hot.",
                "Did the eggs cook?",
                "They kind of cooked. They were sad eggs.",
                "Did he eat them?",
                "He ate one. To prove the second point, which was that he was right.",
                "That's a dad. That's every dad.",
                "My dad once drove four hours in the wrong direction rather than ask my mom for the map.",
                "Where did you end up?",
                "Nebraska. We were going to the beach.",
                "There's no beach in Nebraska.",
                "He found a lake and said, see, there it is.",
                "And you all just got out and swam in the lake?",
                "We swam in the lake. It was a good lake. Nobody ever brought it up again.",
                "When did you start doing stand-up? Was it in Tucson?",
                "It was in Tucson, at a place that was a laundromat during the day.",
                "A laundromat.",
                "They'd push the folding tables together and that was the stage.",
                "How was the sound?",
                "The sound was dryers. I thought I was getting laughs for a year. It was a zipper in a dryer.",
                "That's the saddest thing you've said so far.",
                "It gets worse. The owner paid us in quarters.",
                "For the machines?",
                "For the machines. I had the cleanest clothes of any failing comedian in Arizona.",
                "When did it turn around for you?",
                "When I moved and got a bad neighbor. Truly. I had nothing to say until that man bought a drum kit.",
                "So you've got a neighbor story too, I heard.",
                "Oh, I have the worst neighbor story.",
                "My upstairs neighbor plays the drums at two in the morning.",
                "Just drums? No band?",
                "No band, just him and his anger.",
                "Did you ever complain?",
                "I wrote an hour of comedy about it instead, that's my complaint.",
                "That's the healthiest thing I've ever heard.",
                "It's not healthy, I'm very tired.",
                "Did he ever find out?",
                "He came to the taping. He sat in the front row.",
                "No way.",
                "He laughed at all the drum jokes. Then he went home and played the drums.",
                "That's incredible.",
            ]),
            .cut(.plug, kind: "SELFPROMO", speech: .plug, situations: ["plug round"], [
                "So where can people see the hour?",
                "It's called Loud Neighbors, it's streaming on Netflix starting Friday.",
                "And I'm on tour all winter, all the dates are at samortizcomedy dot com.",
                "I'm on Instagram at sam ortiz jokes, and the podcast is Late Again, wherever you listen.",
                "Go watch it, I think it's the best thing I've ever done.",
            ]),
            .show([
                "We watched it, it's really good.",
                "You did? You actually watched it?",
                "I watched it twice. The part about the drum solo at the wedding, I was crying.",
                "That's a true story too, by the way.",
                "Everything in it is true?",
                "Ninety percent. The other ten percent I made up to make my mom look better.",
                "That's very sweet.",
                "She doesn't think so. She thinks I made her look old.",
                "How old does she think she looks?",
                "She thinks she looks thirty-nine. She has thought that since I was nine.",
                "My mom still tells people I'm in radio.",
                "This isn't radio?",
                "This is two people in a closet with a blanket on the wall, Sam.",
                "It's a nice blanket.",
                "Thank you. It was my grandmother's. She would hate this show.",
                "What would she hate about it?",
                "The talking. She thought anything worth saying could be said in a card.",
                "She's not wrong. Most of this could be a card.",
                "This whole episode could be a card that says my neighbor is loud.",
                "With a diagram.",
                "With a diagram on the back.",
                "Sam, do you write on the road or do you have to be home?",
                "I write in the car. I talk into my phone like a lunatic at red lights.",
                "Do people look at you?",
                "People assume I'm on a call. I'm not. I'm yelling the word bagpipes into a notes app.",
                "And then you listen back later?",
                "I listen back and it's just me saying no, no, that's not it, for eleven minutes.",
                "That's also this show.",
                "How long did the hour take to put together?",
                "Two years. A year to write it and a year to cut the parts where I was mean about my mom.",
                "How much of it was mean about your mom?",
                "At one point? Forty minutes.",
                "And she's seen it?",
                "She's seen it. She gave me a note. She said the drum part goes on too long.",
                "Does it?",
                "A little. She's right. Don't tell her.",
            ]),
            .either(["Okay, hold that thought, we have to take one more quick break."]),
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "back to back"], [
                "Your feet called. They want better shoes.",
                "Kestrel running shoes are built on a foam that gives back with every step.",
                "Try them for thirty days. If your feet don't thank you, send them back, free.",
                "Kestrel. Find your pair at kestrel run dot com.",
            ]),
            .cut(.network, kind: "CROSSPROMO", speech: .promo, situations: ["other show", "back to back"], [
                "If you like this show, check out Morning Static, another Wavelength Media podcast.",
                "Every Tuesday, Dana and Rob break down the week's weirdest news.",
                "Search Morning Static wherever you listen.",
            ]),
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "short spot", "back to back"], [
                "Taxes done in an afternoon? With Ledgerly, yes.",
                "Snap your forms, answer a few questions, and file from your couch. Start free at ledgerly dot com.",
                "Ledgerly. State filing extra. See site for details.",
            ]),
            .either(["And we're back with Sam Ortiz."]),

            // Act three: the regular segment, with a listener's gadget.
            .show([
                "Okay, it's time for Neighbor Court, where you send us your neighbor and we rule on it.",
                "I'm the judge. Pete is the bailiff. Sam, you're the jury.",
                "I've never been picked for a jury. This is a big day for me.",
                "First case. This is from a listener named Jess.",
                "Jess says her neighbor plays the bagpipes.",
                "Bagpipes. That's worse than drums.",
                "That's worse than drums and a treadmill combined.",
                "Indoors or outdoors? It matters legally.",
                "On the balcony. At sunset. Every Sunday.",
                "Okay, that's almost beautiful. I'm conflicted.",
                "Jury?",
                "Guilty. But I want to hear him play first.",
            ]),
            .trap("the listener's gadget", situation: "selling words in the show", [
                "Second case. Dana in Ohio says her downstairs neighbor snores through the floor.",
                "She says she bought a white noise machine, the little round one, thirty bucks online, and it saved her lease.",
                "Should we tell people which one? No. They didn't pay us. Buy any of them.",
            ]),
            .show([
                "Ruling: the snorer is innocent. You can't arrest a man for his sinuses.",
                "I'd like it noted that I snore and I feel seen by this court.",
                "Third case, and this is a good one. A man named Walt.",
                "Walt's neighbor has a rooster. In an apartment.",
                "In an apartment?",
                "On the fourth floor. The rooster's name is Gerald.",
                "Does Gerald know what time it is?",
                "Gerald believes it is always dawn.",
                "I respect Gerald. Gerald has a job and he does it.",
                "Guilty, but only the landlord. Gerald walks free.",
                "Fourth case. This one is short. Priya says her neighbor vacuums at midnight.",
                "Every night?",
                "Every night. For one minute. Just one minute, and then it stops.",
                "What is he vacuuming for one minute?",
                "That's the question, Pete. That's what keeps Priya up. Not the noise. The mystery.",
                "I think it's one specific crumb.",
                "I think he drops the crumb on purpose so he has something to do.",
                "Not guilty. That's a lonely man with a hobby.",
                "Fifth and final case. Marcus says his neighbor practices the same eight seconds of a trumpet solo.",
                "Only eight seconds?",
                "The same eight seconds, for an hour, and he never gets to second nine.",
                "Oh, that would break me. I need to know how it ends.",
                "Marcus says he looked up the song and now he sings second nine through the wall.",
                "Does the neighbor take the hint?",
                "The neighbor thinks the building is haunted by a man who knows the song.",
                "Guilty. Both of them. I sentence them to form a band.",
                "Court is adjourned. Pete, hit the thing.",
                "I don't have a thing. I have a coffee mug.",
                "Hit the mug.",
            ]),
            .trap("the ticket story", situation: "plug words in the show", [
                "Sam, you had a show in Cleveland once where the tickets were priced wrong, right?",
                "They listed them at four dollars instead of forty. It sold out in nine minutes.",
                "Biggest crowd of my life, and every one of them had paid less than a sandwich.",
                "Best audience I ever had, though. Nobody expects anything for four dollars.",
            ]),
            .show([
                "Did the club make you pay the difference?",
                "They tried. I said, you typed it, not me.",
                "That's a strong legal argument.",
                "I learned it in Neighbor Court.",
            ]),
            .either(["Alright, before we wrap up with Sam, one more thing."]),

            // The read with the hosts wandering off in the middle.
            .cut(.ad, kind: "AD", speech: .hostRead, situations: ["host read"], [
                "This episode is also sponsored by Hushwell, and this one is very on theme.",
                "Hushwell makes earplugs you can actually sleep in. They're soft, they don't fall out.",
                "I've been wearing them since the treadmill started, and I slept until seven yesterday.",
                "Sam, you should send a pair to yourself in the past.",
                "I'd have had no career, but I'd be rested.",
                "They come in a little case, four sizes of tips, and they cut the noise without that underwater feeling.",
            ]),
            .either([
                "My brother snores so loud that on a camping trip a ranger came to check on us.",
                "A ranger. With a flashlight. He thought it was a bear.",
                "What did your brother say?",
                "He didn't wake up. That's the whole point of the story.",
            ]),
            .cut(.ad, kind: "AD", speech: .hostRead, situations: ["host read"], [
                "Anyway, that's who Hushwell is for. The rest of the tent.",
                "Right now Late Shift listeners get twenty percent off their first order.",
                "Go to hushwell dot com slash shift and use code SHIFT at checkout.",
                "That's hushwell dot com slash shift, code SHIFT, for twenty percent off.",
                "Hushwell. Sleep through it.",
            ]),
            .either(["Okay. Sam. Last few questions."]),

            // Act four: the wrap-up, the plug round in conversation, the end.
            .show([
                "Go for it.",
                "Best thing about Tucson?",
                "The sunsets. Hands down. The whole sky goes pink and orange.",
                "And the worst thing?",
                "Everything else between June and September.",
                "Do you ever go back?",
                "Every Christmas. My dad still has the truck.",
                "Does he still do the eggs?",
                "He does the eggs for the grandkids now. It's a tradition. Nobody eats them.",
                "What's the worst gig you ever did?",
                "A birthday party on a boat. For a dog.",
                "The dog was turning what?",
                "Seven. He didn't laugh once.",
                "Dogs are a tough room.",
                "Did you get paid at least?",
                "I got paid, and the dog's owner tipped me in dog treats, which I thought was a joke until I opened the bag.",
                "Did you eat one?",
                "I'm not going to answer that on a podcast my mother listens to.",
                "So that's a yes.",
                "It tasted like a cracker that gave up.",
                "What's the best gig you ever did, then?",
                "Honestly? The taping. My mom in the second row, my neighbor in the first, and nobody threw anything.",
                "That's a low bar.",
                "I've had things thrown. A shoe, once. In Reno.",
                "One shoe?",
                "One shoe. He hopped out. I still think about him getting home.",
                "Do you have a pre-show ritual?",
                "I eat a banana and I apologize to it.",
                "Why do you apologize?",
                "I don't know. It started as a bit and now I can't go on unless I've said sorry to a banana.",
                "That's a cult. You're in a cult with yourself.",
                "It has snacks, though.",
                "What are you working on next?",
                "The next hour is about my dad and the lake. He doesn't know yet.",
                "He's going to love it.",
                "He's going to say it wasn't Nebraska. It was Nebraska.",
            ]),
            .cut(.plug, kind: "SELFPROMO", speech: .plug, situations: ["plug round"], [
                "Alright Sam, this was a blast. Tell people where to find you one more time.",
                "Sure. So the special is Loud Neighbors, it's on Netflix Friday.",
                "And you're in Phoenix next month, right? Plug the dates.",
                "Phoenix on the ninth, San Diego on the tenth, then Portland and Seattle the week after.",
                "And tickets are where?",
                "Everything's at samortizcomedy dot com, tickets, dates, the merch, all of it.",
                "Go see him. Buy a shirt.",
            ]),
            .show([
                "Thanks guys, this was fun, I'll come back anytime.",
                "Okay, Pete, before we go, I need an update on the couch situation.",
                "I have decided to pull out the pull-out.",
                "Wow. Growth.",
                "One night. As a test.",
                "That's all we ask.",
                "And if my back still hurts, I'm blaming you.",
                "I'll take that deal.",
                "Did the committee meet yet? The stop sign committee?",
                "We meet Thursday. Gary is bringing more charts.",
                "Bring your own charts.",
                "I'm bringing the diagram of my ceiling. I think it applies.",
                "It doesn't apply.",
                "Everything applies if you have arrows on it.",
                "We also got a correction this week. Last episode I said a tomato is a vegetable.",
                "It's a fruit.",
                "Forty people wrote in. One of them was a botanist and she was very kind about it.",
                "What did the unkind ones say?",
                "One just wrote the word fruit, eleven times.",
                "That's fair.",
                "It is fair. I apologize to tomatoes and to the botanist.",
                "And to the banana.",
                "That's Sam's thing, leave the banana out of it.",
                "Pete, fix the microphone before next week.",
                "I will fix the microphone. Probably.",
            ]),
            .cut(.introOutro, kind: "OUTRO", speech: .credits, situations: ["outro"], [
                "That's the show, thanks to Sam Ortiz for stopping by.",
                "Late Shift is produced by Danny Cole, with music by The Fold.",
                "Our executive producer is Rina Park, for Wavelength Media.",
                "See you next week, everybody.",
            ]),
            .cut(.plug, kind: "SELFPROMO", speech: .plug, situations: ["own plug", "post-roll"], [
                "Hey, it's Nora again. If you want more Late Shift, we do a bonus episode every week.",
                "It's on our Patreon, patreon dot com slash late shift.",
                "Five dollars a month gets you every bonus and the full video of every episode.",
                "It's the best way to support the show. Thank you, seriously.",
            ]),
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "post-roll", "back to back"], [
                "Need a website? Make one in an afternoon with Pagecraft.",
                "Pick a template, drag in your photos, and you're online.",
                "Plans start at twelve dollars a month with a free domain for a year.",
                "Go to pagecraft dot com and use code SHIFT for ten percent off.",
                "Pagecraft. Build it today.",
            ]),
            .cut(.ad, kind: "AD", speech: .spot, situations: ["produced spot", "short spot", "post-roll", "back to back"], [
                "Winter's coming. Are your tires ready?",
                "Get four Northwind all-season tires installed for the price of three, this month only.",
                "Northwind Tire and Auto. Find a shop at northwind tire dot com.",
            ]),
        ])
}
