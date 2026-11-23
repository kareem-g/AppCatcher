import StoreKit
import SwiftUI

/// The paywall. Everything it claims is enforced in the services, so the
/// feature list is a description of behaviour, not a wish. Pushed from
/// Settings, or wrapped in a NavigationStack when shown as a sheet.
struct PremiumView: View {
    @Environment(AppModel.self) private var model

    private var pro: ProService { model.pro }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pro.isPro ? "You're on Pro" : "One purchase. No subscription.")
                        .font(.title2.bold())
                    Text(pro.isPro
                         ? "Backup history, encryption and scheduled cleaning are unlocked."
                         : "No ads, no account, no tracking.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section("Includes") {
                Label("Unlimited backup history", systemImage: "clock.arrow.circlepath")
                Label("Password-encrypted archives", systemImage: "lock")
                Label("Scheduled cleaning", systemImage: "calendar")
                Label("Web data in one-tap and scheduled cleans", systemImage: "globe")
            }

            Section {
                if pro.isPro {
                    Button("Restore Purchases") { Task { await pro.restore() } }.foregroundStyle(.tint)
                    if pro.offersPreviewUnlock {
                        // A local build cannot prove the purchase, so it must
                        // also be able to take the preview unlock back.
                        Button("Lock Pro Again", role: .destructive) { pro.lockAgain() }
                    }
                } else {
                    LabeledContent("AppCatcher Pro", value: pro.product?.displayPrice ?? "$4.99")
                    Button(purchaseTitle) {
                        Task {
                            if pro.offersPreviewUnlock {
                                pro.unlockForPreview()
                            } else {
                                await pro.purchase()
                            }
                        }
                    }
                    .foregroundStyle(.tint)
                    .disabled(pro.status == .purchasing || pro.status == .loading)
                    Button("Restore Purchases") { Task { await pro.restore() } }.foregroundStyle(.tint)
                }
            } footer: {
                Group {
                    if case .failed(let message) = pro.status {
                        Text(message).foregroundStyle(.red)
                    } else if pro.storeIsUnavailable {
                        Text("This build could not load the App Store product, so unlocking turns Pro on locally and charges nothing.")
                    } else if pro.isChecking {
                        Text("Contacting the App Store…")
                    }
                }
                .footnote()
            }
        }
        .listStyle(.plain)
        .navigationTitle("AppCatcher Pro")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var purchaseTitle: String {
        if pro.status == .purchasing { return "Completing Purchase…" }
        if pro.offersPreviewUnlock { return "Unlock Pro on This Build" }
        return "Unlock Pro"
    }
}
