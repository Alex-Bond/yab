import Foundation
import CryptoKit

// Which kept passwords have turned up in a breach, asked of Have I Been
// Pwned without telling it the password. Each password is hashed here; only
// the first five characters of the hash go out, and the service answers with
// every leaked hash that starts that way, hundreds of them, padded to look
// alike, for the match to be made on this Mac (k-anonymity).
//
// Off until you say so on the passwords page: it is the one thing about the
// passwords that ever touches the network.

enum Leaks {
    private static let key = "passwords.leaks"

    static var enabled: Bool {
        get { Store.settings.bool(forKey: key) }
        set { Store.settings.set(newValue, forKey: key) }
    }

    /// Each leaked login's id and how many times its password was seen. Slow:
    /// every password read, one request per distinct hash prefix. Never on
    /// the main thread; `done` is called on it, with how many requests
    /// failed, a check with gaps in it says so rather than looking clean.
    static func check(_ done: @escaping (_ found: [String: Int], _ failed: Int) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            // Prefix → suffix → the logins with that password.
            var wanted: [String: [String: [String]]] = [:]
            for entry in Vault.entries() {
                guard let secret = Vault.password(host: entry.host, user: entry.user), !secret.isEmpty else { continue }
                let hash = Insecure.SHA1.hash(data: Data(secret.utf8)).map { String(format: "%02X", $0) }.joined()
                let prefix = String(hash.prefix(5)), suffix = String(hash.dropFirst(5))
                wanted[prefix, default: [:]][suffix, default: []].append(entry.id)
            }

            var found: [String: Int] = [:]
            var failed = 0
            let lock = NSLock()
            let group = DispatchGroup()
            // A handful at a time: polite to the service, quick enough here.
            let gate = DispatchSemaphore(value: 6)
            for (prefix, suffixes) in wanted {
                guard let url = URL(string: "https://api.pwnedpasswords.com/range/" + prefix) else { continue }
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("true", forHTTPHeaderField: "Add-Padding")
                request.setValue("yab", forHTTPHeaderField: "User-Agent")
                gate.wait()
                group.enter()
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    defer { gate.signal(); group.leave() }
                    guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                          let text = String(data: data, encoding: .utf8)
                    else {
                        lock.lock()
                        failed += 1
                        lock.unlock()
                        return
                    }
                    for line in text.split(whereSeparator: \.isNewline) {
                        let parts = line.split(separator: ":")
                        guard parts.count == 2, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)), count > 0,
                              let ids = suffixes[String(parts[0])]
                        else { continue }
                        lock.lock()
                        ids.forEach { found[$0] = count }
                        lock.unlock()
                    }
                }.resume()
            }
            group.wait()
            done(found, failed)
        }
    }
}
