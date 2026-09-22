import CarPlay
import SwiftData
import UIKit

/// PodSkipper on a car's screen.
///
/// CarPlay audio apps don't draw their own screens: they hand the system
/// lists and it draws them in the car's style. Three tabs — Up Next, Shows,
/// Recent — and the system's Now Playing screen, which reads the same Now
/// Playing information and remote commands as the Lock Screen, so ad skipping,
/// Smart Speed and the rest work exactly as on the phone.
///
/// The car only lists apps signed with the CarPlay audio entitlement
/// (`com.apple.developer.carplay-audio`), which Apple grants on request to
/// paid developer accounts. Without it this class is simply never created.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate {

    private var interface: CPInterfaceController?
    private var tabs: CPTabBarTemplate?
    private let upNext = CPListTemplate(title: "Up Next", sections: [])
    private let shows = CPListTemplate(title: "Shows", sections: [])
    private let recent = CPListTemplate(title: "Recent", sections: [])

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        upNext.tabImage = UIImage(systemName: "list.bullet")
        shows.tabImage = UIImage(systemName: "square.stack")
        recent.tabImage = UIImage(systemName: "clock")
        upNext.emptyViewTitleVariants = ["Nothing Up Next"]
        recent.emptyViewTitleVariants = ["Nothing played yet"]
        let bar = CPTabBarTemplate(templates: [upNext, shows, recent])
        bar.delegate = self
        tabs = bar
        interfaceController.setRootTemplate(bar, animated: false, completion: nil)
        configureNowPlaying()
        Task { @MainActor in self.reloadAll() }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        interface = nil
        tabs = nil
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        Task { @MainActor in self.reloadAll() }
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "Up Next"
        let speed = CPNowPlayingPlaybackRateButton { _ in
            Task { @MainActor in
                let player = PlayerEngine.shared
                let steps: [Double] = [1.0, 1.2, 1.5, 2.0]
                let next = steps.first { $0 > player.playbackRate + 0.01 } ?? steps[0]
                player.playbackRate = next
            }
        }
        nowPlaying.updateNowPlayingButtons([speed])
        nowPlaying.add(self)
    }

    // MARK: Lists

    @MainActor
    private func reloadAll() {
        guard let context = AppLibrary.context else { return }
        let player = PlayerEngine.shared

        var queue: [Episode] = []
        if let current = player.currentEpisode { queue.append(current) }
        queue += (player.upcomingProvider?(player.currentEpisode, 12) ?? [])
            .filter { $0.guid != player.currentEpisode?.guid }
        upNext.updateSections([CPListSection(items: queue.map(item))])

        let podcasts = ((try? context.fetch(FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)]))) ?? [])
        shows.updateSections([CPListSection(items: podcasts.map(showItem))])

        var played = FetchDescriptor<Episode>(predicate: #Predicate { $0.lastPlayedAt != nil },
                                              sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
        played.fetchLimit = 20
        recent.updateSections([CPListSection(items: ((try? context.fetch(played)) ?? []).map(item))])
    }

    @MainActor
    private func item(_ episode: Episode) -> CPListItem {
        let left = max(0, episode.duration - episode.playbackPosition)
        var detail = [episode.podcast?.title ?? ""]
        if left > 60 { detail.append("\(Int(left / 60)) min left") }
        if episode.processingState == .ready { detail.append("Ad-free") }
        let row = CPListItem(text: episode.title, detailText: detail.filter { !$0.isEmpty }.joined(separator: " · "))
        row.isPlaying = PlayerEngine.shared.currentEpisode?.guid == episode.guid
        row.playbackProgress = episode.duration > 0 ? min(1, episode.playbackPosition / episode.duration) : 0
        let guid = episode.guid
        row.handler = { [weak self] _, done in
            Task { @MainActor in
                self?.play(guid)
                done()
            }
        }
        loadImage(episode.artworkURL ?? episode.podcast?.artworkURL, into: row)
        return row
    }

    @MainActor
    private func showItem(_ podcast: Podcast) -> CPListItem {
        let row = CPListItem(text: podcast.title, detailText: podcast.author)
        row.accessoryType = .disclosureIndicator
        let id = podcast.persistentModelID
        row.handler = { [weak self] _, done in
            Task { @MainActor in
                self?.openShow(id)
                done()
            }
        }
        loadImage(podcast.artworkURL, into: row)
        return row
    }

    @MainActor
    private func openShow(_ id: PersistentIdentifier) {
        guard let context = AppLibrary.context,
              let podcast = context.model(for: id) as? Podcast else { return }
        let episodes = podcast.episodes
            .filter { !$0.isArchived }
            .sorted { $0.publishedAt > $1.publishedAt }
            .prefix(40)
        let list = CPListTemplate(title: podcast.title,
                                  sections: [CPListSection(items: episodes.map(item))])
        interface?.pushTemplate(list, animated: true, completion: nil)
    }

    /// Plays straight away. The phone's "play without finding ads?" question
    /// can't be answered on a car's screen, so an episode without its ads
    /// found plays with them, as it would after the countdown.
    @MainActor
    private func play(_ guid: String) {
        guard let context = AppLibrary.context else { return }
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        guard let episode = try? context.fetch(descriptor).first else { return }
        if PlayerEngine.shared.currentEpisode?.guid != guid {
            PlayerEngine.shared.load(episode)
        } else if !PlayerEngine.shared.isPlaying {
            PlayerEngine.shared.play()
        }
        interface?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func loadImage(_ url: String?, into row: CPListItem) {
        guard let url else { return }
        Task { @MainActor in
            if let image = await ImageCache.shared.load(url, size: 44) { row.setImage(image) }
        }
    }
}

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            self.reloadAll()
            self.interface?.popToRootTemplate(animated: true, completion: nil)
            self.tabs?.selectTemplate(at: 0)
        }
    }
}
