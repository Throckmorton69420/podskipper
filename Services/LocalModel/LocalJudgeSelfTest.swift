import Foundation

/// The self-test on the model screen: 40 lines of made-up conversation with
/// one obvious host-read ad (lines 13–23: the hand-off, the Harborline
/// Coffee read, the code, the thank-you). Everything else is the show.
enum LocalJudgeSelfTest {
    static let show = "Dan and Mike Talk"
    static let title = "The Leaning Bookshelf"
    static let notes = "This episode is sponsored by Harborline Coffee."
    static let expected = "One host-read ad for Harborline Coffee, about lines 13–23."

    static let lines: [TimedLine] = {
        let text = [
            "Welcome back to the show, it's me and Dan, we're finally in the same room again.",
            "It's been, what, three weeks since we recorded together?",
            "Three weeks and you still owe me twenty dollars from the airport.",
            "I will pay you, I just don't carry cash anymore, nobody does.",
            "So this weekend I tried to build a bookshelf and it went very badly.",
            "Was it one of those flat pack ones with the tiny wrench?",
            "Yes, and the instructions had no words, just a little cartoon man looking happy.",
            "The cartoon man is always happy, that's the lie.",
            "I got to step twelve and realized the back panel was upside down since step two.",
            "So you took it all apart?",
            "I took it all apart, put it back together, and now it leans to the left.",
            "That's character. That's a bookshelf with a personality.",
            "My wife says it looks like it's trying to leave the room.",
            "Speaking of things that actually work, let's take a quick break.",
            "This episode is brought to you by Harborline Coffee.",
            "Harborline roasts every bag to order and ships it to your door within two days.",
            "I've been drinking their Morning Tide blend every day for a month now.",
            "It's smooth, it's not bitter, and honestly it's the only thing getting me up for these recordings.",
            "They've got whole bean, ground, and those little pods if you're lazy like Dan.",
            "I am lazy and I love the pods.",
            "Right now Harborline is giving our listeners twenty percent off your first order.",
            "Just go to harborlinecoffee dot com slash dan and use code DAN at checkout.",
            "That's harborlinecoffee dot com slash dan, code DAN, for twenty percent off. Terms apply.",
            "Thanks to Harborline for supporting the show.",
            "Okay, back to the bookshelf, because I have a follow-up question.",
            "Did you use the little wooden pegs or did you just skip them?",
            "I skipped them, there were forty of them, who has that kind of time?",
            "The pegs hold the whole thing together, that's why it leans.",
            "Now I know. Now I know why my life is the way it is.",
            "Anyway, my brother-in-law is coming over Saturday to fix it.",
            "Is he handy?",
            "He's a dentist, so he's good with small tools and he loves telling you what you did wrong.",
            "That's perfect, that's exactly who you want.",
            "We also got a lot of emails about the hot sauce episode last week.",
            "People were very upset that I said ketchup counts as a hot sauce.",
            "Because it doesn't, it's not hot, that's the whole point.",
            "It's hot if you microwave it.",
            "That's not what hot sauce means and you know it.",
            "Alright, that's our time, thanks for listening everybody.",
            "We'll see you next week, and Dan, pay me my twenty dollars.",
        ]
        return text.enumerated().map { index, line in
            TimedLine(text: line, start: Double(index) * 6, end: Double(index) * 6 + 5.5)
        }
    }()
}
