import SwiftUI

@MainActor
struct PurchaseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var access: PurchaseAccess
    private let embedded: Bool

    init(access: PurchaseAccess? = nil, embedded: Bool = false) {
        self.access = access ?? .shared
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content.toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            }
        }
        .task { await access.refresh() }
    }

    private var content: some View {
            Form {
                Section {
                    Label(access.statusTitle, systemImage: access.streamAllowed ? "checkmark.circle.fill" : "display")
                        .font(.headline)
                        .accessibilityIdentifier("tailview.purchase.status")
                    Text(access.statusDetail)
                        .foregroundStyle(.secondary)
                }

                if access.state != .lifetime && access.state != .developer {
                    Section {
                        Label("See and control your own Mac", systemImage: "cursorarrow")
                        Label("Listen to Mac audio", systemImage: "speaker.wave.2")
                        Label("Use your iPhone or iPad microphone on Mac", systemImage: "mic")
                    } header: {
                        Text("Full access includes")
                    } footer: {
                        Text("Requires your Mac, the free TailView Mac companion, and Tailscale on both devices. Finish setup and pair your Mac before starting the trial.")
                    }

                    if access.state == .trialAvailable {
                        Section {
                            Button {
                                Task { await access.startTrial() }
                            } label: {
                                Text(trialButtonTitle)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!access.canStartTrial || access.purchaseInProgress)
                            .accessibilityIdentifier("tailview.purchase.start-trial")
                        } header: {
                            Text("7-day free trial")
                        } footer: {
                            Text(trialDisclosure)
                        }
                    }

                    Section {
                        Button {
                            Task { await access.buyLifetime() }
                        } label: {
                            Text(lifetimeButtonTitle)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(access.lifetimeProduct == nil || access.purchaseInProgress || access.state == .loading)
                        .accessibilityIdentifier("tailview.purchase.lifetime")
                    } header: {
                        Text("Keep TailView")
                    } footer: {
                        Text("One payment permanently unlocks screen viewing, control, and audio on your iPhone and iPad using the same Apple Account. No recurring fee. The Mac companion is free.")
                    }
                }

                Section {
                    Button("Restore Purchases") {
                        Task { await access.restore() }
                    }
                    .disabled(access.isBusy)
                    .accessibilityIdentifier("tailview.purchase.restore")

                    if access.productsLoading || access.isBusy {
                        ProgressView(access.isBusy ? "Waiting for the App Store…" : "Loading App Store prices…")
                    }
                    if let message = access.message {
                        Label(message, systemImage: access.messageIsError ? "exclamationmark.circle" : "info.circle")
                            .foregroundStyle(access.messageIsError ? Color.red : Color.secondary)
                            .accessibilityIdentifier("tailview.purchase.message")
                    }
                    if let error = access.productError, access.state != .lifetime && access.state != .developer {
                        Text(error).foregroundStyle(.secondary)
                        Button("Reload App Store Prices") {
                            Task { await access.loadProducts() }
                        }
                        .disabled(access.productsLoading || access.isBusy)
                    }
                } footer: {
                    Text("Restore with the Apple Account used for the original purchase. A restored trial keeps its original end date.")
                }
            }
            .navigationTitle("TailView Access")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var trialButtonTitle: String {
        guard let product = access.trialProduct else { return "Start 7-day free trial" }
        return "Start 7-day free trial · \(product.displayPrice)"
    }

    private var trialDisclosure: String {
        let price = access.lifetimeProduct.map { "The optional permanent unlock costs \($0.displayPrice), paid once. " } ?? "The permanent unlock price must load before you start. "
        return "Starts only when you choose this option and confirm with the App Store. After seven days, screen viewing, control, and audio stop unless you choose to buy the permanent unlock. " + price + "No subscription, no automatic charge. Your saved Macs and setup stay available."
    }

    private var lifetimeButtonTitle: String {
        guard let product = access.lifetimeProduct else { return "Unlock permanently" }
        return "Unlock permanently · \(product.displayPrice)"
    }
}
