import Foundation

// Which copy of an agent runs, and which models it can take.
//
// A Mac often has several copies of each CLI: Homebrew's, npm's under nvm,
// the native installer's, and the ones the ChatGPT and Codex apps keep for
// themselves. They update on their own schedules, and they share one
// config: the Codex app sets `model = "gpt-6.1-sol"` in ~/.codex/config.toml,
// and a Homebrew Codex two versions behind sends it on, to be turned away
// as "not supported when using Codex with a ChatGPT account". The plan
// decides which models it serves to which client version, so what a model
// list says is only true of the copy that fetched it.
//
// So: the newest copy runs (AgentCopies, told from its files, never by
// running it), the model list is asked of that copy when a task starts,
// signed in as the task is (CodexCatalog, `codex debug models`), a model
// or effort it doesn't have is swapped for one it does before the start
// (ModelFit), and a model the plan still turns away is tried once more on
// the next one (Agents.retryModel).

/// The copies of `claude` and `codex` on this Mac, newest first.
enum AgentCopies {
    /// Where each is put, besides the login shell's PATH: installers' own
    /// folders, and the apps that keep a CLI inside.
    static func places(_ name: String, home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) -> [String] {
        var places = folders(home: home).map { $0 + "/" + name }
        if name == "claude" {
            places.append("\(home)/.claude/local/claude")
            places += versions(in: "\(home)/.local/share/claude/versions") { $0 }
        } else if name == "codex" {
            places.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
            places.append("/Applications/Codex.app/Contents/Resources/codex")
            for kind in ["standalone", "app-server-daemon"] {
                places += versions(in: "\(home)/.codex/packages/\(kind)/releases") { $0 + "/bin/codex" }
            }
        }
        return places
    }

