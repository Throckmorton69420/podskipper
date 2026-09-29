import SwiftUI
import SwiftData

/// Pushed from Show Settings: "Audio for This Show".
struct ShowSoundRoute: Hashable {}

/// A show's own sound: use the app default, or its own preset and repairs.
///
/// The controls are `SoundEditorSections`, the same view Speed and Audio
/// uses, editing a `SoundState` that is kept on the show. The player asks for
/// the show's sound every time an episode loads, so an episode of this show
/// plays with it and an episode of another show goes back to the default.
struct ShowSoundView: View {
    @Bindable var podcast: Podcast
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @State private var player = PlayerEngine.shared

    /// Edited here and written to the show on every change. Held locally so
    /// the controls aren't decoding JSON on every redraw.
    @State private var state = SoundState()
    @State private var isCustom = false
    @State private var loaded = false

    var body: some View {
        List {
            modeSection
            if isCustom {
                SoundEditorSections(state: $state)
            } else {
                Text("This show uses your default from Settings → Audio. Choose \"Custom for this show\" to give it its own preset and fixes, starting from your default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentRow()
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Audio for This Show")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .amoledScreen()
        .safeAreaInset(edge: .top, spacing: 0) {
            EQCurvePanel(sound: settings.sound(for: podcast, normalizationGain: playingNormalization))
        }
        .onAppear(perform: load)
        .onChange(of: state) { _, new in
            guard loaded, isCustom else { return }
            podcast.customSound = new
            changed()
        }
    }

    private var modeSection: some View {
        Picker("Sound", selection: Binding(
            get: { isCustom },
            set: { setCustom($0) }
        )) {
            Text("Use my default").tag(false)
            Text("Custom for this show").tag(true)
        }
        .pickerStyle(.segmented)
        .contentRow()
    }

    /// This show's episode's level, when one is playing, so the curve's level
    /// matches what's heard.
    private var playingNormalization: Double? {
        guard let episode = player.currentEpisode, episode.podcast === podcast else { return nil }
        return episode.normalizationGain
    }

    private func load() {
        guard !loaded else { return }
        // A show that only had the old Voice Boost switch set becomes a show
        // with its own sound: the default, with Enhance Dialogue as it was
        // forced. Setting `customSound` clears the old switch.
        if podcast.customSoundData == nil, podcast.voiceBoostOverride != nil {
            podcast.customSound = settings.soundState(for: podcast)
            changed()
        }
        state = settings.soundState(for: podcast)
        isCustom = podcast.customSoundData != nil
        loaded = true
    }

    private func setCustom(_ custom: Bool) {
        guard custom != isCustom else { return }
        isCustom = custom
        if custom {
            // Start from what the show sounds like now.
            state = settings.soundState(for: podcast)
            podcast.customSound = state
        } else {
            podcast.customSound = nil
            state = settings.soundState(for: podcast)
        }
        changed()
    }

    /// Save, and if an episode of this show is playing, let it be heard now.
    private func changed() {
        DeferredSave.request(context)
        if player.currentEpisode?.podcast === podcast {
            player.applyAudioSettingsSoon()
        }
    }
}
