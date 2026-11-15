import Foundation
import Testing
@testable import Fast

// Download Video from a video's right-click menu (#1057): which way a video
// is saved, and the HLS playlists read to put one together.
struct VideoSaveTests {
    private let base = URL(string: "https://video.twimg.com/amplify_video/1849/pl/master.m3u8?tag=16")!

    @Test func nativeSourceDoesNotSaveAnOlderRightClickedVideo() {
        let source = URL(string: "https://video.twimg.com/current.mp4")!
        let old = PointedMedia(src: "blob:https://x.com/old", playlists: ["https://example.com/old.m3u8"])
        let media = VideoSave.pointed(source: source, heard: old, audio: false)
        #expect(VideoSave.route(media) == .download(source))
        #expect(media.playlists.isEmpty)
        let blob = URL(string: old.src)!
        #expect(VideoSave.pointed(source: blob, heard: old, audio: false) == old)
        #expect(VideoSave.pointed(source: source, heard: nil, audio: true).audio)
    }

    @Test func menuExplainsWhenThereIsNoDirectFile() {
        #expect(VideoSave.downloadTitle(PointedMedia(src: "blob:https://x.com/clip")) == "Download Video (No Direct File)")
        #expect(VideoSave.downloadTitle(PointedMedia(src: "")) == "Video Download Unavailable")
        #expect(VideoSave.downloadTitle(PointedMedia(src: "https://example.com/clip.mp4")) == "Download Video")
    }

    @Test func plainFileIsADownload() {
        let media = PointedMedia(src: "https://example.com/clip.mp4")
        #expect(VideoSave.route(media) == .download(URL(string: "https://example.com/clip.mp4")!))
    }

    @Test func aSourceElementIsADownload() {
        let media = PointedMedia(src: "", sources: ["https://example.com/a.m3u8", "https://example.com/a.webm"])
        #expect(VideoSave.route(media) == .download(URL(string: "https://example.com/a.webm")!))
    }

    @Test func aPlaylistSrcIsHLS() {
        let media = PointedMedia(src: "https://example.com/live/index.m3u8")
        #expect(VideoSave.route(media) == .hls([URL(string: "https://example.com/live/index.m3u8")!]))
    }

    @Test func aBlobTriesItselfThenThePlaylists() {
        let media = PointedMedia(src: "blob:https://x.com/9c1e", playlists: ["https://video.twimg.com/a/pl/x.m3u8"])
        #expect(VideoSave.route(media) == .blob(URL(string: "blob:https://x.com/9c1e")!, [URL(string: "https://video.twimg.com/a/pl/x.m3u8")!]))
    }

    @Test func nothingToSaveSaysSo() {
        #expect(VideoSave.route(PointedMedia(src: "")) == .none)
        // A DASH manifest isn't a playlist this puts together.
        #expect(VideoSave.route(PointedMedia(src: "", playlists: ["https://example.com/v.mpd"])) == .none)
    }

    @Test func playlistsSharingThePostersIdComeFirst() {
        let media = PointedMedia(
            src: "blob:https://x.com/1",
            poster: "https://pbs.twimg.com/amplify_video_thumb/1849000000000000001/img/abc.jpg",
            playlists: [
                "https://video.twimg.com/amplify_video/1849000000000000001/pl/master.m3u8",
                "https://video.twimg.com/amplify_video/1849000000000000002/pl/master.m3u8",
            ])
        let ranked = VideoSave.rank(media)
        #expect(ranked.first?.absoluteString.contains("1849000000000000001") == true)
        #expect(ranked.count == 2)
    }

    @Test func withNoHintsTheNewestPlaylistComesFirst() {
        let media = PointedMedia(src: "blob:x", playlists: ["https://a.com/one.m3u8", "https://a.com/two.m3u8", "https://a.com/one.m3u8"])
        #expect(VideoSave.rank(media).map(\.lastPathComponent) == ["one.m3u8", "two.m3u8"])
        let fresh = PointedMedia(src: "blob:x", playlists: ["https://a.com/one.m3u8", "https://a.com/two.m3u8"])
        #expect(VideoSave.rank(fresh).map(\.lastPathComponent) == ["two.m3u8", "one.m3u8"])
    }

    @Test func aTabThatIsTheVideoIsKnownByItsAddress() {
        #expect(VideoSave.isMediaFile(URL(string: "https://video.twimg.com/amplify_video/1849/vid/avc1/1280x720/a.mp4?tag=16")!))
        #expect(VideoSave.isMediaFile(URL(string: "https://example.com/a.m3u8")!))
        #expect(VideoSave.isMediaFile(URL(string: "https://example.com/song.mp3")!))
        #expect(!VideoSave.isMediaFile(URL(string: "https://x.com/ines/status/1849")!))
        #expect(!VideoSave.isMediaFile(URL(string: "file:///Users/a/clip.mp4")!))
    }

