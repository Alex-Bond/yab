import JavaScriptCore
import Testing
@testable import Fast

// Exercise the real page proxy and isolated bridge with shared mock DOM,
// canvas capture and WebCodecs. Native WebKit must separately verify the
// cross-world srcObject identity and actual captured video frames.
@MainActor struct ShareScriptTests {
    private func page() throws -> JSContext {
        let context = try #require(JSContext())
        try evaluate(context, Self.fixture)
        try evaluate(context, """
        (function (window, webkit, Worker) {
          \(ShareScript.bridge)
        })(bridgeWindow, bridgeWindow.webkit, ForbiddenWorker);
        function prepareOwn(id, images) {
          return (function (window) { \(ShareScript.transport("api.prepare(id, images)")) })(bridgeWindow);
        }
        """)
        try evaluate(context, ShareScript.page)
        try evaluate(context, "var api = MediaDevices.prototype[Symbol.for('yab.share')];")
        #expect(try boolean(context, "!!api"))
        return context
    }

    @discardableResult private func evaluate(_ context: JSContext, _ script: String) throws -> JSValue {
        context.exception = nil
        let value = context.evaluateScript(script)
        try #require(context.exception == nil, "JavaScript threw: \(context.exception?.toString() ?? "unknown")")
        return try #require(value)
    }

    private func boolean(_ context: JSContext, _ script: String) throws -> Bool {
        try evaluate(context, script).toBool()
    }

    private func number(_ context: JSContext, _ script: String) throws -> Int {
        Int(try evaluate(context, script).toInt32())
    }

    private func word(_ context: JSContext, _ script: String) throws -> String? {
        try evaluate(context, script).toString()
    }

    private func expectFallback(_ context: JSContext) throws {
        #expect(try word(context, "settled") == "pending")
        #expect(try number(context, "resolutions + rejections") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback').length") == 1)
        #expect(try boolean(context, "messages.find(m => m.kind === 'fallback').token === requestToken"))
        #expect(try word(context, "messages.find(m => m.kind === 'fallback').id") == "own-id")
        #expect(try number(context, "nativeCalls") == 0)
        #expect(try number(context, "timers.size") == 0)
        // Native may deliver a queued frame before consuming fallback.
        #expect(try boolean(context, "api.feed('own-id', 'chunk', '', true, 0)"))
    }

    private func acceptSystemPicker(_ context: JSContext) throws {
        #expect(try boolean(context, "api.system(requestToken)"))
        #expect(try number(context, "nativeCalls") == 1)
        #expect(try boolean(context, "api.feed('own-id', 'chunk', '', true, 0)") == false)
        #expect(try boolean(context, "nativeReceiver === navigator.mediaDevices"))
        #expect(try boolean(context, "nativeConstraints === requestConstraints"))
        #expect(try word(context, "settled") == "pending")
        #expect(try boolean(context, "api.system(requestToken)") == false)
        try evaluate(context, "var nativeTrack = new MediaStreamTrack(); var nativeStream = new MediaStream([nativeTrack]); nativeResolve(nativeStream);")
        #expect(try word(context, "settled") == "resolved")
        #expect(try boolean(context, "result === nativeStream"))
        #expect(try number(context, "resolutions") == 1)
        #expect(try number(context, "rejections") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'started' && m.id === 'system-' + requestToken).length") == 1)
    }