    /// Fallback when a login shell fails, times out, or initializes nvm only
    /// in a terminal. Reading install locations never runs a provider.
    static func folders(home: String) -> [String] {
        var folders = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "\(home)/.npm-global/bin", "\(home)/.npm/bin", "\(home)/.bun/bin",
                       "\(home)/.volta/bin", "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims", "\(home)/.antigravity/bin"]
        folders += versions(in: "\(home)/.nvm/versions/node") { $0 + "/bin" }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        // npm's user prefix can be any absolute folder, including spaces.
        // Expand HOME only, never evaluate shell syntax in a config file.
        if let npm = try? String(contentsOfFile: home + "/.npmrc", encoding: .utf8) {
            for line in npm.components(separatedBy: .newlines) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "prefix" else { continue }
                var prefix = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                prefix = prefix.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
                if prefix.hasPrefix("~/") { prefix = home + prefix.dropFirst() }
                if prefix.hasPrefix("/"), !prefix.contains(":"), !prefix.contains("$") { folders.append(prefix + "/bin") }
            }
        }
        return folders
    }

    /// Keep the shell's order, then add install folders the GUI may miss.
    static func searchPath(_ path: String, home: String) -> String {
        var seen: Set<String> = []
        return (path.components(separatedBy: ":") + folders(home: home) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// A newer selected npm CLI may use a different node than the shell's
    /// first one. Keep its bin folder first, including behind a symlink.
    static func environment(for binary: String, base: [String: String]) -> [String: String] {
        var env = base
        let file = URL(fileURLWithPath: binary)
        var folders = [file.deletingLastPathComponent().path]
        var real = file.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<7 {
            let bin = real.appendingPathComponent("bin")
            if FileManager.default.isExecutableFile(atPath: real.appendingPathComponent("node").path) {
                folders.append(real.path); break
            }
            if FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("node").path) {
                folders.append(bin.path); break
            }
            if real.path == "/" { break }
            real = real.deletingLastPathComponent()
        }
        var seen: Set<String> = []
        env["PATH"] = (folders + (base["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":"))
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// No environment values beyond PATH: credentials never enter a chat.
    static func launchFailure(_ name: String, binary: String, env: [String: String], reason: String, diagnostic: String = "") -> String {
        let detail = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name) \(reason)\nTried: \(binary)\nPATH: \(env["PATH"] ?? "")"
            + (detail.isEmpty ? "" : "\n" + String(detail.suffix(2000)))
    }

    /// Each entry of a folder of versions, made a path.
    private static func versions(in folder: String, _ path: (String) -> String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { path(folder + "/" + $0) }
    }

    /// Every executable called `name` in these PATH folders, in order.
    static func onPath(_ name: String, _ path: String) -> [String] {
        path.split(separator: ":").map { String($0) + "/" + name }
    }

    /// "codex-cli 0.160.0", "2.1.287 (Claude Code)": the numbers.
    static func version(_ said: String) -> [Int]? {
        guard let range = said.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return said[range].split(separator: ".").compactMap { Int($0) }
    }

    static func newer(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return a.count > b.count
    }

    /// The newest of these, told from the files beside each (AgentCopies.
    /// installed), never by running one: macOS checks a binary the moment
    /// it runs, and an old copy it has since flagged would look like Yab's
    /// doing. On a tie, or when none says, the first, so the one the
    /// person's own terminal finds wins.
    static func newest(_ candidates: [String]) -> (path: String, version: [Int]?)? {
        var seen: Set<String> = []
        let there = candidates.filter { path in
            guard FileManager.default.isExecutableFile(atPath: path) else { return false }
            return seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted
        }
        guard let first = there.first else { return nil }
        var best: (path: String, version: [Int])?
        for path in there {
            guard let version = installed(path) else { continue }
            if best == nil || newer(version, than: best!.version) { best = (path, version) }
        }
        guard let best else { return (first, nil) }
        return (best.path, best.version)
    }

    /// A copy's version as its install wrote it down: the npm package it
    /// is part of (package.json, or the ChatGPT app's codex-package.json),
    /// else a folder named for it (Homebrew's Cellar, Claude Code's
    /// versions, Codex's releases). An app's own Info.plist is left alone:
    /// the ChatGPT app's version is the app's, not its Codex's.
    static func installed(_ path: String) -> [Int]? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var folder = real.deletingLastPathComponent()
        for _ in 0..<6 {
            for name in ["package.json", "codex-package.json"] {
                let file = folder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let said = object["version"] as? String else { continue }
                let package = object["name"] as? String ?? ""
                guard name == "codex-package.json" || package.hasPrefix("@openai/codex") || package.hasPrefix("@anthropic-ai/claude-code")
                else { continue }
                if let version = version(said) { return version }
            }
            if folder.path == "/" { break }
            folder = folder.deletingLastPathComponent()
        }
        // "0.157.0-aarch64-apple-darwin", "2.1.287", "v0.160.0"; not nvm's
        // node folder ("versions/node/v22.15.0"), which is node's.
        let parts = real.pathComponents
        for (index, part) in parts.enumerated().reversed() where index > 0 && parts[index - 1] != "node" {
            guard part.range(of: #"^v?\d+(\.\d+)+([-+_].*)?$"#, options: .regularExpression) != nil else { continue }
            return version(part)
        }
        return nil
    }
}

/// What a copy of Codex can be started on, asked of it: `codex debug
/// models` fetches the list the plan serves this client version, signed in
/// as the account in its CODEX_HOME. A copy too old to say falls back to the
/// list it shipped with, then to ~/.codex/models_cache.json when that was
/// fetched by this same version.
@MainActor
enum CodexCatalog {
    struct Model: Equatable {
        let slug: String
        let listed: Bool
        let efforts: [String]
        let defaultEffort: String?
    }

    struct Catalog: Equatable {
        /// Listed first, in Codex's own order.
        var models: [Model]
        /// The models shown in a picker, as AgentModels has them.
        var shown: [AgentModel] = []

        func model(_ slug: String) -> Model? { models.first { $0.slug == slug } }
        /// What Codex starts on when told nothing, near enough: its first.
        var first: Model? { models.first { $0.listed } ?? models.first }
    }

    private static var known: [String: (at: Date, catalog: Catalog)] = [:]
    private static var asking: [String: Task<Catalog?, Never>] = [:]

    private static func key(_ binary: String, _ env: [String: String]) -> String {
        binary + "|" + (env["CODEX_HOME"] ?? "")
    }

    /// The last one heard, however old.
    static func cached(_ binary: String, env: [String: String]) -> Catalog? {
        known[key(binary, env)]?.catalog
    }

    /// Asked again on the next use, after a model was turned away.
    static func forget(_ binary: String, env: [String: String]) {
        known[key(binary, env)] = nil
    }

    /// Every copy's list for this account's CODEX_HOME (nil: the usual
    /// one), asked again after its plan changed.
    static func forget(home: String?) {
        // The usual account runs in the CODEX_HOME of your shell, if any.
        let homes = home.map { [$0] } ?? ["", Shell.cached?.env["CODEX_HOME"]].compactMap { $0 }
        known = known.filter { entry in !homes.contains { entry.key.hasSuffix("|" + $0) } }
    }

    static func catalog(_ binary: String, env: [String: String], permit: ProviderLaunchPermit) async -> Catalog? {
        guard permit.valid else { return nil }
        let key = key(binary, env)
        if let known = known[key], known.at.timeIntervalSinceNow > -600 { return known.catalog }
        if let asking = asking[key] { return await asking.value }
        let task = Task<Catalog?, Never> {
            for args in [["debug", "models"], ["debug", "models", "--bundled"]] {
                let (code, output) = await Shell.run(binary, args, env: env, limit: 20, permit: permit)
                guard permit.valid else { return nil }
                if code == 0, let catalog = parse(output) { return catalog }
            }
            let (_, said) = await Shell.run(binary, ["--version"], env: env, limit: 8, permit: permit)
            guard permit.valid else { return nil }
            return cache(home: env["CODEX_HOME"], version: AgentCopies.version(said))
        }
        asking[key] = task
        let catalog = await task.value
        asking[key] = nil
        guard permit.valid else { return nil }
        if let catalog { known[key] = (Date(), catalog) }
        return catalog
    }

    /// The list Codex keeps, only when this version fetched it.
    static func cache(home: String?, version: [Int]?) -> Catalog? {
        let home = home ?? (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.codex"
        guard let version, let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/models_cache.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fetchedBy = (object["client_version"] as? String).flatMap(AgentCopies.version), fetchedBy == version
        else { return nil }
        return parse(data)
    }

    static func parse(_ output: String) -> Catalog? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        return parse(Data(output[start...].utf8))
    }

    static func parse(_ data: Data) -> Catalog? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["models"] as? [[String: Any]] else { return nil }
        let ordered = rows.sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
        let models = ordered.compactMap { row -> Model? in
            guard let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
            let efforts = (row["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            return Model(slug: slug, listed: (row["visibility"] as? String ?? "list") == "list",
                         efforts: efforts, defaultEffort: row["default_reasoning_level"] as? String)
        }
        guard !models.isEmpty else { return nil }
        return Catalog(models: models.filter(\.listed) + models.filter { !$0.listed }, shown: AgentModels.codexModels(ordered))
    }
}

/// A model and effort a copy of an agent can take, closest to what was
/// asked for.
enum ModelFit {
    /// Least first, as both CLIs order them.
    static let ladder = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// The asked-for model, when the catalog has it and it wasn't turned
    /// away; else Codex's first. The effort, when that model takes it;
    /// else the most it takes short of it, else its own default.
    static func codex(model: String?, effort: String?, in catalog: CodexCatalog.Catalog,
                      avoiding refused: Set<String> = [], provider: String? = nil) -> (model: String?, effort: String?) {
        // A custom provider's model is the person's explicit choice, not
        // one a cached OpenAI catalog may replace on a retry.
        if let provider, provider != "openai" { return (model, effort) }
        var model = model
        if let asked = model, catalog.model(asked) == nil || refused.contains(asked) {
            model = catalog.models.first { $0.listed && !refused.contains($0.slug) }?.slug
        }
        guard let effort, let fits = (model.flatMap(catalog.model) ?? catalog.first), !fits.efforts.isEmpty,
              !fits.efforts.contains(effort) else { return (model, effort) }
        let rank = ladder.firstIndex(of: effort) ?? ladder.count
        let below = fits.efforts.filter { (ladder.firstIndex(of: $0) ?? 0) <= rank }
        let closest = below.max { (ladder.firstIndex(of: $0) ?? 0) < (ladder.firstIndex(of: $1) ?? 0) }
        return (model, closest ?? fits.defaultEffort ?? fits.efforts.first)
    }
}
