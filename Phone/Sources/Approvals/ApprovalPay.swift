import SwiftUI
#if canImport(SyncKit)
import SyncKit
#endif

/// A payment, as the Mac's pay sheet has it (Sources/Fast/PaySheet.swift):
/// the card and where it goes, each opening its list where the page has
/// boxes for one, and the total large. The total and the button step aside
/// while a list or a form is up.
struct ApprovalPayRoot: View {
    let tray: ApprovalTray
    let content: ApprovalContent
    private typealias M = ApprovalMetrics

    var body: some View {
        let pay = content.pay
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                cardRow(pay)
                Divider().padding(.leading, 62)
                placeRow(pay)
            }
            .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: M.group, style: .continuous))
            HStack(alignment: .firstTextBaseline) {
                Text(tray.phase == .paid ? "Paid" : "Total")
                    .font(.system(size: 16))
                    .foregroundStyle(ChatInk.gray(0.6))
                Spacer()
                Text(pay?.amount ?? "")
                    .font(.system(size: M.total, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Ink.primary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("approval.total")
            }
            .padding(.horizontal, 6)
        }
    }

    private func cardRow(_ pay: AssistantApprovalRecords.Detail.Pay?) -> some View {
        let card = pay?.cards.first { $0.id == tray.card }
        let typed = tray.card == ApprovalTray.newID ? tray.newCard : nil
        let title = typed.map { "\(AssistantWallet.brand(of: $0.number)) \u{2022}\u{2022}\u{2022}\u{2022} \(String($0.number.suffix(4)))" }
            ?? card.map(ApprovalContent.cardTitle) ?? "Card on \(pay?.site ?? "the site")"
        let declined = tray.declinedCard != nil && tray.declinedCard == tray.card
        let detail = declined ? "Declined by \(pay?.site ?? "the site")" : (typed?.name ?? card?.name ?? "")
        let opens = pay?.takesCard == true && tray.canChange
        return PayLine(lead: AnyView(CardMark(brand: typed.map { AssistantWallet.brand(of: $0.number) } ?? card?.brand ?? "")),
                       title: title, detail: detail, bad: declined, opens: opens, lit: tray.flash == "card",
                       id: "approval.card") { tray.go(.cards) }
    }

    private func placeRow(_ pay: AssistantApprovalRecords.Detail.Pay?) -> some View {
        let place = pay?.places.first { $0.id == tray.place }
        let typed = tray.place == ApprovalTray.newID ? tray.newPlace : nil
        let line = typed.map { "\($0.street.split(separator: "\n").first.map(String.init) ?? ""), \($0.city)" } ?? place?.line
        let who = typed.map { $0.name.isEmpty ? "New address" : $0.name } ?? place?.who ?? ""
        let detail = [who, pay?.delivery ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        let opens = pay?.takesPlace == true && tray.canChange
        return PayLine(lead: AnyView(PlaceMark(who: who)), title: line ?? "Address on \(pay?.site ?? "the site")", detail: detail,
                       bad: false, opens: opens, lit: tray.flash == "place", id: "approval.place") { tray.go(.places) }
    }
}

/// One of the pay sheet's rows: its mark, two lines, a chevron when it opens.
struct PayLine: View {
    let lead: AnyView
    let title: String
    let detail: String
    let bad: Bool
    let opens: Bool
    let lit: Bool
    let id: String
    let action: () -> Void
    @State private var glow = 0.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                lead.frame(width: ApprovalMetrics.avatar, height: ApprovalMetrics.avatar)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 13, weight: bad ? .medium : .regular))
                            .foregroundStyle(bad ? ApprovalInk.declined : ChatInk.gray(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatInk.gray(0.3))
                    .opacity(opens ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: ApprovalMetrics.payRow)
            .background(ChatInk.fill(0.12 * glow))
            .contentShape(Rectangle())
        }
        .buttonStyle(ApprovalPress())
        .disabled(!opens)
        .onChange(of: lit) { _, now in
            guard now else { return }
            glow = 1
            Motion.approvalGlow.run { glow = 0 }
        }
        .accessibilityIdentifier(id)
    }
}

