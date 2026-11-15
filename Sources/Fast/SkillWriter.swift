import Foundation
import CryptoKit

/// Agent-created instructions stay in the user's skills folder. A revision
/// prevents a stale turn from replacing a skill edited by the person meanwhile.
/// Nothing is written before the user's yes on a card (skill_save), which is
/// bound to these exact words (key), and an agent's skill can't mark a POST
/// as a read: that would let fetch send cookie-bearing POSTs with no tab
/// (Skills.reads), as plugins can't either (BoostContributions.skills).
enum SkillWriter {
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func revision(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(name: String, document: String) throws {
        guard name.range(of: #"\A[a-z0-9]+(?:-[a-z0-9]+)*\z"#, options: .regularExpression) != nil,
              name.utf8.count <= 64 else { throw Invalid("Use a skill name of at most 64 lowercase letters, digits and hyphens.") }
        guard document.utf8.count <= 65_536 else { throw Invalid("A skill must fit in 64 KB.") }
        guard let skill = Skills.parse(document, own: true, path: URL(fileURLWithPath: "/SKILL.md")),
              skill.name == name, !skill.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !skill.body.isEmpty else { throw Invalid("Include matching name, description and a nonempty body in SKILL.md.") }
        guard !skill.reads.contains(where: { $0.method != "GET" }) else {
            throw Invalid("An agent's skill can't add read: POST lines; only the user can, in Settings › Agents › Skills.")
        }
    }

    /// What the user's yes is kept under: this name with these words.
    static func key(name: String, document: String) -> String { "skill:" + name + ":" + revision(document) }

    /// What the card says besides the name: whether it replaces a skill
    /// that comes with Yab, or one of the user's own.
    static func replaces(_ name: String, in root: URL, builtIn: URL?) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(name + "/SKILL.md").path) { return "Changes your skill \(name)" }
        if let builtIn, fm.fileExists(atPath: builtIn.appendingPathComponent(name + "/SKILL.md").path) {
            return "Replaces the built-in skill \(name) for every task"
        }
        return "A new skill for every task"
    }

    /// Everything save checks, without writing: before the card goes up.
    @discardableResult
    static func check(name: String, document: String, replacing: String?, in root: URL) throws -> URL {
        try validate(name: name, document: document)
        let fm = FileManager.default
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let file = folder.appendingPathComponent("SKILL.md")
        // Check links even when their destination is missing (fileExists follows them).
        for path in [folder, file] {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw Invalid("A skill folder or SKILL.md cannot be a symbolic link.")
            }
        }
        if fm.fileExists(atPath: file.path) {
            let old = try String(contentsOf: file, encoding: .utf8)
            guard replacing == revision(old) else {
                throw Invalid("This skill already exists or changed. Read skill(name), preserve its fields, then pass its revision as replacing.")
            }
        } else if replacing != nil {
            throw Invalid("The user skill no longer exists. Read the catalog before creating it again.")
        }
        return file
    }

    @discardableResult
    static func save(name: String, document: String, replacing: String?, in root: URL) throws -> URL {
        let file = try check(name: name, document: document, replacing: replacing, in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
