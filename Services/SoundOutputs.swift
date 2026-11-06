import AVFoundation

/// Pass 58: the speakers or headphones playing now, as `SoundOutput`s, for
/// a show's "Remember for Each Speaker" choice.
enum SoundOutputs {
    /// Set by tests: what `current` returns instead of the audio route.
    nonisolated(unsafe) static var testRoute: [SoundOutput]?

    /// The outputs of the route in use (one, or two for a shared AirPlay
    /// route). Never empty: no route reads as the phone's own speaker.
    static var current: [SoundOutput] {
        if let testRoute { return testRoute }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
            SoundOutput(uid: $0.uid, name: $0.portName, kind: $0.portType.rawValue)
        }
        return outputs.isEmpty ? [SoundOutput(uid: "", name: "Speaker", kind: AVAudioSession.Port.builtInSpeaker.rawValue)] : outputs
    }

    /// "Shower Speaker", or "AirPods Pro and Kitchen" for a shared route.
    static func name(_ outputs: [SoundOutput]) -> String {
        ListFormatter.localizedString(byJoining: outputs.map(\.displayName))
    }
}
