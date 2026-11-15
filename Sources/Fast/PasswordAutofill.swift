import Foundation

// The last account actually used here, unless the page already names one.
// Imported passwords with no usage date remain choices in the account list.
enum PasswordAutofill {
    static func login(in logins: [Login], secret: Bool, empty: Bool,
                      account: String?, named: String?) -> Login? {
        guard empty else { return nil }
        let identity = secret ? nonempty(account) ?? nonempty(named) : nil
        let matching = logins.filter {
            !$0.password.isEmpty && $0.used != nil &&
                (identity == nil || normal($0.user) == identity)
        }
        return matching.max { ($0.used ?? .distantPast) < ($1.used ?? .distantPast) }
    }

    static func normal(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = normal(value)
        return name.isEmpty ? nil : name
    }
}

// Focus, scrolling and typing all report the same field. A declined Touch ID
// request or an emptied password must not turn those reports into more fills.
struct PasswordAutofillAttempts {
    private var document: String?
    private var fields = Set<String>()

    mutating func begin(document: String?, field: String?) -> Bool {
        guard let document, !document.isEmpty, let field, !field.isEmpty else { return false }
        if self.document != document {
            self.document = document
            fields.removeAll()
        }
        return fields.insert(field).inserted
    }

    mutating func reset() {
        document = nil
        fields.removeAll()
    }
}
