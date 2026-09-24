import SwiftUI

/// Touch keys for remote typing when iPadOS has focused the input but shows
/// only a hardware-keyboard accessory strip. These keys send directly to Mac.
struct RemoteFallbackKeyboard: View {
    let onText: (String) -> Void
    let onDelete: () -> Void
    let onReturn: () -> Void
    let onDismiss: () -> Void

    @State private var uppercase = false
    @State private var symbols = false

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("TailView keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if symbols {
                characterRow("1234567890")
                characterRow(["@", "#", "$", "%", "&", "-", "+", "(", ")", "/"])
                HStack(spacing: 5) {
                    modeButton("ABC")
                    ForEach(["*", "\"", "'", ":", ";", "!", "?", "_"], id: \.self) { value in
                        characterButton(value)
                    }
                    deleteButton
                }
            } else {
                characterRow("qwertyuiop")
                characterRow("asdfghjkl")
                    .padding(.horizontal, 12)
                HStack(spacing: 5) {
                    Button {
                        uppercase.toggle()
                    } label: {
                        Text("⇧").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityLabel("Shift")
                    .accessibilityValue(uppercase ? "On" : "Off")
                    .background(uppercase ? Color.accentColor : keyColor, in: keyShape)
                    ForEach(Array("zxcvbnm").map { String($0) }, id: \.self) { value in
                        characterButton(value)
                    }
                    deleteButton
                }
            }
            HStack(spacing: 5) {
                modeButton(symbols ? "ABC" : "123")
                    .frame(width: 50)
                characterButton(",")
                    .frame(width: 38)
                Button("space") { onText(" ") }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(keyColor, in: keyShape)
                    .accessibilityIdentifier("tailview.fallback.key.space")
                characterButton(".")
                    .frame(width: 38)
                Button("return", action: onReturn)
                    .frame(width: 64, height: 44)
                    .background(Color.accentColor.opacity(0.35), in: keyShape)
                    .accessibilityIdentifier("tailview.fallback.key.return")
                Button(action: onDismiss) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .frame(width: 44, height: 44)
                }
                .background(keyColor, in: keyShape)
                .accessibilityLabel("Hide keyboard")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 18))
        .padding(8)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .accessibilityIdentifier("tailview.fallbackKeyboard")
    }

    private var keyShape: RoundedRectangle { RoundedRectangle(cornerRadius: 6) }
    private var keyColor: Color { Color(uiColor: .tertiarySystemFill) }

    private func characterRow(_ letters: String) -> some View {
        characterRow(Array(letters).map { String($0) })
    }

    private func characterRow(_ letters: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(letters, id: \.self) { value in characterButton(value) }
        }
    }

    private func characterButton(_ value: String) -> some View {
        Button {
            onText(symbols || !uppercase ? value : value.uppercased())
            if !symbols { uppercase = false }
        } label: {
            Text(symbols || !uppercase ? value : value.uppercased())
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background(keyColor, in: keyShape)
        .accessibilityIdentifier("tailview.fallback.key.\(value)")
    }

    private func modeButton(_ title: String) -> some View {
        Button(title) {
            symbols.toggle()
            uppercase = false
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(keyColor, in: keyShape)
        .accessibilityLabel(symbols ? "Letters" : "Numbers and symbols")
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "delete.left")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background(keyColor, in: keyShape)
        .accessibilityLabel("Delete")
        .accessibilityIdentifier("tailview.fallback.key.delete")
    }
}
