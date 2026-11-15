import AppKit
import MediaPlayer

extension Bench {
    /// Read the actual published image, not a size inferred from the URL.
    /// WebKit owns a separate native center; this observes Yab's publisher.
    func nowPlayingArtworkProbe() -> [String: Any] {
        guard Store.testing else { return ["error": "requires an isolated test world"] }
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        var result: [String: Any] = ["title": info[MPMediaItemPropertyTitle] ?? "",
                                   "publisher": "application center (WebKit owns its native center)"]
        if let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            result["bounds"] = [artwork.bounds.width, artwork.bounds.height]
            if let image = artwork.image(at: artwork.bounds.size),
               let rep = image.representations.first {
                result["pixels"] = [rep.pixelsWide, rep.pixelsHigh]
            }
        }
        return result
    }
}
