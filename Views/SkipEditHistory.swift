import SwiftData
import SwiftUI

/// Pass 35 (his 11 Oct report): Undo for "What was skipped" that covers
/// everything a change can do. The old Undo lived inside one opened cut, was
/// lost when it closed, and couldn't undo what an edge drag did to the cuts
/// next to it (trimmed, or taken in and removed), nor a cut added by mistake
/// and then removed.
///
/// Each change is undone by putting the whole episode's cuts back as they
/// were before it — every field of every cut, cuts that were removed brought
/// back, cuts that were added taken away — together with the episode's
/// correction log and the show's learned corrections, so an undone edit
/// stops counting as a lesson. Corrections filed in the app-wide list
/// (`GlobalCorrections`) are not rewound; they are matched against text and
/// only add weight, never cut on their own.
struct SegmentSnapshot: Equatable {
    var id: PersistentIdentifier?
    var start, end: Double
    var sponsor: String
    var confidence: Int
    var verdict: UserVerdict
    var kindRaw, deliveryRaw, detailRaw, detectedKindRaw, origin, evidenceText, containsRaw: String
    var isComedyBit, insertedAtDownload, isLocked: Bool
    var detectedStart, detectedEnd: Double
    var startConfidence, endConfidence: Int
    var mergedFromData: Data?

    init(_ s: AdSegment) {
        id = s.persistentModelID
        start = s.start; end = s.end; sponsor = s.sponsor; confidence = s.confidence
        verdict = s.userVerdict
        kindRaw = s.kindRaw; deliveryRaw = s.deliveryRaw; detailRaw = s.detailRaw
        detectedKindRaw = s.detectedKindRaw; origin = s.origin; evidenceText = s.evidenceText
        containsRaw = s.containsRaw
        isComedyBit = s.isComedyBit; insertedAtDownload = s.insertedAtDownload; isLocked = s.isLocked
        detectedStart = s.detectedStart; detectedEnd = s.detectedEnd
        startConfidence = s.startConfidence; endConfidence = s.endConfidence
        mergedFromData = s.mergedFromData
    }

    func apply(to s: AdSegment) {
        s.start = start; s.end = end; s.sponsor = sponsor; s.confidence = confidence
        s.userVerdict = verdict
        s.kindRaw = kindRaw; s.deliveryRaw = deliveryRaw; s.detailRaw = detailRaw
        s.detectedKindRaw = detectedKindRaw; s.origin = origin; s.evidenceText = evidenceText
        s.containsRaw = containsRaw
        s.isComedyBit = isComedyBit; s.insertedAtDownload = insertedAtDownload; s.isLocked = isLocked
        s.detectedStart = detectedStart; s.detectedEnd = detectedEnd
        s.startConfidence = startConfidence; s.endConfidence = endConfidence
        s.mergedFromData = mergedFromData
    }
}

struct EpisodeCutsSnapshot: Equatable {
    var segments: [SegmentSnapshot]
    var correctionLog: Data?
    var showCorrections: Data?
    /// What the change after this snapshot was, for the Undo button.
    var label: String = ""

    @MainActor
    init(_ episode: Episode) {
        segments = episode.adSegments.map(SegmentSnapshot.init)
        correctionLog = episode.correctionLogData
        showCorrections = episode.podcast?.correctionData
    }

    static func == (a: Self, b: Self) -> Bool {
        a.segments == b.segments && a.correctionLog == b.correctionLog && a.showCorrections == b.showCorrections
    }

    /// Puts the episode's cuts back to this state.
    @MainActor
    func restore(_ episode: Episode, context: ModelContext) {
        let wanted = Dictionary(segments.compactMap { s in s.id.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        var restored = Set<PersistentIdentifier>()
        for segment in episode.adSegments {
            if let snapshot = wanted[segment.persistentModelID] {
                snapshot.apply(to: segment)
                restored.insert(segment.persistentModelID)
            } else {
                context.delete(segment)          // added after this state
            }
        }
        for snapshot in segments where snapshot.id.map({ !restored.contains($0) }) ?? true {
            // Removed after this state: back, with every field it had.
            let segment = AdSegment(start: snapshot.start, end: snapshot.end)
            snapshot.apply(to: segment)
            segment.episode = episode
            context.insert(segment)
        }
        episode.correctionLogData = correctionLog
        episode.podcast?.correctionData = showCorrections
    }
}

@MainActor
@Observable
final class SkipEditHistory {
    private(set) var undoStack: [EpisodeCutsSnapshot] = []
    private var baseline: EpisodeCutsSnapshot?

    var canUndo: Bool { !undoStack.isEmpty }
    var lastLabel: String? { undoStack.last?.label }

    func begin(_ episode: Episode) {
        if baseline == nil { baseline = EpisodeCutsSnapshot(episode) }
    }

    /// After a change has been made: the state before it becomes undoable.
    func committed(_ episode: Episode, label: String) {
        let now = EpisodeCutsSnapshot(episode)
        guard var before = baseline, before != now else { baseline = now; return }
        before.label = label
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        baseline = now
    }

    /// Back to the state before the last change. Returns what was undone.
    @discardableResult
    func undo(_ episode: Episode, context: ModelContext) -> String? {
        guard let last = undoStack.popLast() else { return nil }
        last.restore(episode, context: context)
        baseline = EpisodeCutsSnapshot(episode)
        return last.label
    }
}
