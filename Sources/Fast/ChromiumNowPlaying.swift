import AppKit
import MediaPlayer

/// A metadata refresh cannot reclaim playback after another engine starts.
/// Only a new playback transition can take ownership again.
struct ChromiumPlaybackOwnership<Key: Hashable> {
    private(set) var owner: Key?
    private var playback: [Key: Bool] = [:]
    mutating func receive(_ key: Key, playing: Bool, metadataAllowed: Bool, sessionChanged: Bool = false) -> Bool {
        let started = playing && (playback[key] != true || sessionChanged)
        playback[key] = playing
        guard metadataAllowed else {
            if owner == key { owner = nil }
            return false
        }
        if owner != key, started { owner = key }
        return owner == key
    }
    mutating func cede() { owner = nil }
    mutating func end(_ key: Key) {
        playback.removeValue(forKey: key)
        if owner == key { owner = nil }
    }
}

/// MediaPlayer may invoke handlers off the main actor. Only immutable
/// command admission crosses that callback; native dispatch stays on main.
private final class ChromiumNowPlayingAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: Set<String> = []
    private var epoch = UUID()
    func update(_ actions: Set<String>, epoch: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.actions = actions; self.epoch = epoch
    }
    func accepted(_ action: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return actions.contains(action) ? epoch : nil
    }
}

/// The application owns Chromium's system session. Its concealed helper
/// windows do not become the user's Now Playing application on macOS.
@MainActor
final class ChromiumNowPlaying {
    static let shared = ChromiumNowPlaying()
    private weak var owner: ChromiumPage?
    private var report = ChromiumMediaReport()
    private var installed = false
    private let center = MPNowPlayingInfoCenter.default()
    private let admission = ChromiumNowPlayingAdmission()
    private var commandEpoch = UUID()
    private var nativeToken: String?
    private var nativeTokens: [ObjectIdentifier: String] = [:]
    private var ownership = ChromiumPlaybackOwnership<ObjectIdentifier>()

    func receive(_ report: ChromiumMediaReport, page: ChromiumPage) {
        guard !Store.unitTests else { return }
        let key = ObjectIdentifier(page)
        var sessionChanged = false
        if let token = page.media.nativeSession?.token {
            sessionChanged = nativeTokens[key] != token
            nativeTokens[key] = token
        }
        let permitted = ownership.receive(key, playing: report.playing || report.audible,
                                          metadataAllowed: !page.privateMode && !report.hideMetadata,
                                          sessionChanged: sessionChanged)
        guard permitted else {
            if owner === page { clearOwner() }
            return
        }
        if owner !== page { owner = page; commandEpoch = UUID() }
        if nativeToken != page.media.nativeSession?.token {
            nativeToken = page.media.nativeSession?.token; commandEpoch = UUID()
        }
        self.report = report
        guard report.media != nil || report.session != nil || report.audible else { ended(page); return }
        install()
        let session = report.session
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? page.title ?? "",
            MPMediaItemPropertyArtist: session?.artist ?? "",
            MPMediaItemPropertyAlbumTitle: session?.album ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: report.playing ? 1.0 : 0.0,
        ]
        if let media = report.media {
            if media.time >= 0 { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = media.time }
            if media.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = media.duration }
        }
        if !page.media.nativeSessionKnown, let cover = page.navigationTab?.tune?.cover {
            let image = NSImage(cgImage: cover, size: NSSize(width: 112, height: 112))
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = report.playing || report.audible ? .playing : .paused
        refreshCommands(page)
        if let artwork = session?.artwork.first {
            let epoch = commandEpoch
            Accent.of(artwork, shy: page.privateMode) { [weak self, weak page] found in
                guard let self, let page, self.owner === page, self.commandEpoch == epoch,
                      !page.privateMode, !self.report.hideMetadata,
                      self.report.session?.artwork.first == artwork, let found else { return }
                let image = NSImage(cgImage: found.image, size: NSSize(width: 112, height: 112))
                var info = self.center.nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.center.nowPlayingInfo = info
            }
        }
    }

    func ended(_ page: ChromiumPage) {
        nativeTokens.removeValue(forKey: ObjectIdentifier(page))
        ownership.end(ObjectIdentifier(page))
        guard owner === page else { return }
        clearOwner()
    }

    /// WebKit owns its native system session. Invalidate CEF commands and
    /// metadata before yielding, while retaining CEF playback transition state.
    func yieldToWebKit() {
        ownership.cede()
        guard owner != nil else { return }
        clearOwner()
    }

    private func clearOwner() {
        ownership.cede()
        owner = nil; nativeToken = nil; commandEpoch = UUID()
        admission.update([], epoch: commandEpoch)
        let commands = MPRemoteCommandCenter.shared()
        let controls: [MPRemoteCommand] = [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
            commands.nextTrackCommand, commands.previousTrackCommand, commands.changePlaybackPositionCommand]
        for command in controls { command.isEnabled = false }
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private func refreshCommands(_ page: ChromiumPage) {
        var allowed: Set<String>
        if page.media.nativeSessionKnown { allowed = page.media.nativeSession?.remoteCommands ?? [] }
        else {
            allowed = ["play", "pause", "toggle", "seekto"]
            if page.navigationTab?.tune?.next == true { allowed.insert("next") }
            if page.navigationTab?.tune?.previous == true { allowed.insert("previous") }
        }
        admission.update(allowed, epoch: commandEpoch)
        let commands = MPRemoteCommandCenter.shared()
        let controls: [(MPRemoteCommand, String)] = [(commands.playCommand, "play"), (commands.pauseCommand, "pause"),
            (commands.togglePlayPauseCommand, "toggle"), (commands.nextTrackCommand, "next"),
            (commands.previousTrackCommand, "previous"), (commands.changePlaybackPositionCommand, "seekto")]
        for (command, action) in controls { command.isEnabled = allowed.contains(action) }
    }

    private func install() {
        guard !installed else { return }
        installed = true
        let commands = MPRemoteCommandCenter.shared()
        for (command, action) in [(commands.playCommand, "play"), (commands.pauseCommand, "pause"),
                                   (commands.togglePlayPauseCommand, "toggle"),
                                   (commands.nextTrackCommand, "next"), (commands.previousTrackCommand, "previous")] {
            command.isEnabled = false
            command.addTarget { [weak self, admission = self.admission] _ in
                guard let epoch = admission.accepted(action) else { return .commandFailed }
                Task { @MainActor in self?.perform(action, epoch: epoch) }
                return .success
            }
        }
        commands.changePlaybackPositionCommand.isEnabled = false
        commands.changePlaybackPositionCommand.addTarget { [weak self, admission = self.admission] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent,
                  position.positionTime.isFinite, position.positionTime >= 0,
                  let epoch = admission.accepted("seekto") else { return .commandFailed }
            let time = position.positionTime
            Task { @MainActor in
                guard let self, self.commandEpoch == epoch, self.admission.accepted("seekto") == epoch else { return }
                self.owner?.mediaAction("seekto", value: time)
            }
            return .success
        }
    }

    private func perform(_ action: String, epoch: UUID) {
        guard commandEpoch == epoch, admission.accepted(action) == epoch, let page = owner, let tab = page.navigationTab, tab.builtPage === page else { return }
        if action == "next" || action == "previous" {
            tab.tuneWatch.skip(forward: action == "next")
            return
        }
        let play = action == "play" || (action == "toggle" && !report.playing && !report.audible)
        tab.tuneWatch.want(playing: play)
    }
}
