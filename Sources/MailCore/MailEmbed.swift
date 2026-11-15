import Foundation
import NaturalLanguage

// Mail turned into vectors on this Mac, for the mail memory to search by
// what it says rather than by its words alone (docs/mail.md, Memory for
// agents). Apple's own models, nothing leaves the Mac.
//
// Three ways, chosen by the text's language. Where Apple has word vectors
// for it (English, German, French, Spanish, Italian, Portuguese), a text's
// vector is the average of its words' (the ones that mean something). Other
// Latin languages go to the contextual model of their script
// (NLContextualEmbedding): its vectors of the tokens of the words that mean
// something averaged, never punctuation's or numbers' signs, then the
// direction every text shares taken away (the average of a few dozen
// ordinary sentences), since that model was never taught to say how close
// two texts are and, averaged as it comes, puts any two mails at a cosine
// of 0.85. Measured on paraphrased questions against 40 short mails (the
// right one's rank, MRR): the contextual model averaged as it comes 0.41,
// with the words and the shared direction left out 0.68, word vectors 0.88;
// against 2,009 mails of five years, a question sharing no word with its
// mail ("when does the website name expire" for "your domain renews") found
// it first by word vectors, 598th by the contextual model. Leaving the
// signs out too took it on 24 English questions from 0.55 to 0.66.
//
// Cyrillic has no word vectors from Apple, and its contextual model found
// Cyrillic mail badly (MRR 0.26 by vectors alone, the right mail first for
// 3 of 24 questions). So Cyrillic mail goes by its words (MailLemmas), and
// a question also by the memory's own words nearest its own, each word's
// vector read alone through the contextual model ("dentist" near "tooth",
// "physician", "doctor").
//
// The contextual model's files come with macOS, or are fetched by macOS
// from Apple when first asked for (requestAssets: a download, never a
// question to the person). Until they are here, those pieces go by words
// alone and get their vectors later. Word vectors are always here.

/// What turns a text into a vector: Apple's models here, a stand-in in tests.
public protocol MailEmbedder: AnyObject, Sendable {
    /// The model a text is read with: its kind ("en", word vectors; "Latn",
    /// the contextual model of a script; "Cyrl", none, as Cyrillic goes by
    /// its words) and its name with the revision ("en.1"), the name nil
    /// while this Mac has none. `among`: the kinds a question may go to,
    /// the ones a memory has vectors of.
    func model(for text: String, among kinds: Set<String>?) -> (kind: String, name: String?)
    /// A kind's model as it is now, nil while this Mac has none.
    func model(kind: String) -> String?
    /// The text's vector from that model, unit length; nil if it can't be had now.
    func vector(_ text: String, model: String) -> [Float]?
    /// The model a word is read alone with, for the words Cyrillic mail goes
    /// by (MailLemmas): nil while this Mac has none.
    func wordModel() -> String?
    /// A word's own vector, read alone, unit length, and its model's name.
    func word(_ word: String) -> (model: String, vector: [Float])?
    /// Done for now: whatever a model holds in memory may go.
    func rest()
}

extension MailEmbedder {
    public func wordModel() -> String? { nil }
    public func word(_ word: String) -> (model: String, vector: [Float])? { nil }
}

/// The writing a text is mostly in, as Apple's models are split.
public enum MailScript {
    /// "Latn", "Cyrl", or another script's code; Latin when it has no letters.
    public static func of(_ text: String) -> String {
        var latin = 0, cyrillic = 0, other = 0
        for scalar in text.unicodeScalars.prefix(4000) where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            case 0x400...0x52F: cyrillic += 1
            default: other += 1
            }
        }
        if cyrillic > latin, cyrillic >= other { return "Cyrl" }
        if other > latin, other > cyrillic { return "Othr" }
        return "Latn"
    }
}

