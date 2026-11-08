import Foundation

/// Pass 62 (his 8 Nov request: Basic and Hard must be representative, not
/// toy samples, and scored the way the PodSkipper Test scores): version 3 of
/// the two samples every finder takes in Compare Models.
///
/// Both are written from the patterns in his labelled episodes (the
/// PodSkipper Test's 14 situations), with made-up shows, hosts and brands so
/// no finder has seen them. Each line is about six seconds of speech.
///
/// - **Basic** (93 lines, 9 min): an everyday episode — a recorded pre-roll,
///   the show's intro, a host-read ad in the middle, the credits and a
///   recorded post-roll.
/// - **Hard** (164 lines, 16 min): every situation at once — intro, two
///   recorded spots back to back in the first minute (one under 20 s), the
///   show's own tour plug, brand talk nobody paid for and a joke ad (both
///   kept), tour stories that only sound like a plug (kept), a host read of
///   more than two minutes followed at once by a 15-second one, the guest's
///   plug when the host asks for it, another show's promo, the credits, a
///   Patreon plug after them and a recorded post-roll.
///
/// The score is `PodTestScore`'s Everyday score on the sample as one episode
/// (0–100, shown as a percentage): seconds of each break heard past a 2 s
/// edge allowance, 10 s for each break you would notice, twice every second
/// of the show cut and 10 s for every jump — against skipping nothing.
struct BenchScript: Sendable {
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

    var show: String
    var episode: String
    var notes: String
    var lines: [String]
    var breaks: [Break]
    var traps: [Trap]
    /// Hand-offs and returns: cutting or keeping them are both right.
    var either: Set<Int>

    static let secondsPerLine = 6.0
    static let lineLength = 5.5

    static func start(_ line: Int) -> Double { Double(line) * secondsPerLine }
    static func end(_ line: Int) -> Double { Double(line) * secondsPerLine + lineLength }

    /// The sample as one PodSkipper Test episode.
    var episodeForScoring: PodTestPack.Episode {
        let labelled = breaks.map { [Self.start($0.lines.lowerBound), Self.end($0.lines.upperBound)] }
            + either.sorted().map { [Self.start($0), Self.end($0)] }
        return PodTestPack.Episode(
            guid: "bench:" + episode, show: show, duration: Self.end(lines.count - 1),
            breaks: breaks.map { PodTestPack.Break(start: Self.start($0.lines.lowerBound), end: Self.end($0.lines.upperBound),
                                                   kind: $0.kind, situations: $0.situations) },
            labelled: labelled,
            traps: traps.map { PodTestPack.Trap(start: Self.start($0.lines.lowerBound), end: Self.end($0.lines.upperBound),
                                                situation: $0.situation) })
    }

    /// Cut lines as time spans: each run of consecutive lines is one cut.
    static func cuts(_ lines: Set<Int>) -> [PodTestCut] {
        var out: [PodTestCut] = []
        for line in lines.sorted() {
            if let last = out.last, abs(last.end - end(line - 1)) < 1e-9 {
                out[out.count - 1].end = end(line)
            } else {
                out.append(PodTestCut(start: start(line), end: end(line), kind: "cut"))
            }
        }
        return out
    }

    /// PodSkipper Test constants (`Resources/Detection/PodTest.json`).
    static let constants = PodTestPack.bundled()?.constants
        ?? PodTestPack.Constants(edge: 2, noticed: 5, noticeCost: 10, showWeight: 2, jump: 2, jumpCost: 10, showMargin: 1)

    /// Everyday score (0–100) of cutting these lines.
    func everyday(cut: Set<Int>) -> Double {
        let e = episodeForScoring
        let row = PodTestScore.episode(e, cuts: Self.cuts(cut), constants: Self.constants)
        return PodTestScore.everyday([e.guid: row], showOf: [e.guid: e.show]) ?? 0
    }

    // MARK: Basic

