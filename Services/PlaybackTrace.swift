import Foundation
import AVFoundation

/// What the audio system looked like at each moment that matters for "it
/// says it is playing but I hear nothing" (Pass 33, his 9 Oct report).
///
/// The app can't hear the headphones, so this never claims audio was or
/// wasn't audible. It records what can be known: what the player was asked
/// to do, what the engine and session report, the route, and why the route
/// or session last changed — enough to line up with the time he noticed the
/// silence. A snapshot is taken only at events (play, pause, interruptions,
/// route and engine-format changes, the silence watchdog), never per tick.
@MainActor
final class PlaybackTrace {
    static let shared = PlaybackTrace()

    struct Entry: Codable, Sendable {
        var date: Date
        var event: String
        /// The player's own phase: what it believes and was asked to do.
        var phase: String
        /// file (AVAudioEngine), stream (AVPlayer) or video.
        var engine: String
        /// The engine's own report: AVAudioEngine running and node playing,
        /// or AVPlayer's time-control status.
        var engineState: String
        var position: Double
        var category: String
        var mode: String
        var otherAudioPlaying: Bool
        var shouldSilenceSecondary: Bool
        var outputVolume: Float
        var route: String
    }

    private(set) var entries: [Entry] = []
    private let url: URL
    private var saveScheduled = false

    init(url: URL = Diagnostics.folder.appending(path: "playback-trace.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([Entry].self, from: data)) ?? []
        }
    }

    func note(_ event: String, phase: String, engine: String, engineState: String, position: Double) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs
            .map { "\($0.portName) [\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        entries.insert(Entry(date: .now, event: event, phase: phase, engine: engine,
                             engineState: engineState, position: (position * 10).rounded() / 10,
                             category: session.category.rawValue, mode: session.mode.rawValue,
                             otherAudioPlaying: session.isOtherAudioPlaying,
                             shouldSilenceSecondary: session.secondaryAudioShouldBeSilencedHint,
                             outputVolume: session.outputVolume,
                             route: route.isEmpty ? "none" : route), at: 0)
        if entries.count > 300 { entries.removeLast(entries.count - 300) }
        scheduleSave()
    }

    /// Writes at most once a second, off the main actor.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.saveScheduled = false
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(self.entries) else { return }
            let url = self.url
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Plain names for the system's codes

    static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "new device"
        case .oldDeviceUnavailable: "device gone"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no suitable route"
        case .routeConfigurationChange: "route configuration change"
        @unknown default: "reason \(reason.rawValue)"
        }
    }

    static func name(interruptionReason raw: UInt?) -> String {
        guard let raw else { return "none given" }
        switch AVAudioSession.InterruptionReason(rawValue: raw) {
        case .default?: return "another app or a call"
        case .builtInMicMuted?: return "built-in mic muted"
        case .routeDisconnected?: return "route disconnected"
        default: return "reason \(raw)"
        }
    }
}
