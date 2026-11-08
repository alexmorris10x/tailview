import StoreKit
import SwiftUI
import UIKit

/// How people reach Alex: Settings › Support and the access screen (app standard part 9).
enum ContactAlex {
    static let telegramURL = URL(string: "https://t.me/alexmorris10x")!
    static let telegramTitle = "Message Alex on Telegram"
    static let invitation = "Tell me anything: a bug, a wish, a complaint. I read every message and ship fixes fast."
    static let supportURL = URL(string: "https://alexmorris10x.github.io/tailview/support.html")!
    static let privacyURL = URL(string: "https://alexmorris10x.github.io/tailview/privacy.html")!

    /// StoreKit's app transaction ID (iOS 18.4+); earlier, the original ID of
    /// this Apple Account's first purchase here. Nil when neither exists.
    static func loadSupportID() async -> String? {
        if #available(iOS 18.4, *),
           let result = try? await AppTransaction.shared,
           case .verified(let transaction) = result {
            return transaction.appTransactionID
        }
        for await result in Transaction.all {
            if case .verified(let transaction) = result { return String(transaction.originalID) }
        }
        return nil
    }

    /// App, version, OS, device, purchase state and Support ID, for pasting into a message.
    @MainActor
    static func supportDetails(supportID: String?, access: PurchaseAccess) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return [
            "App: Mac Remote \(version) (\(build))",
            "iOS: \(UIDevice.current.systemVersion)",
            "Device: \(deviceModel)",
            "Purchase: \(purchaseState(access.state))",
            "Support ID: \(supportID ?? "none")",
        ].joined(separator: "\n")
    }

    private static func purchaseState(_ state: PurchaseAccess.AccessState) -> String {
        switch state {
        case .loading: return "checking"
        case .trialAvailable: return "none"
        case .trialActive: return "trial"
        case .trialExpired: return "none (trial ended)"
        case .lifetime: return "unlocked"
        case .revoked: return "none (revoked)"
        case .verificationFailed: return "none (verification failed)"
        case .developer: return "unlocked (developer)"
        }
    }

    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }
}

/// Settings › Support: the invitation, Telegram, Support ID, Copy Support Details, support and privacy pages.
struct ContactAlexSection: View {
    @ObservedObject var access: PurchaseAccess
    @State private var supportID: String?
    @State private var supportIDCopied = false
    @State private var supportDetailsCopied = false

    var body: some View {
        Section("Support") {
            Text(ContactAlex.invitation)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tailview.support.invitation")
            Link(destination: ContactAlex.telegramURL) {
                Label(ContactAlex.telegramTitle, systemImage: "paperplane")
            }
            .accessibilityIdentifier("tailview.support.telegram")
            if let supportID {
                LabeledContent("Support ID") {
                    Text(supportID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = supportID
                    supportIDCopied = true
                } label: {
                    Label(supportIDCopied ? "Support ID Copied" : "Copy Support ID",
                          systemImage: supportIDCopied ? "checkmark" : "doc.on.doc")
                }
            }
            Button {
                UIPasteboard.general.string = ContactAlex.supportDetails(supportID: supportID, access: access)
                supportDetailsCopied = true
            } label: {
                Label(supportDetailsCopied ? "Support Details Copied" : "Copy Support Details",
                      systemImage: supportDetailsCopied ? "checkmark" : "doc.on.clipboard")
            }
            Link(destination: ContactAlex.supportURL) {
                Label("Support", systemImage: "questionmark.circle")
            }
            Link(destination: ContactAlex.privacyURL) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
        }
        .task { supportID = await ContactAlex.loadSupportID() }
    }
}
