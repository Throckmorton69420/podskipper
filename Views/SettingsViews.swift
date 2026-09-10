import SwiftUI
import SwiftData
import UIKit

// MARK: - Main settings

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var hasCredentials = R2Credentials.load() != nil

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Ad skipping") {
                Toggle("Skip ads automatically", isOn: $settings.autoSkipEnabled)
                Stepper("Minimum confidence: \(settings.minimumConfidence)",
                        value: $settings.minimumConfidence, in: 0...100, step: 5)
                Text("Higher means fewer wrong cuts, but more ads slip through.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Processing") {
                Toggle("Only while charging", isOn: $settings.processOnlyWhileCharging)
                Text("Transcribing an hour of audio is real work. Leaving this on lets iPhone do it overnight instead of on your battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("On-device AI") {
                if let reason = AdDetector.availability() {
                    Label("Unavailable: \(reason)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Needs an iPhone with Apple Intelligence turned on.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }

            Section("Publishing to Apple Podcasts") {
                NavigationLink {
                    R2SettingsView(hasCredentials: $hasCredentials)
                } label: {
                    HStack {
                        Text("Cloudflare storage")
                        Spacer()
                        if hasCredentials {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not set up").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Optional. Only needed if you want ad-free versions to show up in the Apple Podcasts app, CarPlay, or your Watch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Cloudflare R2 credentials

/// The five values Cloudflare gives you. They go into the Keychain, which is
/// the same place iOS keeps your saved passwords — not into a plain file.
struct R2SettingsView: View {
    @Binding var hasCredentials: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var accountID = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var bucket = "podcasts"
    @State private var publicBaseURL = ""

    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Text("Paste the five values from your Cloudflare account. Step-by-step instructions are in the setup guide.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Account") {
                LabeledField(label: "Account ID",
                             hint: "A long string of letters and numbers",
                             text: $accountID)
            }

            Section("API token") {
                LabeledField(label: "Access Key ID", hint: "", text: $accessKeyID)
                SecureField("Secret Access Key", text: $secretAccessKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Bucket") {
                LabeledField(label: "Bucket name",
                             hint: "The name you gave your R2 bucket",
                             text: $bucket)
                LabeledField(label: "Public address",
                             hint: "e.g. https://pods.yourdomain.com",
                             text: $publicBaseURL)
                    .keyboardType(.URL)
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: statusIsError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .red : .green)
                        .font(.callout)
                }
            }

            Section {
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack {
                        Text("Save and test")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(!isComplete || isTesting)

                if hasCredentials {
                    Button("Remove saved credentials", role: .destructive) {
                        try? R2Credentials.save(emptyCredentials)
                        hasCredentials = false
                        statusMessage = "Removed."
                        statusIsError = false
                    }
                }
            }
        }
        .navigationTitle("Cloudflare storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadExisting)
    }

    private var isComplete: Bool {
        !accountID.isEmpty && !accessKeyID.isEmpty && !secretAccessKey.isEmpty
            && !bucket.isEmpty && !publicBaseURL.isEmpty
    }

    private var emptyCredentials: R2Uploader.Credentials {
        .init(accountID: "", accessKeyID: "", secretAccessKey: "",
              bucket: "", publicBaseURL: "")
    }

    private func loadExisting() {
        guard let saved = R2Credentials.load() else { return }
        accountID = saved.accountID
        accessKeyID = saved.accessKeyID
        secretAccessKey = saved.secretAccessKey
        bucket = saved.bucket
        publicBaseURL = saved.publicBaseURL
    }

    /// Saves, then actually writes a tiny test file to prove the credentials
    /// work. Far better to find out here than three hours into a publish.
    private func saveAndTest() async {
        isTesting = true
        statusMessage = nil
        defer { isTesting = false }

        let trimmed = R2Uploader.Credentials(
            accountID: accountID.trimmed,
            accessKeyID: accessKeyID.trimmed,
            secretAccessKey: secretAccessKey.trimmed,
            bucket: bucket.trimmed,
            publicBaseURL: publicBaseURL.trimmed
        )

        do {
            try R2Credentials.save(trimmed)
            hasCredentials = true
        } catch {
            statusIsError = true
            statusMessage = "Couldn't save to the Keychain."
            return
        }

        let uploader = R2Uploader(credentials: trimmed)
        let probe = Data("PodSkipper connection test".utf8)
        do {
            let url = try await uploader.upload(data: probe,
                                                key: "podskipper-test.txt",
                                                contentType: "text/plain")
            try? await uploader.delete(key: "podskipper-test.txt")
            statusIsError = false
            statusMessage = "Working. Files will appear at \(url.host() ?? trimmed.publicBaseURL)."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}

private struct LabeledField: View {
    let label: String
    let hint: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(hint.isEmpty ? label : hint, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Publish row, shown at the top of each show

struct PublishRow: View {
    let podcast: Podcast
    @Binding var isPublishing: Bool
    @Binding var message: String?

    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var copied = false

    private var readyCount: Int {
        podcast.episodes.filter { $0.processingState == .ready }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feedURL = podcast.publishedFeedURL {
                Text("Your ad-free feed address")
                    .font(.caption).foregroundStyle(.secondary)
                Text(feedURL)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)

                Button {
                    UIPasteboard.general.string = feedURL
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Paste this into Apple Podcasts: Library → ••• → Follow a Show by URL.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Button {
                Task { await publish() }
            } label: {
                HStack {
                    Label(podcast.publishedFeedURL == nil ? "Publish ad-free feed" : "Update feed",
                          systemImage: "arrow.up.circle")
                    if isPublishing { Spacer(); ProgressView() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isPublishing || readyCount == 0)

            if readyCount == 0 {
                Text("Process at least one episode first — tap \"Find ads\" below.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func publish() async {
        isPublishing = true
        message = nil
        copied = false
        defer { isPublishing = false }

        let publisher = FeedPublisher(context: context, pipeline: pipeline)
        do {
            let result = try await publisher.publish(podcast)
            message = "Published \(result.episodesPublished) episode\(result.episodesPublished == 1 ? "" : "s")."
        } catch {
            message = error.localizedDescription
        }
    }
}
