import UIKit
import XCTest
@testable import YabPhone

final class BottomEdgeUnfoldTests: XCTestCase {
    @MainActor
    func testWholeSafeBottomEdgeOnEitherSideAndOrientation() {
        for size in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466)] {
            for left in [false, true] {
                let insets = UIEdgeInsets(top: 0, left: left ? 84 : 0, bottom: 34, right: left ? 0 : 84)
                let region = BottomEdgeUnfold.region(in: CGRect(origin: .zero, size: size), insets: insets)
                for x in [0.15, 0.5, 0.85] {
                    let point = CGPoint(x: insets.left + (size.width - 84) * x, y: size.height - insets.bottom - 5)
                    XCTAssertTrue(region.contains(point))
                    XCTAssertFalse(region.contains(CGPoint(x: point.x, y: region.minY - 1)))
                }
                XCTAssertFalse(region.contains(CGPoint(x: left ? 40 : size.width - 40, y: size.height - 40)))
            }
        }
    }
    @MainActor
    func testOnlyAnUpwardEdgeGestureOnTheCurrentUncoveredPageUnfolds() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let root = try XCTUnwrap(window.rootViewController?.view)
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let page = PageContainer(frame: root.bounds)
        let owner = UIView(frame: root.bounds)
        root.addSubview(page)
        root.addSubview(owner)
        let gesture = BottomEdgeUnfold(app: app)
        gesture.owner = owner
        gesture.install(on: window)
        defer { gesture.uninstall() }
        let edge = try XCTUnwrap(window.gestureRecognizers?.first(where: { $0.delegate === gesture }))
        let plateDrag = UIPanGestureRecognizer()
        owner.addGestureRecognizer(plateDrag)
        XCTAssertTrue(gesture.gestureRecognizer(edge, shouldBeRequiredToFailBy: plateDrag),
                      "the folded plate's lift waits for the bottom edge")
        let unrelated = UIPanGestureRecognizer()
        root.addGestureRecognizer(unrelated)
        XCTAssertFalse(gesture.gestureRecognizer(edge, shouldBeRequiredToFailBy: unrelated))
        let point = CGPoint(x: window.bounds.midX, y: window.bounds.maxY - window.safeAreaInsets.bottom - 5)
        app.chrome.setFolded(true)
        XCTAssertTrue(gesture.receive(at: point, touched: page, in: window))
        XCTAssertFalse(gesture.begin(velocity: CGPoint(x: 0, y: 300)))
        XCTAssertFalse(gesture.begin(velocity: CGPoint(x: 300, y: -20)))
        XCTAssertTrue(gesture.begin(velocity: CGPoint(x: 0, y: -300)))
        gesture.follow(.began)
        XCTAssertFalse(app.chrome.folded)
        app.chrome.setFolded(true)
        gesture.follow(.ended)
        XCTAssertFalse(app.chrome.folded, "page scrolling during the gesture cannot leave the plate folded")
        XCTAssertFalse(gesture.receive(at: point, touched: page, in: window), "expanded chrome retains its existing gestures")
        app.chrome.setFolded(true)
        XCTAssertFalse(gesture.receive(at: CGPoint(x: point.x, y: 100), touched: page, in: window))
        XCTAssertFalse(gesture.receive(at: point, touched: root, in: window), "unrelated mounted surfaces keep their touches")
        app.surfaces.settings = true
        XCTAssertFalse(gesture.receive(at: point, touched: page, in: window))
        app.surfaces.settings = false
        XCTAssertTrue(gesture.receive(at: point, touched: page, in: window))
        app.surfaces.settings = true
        gesture.follow(.ended)
        XCTAssertTrue(app.chrome.folded, "a surface opened during the gesture revokes it")
    }

}
