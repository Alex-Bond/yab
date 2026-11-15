import XCTest
@testable import YabPhone

/// The first run as one chain (Welcome/FirstRun): the way through, what ‹
/// undoes, the hero each path carries, and the pieces the prototype's
/// geometry is drawn from.
@MainActor
final class FirstRunChainTests: XCTestCase {
    private var motion = false

    override func setUp() {
        motion = Motion.disabled
        Motion.disabled = true
        FirstRun.shared.reset()
        SettingsStore.shared.blocksAds = true
    }

    override func tearDown() {
        FirstRun.shared.reset()
        Motion.disabled = motion
    }

    private func world() -> AppModel {
        let empty = try! World.load(named: "empty")
        let app = AppModel(world: empty, fixturesEnabled: false, privateLockEnabled: { false })
        app.sync.pretend(.off, sheet: false)
        return app
    }

    func testWithoutAMacGoesByTheGlobeToPrivacyAndBack() {
        let app = world()
        let run = FirstRun.shared
        run.begin(app)
        XCTAssertEqual(run.step, .welcome)
        XCTAssertTrue(run.worded, "with motion off the welcome is there at once")
        run.getStarted(app)
        XCTAssertEqual(run.step, .mac)
        XCTAssertEqual(run.drop, .back, "the drop went into ‹")
        run.useWithoutMac(app)
        XCTAssertEqual(run.step, .privacy)
        XCTAssertEqual(run.hero, .globe, "the globe is what Continue Without a Mac carried")
        XCTAssertTrue(SettingsStore.shared.withoutMac)
        run.back(app)
        XCTAssertEqual(run.step, .mac, "‹ undoes the step")
        XCTAssertFalse(SettingsStore.shared.withoutMac, "‹ undoes Without a Mac too")
        XCTAssertTrue(app.sync.asksOnFront)
    }

    func testAnotherAppleIDOpensTheKeyIntoTheCardAndBack() {
        let app = world()
        let run = FirstRun.shared
        run.begin(app)
        run.getStarted(app)
        run.useCode(app)
        XCTAssertEqual(run.step, .code)
        XCTAssertEqual(run.hero, .key)
        XCTAssertTrue(run.capsFly, "the keycaps fly out of the key the first time")
        XCTAssertEqual(run.keyTurns, 1, "the key turns like a key in a lock")
        if case .joining(.code) = app.sync.phase {} else { XCTFail("no code is being asked for: \(app.sync.phase)") }
        run.useRecoveryKey(app)
        XCTAssertEqual(run.step, .recovery)
        XCTAssertEqual(app.sync.phase, .joining(.recovery(wrong: false)))
        run.back(app)
        XCTAssertEqual(run.step, .code, "‹ from the Recovery Key is the code")
        run.back(app)
        XCTAssertEqual(run.step, .mac)
        XCTAssertEqual(run.trail, [.welcome], "the way back is the way in")
    }

    func testTheMacFoundIsJoinedWithoutAJoiningScreen() {
        let app = world()
        let run = FirstRun.shared
        run.begin(app)
        run.getStarted(app)
        app.sync.pretend(.on, sheet: false)
        run.settle(app)
        XCTAssertEqual(run.mac, .insync, "in sync with no iCloud join of this launch")
        run.join(app)
        XCTAssertEqual(run.step, .privacy, "Join goes straight on, no Joining screen")
        XCTAssertEqual(run.hero, .tabs, "the Mac's drawing carries on as the shield")
        XCTAssertEqual(run.hops, 1)
    }

    func testTheCodeAcceptedKeepsTheKeyAndOffersNoWayBack() {
        let app = world()
        let run = FirstRun.shared
        run.pretend(.code, .init(mac: .none, hero: .key))
        run.holds = false
        run.succeed(app)
        XCTAssertTrue(run.accepted, "the Mac let the code in")
        XCTAssertEqual(run.hero, .key, "the key carries on to the shield")
        // With motion off every wait is over at once: the shield is next.
        XCTAssertEqual(run.step, .privacy, "a joined code goes on to Private by Default")
        XCTAssertEqual(run.drop, .back, "no logo on the way")
    }

    func testWrongRecoveryKeysCount() {
        let app = world()
        let run = FirstRun.shared
        run.pretend(.recovery, .init(mac: .none, hero: .key))
        run.holds = false
        app.sync.typed = "NOPE-NOPE"
        run.tryRecovery(app)
        XCTAssertEqual(run.wrongs, 1)
        XCTAssertEqual(app.sync.phase, .joining(.recovery(wrong: true)))
        XCTAssertFalse(run.accepted)
    }

    func testBlockingOffLetsTheTrackersStayAndCountsNothing() {
        let run = FirstRun.shared
        run.pretend(.privacy, .init(trackers: .thrown, thrownBack: 4))
        run.holds = false
        run.setBlocking(false)
        XCTAssertFalse(SettingsStore.shared.blocksAds)
        XCTAssertEqual(run.thrownBack, 0, "nothing is thrown back when nothing blocks")
        XCTAssertTrue(run.trackers.allSatisfy { $0 == .at }, "they come and stay around the shield")
    }