/// A card's network, as a small plate: never its number.
struct CardMark: View {
    let brand: String

    var body: some View {
        let (fill, word): (Color, String) = switch brand {
        case "Visa": (Color(red: 0.1, green: 0.12, blue: 0.44), "VISA")
        case "Mastercard": (Color(red: 0.13, green: 0.13, blue: 0.15), "")
        case "American Express": (Color(red: 0.18, green: 0.47, blue: 0.73), "AMEX")
        case "Discover": (Color(red: 0.95, green: 0.45, blue: 0.13), "DISC")
        default: (ChatInk.fill(0.3), "")
        }
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill)
            if brand == "Mastercard" {
                HStack(spacing: -5) {
                    Circle().fill(Color(red: 0.92, green: 0, blue: 0.11)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.97, green: 0.62, blue: 0.11).opacity(0.9)).frame(width: 12, height: 12)
                }
            } else if word.isEmpty {
                Image(systemName: "creditcard").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            } else {
                Text(word).font(.system(size: 8, weight: .heavy)).italic().foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 24)
    }
}

struct PlaceMark: View {
    let who: String

    var body: some View {
        Image(systemName: who == "Office" || who == "Work" ? "briefcase" : "house")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Ink.primary)
            .frame(width: 32, height: 32)
            .background(ChatInk.fill(0.12), in: Circle())
    }
}

// MARK: - the lists

struct ApprovalCardList: View {
    let tray: ApprovalTray
    let content: ApprovalContent

    var body: some View {
        let cards = content.pay?.cards ?? []
        VStack(spacing: 0) {
            if let typed = tray.newCard {
                row(mark: AnyView(CardMark(brand: AssistantWallet.brand(of: typed.number))),
                    title: "\(AssistantWallet.brand(of: typed.number)) \u{2022}\u{2022}\u{2022}\u{2022} \(String(typed.number.suffix(4)))",
                    detail: typed.name, on: tray.card == ApprovalTray.newID, id: "approval.card.new") { tray.pickCard(ApprovalTray.newID) }
                Divider().padding(.leading, 62)
            }
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                row(mark: AnyView(CardMark(brand: card.brand)), title: ApprovalContent.cardTitle(card), detail: card.name,
                    on: tray.card == card.id, id: "approval.card.\(index)") { tray.pickCard(card.id) }
                Divider().padding(.leading, 62)
            }
            row(mark: AnyView(plus), title: "Add Card\u{2026}", detail: "", on: false, add: true, id: "approval.addCard") {
                tray.cardForm = .init()
                tray.go(.newCard)
            }
        }
        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: ApprovalMetrics.group, style: .continuous))
    }
}

struct ApprovalPlaceList: View {
    let tray: ApprovalTray
    let content: ApprovalContent

    var body: some View {
        let places = content.pay?.places ?? []
        VStack(spacing: 0) {
            if let typed = tray.newPlace {
                row(mark: AnyView(PlaceMark(who: typed.name)), title: "\(typed.street.split(separator: "\n").first.map(String.init) ?? ""), \(typed.city)",
                    detail: typed.name, on: tray.place == ApprovalTray.newID, id: "approval.place.new") { tray.pickPlace(ApprovalTray.newID) }
                Divider().padding(.leading, 62)
            }
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                row(mark: AnyView(PlaceMark(who: place.who)), title: place.line, detail: place.who,
                    on: tray.place == place.id, id: "approval.place.\(index)") { tray.pickPlace(place.id) }
                Divider().padding(.leading, 62)
            }
            row(mark: AnyView(plus), title: "Add Address\u{2026}", detail: "", on: false, add: true, id: "approval.addPlace") {
                tray.placeForm = .init()
                tray.go(.newPlace)
            }
        }
        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: ApprovalMetrics.group, style: .continuous))
    }
}

