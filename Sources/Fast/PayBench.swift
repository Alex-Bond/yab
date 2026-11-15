import Foundation

// `agent-pay`, a --test run only: the pay sheet driven as the person would,
// with Touch ID stood in for (nobody's finger is on a farm Mac's sensor).
//
//   action=stub     answer=yes|miss|locked|quiet|off delay=0.4 proof=touch|password
//   action=seed     cards=[{number,name,month,year,used}] addresses=[{name,street,city,postal,source,used}], in memory
//   action=state    what the sheet says
//   action=press    a click on the foot's button: Pay arms the check, Use Password asks it
//   action=touch    a finger on the sensor (the stub's answer), heard only once armed
//   action=key      key=up|down|enter|escape|confirm
//   action=open     pane=cards|places;  action=pick index=N;  action=back
//   action=form     any of name street apt city zip number expires code holder;  action=save
//   action=outcome  paid=true|false order=…  (what the site said, without a site)
//   action=hold     paid=true: the sheet stays on Paid for a picture

extension Bench {
    static let payVerbs: [String: AgentHandler] = [
        "agent-pay": { $0.handleAgentPay($1) },
    ]

    func handleAgentPay(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        guard Store.testing else { answer(["error": "agent-pay only works on a --test run"]); return }
        let action = request["action"] as? String ?? "state"
        switch action {
        case "stub":
            let said = request["answer"] as? String ?? "yes"
            if said == "off" { PayTouch.stub = nil; answer(["ok": true]); return }
            let answers: [String: PaySheetModel.Answer] = ["yes": .yes, "miss": .miss, "locked": .locked, "quiet": .quiet]
            PayTouch.stub = .init(answer: answers[said] ?? .yes, delay: request["delay"] as? Double ?? 0.4,
                                  proof: request["proof"] as? String == "password" ? .password : .touchID)
            answer(["ok": true])
            return
        case "seed":
            // Kept in memory for this run, never in the Mac's keychain.
            var cards: [SavedCard] = [], places: [StreetAddress] = []
            for card in request["cards"] as? [[String: Any]] ?? [] {
                let digits = (card["number"] as? String ?? "").filter(\.isNumber)
                cards.append(SavedCard(id: UUID().uuidString, number: digits, last4: String(digits.suffix(4)), brand: Wallet.brand(of: digits),
                                       name: card["name"] as? String ?? "", month: card["month"] as? Int ?? 8, year: card["year"] as? Int ?? 2029,
                                       used: (card["used"] as? Double).map(Date.init(timeIntervalSince1970:))))
            }
            for place in request["addresses"] as? [[String: Any]] ?? [] {
                var address = StreetAddress(id: UUID().uuidString)
                address.name = place["name"] as? String ?? ""
                address.street = place["street"] as? String ?? ""
                address.city = place["city"] as? String ?? ""
                address.postal = place["postal"] as? String ?? ""
                address.country = "United States"
                address.source = place["source"] as? String
                if let used = place["used"] as? Double { address.used = Date(timeIntervalSince1970: used) }
                places.append(address.tidied())
            }
            PayWallet.standIn = (cards, places)
            answer(["cards": cards.count, "addresses": places.count])
            return
        case "hold":
            PayFlow.holdPaid = request["paid"] as? Bool ?? true
            answer(["ok": true])
            return
        default:
            break
        }
        guard let tab = find(request, in: c.browser) ?? c.browser.tabs.first(where: { Payments.shared.flow($0) != nil }) else {
            answer(missing(request))
            return
        }
        guard let flow = Payments.shared.flow(tab) else { answer(["error": "no pay sheet on that tab"]); return }
        switch action {
        case "press":
            flow.press()
        case "touch":
            flow.finger()
        case "key":
            let keys: [String: PaySheetModel.Key] = ["up": .up, "down": .down, "enter": .enter, "escape": .escape, "confirm": .confirm]
            guard let key = keys[request["key"] as? String ?? ""] else { answer(["error": "key is up, down, enter, escape or confirm"]); return }
            answer(["effect": "\(flow.key(key))", "state": Self.paySaid(flow)])
            return
        case "open":
            flow.open(request["pane"] as? String == "places" ? .places : .cards)
        case "pick":
            flow.pick(request["index"] as? Int ?? 0)
        case "back":
            flow.back()
        case "form":
            for (key, path) in [("name", \PayFlow.Form.name), ("street", \.street), ("apt", \.apt), ("city", \.city), ("zip", \.zip),
                                ("number", \.number), ("expires", \.expires), ("code", \.code), ("holder", \.holder)] {
                if let value = request[key] as? String { flow.form[keyPath: path] = value }
            }
        case "save":
            flow.save()
        case "outcome":
            flow.ended(paid: request["paid"] as? Bool ?? true, order: request["order"] as? String ?? "")
        case "state":
            break
        default:
            answer(["error": "action is stub, seed, state, press, touch, key, open, pick, back, form, save, outcome or hold"])
            return
        }
        answer(Self.paySaid(flow))
    }

    static func paySaid(_ flow: PayFlow) -> [String: Any] {
        let model = flow.model
        return ["tab": flow.tab.map(Bench.short) ?? "", "pane": "\(model.pane)", "phase": "\(model.phase)", "proof": "\(model.proof)", "focus": model.focus,
                "total": model.totalWord, "amount": model.amount, "card": model.chosenCard?.title ?? "",
                "place": model.chosenPlace?.line ?? "", "delivery": model.delivery, "button": model.words(model.face), "line": model.line ?? "", "lineBad": model.lineBad,
                "cards": model.cards.map(\.title), "places": model.places.map(\.line), "item": model.item,
                "takesCard": model.takesCard, "takesPlace": model.takesPlace, "canSave": flow.canSave,
                "listening": model.listening, "misses": model.misses, "shakes": model.shakes]
    }
}
