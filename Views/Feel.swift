import SwiftUI
import UIKit

// MARK: - Haptics, one vocabulary (task 10)

/// What a control does, and so how it should feel. Every control uses one of
/// these, so the same kind of change always feels the same:
///
/// - `selection`: picking one of several (a segment, a tab, a menu choice, a
///   slider landing on a step).
/// - `toggle`: a switch or a two-state button changing.
/// - `confirm`: something done or saved.
/// - `warning`: something removed, stopped or undone.
///
/// `Haptics` (PlayerEngine.swift) keeps the player's own richer set — the
/// skip, the scrubber's detents — which are about playback, not controls.
enum Feel {
    case selection, toggle, confirm, warning

    var sensory: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .toggle:    return .impact(weight: .light)
        case .confirm:   return .success
        case .warning:   return .warning
        }
    }

    /// For action closures (swipe actions, menu items), where there is no
    /// value to watch.
    @MainActor
    func play() {
        switch self {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .toggle:    UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .confirm:   UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:   UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

extension View {
    /// Plays `feel` whenever `trigger` changes.
    func feel<T: Equatable>(_ feel: Feel, trigger: T) -> some View {
        sensoryFeedback(feel.sensory, trigger: trigger)
    }

    /// A slider's feel: a selection tick each time it crosses a step, not on
    /// every point of the drag.
    func feelSteps(_ value: Double, step: Double) -> some View {
        sensoryFeedback(Feel.selection.sensory, trigger: step > 0 ? Int((value / step).rounded()) : 0)
    }
}

/// The system switch, with the `toggle` feel. Set once at the app's root
/// (`.toggleStyle(.feel)`), so every switch in the app gets it and none can
/// be missed.
struct FeelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .feel(.toggle, trigger: configuration.isOn)
    }
}

extension ToggleStyle where Self == FeelToggleStyle {
    static var feel: FeelToggleStyle { FeelToggleStyle() }
}

// MARK: - Motion

extension View {
    /// Rows and shelf items settle in as they scroll onto the screen: a touch
    /// smaller and dimmer at the edges, full size in view. Only scale and
    /// opacity, which the GPU does for nothing. Reduce Motion keeps the fade
    /// and drops the scale.
    func rowScrollTransition(axis: Axis? = nil) -> some View {
        modifier(RowScrollTransition(axis: axis))
    }

    /// A spring that turns into a plain quick fade under Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation = .spring(response: 0.38, dampingFraction: 0.82),
                              value: V) -> some View {
        modifier(ReducibleAnimation(animation: animation, value: value))
    }
}

private struct RowScrollTransition: ViewModifier {
    let axis: Axis?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let scales = !reduceMotion
        return content.scrollTransition(.interactive, axis: axis) { effect, phase in
            effect
                .scaleEffect(phase.isIdentity || !scales ? 1 : 0.96)
                .opacity(phase.isIdentity ? 1 : 0.7)
        }
    }
}

private struct ReducibleAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.15) : animation, value: value)
    }
}
