import SwiftData
import SwiftUI

/// One host or guest, from the feed's `podcast:person` ("role:Name^photo").
struct PersonEntry: Hashable, Identifiable {
    var name: String
    var role: String
    var photo: String?
    var id: String { name.lowercased() }

    init?(_ raw: String) {
        let pieces = raw.split(separator: "^", maxSplits: 1).map(String.init)
        let parts = (pieces.first ?? raw).split(separator: ":", maxSplits: 1).map(String.init)
        let name = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        self.name = name
        self.role = parts.count == 2 ? parts[0].capitalized : "Host"
        self.photo = pieces.count == 2 ? pieces[1] : nil
    }

    /// Each person once (hosts first), from "|"-joined lists.
    static func list(_ lists: [String]) -> [PersonEntry] {
        var seen = Set<String>()
        var result: [PersonEntry] = []
        for list in lists {
            for raw in list.split(separator: "|").map(String.init) {
                guard let entry = PersonEntry(raw), seen.insert(entry.id).inserted else { continue }
                result.append(entry)
            }
        }
        return result.sorted { ($0.role == "Host" ? 0 : 1) < ($1.role == "Host" ? 0 : 1) }
    }
}

/// A person's page (pass 21), opened from Hosts & Guests.
struct PersonRoute: Hashable {
    var name: String
    var photo: String?
}

/// Hosts & Guests as Apple's episode and show pages draw it: round photos
/// (initials when the feed has none), name, role; each opens that person.
struct HostsAndGuestsShelf: View {
    let people: [PersonEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(people) { person in
                    NavigationLink(value: PersonRoute(name: person.name, photo: person.photo)) {
                        VStack(spacing: 6) {
                            PersonPhoto(name: person.name, photo: person.photo, size: 72)
                            Text(person.name).font(.footnote.weight(.semibold)).lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(person.role).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 86)
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("person.\(person.name)")
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }
}

struct PersonPhoto: View {
    let name: String
    let photo: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let photo {
                Artwork(url: photo, size: size)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [Theme.accentHot.opacity(0.8), Theme.accentWarm.opacity(0.7)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .clipShape(Circle())
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// Everything with one person in it: their episodes in the library, then
/// shows with them in Apple's catalog.
struct PersonView: View {
    let route: PersonRoute
    @Environment(\.modelContext) private var context
    @State private var episodes: [Episode] = []
    @State private var shows: [PodcastSearchResult] = []
    @State private var previewShow: PodcastSearchResult?

    var body: some View {
        List {
            VStack(spacing: 10) {
                PersonPhoto(name: route.name, photo: route.photo, size: 120)
                Text(route.name).font(.title2.bold())
            }
            .frame(maxWidth: .infinity)
            .plainRow(top: 12, bottom: 8)
            if !episodes.isEmpty {
                SectionHeader("Episodes")
                ForEach(episodes) { episode in
                    EpisodeCompactRow(episode: episode).contentRow()
                }
            }
            if !shows.isEmpty {
                SectionHeader("Shows")
                NavigationShelf(items: shows, artwork: { $0.artworkURL }, size: Metrics.artStrip) { show in
                    Text(show.title).font(.footnote.weight(.medium)).lineLimit(2)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } onTap: { show in previewShow = show }
                .fullWidthRow()
            }
            if episodes.isEmpty && shows.isEmpty {
                Text("Looking for \(route.name)…").foregroundStyle(.secondary).contentRow()
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .amoledScreen()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $previewShow) { ShowPreviewView(show: $0) }
        .accessibilityIdentifier("PersonPage")
        .task(id: route.name) {
            let name = route.name
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.people.localizedStandardContains(name) },
                sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            descriptor.fetchLimit = 60
            episodes = (try? context.fetch(descriptor)) ?? []
            shows = (try? await PodcastSearch.searchPeople(name, limit: 15)) ?? []
        }
    }
}
