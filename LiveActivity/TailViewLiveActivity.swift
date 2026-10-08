import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TailViewWidgets: WidgetBundle {
    var body: some Widget {
        TailViewControlsLiveActivity()
    }
}

struct TailViewControlsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TailViewControlsAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "display")
                    Text(context.attributes.macName).font(.headline)
                    Spacer()
                    Text(StatusText.text(context))
                        .font(.caption)
                        .foregroundStyle(context.isStale ? Color.orange : Color.secondary)
                }
                ControlButtons(state: context.state)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.macName, systemImage: "display")
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(StatusText.text(context))
                        .font(.caption)
                        .foregroundStyle(context.isStale ? Color.orange : Color.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ControlButtons(state: context.state)
                }
            } compactLeading: {
                if context.isStale {
                    Image(systemName: StatusText.staleSymbol).foregroundStyle(.orange)
                } else {
                    Image(systemName: MicrophoneSymbol.name(context.state))
                        .foregroundStyle(MicrophoneSymbol.color(context.state))
                }
            } compactTrailing: {
                if context.isStale {
                    Text("Open").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } else if context.state.functionHeld {
                    Text("fn").font(.caption.weight(.bold)).foregroundStyle(.green)
                } else {
                    Image(systemName: context.state.macSoundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .foregroundStyle(context.state.macSoundOn ? Color.primary : Color.red)
                }
            } minimal: {
                if context.isStale {
                    Image(systemName: StatusText.staleSymbol).foregroundStyle(.orange)
                } else if context.state.functionHeld {
                    Text("fn").font(.caption2.weight(.bold)).foregroundStyle(.green)
                } else {
                    Image(systemName: MicrophoneSymbol.name(context.state))
                        .foregroundStyle(MicrophoneSymbol.color(context.state))
                }
            }
        }
    }
}

/// TailView confirms the activity while it runs. A stale activity means iOS
/// suspended or ended the app, so its buttons and status are out of date.
private enum StatusText {
    static let staleSymbol = "exclamationmark.triangle.fill"

    static func text(_ context: ActivityViewContext<TailViewControlsAttributes>) -> String {
        context.isStale ? "Not running – open TailView" : context.state.status
    }
}

private enum MicrophoneSymbol {
    static func name(_ state: TailViewControlsAttributes.ContentState) -> String {
        !state.microphoneOn ? "mic.slash.fill" : state.microphoneNeedsAttention ? "mic.badge.xmark" : "mic.fill"
    }

    static func color(_ state: TailViewControlsAttributes.ContentState) -> Color {
        !state.microphoneOn ? .red : state.microphoneNeedsAttention ? .orange : .primary
    }
}

private struct ControlButtons: View {
    let state: TailViewControlsAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleMicrophoneIntent()) {
                Label(state.microphoneOn ? "Mic on" : "Mic off", systemImage: MicrophoneSymbol.name(state))
                    .frame(maxWidth: .infinity)
            }
            .tint(MicrophoneSymbol.color(state))
            Button(intent: ToggleMacSoundIntent()) {
                Label(state.macSoundOn ? "Sound on" : "Sound off",
                      systemImage: state.macSoundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(state.macSoundOn ? .primary : .red)
            Button(intent: ToggleFunctionHoldIntent()) {
                Text(state.functionHeld ? "Release fn" : "Hold fn")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .tint(state.functionHeld ? .green : .primary)
            .disabled(!state.controlAvailable && !state.functionHeld)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
    }
}
