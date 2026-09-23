import SwiftUI

/// Settings → Diagnostics (pass 16): what this phone measured.
///
/// The point is that "how fast is ad finding on the phone" and "does it get
/// hot" get answered with numbers he can send, not descriptions. Share makes
/// one JSON file (timings, device, every MetricKit report) to AirDrop to the
/// Mac or save to Files.
struct DiagnosticsView: View {
    @State private var log = TimingLog.shared
    @State private var reports: [MetricsSubscriber.SavedReport] = []
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                row("Phone", Diagnostics.deviceModel)
                row("iOS", UIDevice.current.systemVersion)
                row("Build", BuildInfo.commit)
                row("Apple Intelligence", AdDetector.availability() ?? "Ready")
                row("Heat right now", Diagnostics.thermalName.capitalized)
            }

            Section {
                row("Transcribing", perHour(log.median(\.transcribePerHour)))
                row("Finding ads", perHour(log.median(\.detectPerHour)))
            } header: {
                Text("Typical speed")
            } footer: {
                Text("Median seconds of work per hour of audio, over the episodes below.")
            }

            Section("Episodes processed") {
                if log.entries.isEmpty {
                    Text("Nothing yet. Each episode the app finds ads in adds a line here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(log.entries.prefix(50)) { entry in
                    TimingRow(entry: entry)
                }
            }

            Section {
                if reports.isEmpty {
                    Text("None yet. iOS sends the first daily report about a day after install, and crash or hang reports when they happen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(reports.prefix(20)) { report in
                    HStack {
                        Image(systemName: report.kind == "daily" ? "calendar" : "exclamationmark.triangle")
                            .foregroundStyle(report.kind == "daily" ? Color.secondary : Color.orange)
                        Text(report.kind == "daily" ? "Daily report" : "Problem report")
                        Spacer()
                        Text(report.date, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Reports from iOS")
            } footer: {
                Text("Battery use, heat, hangs and crashes, measured by iOS itself.")
            }

            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("ShareDiagnostics")
                } else if let exportError {
                    Text(exportError).foregroundStyle(.orange)
                }
                Button("Clear timings", role: .destructive) { log.clear() }
                    .disabled(log.entries.isEmpty)
            } footer: {
                Text("One file with everything above. AirDrop it to the Mac, or save it to Files.")
            }
        }
        .navigationTitle("Diagnostics")
        .amoledScreen()
        .task {
            reports = MetricsSubscriber.savedReports()
            do { exportURL = try Diagnostics.exportFile() }
            catch { exportError = error.localizedDescription }
        }
        .onChange(of: log.entries.count) { _, _ in
            exportURL = try? Diagnostics.exportFile()
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func perHour(_ seconds: Double?) -> String {
        guard let seconds else { return "Not measured yet" }
        return "\(Int(seconds.rounded())) s per hour"
    }
}

private struct TimingRow: View {
    let entry: ProcessingTiming

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.episode).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(entry.show) · \(formatDuration(entry.audioSeconds)) of audio")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 12) {
                stat("Transcribe", entry.transcribeSeconds.map(seconds) ?? "reused")
                stat("Find ads", seconds(entry.detectSeconds))
                stat("Heat", entry.thermalAtEnd)
            }
            .font(.caption.monospacedDigit())
            Text(conditions).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var conditions: String {
        var parts = [entry.date.formatted(.dateTime.month().day().hour().minute())]
        parts.append(entry.onPower ? "plugged in" : "on battery")
        if entry.lowPowerMode { parts.append("Low Power Mode") }
        parts.append(entry.foreground ? "app open" : "in background")
        return parts.joined(separator: " · ")
    }

    private func seconds(_ s: Double) -> String {
        s >= 90 ? "\(Int(s / 60))m \(Int(s) % 60)s" : "\(Int(s.rounded()))s"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