    func testTheDefaultBrowserStepIsTheOnlyPlaceTheDropComesBack() {
        let run = FirstRun.shared
        for step in [FirstRun.Step.mac, .code, .recovery, .privacy] {
            run.pretend(step)
            XCTAssertEqual(run.drop, .back, "\(step) must not show the logo")
        }
        run.pretend(.makeDefault)
        XCTAssertEqual(run.drop, .icon, "the app icon is the drop's other place")
        run.pretend(.welcome)
        XCTAssertEqual(run.drop, .welcome)
        run.pretend(.end)
        XCTAssertEqual(run.drop, .eyes, "the drop ends as the field's eyes")
    }

    func testEveryStateOfTheChainIsNamedAndDistinct() {
        let names = StateCatalog.welcome.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for name in ["welcome.1", "welcome.5", "welcome.9", "welcome.13", "welcome.16", "welcome.18", "welcome.21"] {
            XCTAssertNotNil(StateCatalog.named(name), name)
        }
    }

    // MARK: - the drawing's geometry

    func testTheSmallPiecesStayOnEveryStepAndTheLargeOnesLeave() {
        let small = ChainGeo.smallOnes
        XCTAssertEqual(small.count, 10, "ten small pieces, as the prototype's two sets hold")
        for i in small {
            let pose = FieldSticker.pose(i, .privacy, burst: true)
            XCTAssertEqual(pose.box.o, 1, accuracy: 0.001, "a small piece stays")
        }
        let large = ChainGeo.field24.indices.filter { !ChainGeo.field24[$0].small && !Set(FirstRun.Drawing.allCases.map(ChainGeo.home)).contains($0) }
        for i in large {
            XCTAssertEqual(FieldSticker.pose(i, .privacy, burst: true).box.o, 0, "a large drawing leaves")
        }
    }

    func testTheRecoveryKeySplitsIntoGroupsOfFour() {
        XCTAssertEqual(RecoveryCard.parts("MZ4Q-81TC-7H"), ["MZ4Q", "81TC", "7H"])
        XCTAssertEqual(RecoveryCard.parts("mz4q81tc"), ["MZ4Q", "81TC"])
        XCTAssertEqual(RecoveryCard.parts(""), [])
        XCTAssertEqual(RecoveryCard.parts(String(repeating: "A", count: 80)).count, RecoveryCard.groups)
        XCTAssertEqual(RecoveryCard.caret(["MZ4Q", "81"]), 1, "the caret is in the group being typed")
        XCTAssertEqual(RecoveryCard.caret(["MZ4Q"]), 1, "a full group moves the caret on")
    }

    func testEveryPenDrawingTheChainAsksForIsThere() {
        for drawing in FirstRun.Drawing.allCases {
            let pen = ChainGeo.pen(drawing)
            XCTAssertNotNil(FirstRunPenArt.path(pen.ink, marker: false), pen.ink)
            XCTAssertNotNil(FirstRunPenArt.path(pen.marker, marker: true), pen.marker)
        }
        for sticker in ChainGeo.field24 {
            if let ink = sticker.ink { XCTAssertNotNil(FirstRunPenArt.path(ink, marker: false), ink) }
            if let marker = sticker.marker { XCTAssertNotNil(FirstRunPenArt.path(marker, marker: true), marker) }
        }
        for name in ["privacy", "watch", "spark"] {
            XCTAssertNotNil(FirstRunPenArt.path(name, marker: false), name)
        }
        for layer in ["blob", "cheek", "face", "eye"] {
            XCTAssertNotNil(FirstRunPenArt.mark(layer), layer)
        }
    }

    /// The window pins the first run to the default text size
    /// (YabPhoneApp: traitOverrides.preferredContentSizeCategory = .large),
    /// so Larger Text cannot clip it; were that lifted, a title still grows
    /// only to 1.45 and wraps to the two lines its box holds.
    func testATitleAtTheLargestTextSizeStillFitsItsBox() {
        let space = ChainSpace(CGSize(width: 402, height: 874), tablet: false, typeSize: .accessibility5)
        XCTAssertLessThanOrEqual(space.type, 1.7)
        for (text, size, cap, box) in [("Join Your Mac", 26.0, 1.45, 110.0), ("Type This on Your Mac", 28.0, 1.35, 96.0),
                                       ("Recovery Key", 28.0, 1.35, 96.0),
                                       ("Private by Default", 26.0, 1.45, 110.0), ("Make Yab Default?", 26.0, 1.45, 110.0)] {
            let grown = size * min(cap, space.type)
            let font = UIFont.systemFont(ofSize: grown, weight: .bold)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: 354, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
            XCTAssertLessThanOrEqual(measured.height, box, "\(text) at \(grown) pt needs \(measured.height) of \(box)")
            XCTAssertLessThanOrEqual(ceil(measured.height / font.lineHeight), 2, "\(text) wraps past two lines")
        }
    }

    func testTheStageFitsEveryScreenItIsDrawnOn() {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667), CGSize(width: 440, height: 956), CGSize(width: 1024, height: 1366)] {
            let space = ChainSpace(size, tablet: size.width > 700, typeSize: .large)
            XCTAssertGreaterThan(space.s, 0.5)
            XCTAssertLessThanOrEqual(space.x(402), size.width + 0.5, "\(size) cuts the stage off")
            XCTAssertLessThanOrEqual(space.y(874), size.height + 0.5, "\(size) cuts the stage off")
            XCTAssertGreaterThanOrEqual(space.x(0), -0.5)
        }
    }
}
