import SwiftUI
import WidgetKit

private struct ConnectEntry: TimelineEntry {
    let date: Date
}

private struct ConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConnectEntry { ConnectEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ConnectEntry) -> Void) {
        completion(ConnectEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConnectEntry>) -> Void) {
        // This is a launcher, so it needs no network requests or background refresh.
        completion(Timeline(entries: [ConnectEntry(date: .now)], policy: .never))
    }
}

struct TailViewConnectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TailViewConnect", provider: ConnectProvider()) { _ in
            ConnectWidgetView()
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.06, green: 0.14, blue: 0.24),
                                            Color(red: 0.02, green: 0.07, blue: 0.13)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .widgetURL(WidgetRoute.connect.url)
        }
        .configurationDisplayName("Connect to Mac")
        .description("Open your saved Mac in TailView. Add keyboard and settings shortcuts with the medium widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        .disfavoredLocations([.iPhoneWidgetsOnMac], for: [.systemSmall, .systemMedium])
    }
}

private struct ConnectWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "display")
                .font(.title2)
                .widgetAccentable()
                .accessibilityLabel("Connect to Mac in TailView")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("TailView", systemImage: "display").font(.headline)
                Text("Connect to Mac").font(.caption)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                Link(destination: WidgetRoute.connect.url) { connectCard }
                VStack(spacing: 10) {
                    shortcut("Keyboard", symbol: "keyboard", route: .keyboard)
                    shortcut("Settings", symbol: "gearshape", route: .settings)
                }
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
        default:
            connectCard.foregroundStyle(.white)
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: "display")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.cyan)
                    .widgetAccentable()
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 4)
            Text("TailView")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("Connect to Mac")
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text("Open your saved Mac")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TailView. Connect to your saved Mac.")
    }

    private func shortcut(_ title: String, symbol: String, route: WidgetRoute) -> some View {
        Link(destination: route.url) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("Open TailView \(title)")
    }
}

#Preview(as: .systemSmall) {
    TailViewConnectWidget()
} timeline: {
    ConnectEntry(date: .now)
}

#Preview(as: .systemMedium) {
    TailViewConnectWidget()
} timeline: {
    ConnectEntry(date: .now)
}