/// Words that say little of what a mail is about: left out of a vector's
/// average and of a question's words.
public enum MailFiller {
    public static let words: Set<String> = Set("""
    a an the to of in on at for from by with and or but is are was were be been being am do does did done i me my mine \
    we our ours you your yours he him his she her it its they them their this that these those what when where which who \
    whom whose why how can could would should will shall may might must have has had having not no yes if so as up down \
    out about into over after before than then there here just also very too all any some more most such only own same \
    other each few both s t re ve ll d m don didn doesn isn aren wasn weren hasn haven hadn won wouldn shouldn couldn \
    let get got please hi hello dear thanks thank regards via per etc ok okay
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}

/// Cyrillic mail as the memory reads it: by its words, as they are
/// written. The empty words are left out (MailFiller); the rest all count.
public enum MailLemmas {
    /// Whether a text goes by its words: it is mostly Cyrillic.
    public static func reads(_ text: String) -> Bool { MailScript.of(text) == "Cyrl" }

    /// A text's words in order, as the memory's index keeps them.
    public static func read(_ text: String) -> [String] {
        let text = String(text.prefix(MailMemory.most))
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            guard !MailFiller.words.contains(word), word.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
            out.append(word)
            return true
        }
        return out
    }

    /// The words of a question, each once.
    public static func question(_ text: String) -> [String] {
        var out: [String] = []
        for word in read(text) where (word.count >= 2 || word.allSatisfy(\.isNumber)) && !out.contains(word) {
            out.append(word)
            if out.count == 12 { break }
        }
        return out
    }

    /// Words worth a vector of their own, to be found near a question's:
    /// letters only, three or more.
    public static func known(_ word: String) -> Bool { word.count >= 3 && word.allSatisfy(\.isLetter) }
}

/// Vectors kept as bytes: each number a signed byte, the vector's largest
/// one at ±127, its scale beside it. A 512-number vector is 512 bytes, and
/// its cosine with another is off by less than 0.01.
public enum MailVector {
    /// The kind of a model's name: "en" of "en.1".
    public static func kind(of model: String) -> String { String(model.prefix { $0 != "." }) }

    static func quantize(_ vector: [Float]) -> (scale: Float, bytes: [Int8]) {
        let top = vector.reduce(Float(0)) { max($0, abs($1)) }
        guard top > 0 else { return (1, Array(repeating: 0, count: vector.count)) }
        let scale = top / 127
        return (scale, vector.map { Int8(max(-127, min(127, ($0 / scale).rounded()))) })
    }

    static func floats(_ bytes: [Int8], scale: Float) -> [Float] { bytes.map { Float($0) * scale } }

    public static func unit(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            aa += a[i] * a[i]
            bb += b[i] * b[i]
        }
        return aa > 0 && bb > 0 ? dot / (aa.squareRoot() * bb.squareRoot()) : 0
    }
}

/// Apple's models: word vectors by language, the contextual model by
/// script, loaded when first used and let go when the work is done. One
/// text at a time goes through them.
public final class AppleEmbedder: MailEmbedder, @unchecked Sendable {
    public static let shared = AppleEmbedder()
    public static let languages: [String: NLLanguage] = ["en": .english, "de": .german, "fr": .french, "es": .spanish,
                                                  "it": .italian, "pt": .portuguese]
    /// The scripts whose texts get a contextual model's vector: Cyrillic
    /// goes by its words (MailLemmas), each word's own vector alone.
    public static let scripts: [String: NLScript] = ["Latn": .latin]
    /// How a contextual model's tokens are made one vector, in its name
    /// after the model's revision: 2, the tokens of the words that mean
    /// something (1 had punctuation's too). Another way of pooling makes
    /// the vectors again (MailMemoryBuild.renew).
    static let pooling = 2

    private struct Loaded {
        public let embedding: NLContextualEmbedding
        /// The direction every text shares, taken away from each vector.
        let mean: [Float]
    }

    private let lock = NSLock()
    private var loaded: [String: Loaded] = [:]
    private var words: [String: NLEmbedding] = [:]
    /// Cyrillic's contextual model, for words read alone.
    private var cyrillic: NLContextualEmbedding?
    /// What a kind's model is, as last looked: its name, or nil without files.
    private var looked: [String: (name: String?, at: Date)] = [:]
    /// Scripts whose files were asked of macOS this run.
    private var fetching: Set<String> = []

    public func model(for text: String, among kinds: Set<String>?) -> (kind: String, name: String?) {
        let kind = Self.kind(for: text, among: kinds)
        return (kind, kinds.map { $0.contains(kind) } == false ? nil : model(kind: kind))
    }

    /// A text's kind: its language's word vectors where Apple has them,
    /// else its script's contextual model. A question's language is told
    /// among the kinds given only, as a few words are easily taken for
    /// another language ("domain renewal" for Indonesian).
    public static func kind(for text: String, among kinds: Set<String>?) -> String {
        let script = MailScript.of(text)
        guard script == "Latn" else { return script }
        let open = languages.keys.filter { kinds?.contains($0) ?? true }
        guard !open.isEmpty else { return script }
        let recognizer = NLLanguageRecognizer()
        if kinds != nil { recognizer.languageConstraints = open.compactMap { languages[$0] } }
        recognizer.processString(String(text.prefix(1000)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
        let best = open.max { (hypotheses[languages[$0]!] ?? 0) < (hypotheses[languages[$1]!] ?? 0) }
        guard let best else { return script }
        if kinds != nil { return best }
        // A mail: its language's own when that is what it is mostly in.
        let share = open.reduce(0.0) { $0 + (hypotheses[languages[$1]!] ?? 0) }
        return recognizer.dominantLanguage == languages[best] || share >= 0.5 ? best : script
    }

    public func model(kind: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = looked[kind], Date().timeIntervalSince(known.at) < 60 { return known.name }
        var name: String?
        if let language = Self.languages[kind] {
            name = NLEmbedding.wordEmbedding(for: language).map { kind + "." + String($0.revision) }
        } else if let script = Self.scripts[kind], let embedding = NLContextualEmbedding(script: script) {
            if embedding.hasAvailableAssets {
                name = Self.name(kind, embedding)
            } else {
                fetch(kind, embedding)
            }
        }
        looked[kind] = (name, Date())
        return name
    }

    /// A contextual model's name: its script, its revision, its pooling.
    private static func name(_ script: String, _ embedding: NLContextualEmbedding) -> String {
        script + "." + String(embedding.revision) + "." + String(pooling)
    }

    /// macOS fetches the model from Apple: no question to the person, and
    /// nothing waits on it; vectors come later.
    private func fetch(_ kind: String, _ embedding: NLContextualEmbedding) {
        guard fetching.insert(kind).inserted else { return }
        Task.detached(priority: .background) { _ = try? await embedding.requestAssets() }
    }

    public func vector(_ text: String, model: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let kind = MailVector.kind(of: model)
        if let language = Self.languages[kind] {
            if words[kind] == nil { words[kind] = NLEmbedding.wordEmbedding(for: language) }
            guard let embedding = words[kind], kind + "." + String(embedding.revision) == model else { return nil }
            return Self.average(text, embedding)
        }
        guard let loaded = load(model) else { return nil }
        guard let pooled = Self.pool(text, loaded.embedding) else { return nil }
        return MailVector.unit(zip(pooled, loaded.mean).map { $0 - $1 })
    }

    public func wordModel() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = looked["word"], Date().timeIntervalSince(known.at) < 60 { return known.name }
        var name: String?
        if let embedding = NLContextualEmbedding(script: .cyrillic) {
            if embedding.hasAvailableAssets { name = "Cyrl." + String(embedding.revision) + ".word" } else { fetch("Cyrl", embedding) }
        }
        looked["word"] = (name, Date())
        return name
    }

    /// A word through Cyrillic's contextual model as a sentence of its own,
    /// the word and a period, its own tokens' vectors averaged. Alone,
    /// without the stop, some hundreds of common words ("may", "work",
    /// "bill") come out as one and the same vector.
    public func word(_ word: String) -> (model: String, vector: [Float])? {
        lock.lock()
        defer { lock.unlock() }
        if cyrillic == nil {
            guard let embedding = NLContextualEmbedding(script: .cyrillic), embedding.hasAvailableAssets,
                  (try? embedding.load()) != nil else { return nil }
            cyrillic = embedding
        }
        let text = word + "."
        guard let embedding = cyrillic, !word.isEmpty, let at = text.range(of: word),
              let result = try? embedding.embeddingResult(for: text, language: nil) else { return nil }
        let width = Int(embedding.dimension)
        var sum = [Double](repeating: 0, count: width)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, range in
            guard !range.isEmpty, range.overlaps(at), vector.count == width else { return true }
            count += 1
            for i in 0..<width { sum[i] += vector[i] }
            return true
        }
        guard count > 0 else { return nil }
        return ("Cyrl." + String(embedding.revision) + ".word", MailVector.unit(sum.map { Float($0 / Double(count)) }))
    }

    public func rest() {
        lock.lock()
        defer { lock.unlock() }
        for model in loaded.values { model.embedding.unload() }
        cyrillic?.unload()
        cyrillic = nil
        loaded = [:]
        words = [:]
    }

    private func load(_ model: String) -> Loaded? {
        if let known = loaded[model] { return known }
        let script = MailVector.kind(of: model)
        guard let kind = Self.scripts[script], let embedding = NLContextualEmbedding(script: kind),
              Self.name(script, embedding) == model, embedding.hasAvailableAssets,
              (try? embedding.load()) != nil else { return nil }
        let pooled = Self.latin.compactMap { Self.pool($0, embedding) }
        guard !pooled.isEmpty else { return nil }
        var mean = [Float](repeating: 0, count: pooled[0].count)
        for vector in pooled where vector.count == mean.count {
            for i in mean.indices { mean[i] += vector[i] / Float(pooled.count) }
        }
        let made = Loaded(embedding: embedding, mean: mean)
        loaded[model] = made
        return made
    }

    /// A text's words that mean something, their vectors averaged, unit
    /// length; all zero when none is in the model's words, which matches
    /// nothing.
    public static func average(_ text: String, _ embedding: NLEmbedding) -> [Float] {
        var sum = [Double](repeating: 0, count: embedding.dimension)
        for word in text.prefix(4000).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        where word.count > 1 && !MailFiller.words.contains(word) {
            guard let vector = embedding.vector(for: word), vector.count == sum.count else { continue }
            for i in sum.indices { sum[i] += vector[i] }
        }
        return MailVector.unit(sum.map { Float($0) })
    }

    /// The model's vectors for a text's tokens, averaged over the words
    /// that mean something, unit length.
    public static func pool(_ text: String, _ embedding: NLContextualEmbedding) -> [Float]? {
        // The model reads 256 tokens at most; past that is never seen.
        let text = String(text.prefix(1600))
        guard !text.isEmpty, let result = try? embedding.embeddingResult(for: text, language: nil) else { return nil }
        let meaning = meaningful(text)
        let width = Int(embedding.dimension)
        var sum = [Double](repeating: 0, count: width), all = [Double](repeating: 0, count: width)
        var kept = 0, every = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, range in
            // The model's own tokens stand for no words.
            guard !range.isEmpty, vector.count == width else { return true }
            every += 1
            for i in 0..<width { all[i] += vector[i] }
            if meaning.contains(range.lowerBound.utf16Offset(in: text)) {
                kept += 1
                for i in 0..<width { sum[i] += vector[i] }
            }
            return true
        }
        let (total, count) = kept > 0 ? (sum, kept) : (all, every)
        guard count > 0 else { return nil }
        return MailVector.unit(total.map { Float($0 / Double(count)) })
    }

    /// Where the words that mean something are, as UTF-16 offsets: words
    /// with a letter, not the empty ones; never punctuation or a number.
    private static func meaningful(_ text: String) -> IndexSet {
        var out = IndexSet()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: \.isLetter), !MailFiller.words.contains(text[range].lowercased()) {
                let span = NSRange(range, in: text)
                out.insert(integersIn: span.location..<(span.location + span.length))
            }
            return true
        }
        return out
    }

    // MARK: - ordinary sentences, for the direction all texts share

    static let latin = [
        "Thanks for getting back to me so quickly.", "I'll be in the office tomorrow if you want to talk.",
        "Please find the documents attached to this email.", "Let me know if you have any questions about the proposal.",
        "We should schedule a call next week to go over the details.", "Your order has been confirmed and will ship soon.",
        "The team is working on the new release and expects to finish by Friday.", "Can we move our meeting to the afternoon?",
        "Here is the summary of what we discussed today.", "I'm sorry for the delay, I was traveling last week.",
        "The payment was received, thank you.", "We're excited to announce our new product.",
        "Click the link below to verify your email address.", "Your appointment is scheduled for next Monday.",
        "I'd love to hear your thoughts on the design.", "The invoice for this month is attached.",
        "Our records show that your account needs attention.", "Welcome aboard, we're glad to have you on the team.",
        "The event starts at seven, dinner will be served.", "Could you please confirm the address for the delivery?",
        "We updated our privacy policy and terms of service.", "I just wanted to follow up on my previous message.",
        "The kids loved the park, we should go again soon.", "Your flight has been rescheduled, see the new times below.",
        "Thanks again for your help with the move.", "The report shows strong growth in the third quarter.",
        "Don't forget to bring your laptop to the workshop.", "We have a few openings for the spring session.",
        "Your package was delivered to the front door.", "I've shared the folder with you, let me know if you can open it.",
    ]
}
