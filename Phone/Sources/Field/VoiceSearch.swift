import AVFoundation
import Speech
import SwiftUI
import os

/// Voice search, from the right button's menu (Voice Search, after New
/// Chat, on the +'s hold): New Tab's field opens and Yab
/// listens (on this iPhone when its recognizer can; the microphone and Speech
/// Recognition are asked for only now, the first time), the words come into
/// the field as they are heard and the rows follow them, and a pause after
/// them, or a tap on the lit microphone, is Return: a search, an address, an
/// ask, as typed words would be. Nothing heard, it stops by itself and the
/// field is as it was. Typing while it listens takes over. The field keeps
/// its own look until then: the microphone is in it only while it listens.
/// Offered where speech can be recognized, and in Private only on this iPhone.
@MainActor
@Observable
final class VoiceSearch {
    enum Phase: Equatable, Sendable { case idle, asking, listening }

    enum Permission: Equatable, Sendable { case granted, microphoneOff, speechOff }

    private(set) var phase: Phase = .idle
    /// What it has heard so far.
    private(set) var heard = ""
    /// Speech can be recognized here at all: the microphone shows.
    private(set) var available: Bool

    var listening: Bool { phase != .idle }

    @ObservationIgnored private(set) var engine: any VoiceEngine
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var silence: Task<Void, Never>?
    /// The field's words before it listened, back when nothing was said.
    @ObservationIgnored private var before = ""
    @ObservationIgnored private var session = UUID()
    /// Named states: listening never stops on quiet, so it can be pictured.
    @ObservationIgnored private var holdsOpen = false
    @ObservationIgnored private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "voice")

    /// Nothing heard this long after the tap: it stops.
    @ObservationIgnored var firstWords: Duration = .seconds(6)
    /// This long quiet after words: they are all.
    @ObservationIgnored var pause: Duration = .milliseconds(1300)

    init(app: AppModel?, engine: (any VoiceEngine)? = nil, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.app = app
        let chosen: any VoiceEngine
        if let engine {
            chosen = engine
        } else if LaunchOptions.current.isTestRun, let i = arguments.firstIndex(of: "-YabVoice"), i + 1 < arguments.count {
            // UI tests: the simulator can't listen, so a stand-in hears these words.
            chosen = StandInVoice(arguments[i + 1])
        } else if LaunchOptions.current.isTestRun {
            // Test runs picture the same field everywhere: no microphone
            // unless a test or a state brings its stand-in.
            chosen = NoVoice()
        } else {
            chosen = SpeechEngine()
        }
        self.engine = chosen
        available = chosen.isAvailable
    }

    /// Named states and tests: a stand-in that hears `words`, stopping after
    /// `holdAfter` of them while still listening.
    func useStandIn(_ words: String, holdAfter: Int? = nil) {
        let standIn = StandInVoice(words)
        standIn.holdAfter = holdAfter
        use(standIn, holdsOpen: holdAfter != nil)
    }

    /// Tests: another engine; `holdsOpen` keeps it listening through quiet.
    func use(_ engine: any VoiceEngine, holdsOpen: Bool = false) {
        teardown()
        self.engine = engine
        self.holdsOpen = holdsOpen
        available = engine.isAvailable
    }

    /// The menu offers Voice Search: speech is recognized here, and for a
    /// private page on this iPhone, never on a server.
    func offers(privately: Bool) -> Bool { available && (!privately || engine.onDevice) }

    /// The lit microphone in New Tab's field, only while it listens.
    func shows(in field: FieldModel) -> Bool { available && field.mode == .newTab && listening }

    // MARK: - listening

    /// The microphone tapped: listen, or, listening, take what was heard.
    func toggle() { listening ? finish() : begin() }

    func begin() {
        guard let app, phase == .idle, app.field.mode == .newTab, available else { return }
        Haptics.play(.soft, reason: Haptics.Reason.voice)
        phase = .asking
        before = app.field.text
        heard = ""
        let session = UUID()
        self.session = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            let permission = await self.engine.authorize()
            guard self.session == session, self.phase == .asking else { return }
            switch permission {
            case .microphoneOff:
                self.phase = .idle
                app.say("Microphone is off for Yab in Settings", glyph: .microphone)
            case .speechOff:
                self.phase = .idle
                app.say("Speech Recognition is off for Yab in Settings", glyph: .microphone)
            case .granted:
                do {
                    try self.engine.start(heard: { [weak self] words, final in
                        guard self?.session == session else { return }
                        self?.hear(words, final: final)
                    }, ended: { [weak self] error in
                        guard self?.session == session else { return }
                        self?.ended(error)
                    })
                    self.phase = .listening
                    self.wait(self.firstWords)
                } catch {
                    self.log.error("voice: \(String(describing: error), privacy: .public)")
                    self.teardown()
                    app.say("Voice search isn't available now", glyph: .microphone)
                }
            }
        }
    }

    /// Words as they are heard, each time the whole of them so far.
    func hear(_ words: String, final: Bool) {
        guard phase == .listening, let app else { return }
        heard = words
        app.field.typed(words)
        if final { done() } else { wait(pause) }
    }

    private func wait(_ quiet: Duration) {
        silence?.cancel()
        guard !holdsOpen else { return }
        silence = Task { @MainActor [weak self] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// A tap on the lit microphone, or quiet: what was heard goes, or nothing.
    func finish() {
        guard listening else { return }
        if Self.route(heard) == nil { cancel() } else { done() }
    }

    /// The recognizer stopped on its own: what it heard goes, an error says nothing.
    private func ended(_ error: Error?) {
        guard phase == .listening else { return }
        if let error { log.info("voice ended: \(String(describing: error), privacy: .public)") }
        finish()
    }

    /// Return with the heard words, as if typed.
    private func done() {
        let words = Self.route(heard)
        teardown()
        guard let app else { return }
        guard let words else { app.field.typed(before); return }
        Haptics.play(.selection, reason: Haptics.Reason.voiceHeard)
        app.field.typed(words)
        app.fieldReturn()
    }

    /// Stops without a choice: the field's words as they were before.
    func cancel() {
        guard listening else { return }
        teardown()
        app?.field.typed(before)
    }

    /// The person typed while it listened: their words stay, it stops.
    func interrupted() {
        guard listening else { return }
        teardown()
    }

    private func teardown() {
        session = UUID()
        silence?.cancel()
        silence = nil
        engine.cancel()
        phase = .idle
        heard = ""
        // Others' audio goes on; a playing page keeps its session.
        if let playback = app?.pages.playback { PagePlayback.setSession(!playback.playing.isEmpty) }
    }

    // MARK: - what goes into the field

    /// Heard words as the field takes them: spaces made single, the full
    /// stop dictation puts at the end gone (a question mark stays: it makes
    /// an ask), a spoken address written as one ("apple dot com" is
    /// apple.com); nil for nothing heard.
    static func route(_ heard: String) -> String? {
        var words = heard.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while words.hasSuffix(".") { words.removeLast() }
        words = words.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return nil }
        let lower = " " + words.lowercased() + " "
        if lower.contains(" dot ") {
            let written = lower.replacingOccurrences(of: " w w w ", with: " www ")
                .replacingOccurrences(of: " dot ", with: ".")
                .replacingOccurrences(of: " slash ", with: "/")
                .trimmingCharacters(in: .whitespaces)
            if Words.address(written) != nil { return written }
        }
        return words
    }
}

