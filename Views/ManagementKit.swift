import SwiftUI
import UIKit

/// Pass 35: the shared pieces every management screen uses — one way to ask
/// before deleting, one way to report what happened, one byte formatter.
///
/// His 9 Oct phone showed two confirmations floating away from what he
/// tapped: the Core AI test warning (attached to an invisible row at the
/// bottom of the model list, so iOS anchored it there, off screen) and Clear
/// Downloads (anchored to the middle of a full-width row). On iOS 27 a
/// confirmation dialog is a popover anchored to the view it is attached to,
/// so one attached to a list, an invisible row, a swipe action or a menu has
/// nothing sensible to point at. Every confirmation here is a system alert
/// instead: centred, always on screen, no arrow, and it names exactly what
/// goes and what stays.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var actionTitle: String
    var destructive = true
    var perform: @MainActor () async -> Void
}

extension View {
    /// Presents `request` as an alert. The action runs once: the request is
    /// cleared before it starts, so a second tap can't run it again.
    func confirmation(_ request: Binding<Confirmation?>) -> some View {
        alert(request.wrappedValue?.title ?? "", isPresented: Binding(
            get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
              presenting: request.wrappedValue) { pending in
            Button(pending.actionTitle, role: pending.destructive ? .destructive : nil) {
                request.wrappedValue = nil
                Task { @MainActor in await pending.perform() }
            }
            .accessibilityIdentifier("confirmation.action")
            Button("Cancel", role: .cancel) { request.wrappedValue = nil }
        } message: { pending in
            Text(pending.message)
        }
    }
}

/// Bytes as Files shows them.
func formattedBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

/// What a management action did, shown at the top of the list until the next one.
struct ResultNote: Equatable {
    var text: String
    var failed: Bool = false

    static func freed(_ bytes: Int64, removed: Int, noun: String, failures: [String] = []) -> ResultNote {
        var text = removed == 0 && failures.isEmpty ? "Nothing was removed."
            : "Removed \(removed) \(noun)\(removed == 1 ? "" : "s"), freeing \(formattedBytes(bytes))."
        if !failures.isEmpty {
            text += " " + (failures.count == 1 ? failures[0] : "\(failures.count) items were kept or failed: " + failures.prefix(3).joined(separator: "; "))
        }
        return ResultNote(text: text, failed: !failures.isEmpty)
    }
}

struct ResultNoteRow: View {
    let note: ResultNote
    var body: some View {
        Label(note.text, systemImage: note.failed ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.subheadline)
            .foregroundStyle(note.failed ? .orange : .secondary)
            .accessibilityIdentifier("management.result")
    }
}

/// The free-space line, with a warning when the phone is nearly full.
struct FreeSpaceRow: View {
    let free: Int64?
    var body: some View {
        if let free {
            LabeledContent("Free on this iPhone", value: formattedBytes(free))
            if free < StorageGuard.lowThreshold {
                Label("This iPhone is nearly full. Model downloads, model preparation and backups are paused until more space is free, and iOS can fail to open the library when space runs out.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("storage.lowSpace")
            }
        }
    }
}

/// Edit/Done that drives a screen's own edit mode. A toolbar EditButton
/// reads the navigation stack's edit mode, not the one a List was given with
/// `.environment(\.editMode, …)`, so on his phone Edit changed nothing; this
/// toggles the same binding the List uses.
struct EditModeButton: View {
    @Binding var editMode: EditMode
    var onDone: () -> Void = {}
    var body: some View {
        Button(editMode.isEditing ? "Done" : "Select") {
            withAnimation {
                if editMode.isEditing { editMode = .inactive; onDone() } else { editMode = .active }
            }
        }
        .fontWeight(editMode.isEditing ? .semibold : .regular)
        .accessibilityIdentifier("management.edit")
    }
}

/// Pass 35: the share sheet, presented by UIKit from the top view controller.
/// His listening-history export showed a row that did nothing when tapped;
/// this is the one way files are shared from Backup & Restore and Storage.
enum SharePresenter {
    @MainActor
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        // iPad: anchored to the middle of the screen rather than nowhere.
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}

/// A file the app just made: what it is, how big, where it is, and what can
/// be done with it. The whole row shares; Delete asks first.
struct FileResultRow: View {
    let url: URL
    var location = "On My iPhone → PodSkipper"
    var onDelete: (() -> Void)? = nil
    @State private var bytes: Int64 = 0
    @State private var confirm: Confirmation?

    var body: some View {
        Button { SharePresenter.present([url]) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill").font(.title3).foregroundStyle(Theme.accentHot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).lineLimit(2).foregroundStyle(.primary)
                    Text("\(formattedBytes(bytes)) · \(location)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accentHot)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Share \(url.lastPathComponent)")
        .accessibilityIdentifier("file.share")
        .contextMenu {
            Button("Share", systemImage: "square.and.arrow.up") { SharePresenter.present([url]) }
            if let onDelete {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirm = Confirmation(title: "Delete \(url.lastPathComponent)?",
                                           message: "Removes this file from \(location). Your library isn't touched, and copies you've shared elsewhere stay.",
                                           actionTitle: "Delete") { onDelete() }
                }
            }
        }
        .confirmation($confirm)
        .task(id: url) {
            bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// Pass 35: the actions for what is selected, in a glass bar above the tab
/// bar and mini player (`.safeAreaBar`, as the show page does). A toolbar
/// `.bottomBar` sits underneath the app's own tab bar, where his storage
/// screens' Remove button was drawn but couldn't be reached.
struct SelectionActionBar: View {
    struct Action: Identifiable {
        let id = UUID()
        var title: String
        var symbol: String
        var enabled = true
        var run: () -> Void
    }
    let count: Int
    var noun = "selected"
    /// Pass 45: off where the page's title already says how many.
    var showsCount = true
    let actions: [Action]

    var body: some View {
        VStack(spacing: 8) {
            if showsCount {
                Text(count == 0 ? "Select items" : "\(count) \(noun)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button(action: action.run) {
                            // Pass 45: a lone action hugs its words instead of
                            // spanning the screen above the mini player.
                            GlassButtonLabel(title: action.title, systemImage: action.symbol, fills: actions.count > 1)
                                .padding(.horizontal, actions.count > 1 ? 0 : 12)
                        }
                        .buttonStyle(.glass)
                        .disabled(!action.enabled || count == 0)
                        .accessibilityIdentifier("selection." + action.title)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

extension View {
    /// The selection bar while `editing`, nothing otherwise.
    func selectionBar(_ editing: Bool, _ bar: @escaping () -> SelectionActionBar) -> some View {
        safeAreaBar(edge: .bottom) { if editing { bar() } }
    }
}

/// Pass 35: one confirmation per page. A section built from several List
/// rows (a `Group`) can't hold an alert itself — a Group's modifiers go on
/// each row, so every row presents it, and a lazy row that has scrolled away
/// presents nothing. The page's List hosts it; sections ask through here.
struct AskConfirmation {
    fileprivate var handler: @MainActor (Confirmation) -> Void = { _ in }
    @MainActor func callAsFunction(_ request: Confirmation) { handler(request) }
}

extension EnvironmentValues {
    @Entry var askConfirmation = AskConfirmation()
}

private struct ConfirmationHost: ViewModifier {
    @State private var request: Confirmation?
    func body(content: Content) -> some View {
        content
            .environment(\.askConfirmation, AskConfirmation(handler: { request = $0 }))
            .confirmation($request)
    }
}

extension View {
    /// Hosts confirmations asked for by anything inside (`askConfirmation`).
    func confirmationHost() -> some View { modifier(ConfirmationHost()) }
}
