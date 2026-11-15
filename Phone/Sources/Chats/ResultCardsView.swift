import SwiftUI
import SyncKit

/// What a turn made on the Mac, as the Mac's chat shows it under the answer
/// (ChatResultCard there): pages found, a comparison, an event, a reminder,
/// a watch, a routine, a folder of tabs. Each card as wide as what it
/// holds, up to 356; a row opens its page here.
struct ResultCardsView: View {
    let cards: [ResultCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                ResultCardView(card: card)
            }
        }
    }
}

private struct ResultCardView: View {
    let card: ResultCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .padding(card.kind == .links || card.kind == .folder || card.kind == .table ? 6 : 12)
            .frame(maxWidth: 356, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.outline.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Ink.shadow.opacity(0.06), radius: 6, y: 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.card." + card.kind.rawValue)
    }

    @ViewBuilder private var content: some View {
        switch card.kind {
        case .links, .folder:
            VStack(alignment: .leading, spacing: 0) {
                if card.kind == .folder {
                    row(nil) {
                        Text(card.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1)
                        Spacer(minLength: 12)
                        Text("on your Mac").font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.5))
                    }
                }
                ForEach(Array((card.rows ?? []).enumerated()), id: \.offset) { _, item in
                    row(item.url) {
                        Favicon(icon: item.site ?? ResultCard.host(item.url) ?? "", host: item.site ?? ResultCard.host(item.url), size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 15, weight: card.kind == .links ? .medium : .regular))
                                .foregroundStyle(Ink.primary).lineLimit(1)
                            if card.kind == .links, !ResultCard.under(item).isEmpty {
                                Text(ResultCard.under(item)).font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.5)).lineLimit(1)
                            }
                        }
                    }
                }
            }
        case .table:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((card.rows ?? []).enumerated()), id: \.offset) { index, item in
                    row(item.url) {
                        Favicon(icon: item.site ?? ResultCard.host(item.url) ?? "", host: item.site ?? ResultCard.host(item.url), size: 20)
                        Text(item.title).font(.system(size: 15)).foregroundStyle(Ink.primary).lineLimit(1)
                        Spacer(minLength: 12)
                        Text((item.cells ?? []).joined(separator: " \u{00B7} "))
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.primary).lineLimit(1)
                    }
                    .background(Ink.primary.opacity(card.lit == index ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        case .event:
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text(day("EEE").uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 11).background(Color(red: 0.90, green: 0.28, blue: 0.30))
                    Text(day("d")).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.primary).frame(maxHeight: .infinity)
                }
                .frame(width: 34, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.outline.opacity(0.1), lineWidth: 0.5))
                two(card.title, [card.hours(), card.detail].compactMap { $0 }.joined(separator: " \u{00B7} "))
            }
            .onTapGesture { if let url = card.url.flatMap(URL.init(string:)) { openURL(url) } }
        case .promise:
            Text(card.promise()).font(.system(size: 15)).foregroundStyle(Ink.primary)
        case .watch:
            two("Watching: " + card.title, card.value.map { "Now " + $0 + (card.site.map { " on " + $0 } ?? "") } ?? "")
                .onTapGesture { if let url = card.url.flatMap(URL.init(string:)) { openURL(url) } }
        case .routine:
            two(card.title, card.detail ?? "")
        }
    }

    private func row(_ address: String?, @ViewBuilder _ label: () -> some View) -> some View {
        HStack(spacing: 10) { label() }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(minHeight: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if let url = address.flatMap(URL.init(string:)) { openURL(url) } }
    }

    private func two(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 13)).monospacedDigit().foregroundStyle(ChatInk.gray(0.5)).lineLimit(1)
            }
        }
    }

    private func day(_ pattern: String) -> String {
        guard let at = card.at else { return "" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.dateFormat = pattern
        return format.string(from: Date(timeIntervalSince1970: at))
    }
}