extension AppModel {
    /// The right button's Voice Search: New Tab's field, listening.
    func openVoiceSearch(from origin: CGRect? = nil) {
        openNewTab(from: origin) { [weak self] in self?.voice.begin() }
    }
}

extension Haptics.Reason {
    static let voice = "voice"
}

/// Who listens: Apple's recognizer, or the tests' stand-in.
@MainActor
protocol VoiceEngine: AnyObject {
    var isAvailable: Bool { get }
    /// Recognizes on this iPhone, never on Apple's servers.
    var onDevice: Bool { get }
    /// Asks for the microphone and Speech Recognition, only when listening starts.
    func authorize() async -> VoiceSearch.Permission
    /// Listens: `heard` with all the words so far (and whether they are
    /// final), `ended` once it stops by itself.
    func start(heard: @escaping @MainActor (String, Bool) -> Void, ended: @escaping @MainActor (Error?) -> Void) throws
    func cancel()
}

/// Apple's speech recognition, on this iPhone whenever its recognizer can.
@MainActor
final class SpeechEngine: VoiceEngine {
    enum Failure: Error { case unavailable, noMicrophone }

    private let recognizer = SFSpeechRecognizer()
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer != nil && SFSpeechRecognizer.authorizationStatus() != .restricted }
    var onDevice: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func authorize() async -> VoiceSearch.Permission {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard speech == .authorized else { return .speechOff }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .undetermined: return await AVAudioApplication.requestRecordPermission() ? .granted : .microphoneOff
        default: return .microphoneOff
        }
    }

    func start(heard: @escaping @MainActor (String, Bool) -> Void, ended: @escaping @MainActor (Error?) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never leaves this iPhone when it doesn't have to.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .search
        request.addsPunctuation = true
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw Failure.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        audio.prepare()
        try audio.start()
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, error in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                if let words { heard(words, final) }
                if error != nil || final { ended(error) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
    }
}

/// Test runs without a stand-in: no microphone.
@MainActor
final class NoVoice: VoiceEngine {
    var isAvailable: Bool { false }
    var onDevice: Bool { false }
    func authorize() async -> VoiceSearch.Permission { .speechOff }
    func start(heard: @escaping @MainActor (String, Bool) -> Void, ended: @escaping @MainActor (Error?) -> Void) throws {
        throw SpeechEngine.Failure.unavailable
    }
    func cancel() {}
}

/// UI tests and named states: hears its words one more every quarter
/// second, as a person says them, then is quiet.
@MainActor
final class StandInVoice: VoiceEngine {
    private let words: [String]
    /// Stops after this many words, still listening (named states).
    var holdAfter: Int?
    private var feeding: Task<Void, Never>?

    init(_ words: String) { self.words = words.split(separator: " ").map(String.init) }

    var isAvailable: Bool { true }
    var onDevice: Bool { true }

    func authorize() async -> VoiceSearch.Permission { .granted }

    func start(heard: @escaping @MainActor (String, Bool) -> Void, ended: @escaping @MainActor (Error?) -> Void) throws {
        let words = words, hold = holdAfter
        feeding = Task { @MainActor in
            for count in 1...max(1, words.count) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if let hold, count > hold { return }
                heard(words.prefix(count).joined(separator: " "), false)
            }
        }
    }

    func cancel() {
        feeding?.cancel()
        feeding = nil
    }
}