    static let basic = BenchScript(
        show: "Kitchen Table",
        episode: "The Great Sourdough Feud",
        notes: "Maya and Jordan settle the sourdough argument once and for all. Sponsored by Freshbox and Harbor Insurance.",
        lines: [
            // 0–4 recorded pre-roll
            "Switching car insurance shouldn't feel like a second job.",
            "With Harbor Insurance, you can get a quote in about four minutes, right from your phone.",
            "Drivers who switched saved an average of five hundred and twelve dollars a year.",
            "Get your free quote today at harborinsurance dot com.",
            "Harbor Insurance. Savings vary. Underwritten by Harbor Mutual Group.",
            // 5–6 intro
            "Welcome to Kitchen Table, the show where we argue about food so you don't have to. I'm Maya.",
            "And I'm Jordan, and today we are finally settling the sourdough thing.",
            // 7–33 show
            "Okay, so for anyone who missed it, last week Jordan said sourdough is just bread with a publicist.",
            "And I stand by that. It's bread. It's flour, water and salt with an attitude.",
            "It is not just attitude, it's wild yeast, it's fermentation, it's a living thing on my counter.",
            "You named it. You named the jar. What's it called again?",
            "Its name is Doughlores, and she is fourteen months old.",
            "Fourteen months of feeding a jar instead of buying a loaf for four dollars.",
            "The loaf you buy for four dollars is full of things I can't pronounce.",
            "So is half the stuff in your spice cabinet.",
            "That's different, that's flavor.",
            "Okay, but here's my real question. Does it actually taste different, or do people just say it does?",
            "It tastes completely different. It's tangy, the crust crackles, the inside is chewy.",
            "I'll give you the crust. The crust is good.",
            "Thank you. That's the fermentation and the steam in the oven.",
            "I tried making one during the lockdown, like everybody did.",
            "How did that go?",
            "It came out like a hockey puck. A dense, sour hockey puck.",
            "That's because you didn't let it rise long enough. You have to be patient.",
            "I was patient for six hours, Maya.",
            "Six hours is nothing. Mine proofs overnight in the fridge.",
            "See, this is what I mean. Overnight. For bread.",
            "Good things take time. You'd know that if you ever cooked anything that wasn't in a microwave.",
            "Hey, I make an excellent omelet.",
            "You make a scrambled egg and fold it and call it an omelet.",
            "That's an omelet. That's literally what an omelet is.",
            "We're getting off track. Let's settle this with a blind taste test after the break.",
            "Fine. But I'm picking the store bread.",
            // 33 hand-off (either)
            "Deal. We'll be right back.",
            // 34–45 host-read ad
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
            // 46 return (either)
            "Okay, we're back, and I have two slices in front of me.",
            // 47–84 show
            "One is my sourdough, one is whatever Jordan bought at the gas station.",
            "It wasn't the gas station, it was the grocery store. It has seeds on it.",
            "Okay, I'm closing my eyes. Hand me slice number one.",
            "Here you go.",
            "Hmm. This is soft. This is sweet. This is the store bread, obviously.",
            "Correct. Now slice number two.",
            "Oh. Oh no.",
            "What? What's wrong?",
            "It's really good. It's tangy, and the crust, okay, I hate this.",
            "Ha! Doughlores wins.",
            "I'm not saying it's worth fourteen months of feeding a jar.",
            "But you're saying it's better.",
            "I'm saying it's better bread. I'm not saying it's a better life choice.",
            "I'll take it. That's a win for team sourdough.",
            "We got a lot of messages about this last week, by the way.",
            "So many. Someone sent me a photo of their starter, it's named Bread Pitt.",
            "That's a great name. Better than Doughlores, honestly.",
            "Excuse me.",
            "Another listener said her grandmother kept the same starter for forty years.",
            "Forty years? That jar is older than me.",
            "That's the thing, it gets passed down. It's like a family heirloom you can eat.",
            "Okay, that's actually kind of beautiful.",
            "See? You're coming around.",
            "Don't push it. Next week we're doing the hot sauce episode and I'm going to win that one.",
            "You can't handle spice. You put milk in your curry.",
            "That was one time and it was too hot for anyone.",
            "It was a mild curry, Jordan.",
            "Anyway, if you have a hot sauce you think we should try, write in and tell us.",
            "We read every message, even the mean ones.",
            "Especially the mean ones.",
            "Okay, I think that settles it. Sourdough is better, and Jordan has to admit it on the record.",
            "I admit the bread is better. I do not admit that I was wrong.",
            "That's literally the same thing.",
            "It is not, and that's going to be the title of my memoir.",
            "Alright, that's our show. Thanks for sitting down at the Kitchen Table with us.",
            "Go hug your starter. Or don't. Buy the store bread. I won't judge.",
            "You will judge.",
            "I will a little bit judge.",
            // 85–87 credits
            "Kitchen Table is produced by Priya Shah and edited by Tom Becker.",
            "Our theme music is by The Lowlights.",
            "Kitchen Table is a Copperline Audio production.",
            // 88–92 recorded post-roll
            "Ever wish your phone plan just worked? With Signal Mobile, it does.",
            "Unlimited talk, text and data on the nation's fastest network, for just twenty-five dollars a month.",
            "No contracts, no hidden fees, and you keep your number.",
            "Switch in minutes at signalmobile dot com.",
            "Signal Mobile. Taxes and fees extra. Speeds may slow after thirty-five gigabytes.",
        ],
        breaks: [
            Break(lines: 0...4, category: .ad, kind: "AD", situations: ["produced spot", "pre-roll"]),
            Break(lines: 5...6, category: .introOutro, kind: "INTRO", situations: ["intro"]),
            Break(lines: 34...45, category: .ad, kind: "AD", situations: ["host read"]),
            Break(lines: 85...87, category: .introOutro, kind: "OUTRO", situations: ["outro"]),
            Break(lines: 88...92, category: .ad, kind: "AD", situations: ["produced spot", "post-roll"]),
        ],
        traps: [],
        either: [33, 46])

