import SwiftUI

/// Pass 38: what PodSkipper's reader has learned on this iPhone
/// (`OnDeviceReaderLearner`), and a way to forget it.
struct ReaderLearningView: View {
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
