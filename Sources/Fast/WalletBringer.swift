import SwiftUI

/// Settings' row for cards and addresses from elsewhere: brought in right
/// there, from every browser that has some at once or from one, and said
/// under the row when done. Safari's export needs Autofill's own screen,
/// where Yab waits for the file, so that one goes there.
struct WalletBringer: View {
    @ObservedObject var browser: Browser
    let anchor: String
    /// Worn where the rows around it wear theirs (Passwords), not on Bring
    /// in, whose rows go without.
    var icon = false

    private enum Stage: Equatable {
        case counting
        case idle
        case bringing(String)
        case said(String)
    }
    @State private var stage: Stage = .counting
    @State private var wallets: [(source: Chromium.Source, cards: Int, addresses: Int)] = []

    var body: some View {
        Group {
            if icon {
                FeatureRow("Bring cards and addresses in", icon: "tray.and.arrow.down", tint: .systemGray, detail: detail) { button }
            } else {
                SettingsRow("Bring cards and addresses in", detail: detail) { button }
            }
        }
        .settingsAnchor(anchor)
        .task { count() }
    }

    @ViewBuilder
    private var button: some View {
        if case .bringing = stage {
            ProgressView().controlSize(.small)
        } else {
            Menu("Bring In") {
                if wallets.count > 1 {
                    Button("All Browsers") { bring(wallets.map(\.source)) }
                    Divider()
                }
                ForEach(wallets, id: \.source.id) { wallet in
                    Button("\(wallet.source.name) · \(Browser.walletCount(wallet.cards, wallet.addresses))") { bring([wallet.source]) }
                }
                if !wallets.isEmpty { Divider() }
                Button("Safari…") {
                    browser.tuning = false
                    browser.openPlace(.autofill)
                    browser.bringMore()
                    browser.waitForSafari("safari")
                }
                Button("Your Card in Contacts") { fromContacts() }
            }
            .settingsButton()
            .fixedSize()
        }
    }

    /// Under the title: what is waiting where, what is happening, or what
    /// came of it.
    private var detail: String {
        switch stage {
        case .counting: return "From Chrome, Arc, Safari or your card in Contacts."
        case .bringing(let name): return "Bringing them in from \(name)…"
        case .said(let text): return text
        case .idle:
            guard !wallets.isEmpty else { return "From Chrome, Arc, Safari or your card in Contacts." }
            let cards = wallets.reduce(0) { $0 + $1.cards }, addresses = wallets.reduce(0) { $0 + $1.addresses }
            let names = wallets.map(\.source.name)
            let where_ = names.count == 1 ? names[0] : names.count == 2 ? "\(names[0]) and \(names[1])" : "\(names.count) browsers"
            return "\(Browser.walletCount(cards, addresses)) in \(where_). Existing cards and addresses are kept."
        }
    }

    /// The browsers with some, counted without their keys, off the main
    /// thread.
    private func count() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Chromium.installed().compactMap { source -> (source: Chromium.Source, cards: Int, addresses: Int)? in
                let count = Chromium.walletCount(source)
                return count.cards + count.addresses > 0 ? (source, count.cards, count.addresses) : nil
            }.sorted { $0.cards + $0.addresses > $1.cards + $1.addresses }
            DispatchQueue.main.async {
                wallets = found
                if stage == .counting { stage = .idle }
            }
        }
    }

    /// Each browser's in turn, its key asked once; one that says no doesn't
    /// stop the rest, and is named at the end.
    private func bring(_ sources: [Chromium.Source]) {
        guard let first = sources.first else { return }
        stage = .bringing(first.name)
        DispatchQueue.global(qos: .userInitiated).async {
            var kept = (cards: 0, addresses: 0)
            var refused: [String] = []
            for source in sources {
                DispatchQueue.main.async { stage = .bringing(source.name) }
                guard let found = try? Chromium.wallet(source) else { refused.append(source.name); continue }
                let took = Wallet.take(cards: found.cards, addresses: found.addresses)
                kept.cards += took.cards
                kept.addresses += took.addresses
            }
            DispatchQueue.main.async {
                let brought = kept.cards + kept.addresses == 0 ? "Nothing new: they are all here already." : "Brought in \(Browser.walletCount(kept.cards, kept.addresses))."
                let trouble = refused.isEmpty ? "" : " \(refused.joined(separator: " and ")) didn’t hand over \(refused.count == 1 ? "its" : "their") key: try again and choose Always Allow."
                stage = .said(brought + trouble)
            }
        }
    }

    private func fromContacts() {
        stage = .bringing("Contacts")
        MeCard.addresses { found in
            DispatchQueue.global(qos: .userInitiated).async {
                let kept = Wallet.take(cards: [], addresses: found)
                DispatchQueue.main.async {
                    stage = .said(found.isEmpty ? "Your contact card has no address."
                                  : kept.addresses == 0 ? "Every address on your contact card is here already."
                                  : "Brought in \(Browser.walletCount(0, kept.addresses)).")
                }
            }
        }
    }
}