    // MARK: Hard

    static let hard = BenchScript(
        show: "Late Shift",
        episode: "Loud Neighbors (with Sam Ortiz)",
        notes: "Comedian Sam Ortiz joins Nora and Pete to talk about loud neighbors, Tucson summers and the new special. Supported by Brightnest and Ridgeline Bank.",
        lines: [
            // 0–2 intro
            "You're listening to Late Shift with Nora and Pete.",
            "A Wavelength Media podcast.",
            "Here we go.",
            // 3–5 recorded spot, 18 s
            "Tired of overdraft fees? Ridgeline Bank has none. Not one.",
            "Open a checking account in five minutes at ridgeline dot com.",
            "Ridgeline Bank. Member FDIC.",
            // 6–9 recorded spot, back to back
            "This winter, Arcadia Air is flying nonstop to more warm places than ever.",
            "Fares to Cancun, Tucson and Honolulu start at ninety-nine dollars each way.",
            "Book by Friday at arcadia air dot com.",
            "Arcadia Air. Restrictions apply. Fares are one way and include taxes.",
            // 10–30 show
            "Hey everybody, welcome back to Late Shift. I'm Nora, Pete is here.",
            "Hello, hello.",
            "I went to Costco yesterday and bought forty rolls of paper towels.",
            "Forty. For one person. What's your plan there?",
            "The plan is I never think about paper towels again until 2028.",
            "Did you at least get the hot dog?",
            "Of course I got the hot dog, a dollar fifty, it's the last honest price in America.",
            "That's actually true, Costco is great, I'm not even getting paid to say that.",
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
            "Speaking of being awake, we've got some news.",
            // 31–34 own plug (tour)
            "We are going on tour this fall. The Late Shift Live tour.",
            "Denver on the fourth, Austin on the twelfth, Chicago on the twentieth.",
            "Tickets are on sale now at lateshiftlive dot com.",
            "Come say hi, we'll hang out after every show.",
            // 35–55 show
            "Okay so my back has been killing me all week.",
            "You sleep on a couch, that's why.",
            "I sleep on a very nice couch.",
            "It's a couch, Pete. It's not a bed.",
            "It has a pull-out.",
            "And do you pull it out?",
            "No.",
            "There it is.",
            "You know what this show needs? A sponsor for my bad back.",
            "Introducing Pete's Back Brace, now with extra duct tape, use code OUCH for nothing off.",
            "Pete's Back Brace, because you'll never sleep in a real bed. Side effects include sadness.",
            "Please nobody make that, I'm begging you.",
            "Our last tour, though, the hotel in Denver had the worst beds I've ever slept on.",
            "That was the one where the fire alarm went off at three in the morning.",
            "And everyone was in the parking lot in pajamas, and a guy asked us for a picture.",
            "In the parking lot. At three in the morning. And we said yes.",
            "We always say yes, that's the job.",
            "Anyway, speaking of beds, Pete, I have a recommendation for you.",
            "Is this a real one or another back brace?",
            "This one's real.",
            "Okay, go.",
            // 56 hand-off (either)
            "We'll get to Sam in a minute, but first, this.",
            // 57–80 host read, 144 s
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
            "So here's the deal for Late Shift listeners.",
            "Go to brightnest dot com slash late and you'll get fifteen percent off your mattress.",
            "Plus they'll throw in two free pillows.",
            "That's brightnest dot com slash late, fifteen percent off and two free pillows.",
            "Brightnest dot com slash late.",
            "Seriously, Pete, get a bed.",
            "Thanks to Brightnest for supporting the show.",
            // 81–83 host read, 15 s, back to back
            "And this episode is also brought to you by Ridgeline Bank. No overdraft fees, no minimum balance.",
            "Open an account in five minutes at ridgeline dot com slash late.",
            "Ridgeline Bank, member FDIC.",
            // 84 return (either)
            "Okay, we're back, and we have a guest today.",
            // 85–110 show with the guest
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
            "So where can people see the hour?",
            // 111–114 plug round (the host asks)
            "It's called Loud Neighbors, it's streaming on Netflix starting Friday.",
            "And I'm on tour all winter, all the dates are at samortizcomedy dot com.",
            "I'm on Instagram at sam ortiz jokes, and the podcast is Late Again, wherever you listen.",
            "Go watch it, I think it's the best thing I've ever done.",
            // 115–130 show
            "We watched it, it's really good.",
            "You did? You actually watched it?",
            "I watched it twice. The part about the drum solo at the wedding, I was crying.",
            "That's a true story too, by the way.",
            "Everything in it is true?",
            "Ninety percent. The other ten percent I made up to make my mom look better.",
            "That's very sweet.",
            "She doesn't think so. She thinks I made her look old.",
            "Alright, before we let you go, one last question.",
            "Go for it.",
            "Best thing about Tucson?",
            "The sunsets. Hands down. The whole sky goes pink and orange.",
            "And the worst thing?",
            "Everything else between June and September.",
            "Alright Sam, this was a blast.",
            "Thanks guys, this was fun, I'll come back anytime.",
            // 131–133 another show's promo
            "If you like this show, check out Morning Static, another Wavelength Media podcast.",
            "Every Tuesday, Dana and Rob break down the week's weirdest news.",
            "Search Morning Static wherever you listen.",
            // 134–150 show
            "Okay, Pete, before we go, I need an update on the couch situation.",
            "I have decided to pull out the pull-out.",
            "Wow. Growth.",
            "One night. As a test.",
            "That's all we ask.",
            "And if my back still hurts, I'm blaming you.",
            "I'll take that deal.",
            "Also, we got an email from a listener named Jess.",
            "Jess says her neighbor plays the bagpipes.",
            "Bagpipes. That's worse than drums.",
            "That's worse than drums and a treadmill combined.",
            "Jess, we're so sorry, there's nothing we can do for you.",
            "Move. That's my advice.",
            "That's terrible advice.",
            "It's the only advice.",
            "Pete, fix the microphone before next week.",
            "I will fix the microphone. Probably.",
            // 151–154 credits
            "That's the show, thanks to Sam Ortiz for stopping by.",
            "Late Shift is produced by Danny Cole, with music by The Fold.",
            "Our executive producer is Rina Park, for Wavelength Media.",
            "See you next week, everybody.",
            // 155–158 own plug after the credits
            "Hey, it's Nora again. If you want more Late Shift, we do a bonus episode every week.",
            "It's on our Patreon, patreon dot com slash late shift.",
            "Five dollars a month gets you every bonus and the full video of every episode.",
            "It's the best way to support the show. Thank you, seriously.",
            // 159–163 recorded post-roll
            "Need a website? Make one in an afternoon with Pagecraft.",
            "Pick a template, drag in your photos, and you're online.",
            "Plans start at twelve dollars a month with a free domain for a year.",
            "Go to pagecraft dot com and use code SHIFT for ten percent off.",
            "Pagecraft. Build it today.",
        ],
        breaks: [
            Break(lines: 0...2, category: .introOutro, kind: "INTRO", situations: ["intro"]),
            Break(lines: 3...5, category: .ad, kind: "AD", situations: ["produced spot", "short spot", "pre-roll", "back to back"]),
            Break(lines: 6...9, category: .ad, kind: "AD", situations: ["produced spot", "pre-roll", "back to back"]),
            Break(lines: 31...34, category: .plug, kind: "SELFPROMO", situations: ["own plug"]),
            Break(lines: 57...80, category: .ad, kind: "AD", situations: ["host read", "long read", "back to back"]),
            Break(lines: 81...83, category: .ad, kind: "AD", situations: ["host read", "short spot", "back to back"]),
            Break(lines: 111...114, category: .plug, kind: "SELFPROMO", situations: ["plug round"]),
            Break(lines: 131...133, category: .network, kind: "CROSSPROMO", situations: ["other show"]),
            Break(lines: 151...154, category: .introOutro, kind: "OUTRO", situations: ["outro"]),
            Break(lines: 155...158, category: .plug, kind: "SELFPROMO", situations: ["own plug", "post-roll"]),
            Break(lines: 159...163, category: .ad, kind: "AD", situations: ["produced spot", "post-roll", "back to back"]),
        ],
        traps: [
            Trap(name: "the brand chatter", lines: 16...17, situation: "selling words in the show"),
            Trap(name: "the joke ad", lines: 43...45, situation: "selling words in the show"),
            Trap(name: "the tour stories", lines: 47...50, situation: "plug words in the show"),
        ],
        either: [56, 84])
}
