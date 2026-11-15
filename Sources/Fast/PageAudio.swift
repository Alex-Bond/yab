import AppKit

/// Whole-page output muting, independent of DOM media volume and capture.
@MainActor
protocol PageAudioControl: AnyObject {
    func setAudioMuted(_ muted: Bool)
}

extension PageView: PageAudioControl {
    func setAudioMuted(_ muted: Bool) { AudioWatch.mute(self, muted) }
}
