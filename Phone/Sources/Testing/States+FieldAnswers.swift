import Foundation

extension StateCatalog {
    static let fieldAnswers: [NamedState] = [
        answerState("field.answer.sum", "Calculator", "2400*12"),
        answerState("field.answer.units", "Unit conversion", "5 km to mi"),
        answerState("field.answer.base", "Number base", "255 in hex"),
        answerState("field.answer.time", "Time keeps search", "time in tokyo"),
        answerState("field.answer.long", "Long sum on a small phone", "(1234567+9876543)*12"),
        NamedState("field.answer.waiting", "Waiting for rates", "A pending currency answer cannot be copied by tap or Return.") { app in
            Rates.shared.set([:])
            app.surfaces.openField(.address)
            app.field.typed("100 dollars to euros")
        },
        NamedState("field.answer.private", "Private calculator", "An on-device answer with the eyes shut, no history or agent rows.") { app in
            app.surfaces.openField(.newTab)
            app.field.setPrivate(true)
            app.field.typed("20% of 80")
        },
        NamedState("field.answer.chats", "Chats keep their search", "Arithmetic words search Chats, with no calculator plate or math keys.") { app in
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            app.field.openSpaces()
            app.field.typed("2+2")
        },
        NamedState("field.answer.rates", "Currency conversion", "Rates are local fixture values; 100 dollars is 90 euros.") { app in
            Rates.shared.set(["EUR": 0.9, "GBP": 0.8])
            app.surfaces.openField(.address)
            app.field.typed("100 dollars to euros")
        },
    ]

    private static func answerState(_ name: String, _ title: String, _ words: String) -> NamedState {
        NamedState(name, title, "The selected C: a separate answer plate above the search rows, numeric operators above the keyboard.") { app in
            app.surfaces.openField(.address)
            app.field.typed(words)
        }
    }
}
