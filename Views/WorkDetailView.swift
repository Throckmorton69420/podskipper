import SwiftUI

/// What the progress banner opens into.
///
/// The banner is one line; asked for was the whole picture behind it — each
/// step of the job in progress, the list of what is queued with the ability
/// to change its order, and the running commentary as it happens.
struct WorkDetailView: View {
    let pipeline: ProcessingPipeline
    /// Whether the job's Open button can push the episode: not in a sheet
    /// with no navigation stack of its own.
    var canOpen = true
    var onOpen: () -> Void = {}
    @State private var queue = PublishQueue.shared
    @State private var publisher = FeedPublisher.shared

    /// The sections, as a list with no background of its own — it sits inside
    /// the expanded glass banner.
    var body: some View {
        List {
            if let error = queue.storageError {
                Section {
                    SectionHeader("Publishing needs attention")
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            currentSection
            queueSection
            logSection
            if !queue.finished.isEmpty {
                Section {
                    SectionHeader("Finished")
                    ForEach(queue.finished) { job in
                        HStack {
                            JobRow(job: job)
                            if case .failed = job.state { retryButton(job) }
                            if case .cancelled = job.state { retryButton(job) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Refreshes the line itself, not the feeds (pass 20).
        .refreshable {
            await pipeline.refreshLine()
            Feel.selection.play()
        }
        .environment(\.editMode, .constant(queue.waiting.count > 1 ? .active : .inactive))
        .listRowBackground(Color.clear)
    }

    // MARK: - Now

    @ViewBuilder
    private var currentSection: some View {
        Section {
            SectionHeader("Now")
            if let job = queue.current {
                JobRow(job: job)
                Button("Cancel publishing", systemImage: "xmark.circle", role: .destructive) {
                    queue.cancel(job)
                    Feel.warning.play()
                }
                .accessibilityLabel("Cancel publishing \(job.title)")
            }
            if !pipeline.isRunning, publisher.isPublishing {
                StepList(title: publisher.currentEpisodeTitle ?? "Publishing",
                         steps: publisher.plan.map(\.label),
                         current: publisher.stepNumber - 1,
                         fraction: publisher.stageFraction)
            } else {
                // Finding ads: the Activity page's own row (task 10).
                ActivityNowContent(pipeline: pipeline, canOpen: canOpen, onOpen: onOpen)
            }
        }
    }

    private func retryButton(_ job: PublishQueue.Job) -> some View {
        Button("Retry", systemImage: "arrow.clockwise") { queue.retry(job); Feel.selection.play() }
            .buttonStyle(.bordered)
            .accessibilityLabel("Retry publishing \(job.title)")
    }

    // MARK: - Queue

    @ViewBuilder
    private var queueSection: some View {
        if !queue.waiting.isEmpty {
            Section {
                SectionHeader("Up next to publish")
                ForEach(queue.waiting) { job in
                    JobRow(job: job)
                        .swipeActions {
                            Button("Remove", role: .destructive) { Feel.warning.play(); queue.remove(job) }
                        }
                }
                .onMove { queue.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                if queue.waiting.count > 1 {
                    Text("Drag to change the order. Swipe to remove.")
                }
            }
        }
    }

    // MARK: - Log

    @ViewBuilder
    private var logSection: some View {
        if !publisher.log.isEmpty {
            Section {
                SectionHeader("What's happening")
                ForEach(publisher.log.suffix(40).reversed()) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(line.at, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct JobRow: View {
    let job: PublishQueue.Job

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var symbol: String {
        switch job.state {
        case .waiting: return "clock"
        case .offline: return "wifi.slash"
        case .findingAds: return "wand.and.sparkles"
        case .publishing: return "arrow.up.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var detail: String {
        switch job.state {
        case .waiting: return job.showTitle
        case .offline: return "Waiting for a connection — carries on by itself"
        case .findingAds: return "Finding ads first"
        case .publishing: return job.reason ?? "Publishing"
        case .done(let text), .failed(let text), .cancelled(let text): return text
        }
    }
}

/// The steps of one job, ticked off as they pass.
private struct StepList: View {
    let title: String
    let steps: [String]
    let current: Int
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).lineLimit(2)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    Group {
                        if index < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if index == current {
                            ProgressView(value: max(0.02, min(1, fraction)))
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 22)
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(index > current ? .secondary : .primary)
                    Spacer()
                    if index == current {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
