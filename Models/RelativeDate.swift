import Foundation

/// How a date reads when the point is "how long ago", not "which day".
///
/// The library used to label every show with its unplayed episode count, so a
/// show you had just followed announced "100 new". The count was true and
/// meaningless — none of those episodes were new, they were old and unheard.
/// What tells you something about a show at a glance is when it last put
/// something out, and these are the shapes that reads in.
///
/// The vocabulary follows what a listener expects from a podcast app: terse and
/// unspaced up close ("5m ago", "3h ago", "2d ago"), then a weekday inside the
/// last week, then a date. `Date.FormatStyle` is used for the calendar cases so
/// the result follows the reader's own locale and region rather than a format
/// string baked in here.
enum RelativeDate {

    /// The short form, for a metadata line under a title.
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)

        // A feed with a clock ahead of ours should not read "in 3 hours".
        if seconds < 60 { return "Just now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }

        // Inside a fortnight a weekday is more use than a number.
        if days < 14 { return date.formatted(.dateTime.weekday(.wide)) }

        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// A release date as an episode list writes it: "Sep 14" this year,
    /// "Dec 26, 2025" before it.
    static func release(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// The long form, for a show header where there is room for a sentence.
    static func long(_ date: Date, now: Date = .now) -> String {
        "Last updated \(short(date, now: now))"
    }

    /// A duration as a podcast app writes it: `54m`, `1h 54m`, `2h`.
    ///
    /// Fixed width matters here. The episode row's action button used to get
    /// squeezed out by a long duration, because `1h 54m` is half again as wide
    /// as `54m` and the row divided its space by measuring the text. The row now
    /// reserves the space instead, but keeping this compact is still what makes
    /// the reserved space small enough to be worth reserving.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    /// Time still to go, for a partly played episode.
    static func remaining(_ seconds: Double) -> String {
        guard seconds > 30 else { return "Finished" }
        return "\(duration(seconds)) left"
    }
}
