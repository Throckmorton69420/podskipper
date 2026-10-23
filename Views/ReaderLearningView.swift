import SwiftUI

/// Pass 38: what PodSkipper's reader has learned on this iPhone
/// (`OnDeviceReaderLearner`), and a way to forget it.
struct ReaderLearningView: View {
    /// "12 ads, 3 plugs, 140 of the show".
    static func counts(_ sentences: [String: Int]) -> String {
        let names = ["ad": "ad", "selfPromo": "plug", "crossPromo": "promo", "intro": "intro", "outro": "outro"]
        var parts = names.compactMap { key, word -> (Int, String)? in
            guard let n = sentences[key], n > 0 else { return nil }
            return (["ad", "selfPromo", "crossPromo", "intro", "outro"].firstIndex(of: key) ?? 0,
                    "\(n) \(word) sentence\(n == 1 ? "" : "s")")
        }.sorted { $0.0 < $1.0 }.map(\.1)
        if let show = sentences["show"], show > 0 { parts.append("\(show) of the show") }
        return parts.joined(separator: ", ")
    }

    @State private var status = OnDeviceReaderLearner.Status()
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Text(status.summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("readerLearning.summary")
                if let trained = status.trainedAt {
                    LabeledContent("Last Learned", value: trained.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("Your confirmations, edits, locks, added cuts and Not an Ad teach the reader the most. Reads by an on-device model that scored 70 % or more on its test teach it too. Each change is checked against labelled episodes and your own earlier corrections before it is used; if it does worse, the previous version stays. Everything stays on this iPhone and is included in backups.")
            }
            // Pass 46: what each episode taught, and from whom — the listener's
            // corrections, two different models agreeing on what each found
            // itself, or the ad-free download.
            if let evidence = status.evidence, !evidence.isEmpty {
                Section {
                    ForEach(evidence, id: \.episode) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title.isEmpty ? item.show : item.title)
                                .font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(item.teacher.prefix(1).uppercased() + item.teacher.dropFirst())
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(Self.counts(item.sentences))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("What It Learned From")
                } footer: {
                    Text("Only stretches models of two different families each found by themselves count; what the reader found on its own never teaches it.")
                }
            }
            if let setAside = status.setAside {
                Section { Text(setAside).font(.footnote).foregroundStyle(.secondary) }
            }
            if !status.history.isEmpty {
                Section("Recent Changes") {
                    ForEach(status.history, id: \.self) { line in
                        Text(line).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section {
                Button("Forget What It Learned", role: .destructive) { confirmReset = true }
                    .disabled(status.goldExamples + status.silverExamples == 0 && !status.inUse)
                    .accessibilityIdentifier("readerLearning.reset")
            } footer: {
                Text("The reader goes back to how it came with this version. Your corrections stay on your episodes and shows.")
            }
        }
        .navigationTitle("Learned on This iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .task { status = await OnDeviceReaderLearner.shared.currentStatus() }
        .refreshable { status = await OnDeviceReaderLearner.shared.currentStatus() }
        .confirmationDialog("Forget what the reader learned on this iPhone?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Forget What It Learned", role: .destructive) {
                Task {
                    await OnDeviceReaderLearner.shared.reset()
                    status = await OnDeviceReaderLearner.shared.currentStatus()
                }
            }
        }
    }
}
