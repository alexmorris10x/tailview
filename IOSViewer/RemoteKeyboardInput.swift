import SwiftUI
import UIKit

/// A real UIKit text input opens the configured iOS keyboard. Its edits are
/// forwarded immediately, so no local text field or Send step is shown.
struct RemoteKeyboardInput: UIViewRepresentable {
    let isActive: Bool
    let focusRequest: Int
    let onText: (String) -> Void
    let onDelete: () -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> RemoteTextField {
        let field = RemoteTextField(frame: .zero)
        field.delegate = context.coordinator
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.accessibilityElementsHidden = true
        field.accessibilityIdentifier = "tailview.remoteKeyboardInput"
        return field
    }

    func updateUIView(_ field: RemoteTextField, context: Context) {
        context.coordinator.parent = self
        let shouldRefresh = context.coordinator.lastFocusRequest != focusRequest
        context.coordinator.lastFocusRequest = focusRequest
        field.desiredActive = isActive
        field.refreshFocus(restart: shouldRefresh)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RemoteKeyboardInput
        var lastFocusRequest = -1

        init(_ parent: RemoteKeyboardInput) { self.parent = parent }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard parent.isActive else { return false }
            if string.isEmpty { parent.onDelete() }
            else { parent.onText(string) }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if parent.isActive { parent.onReturn() }
            return false
        }
    }
}

final class RemoteTextField: UITextField {
    var desiredActive = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshFocus(restart: false)
    }

    func refreshFocus(restart: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.window != nil else { return }
            if self.desiredActive {
                if restart && self.isFirstResponder { self.resignFirstResponder() }
                if !self.isFirstResponder { self.becomeFirstResponder() }
            } else {
                if self.isFirstResponder { self.resignFirstResponder() }
            }
        }
    }
}