private var plus: some View {
    Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
        .frame(width: 32, height: 32)
}

@MainActor
private func row(mark: AnyView, title: String, detail: String, on: Bool, add: Bool = false, id: String,
                 _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 12) {
            mark.frame(width: ApprovalMetrics.avatar, height: ApprovalMetrics.avatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(add ? Color.accentColor : Ink.primary).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor).opacity(on ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: ApprovalMetrics.payRow)
        .contentShape(Rectangle())
    }
    .buttonStyle(ApprovalPress())
    .accessibilityAddTraits(on ? .isSelected : [])
    .accessibilityIdentifier(id)
}

// MARK: - the forms

/// Add Card, as on the Mac: kept in Yab, so every Mac in Sync has it. iOS's
/// AutoFill offers the cards it knows and Scan Card over the keyboard.
struct ApprovalCardForm: View {
    @Bindable var tray: ApprovalTray
    @FocusState private var focus: Field?
    private enum Field { case number, expires, csc, name }

    var body: some View {
        VStack(spacing: 0) {
            field("Number", "Card number", $tray.cardForm.number, .number, type: .creditCardNumber, keys: .numberPad)
            Divider().padding(.leading, 14)
            HStack(spacing: 0) {
                field("Expires", "MM / YY", $tray.cardForm.expires, .expires, type: .creditCardExpiration, keys: .numberPad)
                Divider().frame(height: 48)
                field(nil, "CVC", $tray.cardForm.csc, .csc, type: .creditCardSecurityCode, keys: .numberPad)
            }
            Divider().padding(.leading, 14)
            field("Name", "Name on card", $tray.cardForm.name, .name, type: .creditCardName, keys: .default)
        }
        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: ApprovalMetrics.group, style: .continuous))
        // The keyboard comes once the form has finished coming in.
        .onChange(of: tray.settledStep, initial: true) { _, step in if step == .newCard, focus == nil { focus = .number } }
    }

    private func field(_ label: String?, _ hint: String, _ text: Binding<String>, _ which: Field,
                       type: UITextContentType, keys: UIKeyboardType) -> some View {
        HStack(spacing: 8) {
            if let label { Text(label).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.primary).frame(width: 66, alignment: .leading) }
            TextField(hint, text: text)
                .font(.system(size: 16))
                .textContentType(type)
                .keyboardType(keys)
                .autocorrectionDisabled()
                .focused($focus, equals: which)
                .accessibilityIdentifier("approval.form.\(hint)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

struct ApprovalPlaceForm: View {
    @Bindable var tray: ApprovalTray
    @FocusState private var focus: Field?
    private enum Field { case name, street, apt, city, postal }

    var body: some View {
        VStack(spacing: 0) {
            field("Name", "Full name", $tray.placeForm.name, .name, type: .name)
            Divider().padding(.leading, 14)
            field("Street", "Street and number", $tray.placeForm.street, .street, type: .streetAddressLine1)
            Divider().padding(.leading, 14)
            field("Apt", "Optional", $tray.placeForm.apt, .apt, type: .streetAddressLine2)
            Divider().padding(.leading, 14)
            HStack(spacing: 0) {
                field("City", "City", $tray.placeForm.city, .city, type: .addressCity)
                Divider().frame(height: 48)
                field(nil, "ZIP", $tray.placeForm.postal, .postal, type: .postalCode)
            }
        }
        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: ApprovalMetrics.group, style: .continuous))
        .onChange(of: tray.settledStep, initial: true) { _, step in if step == .newPlace, focus == nil { focus = .name } }
    }

    private func field(_ label: String?, _ hint: String, _ text: Binding<String>, _ which: Field, type: UITextContentType) -> some View {
        HStack(spacing: 8) {
            if let label { Text(label).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.primary).frame(width: 66, alignment: .leading) }
            TextField(hint, text: text)
                .font(.system(size: 16))
                .textContentType(type)
                .focused($focus, equals: which)
                .accessibilityIdentifier("approval.form.\(hint)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}
