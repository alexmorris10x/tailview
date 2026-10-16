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
    /// Command-V or a Paste menu. Returns false to insert the text as typing.
    let onPaste: () -> Bool
    let onSoftwareKeyboardVisibilityChange: (Bool) -> Void

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
        // Keyboard extensions delete through UITextDocumentProxy. An empty
        // document can swallow that request before deleteBackward is called.
        // Keep one private character and reject local edits below so every
        // repeated deletion still has a character to target.
        field.text = "\u{200B}"
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.accessibilityElementsHidden = true
        field.accessibilityIdentifier = "tailview.remoteKeyboardInput"
        field.onSoftwareKeyboardVisibilityChange = { [weak coordinator = context.coordinator] visible in
            coordinator?.parent.onSoftwareKeyboardVisibilityChange(visible)
        }
        field.onDeleteBackward = { [weak coordinator = context.coordinator] in
            guard let parent = coordinator?.parent, parent.isActive else { return }
            parent.onDelete()
        }
        field.onPaste = { [weak coordinator = context.coordinator] in
            guard let parent = coordinator?.parent, parent.isActive else { return true }
            return parent.onPaste()
        }
        return field
    }

    func updateUIView(_ field: RemoteTextField, context: Context) {
        context.coordinator.parent = self
        field.onSoftwareKeyboardVisibilityChange = { [weak coordinator = context.coordinator] visible in
            coordinator?.parent.onSoftwareKeyboardVisibilityChange(visible)
        }
        let shouldRefresh = context.coordinator.lastFocusRequest != focusRequest
        let activeChanged = context.coordinator.lastActive != isActive
        context.coordinator.lastFocusRequest = focusRequest
        context.coordinator.lastActive = isActive
        field.desiredActive = isActive
        if shouldRefresh || activeChanged { field.refreshFocus(restart: shouldRefresh) }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RemoteKeyboardInput
        var lastFocusRequest = -1
        var lastActive: Bool?

        init(_ parent: RemoteKeyboardInput) { self.parent = parent }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard parent.isActive else { return false }
            if string.isEmpty {
                // Some keyboards replace a range instead of calling the
                // field's deleteBackward override. Forward either path once.
                if range.length > 0 { parent.onDelete() }
            } else {
                parent.onText(string)
            }
            // Never send or remove the private placeholder.
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
    var onSoftwareKeyboardVisibilityChange: ((Bool) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPaste: (() -> Bool)?
    private var focusGeneration = 0
    private var pendingRefocusGeneration: Int?
    private var softwareKeyboardVisible = false
    private var keyWindowObserver: NSObjectProtocol?
    private var keyboardShowObserver: NSObjectProtocol?
    private var keyboardHideObserver: NSObjectProtocol?

    /// Direct Backspace events, including hardware auto-repeat. Do not call
    /// super: that would also reach the delegate and delete the placeholder.
    override func deleteBackward() {
        onDeleteBackward?()
    }

    /// A hardware Command-V or a Paste menu. Handled pastes go to the Mac in
    /// one piece; otherwise UIKit inserts the text and it is typed as before.
    override func paste(_ sender: Any?) {
        if onPaste?() != true { super.paste(sender) }
    }

    deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        if let keyboardShowObserver { NotificationCenter.default.removeObserver(keyboardShowObserver) }
        if let keyboardHideObserver { NotificationCenter.default.removeObserver(keyboardHideObserver) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = nil
        if let window {
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.refreshFocus(restart: false) }
        }
        if keyboardShowObserver == nil {
            keyboardShowObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
            ) { [weak self] notification in self?.keyboardDidShow(notification) }
            keyboardHideObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.keyboardDidHide() }
        }
        refreshFocus(restart: false)
    }

    func refreshFocus(restart: Bool) {
        focusGeneration += 1
        let generation = focusGeneration
        pendingRefocusGeneration = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusGeneration == generation, let window = self.window else { return }
            if self.desiredActive {
                guard window.isKeyWindow else {
                    #if DEBUG
                    self.logKeyboard("windowNotKey")
                    #endif
                    return
                }
                if restart && self.isFirstResponder {
                    // A visible keyboard needs no restart. Resigning and
                    // immediately reactivating can hide it instead.
                    guard !self.softwareKeyboardVisible else { return }
                    self.pendingRefocusGeneration = generation
                    self.resignFirstResponder()
                    // With no onscreen keyboard there may be no didHide
                    // notification, so retry after UIKit's transition settles.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        self?.finishPendingRefocus(generation)
                    }
                } else if !self.isFirstResponder {
                    _ = self.becomeFirstResponder()
                    #if DEBUG
                    self.logKeyboard("focused")
                    #endif
                }
            } else {
                if self.isFirstResponder { self.resignFirstResponder() }
            }
        }
    }

    private func keyboardDidShow(_ notification: Notification) {
        guard desiredActive else { return }
        if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
           let window {
            let inWindow = window.convert(frame, from: window.screen.coordinateSpace)
            let visible = window.bounds.intersection(inWindow).height > 100
            if softwareKeyboardVisible != visible {
                softwareKeyboardVisible = visible
                onSoftwareKeyboardVisibilityChange?(visible)
            }
            #if DEBUG
            logKeyboard("didShow overlap=\(Int(window.bounds.intersection(inWindow).height))")
            #endif
        }
    }

    private func keyboardDidHide() {
        if softwareKeyboardVisible {
            softwareKeyboardVisible = false
            onSoftwareKeyboardVisibilityChange?(false)
        }
        #if DEBUG
        logKeyboard("didHide")
        #endif
        if let generation = pendingRefocusGeneration { finishPendingRefocus(generation) }
    }

    private func finishPendingRefocus(_ generation: Int) {
        guard pendingRefocusGeneration == generation else { return }
        pendingRefocusGeneration = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusGeneration == generation,
                  self.desiredActive, self.window?.isKeyWindow == true else { return }
            _ = self.becomeFirstResponder()
            #if DEBUG
            self.logKeyboard("refocused")
            #endif
        }
    }

    #if DEBUG
    private func logKeyboard(_ stage: String) {
        print("TailViewKeyboard \(stage) keyWindow=\(window?.isKeyWindow == true) firstResponder=\(isFirstResponder)")
    }
    #endif
}