    private func expectTabFailure(_ context: JSContext, reason: String) throws {
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == "AbortError")
        #expect(try word(context, "rejection.message")?.contains(reason) == true)
        #expect(try word(context, "rejection.message")?.contains("selected browser tab") == true)
        #expect(try number(context, "rejections") == 1)
        #expect(try number(context, "resolutions") == 0)
        #expect(try number(context, "nativeCalls") == 0)
        #expect(try number(context, "timers.size") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback' || m.kind === 'started').length") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'stop' && m.id === 'own-id').length") == 1)
        #expect(try boolean(context, "api.feed('own-id', 'chunk', '', true, 0)") == false)
        #expect(try boolean(context, "api.system(requestToken)") == false)
        #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].end('own-id')") == false)
    }

    @Test func trustedTypesCannotBlockCanvasCaptureAndNoWorkerIsConstructed() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn();")
        #expect(try word(context, "settled") == "pending")
        #expect(try number(context, "workerAttempts + pageWorkerAttempts") == 0)
        #expect(try number(context, "captureAttempts") == 1)
        #expect(try number(context, "canvases[0].captureRate") == 30)
        #expect(try number(context, "canvases[0].width") == 1200)
        #expect(try number(context, "canvases[0].height") == 800)
        #expect(try number(context, "decoders.length + carrierReads") == 0)

        try evaluate(context, "sendFormat(); sendChunk(true, 1234); var ownFrame = new Frame(); decoders[0].emit(ownFrame);")
        #expect(try word(context, "settled") == "resolved")
        #expect(try boolean(context, "result.getVideoTracks()[0] === canvasStreams[0].getVideoTracks()[0]"))
        #expect(try number(context, "workerAttempts + pageWorkerAttempts") == 0)
        #expect(try number(context, "carrierReads") == 1)
        #expect(try number(context, "carriers.length") == 1)
        #expect(try boolean(context, "carriers[0].hidden && carriers[0].srcObject === null && carriers[0].removed"))
        #expect(try number(context, "document.documentElement.children.length") == 0)
        #expect(try boolean(context, "window[Symbol.for('yab.share.worker')] === undefined"))
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback').length") == 0)
    }

    @Test func imageCaptureDeliversOnlyDecodedPixelsWithoutAVideoCodec() throws {
        let context = try page()
        try evaluate(context, "VideoDecoder = undefined; EncodedVideoChunk = undefined; begin(); prepareOwn('own-id', true); api.answer(requestToken, {choice:'own', id:'own-id', surface:'browser'}); api.feed('own-id', 'format', '', 'image/jpeg', 1200, 800); sendChunk(true, 1);")
        #expect(try word(context, "settled") == "pending")
        #expect(try number(context, "imageDecodes.length") == 1)
        try evaluate(context, "sendChunk(true, 2); var bitmap = new Frame(); bitmap.width = 1200; bitmap.height = 800; imageDecodes[0].resolve(bitmap);")
        #expect(try word(context, "settled") == "resolved")
        #expect(try number(context, "imageDecodes.length") == 1)
        #expect(try number(context, "bitmap.closes") == 1)
        #expect(try number(context, "decoders.length") == 0)
        #expect(try boolean(context, "result.getVideoTracks()[0] === canvasStreams[0].getVideoTracks()[0]"))
        try evaluate(context, "sendChunk(true, 1); sendChunk(true, 3);")
        #expect(try number(context, "imageDecodes.length") == 2)
        #expect(try number(context, "resolutions") == 1)
    }

    @Test func endedImageCaptureClosesLateBitmapWithoutHandingItToThePage() throws {
        let context = try page()
        try evaluate(context, "begin(); prepareOwn('own-id', true); api.answer(requestToken, {choice:'own', id:'own-id', surface:'browser'}); api.feed('own-id', 'format', '', 'image/jpeg', 1200, 800); sendChunk(true, 1); api.feed('own-id', 'end'); var bitmap = new Frame(); imageDecodes[0].resolve(bitmap);")
        #expect(try word(context, "settled") == "rejected")
        #expect(try number(context, "bitmap.closes") == 1)
        #expect(try number(context, "carriers.length + resolutions") == 0)
        #expect(try word(context, "canvasStreams[0].getVideoTracks()[0].readyState") == "ended")
    }

    @Test func imageDecodeFailureRejectsTheSelectedTabWithoutChangingSources() throws {
        let context = try page()
        try evaluate(context, "begin(); prepareOwn('own-id', true); api.answer(requestToken, {choice:'own', id:'own-id', surface:'browser'}); api.feed('own-id', 'format', '', 'image/jpeg', 1200, 800); sendChunk(true, 1); imageDecodes[0].reject(new Error('Image decode failed'));")
        try expectTabFailure(context, reason: "Image decode failed")
    }

    /// A tab's sound for an extension (ExtensionTabAudio): Yab's side makes
    /// its track only for an id Yab prepared, never on a page's word; the
    /// track reaches the page through the carrier, takes what is fed, and
    /// ends with the share.
    @Test func aTabsSoundComesOnlyForAnIdYabPrepared() throws {
        let context = try page()
        try evaluate(context, Self.sound)
        try evaluate(context, "window.dispatchEvent(new CustomEvent('yab-share-worker', { detail: JSON.stringify({ id: 'sound-id', message: { type: 'sound' } }) }));")
        #expect(try number(context, "audioContexts.length") == 0)
        #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].sound('sound-id', 'f.1', 48000, 'AQID')") == false)

        try evaluate(context, """
        var soundStream = null, soundError = null;
        api.sound('stream-7').then(function (s) { soundStream = s; }, function (e) { soundError = e; });
        var soundAsk = messages.find(function (m) { return m.kind === 'sound'; });
        """)
        #expect(try word(context, "soundAsk.stream") == "stream-7")
        #expect(try boolean(context, "(function (window, id) { \(ShareScript.transport("api.prepareSound(id)")) })(bridgeWindow, 'sound-id')"))
        try evaluate(context, "api.answer(soundAsk.token, { choice: 'sound', id: 'sound-id', label: 'Fixture tab' });")
        #expect(try number(context, "audioContexts.length") == 1)
        #expect(try boolean(context, "soundStream !== null && soundError === null"))
        #expect(try boolean(context, "soundStream.getAudioTracks()[0] === audioContexts[0].out.stream.tracks[0]"))
        #expect(try word(context, "soundStream.getAudioTracks()[0].label") == "Fixture tab")
        #expect(try boolean(context, "carriers.every(function (c) { return c.srcObject === null && c.removed; })"))
        #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].sound('sound-id', 'f.1', 48000, 'AQID')"))

        // Yab ends it: the page's track ends, the context is closed.
        #expect(try boolean(context, "api.feed('sound-id', 'end')"))
        #expect(try boolean(context, "soundStream.getAudioTracks()[0].events.indexOf('ended') >= 0"))
        #expect(try boolean(context, "audioContexts[0].closed"))
        #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].sound('sound-id', 'f.1', 48000, 'AQID')") == false)
    }

    private static let sound = #"""
    var audioContexts = [];
    function AudioContext() {
      this.sampleRate = 48000; this.state = 'running'; this.closed = false; this.destination = {};
      audioContexts.push(this);
    }
    AudioContext.prototype.createMediaStreamDestination = function () {
      return this.out = { stream: new MediaStream([new MediaStreamTrack()]) };
    };
    AudioContext.prototype.createScriptProcessor = function () { return { connect: function () {}, disconnect: function () {} }; };
    AudioContext.prototype.createGain = function () { return { gain: { value: 1 }, connect: function () {} }; };
    AudioContext.prototype.resume = function () { return Promise.resolve(); };
    AudioContext.prototype.close = function () { this.closed = true; return Promise.resolve(); };
    bridgeWindow.AudioContext = AudioContext;
    window.AudioContext = AudioContext;
    MediaStream.prototype.getAudioTracks = function () { return this.tracks; };
    """#

    @Test func pageMessagesCannotCreateAnUnpreparedCapturePipeline() throws {
        let context = try page()
        try evaluate(context, "window.dispatchEvent(new CustomEvent('yab-share-worker', { detail: JSON.stringify({ id: 'unprepared', message: { type: 'start', width: 1200, height: 800 } }) }));")
        #expect(try number(context, "canvases.length + captureAttempts + decoders.length") == 0)
        #expect(try number(context, "workerAttempts + pageWorkerAttempts") == 0)
        #expect(try number(context, "messages.length") == 0)
        #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].end('unprepared')") == false)
    }

    @Test func formatAndChunksReachOnlyThePreparedDecoder() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn();")
        #expect(try boolean(context, "sendFormat()"))
        #expect(try boolean(context, "sendChunk(true, 1234)"))
        #expect(try number(context, "decoders.length") == 1)
        #expect(try boolean(context, "decoders[0].configurations[0].codec === 'avc1.64001e'"))
        #expect(try boolean(context, "decoders[0].configurations[0].description instanceof Uint8Array && Array.from(decoders[0].configurations[0].description).join(',') === '1,2,3'"))
        #expect(try boolean(context, "decoders[0].configurations[0].codedWidth === 1200 && decoders[0].configurations[0].codedHeight === 800"))
        #expect(try boolean(context, "decoders[0].chunks[0].type === 'key' && decoders[0].chunks[0].timestamp === 1234"))
        #expect(try boolean(context, "decoders[0].chunks[0].data instanceof Uint8Array && Array.from(decoders[0].chunks[0].data).join(',') === '1,2,3'"))
        #expect(try boolean(context, "api.feed('unprepared', 'chunk', 'AQID', true, 1234)") == false)
        #expect(try number(context, "decoders[0].chunks.length") == 1)
        #expect(try word(context, "settled") == "pending")
    }

    @Test func decodedFramesAreDrawnAndClosedAndTrackIsHandedOffOnce() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn(); sendFormat(); sendChunk(true, 1234); var first = new Frame(); var second = new Frame(); decoders[0].emit(first); decoders[0].emit(second);")
        #expect(try number(context, "draws.length") == 2)
        #expect(try boolean(context, "draws[0].frame === first && draws[1].frame === second"))
        #expect(try boolean(context, "draws[0].arguments.join(',') === '0,0,1200,800'"))
        #expect(try number(context, "first.closes") == 1)
        #expect(try number(context, "second.closes") == 1)
        #expect(try number(context, "resolutions") == 1)
        #expect(try number(context, "rejections") == 0)
        #expect(try number(context, "carriers.length") == 1)
        #expect(try number(context, "runRedraw()") == 1)
        #expect(try number(context, "timers.size") == 0)
    }

    @Test func firstHandoffRedrawsTheRetainedCanvasAfterTheConsumerAttaches() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn(); sendFormat(); var first = new Frame(); decoders[0].emit(first);")
        #expect(try word(context, "settled") == "resolved")
        #expect(try number(context, "first.closes") == 1)
        #expect(try number(context, "draws.length") == 1)
        #expect(try number(context, "timers.size") == 1)
        #expect(try number(context, "canvasStreams[0].getVideoTracks()[0].requests") == 1)

        // No further decoder output arrives after the page receives the track.
        #expect(try number(context, "runRedraw()") == 1)
        #expect(try number(context, "draws.length") == 2)
        #expect(try boolean(context, "draws[1].frame === canvases[0] && draws[1].arguments.join(',') === '0,0'"))
        #expect(try number(context, "canvasStreams[0].getVideoTracks()[0].requests") == 2)
        #expect(try number(context, "first.closes") == 1)
        #expect(try number(context, "resolutions") == 1)
        #expect(try number(context, "rejections") == 0)
        #expect(try number(context, "carriers.length") == 1)
        #expect(try number(context, "timers.size") == 0)
    }

    @Test(arguments: ["native", "page"])
    func endingTheShareSuppressesAnAlreadyQueuedRedraw(source: String) throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn(); sendFormat(); decoders[0].emit(new Frame());")
        try evaluate(context, "var redraw = Array.from(timers.values())[0]; var track = result.getVideoTracks()[0]; var drawCount = draws.length; var requestCount = track.requests;")
        #expect(try boolean(context, "typeof redraw === 'function'"))
        if source == "native" {
            #expect(try boolean(context, "api.feed('own-id', 'end')"))
        } else {
            try evaluate(context, "track.stop();")
        }
        #expect(try number(context, "timers.size") == 0)
        try evaluate(context, "redraw(); var lateFrame = new Frame(); decoders[0].emit(lateFrame);")
        #expect(try boolean(context, "draws.length === drawCount && track.requests === requestCount"))
        #expect(try number(context, "lateFrame.closes") == 1)
        #expect(try number(context, "decoders[0].closes") == 1)
        #expect(try word(context, "track.readyState") == "ended")
        #expect(try number(context, "resolutions") == 1)
        #expect(try number(context, "rejections") == 0)
        #expect(try number(context, "carriers.length") == 1)
        #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].end('own-id')") == false)
    }

    @Test func queuedOutputAfterEndClosesItsFrameWithoutDrawingOrReplying() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn(); sendFormat(); var decoder = decoders[0];")
        #expect(try boolean(context, "api.feed('own-id', 'end')"))
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == "AbortError")
        try evaluate(context, "var lateFrame = new Frame(); decoder.emit(lateFrame);")
        #expect(try number(context, "lateFrame.closes") == 1)
        #expect(try number(context, "draws.length + carriers.length") == 0)
        #expect(try number(context, "decoder.closes") == 1)
        #expect(try word(context, "canvasStreams[0].getVideoTracks()[0].readyState") == "ended")
        #expect(try number(context, "rejections") == 1)
        #expect(try number(context, "resolutions") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback').length") == 0)
    }

    @Test(arguments: ["capture", "constructor", "configure", "decode", "draw", "error", "timeout"])
    func browserCaptureFailureNeverOpensTheSystemPicker(failure: String) throws {
        let context = try page()
        let reason: String
        switch failure {
        case "capture":
            reason = "Canvas capture failed"
            try evaluate(context, "captureMode = 'throws'; begin(); chooseOwn();")
        case "constructor", "configure":
            reason = failure == "constructor" ? "Decoder constructor failed" : "Decoder configure failed"
            try evaluate(context, "decoderMode = '\(failure)-throws'; begin(); chooseOwn(); sendFormat();")
        case "decode":
            reason = "Decoder decode failed"
            try evaluate(context, "decoderMode = 'decode-throws'; begin(); chooseOwn(); sendFormat(); sendChunk(true, 1234);")
        case "draw":
            reason = "Canvas draw failed"
            try evaluate(context, "drawMode = 'throws'; begin(); chooseOwn(); sendFormat(); var failedFrame = new Frame(); decoders[0].emit(failedFrame);")
            #expect(try number(context, "failedFrame.closes") == 1)
        case "error":
            reason = "Decoder asynchronous failure"
            try evaluate(context, "begin(); chooseOwn(); sendFormat(); decoders[0].fail(new Error('Decoder asynchronous failure'));")
        default:
            reason = "timed out"
            try evaluate(context, "begin(); chooseOwn(); var expiredStartup = Array.from(timers.values())[0]; expiredStartup(); expiredStartup();")
        }
        try expectTabFailure(context, reason: reason)
        if failure != "capture" {
            #expect(try word(context, "canvasStreams[0].getVideoTracks()[0].readyState") == "ended")
        }
        if try number(context, "decoders.length") > 0 {
            try evaluate(context, "var lateFrame = new Frame(); decoders[0].emit(lateFrame); decoders[0].fail(new Error('Late error'));")
            #expect(try number(context, "lateFrame.closes") == 1)
            #expect(try number(context, "decoders[0].closes") == 1)
            #expect(try number(context, "rejections") == 1)
            #expect(try number(context, "resolutions") == 0)
        }
    }

    @Test(arguments: ["decoder", "chunk", "canvas", "context"])
    func missingCaptureCapabilitiesRejectTheSelectedTab(capability: String) throws {
        let context = try page()
        switch capability {
        case "decoder": try evaluate(context, "VideoDecoder = undefined;")
        case "chunk": try evaluate(context, "EncodedVideoChunk = undefined;")
        case "canvas": try evaluate(context, "captureMode = 'unavailable';")
        default: try evaluate(context, "contextMode = 'unavailable';")
        }
        try evaluate(context, "begin(); chooseOwn();")
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == "AbortError")
        #expect(try number(context, "nativeCalls") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback').length") == 0)
        #expect(try number(context, "timers.size") == 0)
        #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].end('own-id')") == false)
    }

    @Test func aTabPlayingVideoKeepsItsFrames() throws {
        let context = try page()
        try evaluate(context, "begin(); prepareOwn('own-id'); api.answer(requestToken, { choice: 'own', id: 'own-id', surface: 'browser', motion: true, label: 'Shared tab', width: 1200, height: 800 }); sendFormat(); decoders[0].emit(new Frame());")
        #expect(try word(context, "settled") == "resolved")
        // With 'detail', a YouTube tab reached Meet at 5 frames a second.
        #expect(try boolean(context, "result.getVideoTracks()[0].contentHint !== 'detail'"))
    }

    @Test func ownTrackKeepsSettingsAndStopClosesTheCapture() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn(); sendFormat(); decoders[0].emit(new Frame());")
        try evaluate(context, "var ownTrack = result.getVideoTracks()[0];")
        #expect(try word(context, "settled") == "resolved")
        #expect(try number(context, "resolutions") == 1)
        #expect(try number(context, "rejections") == 0)
        #expect(try word(context, "ownTrack.label") == "Shared tab")
        // A still tab keeps its size (request 1030).
        #expect(try word(context, "ownTrack.contentHint") == "detail")
        #expect(try boolean(context, "ownTrack.getSettings().displaySurface === 'browser' && ownTrack.getSettings().logicalSurface === true && ownTrack.getSettings().cursor === 'always'"))
        #expect(try number(context, "ownTrack.getSettings().width") == 1200)
        #expect(try number(context, "ownTrack.getSettings().height") == 800)
        #expect(try number(context, "ownTrack.getSettings().frameRate") == 30)
        #expect(try boolean(context, "api.system(requestToken)") == false)

        try evaluate(context, "ownTrack.stop(); ownTrack.stop(); var lateFrame = new Frame(); decoders[0].emit(lateFrame);")
        #expect(try number(context, "messages.filter(m => m.kind === 'stop' && m.id === 'own-id').length") == 1)
        #expect(try number(context, "decoders[0].closes") == 1)
        #expect(try word(context, "ownTrack.readyState") == "ended")
        #expect(try number(context, "lateFrame.closes") == 1)
        #expect(try number(context, "draws.length") == 1)
        #expect(try boolean(context, "api.feed('own-id', 'end')") == false)
    }

    @Test(arguments: ["error", "draw"])
    func failureAfterReadinessEndsTheAcceptedTrackOnce(failure: String) throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn(); sendFormat(); decoders[0].emit(new Frame());")
        try evaluate(context, "var ownTrack = result.getVideoTracks()[0];")
        if failure == "draw" {
            try evaluate(context, "drawMode = 'throws'; var failedFrame = new Frame(); decoders[0].emit(failedFrame);")
            #expect(try number(context, "failedFrame.closes") == 1)
        } else {
            try evaluate(context, "decoders[0].fail(new Error('Decoder asynchronous failure'));")
        }
        try evaluate(context, "decoders[0].fail(new Error('Late error')); var lateFrame = new Frame(); decoders[0].emit(lateFrame);")
        #expect(try word(context, "settled") == "resolved")
        #expect(try number(context, "resolutions") == 1)
        #expect(try number(context, "rejections") == 0)
        #expect(try word(context, "ownTrack.readyState") == "ended")
        #expect(try number(context, "ownTrack.events.filter(e => e === 'ended').length") == 1)
        #expect(try number(context, "decoders[0].closes") == 1)
        #expect(try number(context, "lateFrame.closes") == 1)
        #expect(try number(context, "messages.filter(m => m.kind === 'stop' && m.id === 'own-id').length") == 1)
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback').length") == 0)
    }

    @Test(arguments: ["window", "monitor"])
    func otherSurfacesCanFallBackWhenCanvasCaptureFails(surface: String) throws {
        let context = try page()
        try evaluate(context, "captureMode = 'throws'; begin();")
        #expect(try boolean(context, "chooseOwn('\(surface)')"))
        #expect(try number(context, "captureAttempts") == 1)
        try expectFallback(context)
        try acceptSystemPicker(context)
    }

    @Test func windowStartupTimeoutFallsBackOnlyOnceAndClosesTheTrack() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn('window'); var expiredStartup = Array.from(timers.values())[0]; expiredStartup(); expiredStartup();")
        #expect(try word(context, "canvasStreams[0].getVideoTracks()[0].readyState") == "ended")
        try expectFallback(context)
        try acceptSystemPicker(context)
    }

    @Test(arguments: ["prepared", "unprepared"])
    func nativeEndBeforePageAnswerRejectsTheWaitingToken(preparation: String) throws {
        let context = try page()
        try evaluate(context, "begin();")
        if preparation == "prepared" {
            #expect(try boolean(context, "prepareOwn('own-id')"))
            #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].end('own-id')"))
        }
        #expect(try boolean(context, "api.end('own-id', requestToken)"))
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == "AbortError")

        // A queued preparation can finish after native Stop. Its stale
        // callback disposes the new capture instead of answering own.
        if preparation == "unprepared" {
            #expect(try boolean(context, "prepareOwn('own-id')"))
            #expect(try boolean(context, "bridgeWindow[Symbol.for('yab.share.worker')].end('own-id')"))
        }
        #expect(try boolean(context, "api.answer(requestToken, { choice: 'own', id: 'own-id', surface: 'browser' })") == false)
        #expect(try boolean(context, "api.end('own-id', requestToken)") == false)
        #expect(try boolean(context, "api.system(requestToken)") == false)
        #expect(try word(context, "canvasStreams[0].getVideoTracks()[0].readyState") == "ended")
        #expect(try number(context, "decoders.length") == 0)
        #expect(try number(context, "rejections") == 1)
        #expect(try number(context, "resolutions") == 0)
        #expect(try number(context, "timers.size") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback').length") == 0)
        #expect(try number(context, "nativeCalls") == 0)
    }

    @Test func captureEndingBeforeReadinessRejectsThePendingPromise() throws {
        let context = try page()
        try evaluate(context, "begin(); chooseOwn(); sendFormat();")
        #expect(try boolean(context, "api.feed('own-id', 'end')"))
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == "AbortError")
        #expect(try number(context, "rejections") == 1)
        #expect(try number(context, "decoders[0].closes") == 1)
        #expect(try number(context, "timers.size") == 0)
        try evaluate(context, "var lateFrame = new Frame(); decoders[0].emit(lateFrame);")
        #expect(try number(context, "lateFrame.closes") == 1)
        #expect(try number(context, "resolutions + carriers.length") == 0)
        #expect(try number(context, "messages.filter(m => m.kind === 'fallback').length") == 0)
        #expect(try boolean(context, "api.system(requestToken)") == false)
    }

    @Test func captureEndingBeforeFallbackIsConsumedRejectsThePromise() throws {
        let context = try page()
        try evaluate(context, "captureMode = 'throws'; begin(); chooseOwn('window');")
        try expectFallback(context)
        #expect(try boolean(context, "api.feed('own-id', 'end')"))
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == "AbortError")
        #expect(try number(context, "rejections") == 1)
        #expect(try number(context, "resolutions") == 0)
        #expect(try boolean(context, "api.system(requestToken)") == false)
        #expect(try number(context, "nativeCalls") == 0)
        #expect(try boolean(context, "api.feed('own-id', 'end')") == false)
    }

    @Test func cancellingFallbackClearsTheFailedShareAndRejectsOnce() throws {
        let context = try page()
        try evaluate(context, "captureMode = 'throws'; begin(); chooseOwn('window');")
        try expectFallback(context)
        #expect(try boolean(context, "api.answer(requestToken, { choice: 'cancel' })"))
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == "NotAllowedError")
        #expect(try number(context, "rejections") == 1)
        #expect(try boolean(context, "api.feed('own-id', 'chunk', '', true, 0)") == false)
        #expect(try boolean(context, "api.feed('own-id', 'end')") == false)
        #expect(try boolean(context, "api.system(requestToken)") == false)
        #expect(try boolean(context, "api.answer(requestToken, { choice: 'cancel' })") == false)
        #expect(try number(context, "nativeCalls") == 0)
    }

    @Test(arguments: ["gesture", "video"])
    func invalidRequestsRejectBeforeOpeningAPicker(reason: String) throws {
        let context = try page()
        try evaluate(context, reason == "gesture"
                     ? "navigator.userActivation.isActive = false; begin();"
                     : "requestConstraints.video = false; begin();")
        #expect(try word(context, "settled") == "rejected")
        #expect(try word(context, "rejection.name") == (reason == "gesture" ? "InvalidStateError" : "TypeError"))
        #expect(try number(context, "rejections") == 1)
        #expect(try number(context, "messages.length") == 0)
        #expect(try number(context, "captureAttempts + decoders.length") == 0)
        #expect(try number(context, "nativeCalls") == 0)
    }

    @Test(arguments: ["reject", "throw"])
    func systemFailureSettlesTheOriginalPromise(mode: String) throws {
        let context = try page()
        try evaluate(context, "captureMode = 'throws'; nativeMode = '\(mode)'; begin(); chooseOwn('window');")
        try expectFallback(context)
        #expect(try boolean(context, "api.system(requestToken)"))
        if mode == "reject" {
            #expect(try word(context, "settled") == "pending")
            try evaluate(context, "nativeReject(new DOMException('Native denied', 'NotAllowedError'));")
        }
        #expect(try word(context, "settled") == "rejected")
        #expect(try number(context, "resolutions") == 0)
        #expect(try number(context, "rejections") == 1)
        #expect(try word(context, "rejection.name") == "NotAllowedError")
        #expect(try number(context, "nativeCalls") == 1)
        #expect(try boolean(context, "nativeConstraints === requestConstraints"))
        #expect(try boolean(context, "nativeReceiver === navigator.mediaDevices"))
        #expect(try boolean(context, "api.system(requestToken)") == false)
        #expect(try number(context, "messages.filter(m => m.kind === 'started').length") == 0)
    }

    private static let fixture = #"""
    var window = this;
    var messages = [], workerAttempts = 0, pageWorkerAttempts = 0;
    var canvases = [], canvasStreams = [], captureAttempts = 0, captureMode = 'manual';
    var contextMode = 'manual', drawMode = 'manual', draws = [];
    var decoders = [], decoderMode = 'manual';
    var imageDecodes = [];
    function Blob(parts, options) { this.parts = parts; this.type = options.type; }
    function createImageBitmap(blob) {
      return new Promise(function (resolve, reject) { imageDecodes.push({blob:blob, resolve:resolve, reject:reject}); });
    }
    var timers = new Map(), timerDelays = new Map(), timerSequence = 0;
    function setTimeout(callback, delay) { var id = ++timerSequence; timers.set(id, callback); timerDelays.set(id, delay || 0); return id; }
    function clearTimeout(id) { timers.delete(id); timerDelays.delete(id); }
    function runRedraw() {
      var queued = Array.from(timerDelays).filter(function (entry) { return entry[1] === 0; });
      queued.forEach(function (entry) { var callback = timers.get(entry[0]); clearTimeout(entry[0]); if (callback) callback(); });
      return queued.length;
    }
    function CustomEvent(type, options) { this.type = type; this.detail = options.detail; this.bubbles = !!options.bubbles; }
    function Event(type) { this.type = type; }
    var eventListeners = {};
    window.addEventListener = function (type, listener) { (eventListeners[type] || (eventListeners[type] = [])).push(listener); };
    window.removeEventListener = function (type, listener) {
      eventListeners[type] = (eventListeners[type] || []).filter(function (item) { return item !== listener; });
    };
    window.dispatchEvent = function (event) {
      if (!event.target) event.target = window;
      (eventListeners[event.type] || []).slice().forEach(function (listener) { listener(event); });
      return true;
    };
    var bridgeWindow = {
      addEventListener: window.addEventListener,
      removeEventListener: window.removeEventListener,
      dispatchEvent: window.dispatchEvent,
      webkit: { messageHandlers: { yabShare: { postMessage: function (message) { messages.push(message); } } } }
    };
    var carriers = [], carrierReads = 0;
    var document = {
      documentElement: { children: [], appendChild: function (node) { this.children.push(node); } },
      createElement: function (tag) {
        if (tag === 'canvas') {
          var canvas = {
            width: 300, height: 150,
            getContext: function (kind) {
              if (contextMode === 'unavailable' || kind !== '2d') return null;
              return { drawImage: function (frame) {
                if (drawMode === 'throws') throw new Error('Canvas draw failed');
                draws.push({ frame: frame, canvas: canvas, arguments: Array.from(arguments).slice(1) });
              } };
            },
            captureStream: function (rate) {
              captureAttempts++; this.captureRate = rate;
              if (captureMode === 'throws') throw new Error('Canvas capture failed');
              var stream = new MediaStream([new MediaStreamTrack()]);
              canvasStreams.push(stream); return stream;
            }
          };
          if (captureMode === 'unavailable') canvas.captureStream = undefined;
          canvases.push(canvas); return canvas;
        }
        if (tag !== 'video' && tag !== 'audio') throw new Error('Unexpected fixture element: ' + tag);
        var node = {
          tagName: tag.toUpperCase(), hidden: false, removed: false, stream: null,
          dispatchEvent: function (event) { event.target = this; return window.dispatchEvent(event); },
          remove: function () {
            this.removed = true;
            document.documentElement.children = document.documentElement.children.filter(function (item) { return item !== node; });
          }
        };
        Object.defineProperty(node, 'srcObject', {
          get: function () { if (this.stream) carrierReads++; return this.stream; },
          set: function (value) { this.stream = value; }
        });
        carriers.push(node); return node;
      }
    };
    function DOMException(message, name) { this.message = message; this.name = name; }
    DOMException.prototype = Object.create(Error.prototype);
    function atob(value) {
      if (value === '') return '';
      if (value === 'AQID') return String.fromCharCode(1, 2, 3);
      throw new Error('Unexpected fixture base64');
    }
    function Worker() { pageWorkerAttempts++; throw new TypeError('This assignment requires a TrustedScriptURL'); }
    function ForbiddenWorker() { workerAttempts++; throw new Error('Canvas capture must not construct a Worker'); }
    function VideoDecoder(options) {
      if (decoderMode === 'constructor-throws') throw new Error('Decoder constructor failed');
      this.options = options; this.state = 'unconfigured'; this.configurations = []; this.chunks = []; this.closes = 0; this.decodeQueueSize = 0;
      decoders.push(this);
    }
    VideoDecoder.prototype.configure = function (config) {
      this.configurations.push(config);
      if (decoderMode === 'configure-throws') throw new Error('Decoder configure failed');
      this.state = 'configured';
    };
    VideoDecoder.prototype.decode = function (chunk) {
      this.chunks.push(chunk);
      if (decoderMode === 'decode-throws') throw new Error('Decoder decode failed');
    };
    VideoDecoder.prototype.close = function () { this.closes++; this.state = 'closed'; };
    VideoDecoder.prototype.emit = function (frame) { this.options.output(frame); };
    VideoDecoder.prototype.fail = function (error) { this.options.error(error); };
    function EncodedVideoChunk(options) { this.type = options.type; this.timestamp = options.timestamp; this.data = options.data; }
    function Frame() { this.displayWidth = this.codedWidth = 1200; this.displayHeight = this.codedHeight = 800; this.closes = 0; }
    Frame.prototype.close = function () { this.closes++; };
    function MediaStreamTrack() { this.readyState = 'live'; this.events = []; this.listeners = {}; this.requests = 0; }
    MediaStreamTrack.prototype.getSettings = function () { return {}; };
    MediaStreamTrack.prototype.requestFrame = function () { this.requests++; };
    MediaStreamTrack.prototype.stop = function () { this.readyState = 'ended'; };
    MediaStreamTrack.prototype.addEventListener = function (type, listener) { this.listeners[type] = listener; };
    MediaStreamTrack.prototype.dispatchEvent = function (event) {
      this.events.push(event.type);
      if (this.listeners[event.type]) this.listeners[event.type](event);
    };
    function MediaStream(tracks) { this.tracks = tracks; }
    MediaStream.prototype.getTracks = function () { return this.tracks; };
    MediaStream.prototype.getVideoTracks = function () { return this.tracks; };
    var nativeMode = 'resolve', nativeCalls = 0, nativeResolve = null, nativeReject = null;
    var nativeConstraints = null, nativeReceiver = null;
    function MediaDevices() {}
    MediaDevices.prototype.getDisplayMedia = function (constraints) {
      nativeCalls++; nativeConstraints = constraints; nativeReceiver = this;
      if (nativeMode === 'throw') throw new DOMException('Native denied', 'NotAllowedError');
      return new Promise(function (resolve, reject) { nativeResolve = resolve; nativeReject = reject; });
    };
    var navigator = { mediaDevices: new MediaDevices(), userActivation: { isActive: true } };
    var requestConstraints = { video: { displaySurface: 'monitor' }, audio: true, systemAudio: 'include' };
    var requestToken = null, settled = 'pending', resolutions = 0, rejections = 0, result = null, rejection = null;
    function begin() {
      navigator.mediaDevices.getDisplayMedia(requestConstraints).then(function (stream) {
        resolutions++; settled = 'resolved'; result = stream;
      }, function (error) {
        rejections++; settled = 'rejected'; rejection = error;
      });
      var question = messages.find(function (message) { return message.kind === 'ask'; });
      requestToken = question ? question.token : null;
    }
    function chooseOwn(surface) {
      prepareOwn('own-id');
      return api.answer(requestToken, { choice: 'own', id: 'own-id', surface: surface || 'browser', label: 'Shared tab', width: 1200, height: 800 });
    }
    function sendFormat() { return api.feed('own-id', 'format', 'AQID', 'avc1.64001e', 1200, 800); }
    function sendChunk(key, time) { return api.feed('own-id', 'chunk', 'AQID', key, time); }
    """#
}
