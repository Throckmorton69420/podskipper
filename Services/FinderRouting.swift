import Foundation

/// Pass 63 (his 10 Nov report: "Use It on Screen Too" silently took over
/// from the chosen MLX or Core AI model, did nothing with the Reader chosen
/// and was ignored with Apple Intelligence): who finds the ads on screen and
/// who finds them off screen, decided in one place from two settings he can
/// see — **Find Ads With** (five choices, a CPU model one of them) and
/// **When Locked or in the Background** — and said back to him in one
/// sentence. The pipeline's branches follow the same rules
/// (`ProcessingPipeline.readWithModel` / `readWithCoreAI` / `readWithCPU`,
/// and Apple Intelligence's off-screen hand-over); `Pass63RoutingTests`
/// holds the two together.
enum FinderRouting {
    /// Who reads an episode after the Reader (which always reads first).
    enum Engine: Equatable, Sendable {
        case reader
        case apple
        case mlx(String)
        case coreAI(String)
        case cpu(String)

        var name: String {
            switch self {
            case .reader: "PodSkipper Reader"
            case .apple: "Apple Intelligence"
            case .mlx(let name), .coreAI(let name), .cpu(let name): name
            }
        }
    }

    /// Everything the routing depends on.
    struct Facts: Equatable, Sendable {
        var choice: AdFinderChoice
        /// The chosen models' names.
        var mlx = "the MLX model"
        var coreAI = "the Core AI model"
        var cpu = "the CPU model"
        /// The chosen CPU model is on this iPhone and this build can run it.
        var cpuReady = false
        /// "When Locked or in the Background": the CPU model reads (true), or
        /// the episode waits for the screen with the Reader's cuts (false).
        var backgroundCPU = true
        /// Signed with Background GPU Access (his builds aren't).
        var backgroundGPU = false
    }

    struct Plan: Equatable, Sendable {
        /// With PodSkipper on screen.
        var onScreen: Engine
        /// Locked, or another app in front.
        var offScreen: Engine
        /// Who reads the episode again once PodSkipper is back on screen,
        /// when the off-screen read wasn't the chosen finder's.
        var again: Engine?
        /// One sentence for Settings.
        var summary: String
    }

    static func plan(_ f: Facts) -> Plan {
        let cpuFallback = f.backgroundCPU && f.cpuReady
        switch f.choice {
        case .reader:
            return Plan(onScreen: .reader, offScreen: .reader, again: nil,
                        summary: "PodSkipper Reader finds the ads on screen and off: nothing else reads.")
        case .cpu:
            guard f.cpuReady else {
                return Plan(onScreen: .reader, offScreen: .reader, again: nil,
                            summary: "\(f.cpu) isn’t downloaded yet, so PodSkipper Reader finds the ads on screen and off until it is.")
            }
            return Plan(onScreen: .cpu(f.cpu), offScreen: .cpu(f.cpu), again: nil,
                        summary: "\(f.cpu) finds the ads on screen and off (slower while locked on battery, full speed on the charger overnight), after PodSkipper Reader.")
        case .apple:
            if cpuFallback {
                return Plan(onScreen: .apple, offScreen: .cpu(f.cpu), again: .apple,
                            summary: "On screen Apple Intelligence finds the ads; locked or in the background on battery \(f.cpu) reads first and Apple Intelligence reads again when you’re back.")
            }
            return Plan(onScreen: .apple, offScreen: .reader, again: .apple,
                        summary: "On screen Apple Intelligence finds the ads; locked or in the background on battery PodSkipper Reader’s cuts are used until Apple Intelligence reads when you’re back.")
        case .model, .coreAI:
            let chosen: Engine = f.choice == .model ? .mlx(f.mlx) : .coreAI(f.coreAI)
            if f.backgroundGPU {
                return Plan(onScreen: chosen, offScreen: chosen, again: nil,
                            summary: "\(chosen.name) finds the ads on screen and off, after PodSkipper Reader.")
            }
            if cpuFallback {
                return Plan(onScreen: chosen, offScreen: .cpu(f.cpu), again: nil,
                            summary: "On screen \(chosen.name) finds the ads; locked or in the background \(f.cpu) reads instead, and its result is kept.")
            }
            return Plan(onScreen: chosen, offScreen: .reader, again: chosen,
                        summary: "On screen \(chosen.name) finds the ads; locked or in the background PodSkipper Reader’s cuts are used until \(chosen.name) reads when you’re back.")
        }
    }

    /// The facts as they are now.
    @MainActor
    static func current(choice: AdFinderChoice) -> Facts {
        let cpu = CPUReading.selected
        return Facts(choice: choice, mlx: ModelStore.shared.selected.name,
                     coreAI: CoreAIModelLibrary.shared.selectedEntry?.name ?? "the Core AI model",
                     cpu: cpu.name, cpuReady: (CPUReading.engineIncluded || CPUReading.isDemo) && cpu.isDownloaded,
                     backgroundCPU: CPUReading.isEnabled, backgroundGPU: SignedEntitlements.backgroundGPU)
    }

    /// Pass 62's "Use It on Screen Too" becomes the fifth choice of Find Ads
    /// With, once: on with an MLX or Core AI model chosen, the CPU model was
    /// already reading everything.
    static func migratePrimarySwitch(defaults: UserDefaults = .standard) {
        let key = "cpuReading.primary"
        guard defaults.object(forKey: key) != nil else { return }
        let wasOn = defaults.bool(forKey: key)
        defaults.removeObject(forKey: key)
        let finder = defaults.string(forKey: "adFinder") ?? AdFinderChoice.apple.rawValue
        guard wasOn, finder == AdFinderChoice.model.rawValue || finder == AdFinderChoice.coreAI.rawValue else { return }
        defaults.set(AdFinderChoice.cpu.rawValue, forKey: "adFinder")
    }
}
