import SwiftUI

// Pass 35: the iCloud, Widgets & CarPlay page is `DevicesSection`
// (Settings → iCloud, Widgets & CarPlay), with status read from the app's
// own signature. The widget gallery below is shared with it.

/// The widgets drawn at their real Home Screen sizes, from the same views the
/// widget extension uses.
struct WidgetGalleryView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                tile(width: 158, height: 158) { UpNextWidgetView(snapshot: snapshot, size: .small) }
                tile(width: 158, height: 158) { NowPlayingWidgetView(snapshot: snapshot) }
            }
            tile(width: 330, height: 158) { UpNextWidgetView(snapshot: snapshot, size: .medium) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("WidgetGallery")
    }

    private func tile<Content: View>(width: CGFloat, height: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: width, height: height)
            .background(WidgetStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCorner, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}