    @Test func attributesKeepQuotedCommas() {
        let a = VideoSave.attributes(#"BANDWIDTH=2176000,CODECS="mp4a.40.2,avc1.640020",AUDIO="audio-128000""#[...])
        #expect(a["BANDWIDTH"] == "2176000")
        #expect(a["CODECS"] == "mp4a.40.2,avc1.640020")
        #expect(a["AUDIO"] == "audio-128000")
    }

    @Test func aMasterPlaylistPicksTheBestVariantAndItsSound() {
        let text = """
        #EXTM3U
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:NAME="Audio",TYPE=AUDIO,GROUP-ID="audio-32000",AUTOSELECT=YES,URI="/amplify_video/1849/pl/mp4a/32000/a.m3u8"
        #EXT-X-MEDIA:NAME="Audio",TYPE=AUDIO,GROUP-ID="audio-128000",AUTOSELECT=YES,URI="/amplify_video/1849/pl/mp4a/128000/a.m3u8"
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=279000,BANDWIDTH=300000,RESOLUTION=480x270,CODECS="mp4a.40.2,avc1.4D401E",AUDIO="audio-32000"
        /amplify_video/1849/pl/avc1/480x270/v.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2176000,BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="mp4a.40.2,avc1.640020",AUDIO="audio-128000"
        /amplify_video/1849/pl/avc1/1280x720/v.m3u8
        """
        guard case .master(let variants, let renditions) = VideoSave.parse(text, base: base) else {
            Issue.record("not a master playlist"); return
        }
        #expect(variants.count == 2)
        let chosen = VideoSave.choose(variants, renditions)
        #expect(chosen?.video.absoluteString == "https://video.twimg.com/amplify_video/1849/pl/avc1/1280x720/v.m3u8")
        #expect(chosen?.audio?.absoluteString == "https://video.twimg.com/amplify_video/1849/pl/mp4a/128000/a.m3u8")
    }

    @Test func aMediaPlaylistListsItsPiecesAfterTheMap() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:3
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="/v/init.mp4"
        #EXTINF:3.000,
        /v/0/0000/1.m4s
        #EXTINF:3.000,
        /v/0/0003/2.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let track) = VideoSave.parse(text, base: base) else { Issue.record("not a media playlist"); return }
        #expect(track.map?.absoluteString == "https://video.twimg.com/v/init.mp4")
        #expect(track.segments.map(\.lastPathComponent) == ["1.m4s", "2.m4s"])
        #expect(track.unsupported == nil)
        #expect(!track.transport)
    }

    @Test func liveEncryptedAndRangedPlaylistsAreRefused() {
        let live = "#EXTM3U\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts\n"
        guard case .media(let open) = VideoSave.parse(live, base: base) else { Issue.record("live"); return }
        #expect(open.unsupported == "live")
        #expect(open.transport)
        let locked = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST\n"
        guard case .media(let key) = VideoSave.parse(locked, base: base) else { Issue.record("key"); return }
        #expect(key.unsupported == "encrypted")
        let ranged = "#EXTM3U\n#EXTINF:2,\n#EXT-X-BYTERANGE:100@0\na.mp4\n#EXT-X-ENDLIST\n"
        guard case .media(let range) = VideoSave.parse(ranged, base: base) else { Issue.record("range"); return }
        #expect(range.unsupported == "byte ranges")
        #expect(VideoSave.parse("not a playlist", base: base) == .none)
    }

    @Test func theFileIsNamedForThePage() {
        #expect(VideoSave.name(title: "Ines on X: \"look/at this\"", host: "x.com", ext: "mp4") == "Ines on X \"look at this\".mp4")
        #expect(VideoSave.name(title: "  ", host: "x.com", ext: "mp4") == "yab-x.com-video.mp4")
        #expect(VideoSave.name(title: "", host: "", ext: "ts") == "yab-page-video.ts")
    }

    @Test func pointedMediaReadsThePagesMessage() {
        let media = PointedMedia(["src": "blob:https://x.com/1", "sources": ["https://a.com/b.mp4"], "poster": "p",
                                  "playlists": ["https://a.com/m.m3u8"], "segment": "s", "audio": true])
        #expect(media == PointedMedia(src: "blob:https://x.com/1", sources: ["https://a.com/b.mp4"], poster: "p",
                                      playlists: ["https://a.com/m.m3u8"], segment: "s", audio: true))
        #expect(PointedMedia(["poster": "p"]) == nil)
    }
}
