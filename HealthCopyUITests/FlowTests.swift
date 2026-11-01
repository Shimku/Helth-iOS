import XCTest

/// Drives one debug run of the app (arguments come from HC_ARGS) and answers Health's
/// permission screen the way a person would: Turn On All, then Allow.
final class FlowTests: XCTestCase {
    @MainActor
    func testFlow() throws {
        let args = ProcessInfo.processInfo.environment["HC_ARGS"] ?? ""
        let app = XCUIApplication()
        app.launchArguments = args.split(separator: " ").map(String.init)
        XCTContext.runActivity(named: "HC args: \(args)") { _ in }
        app.launch()
        let status = app.staticTexts["debug-status"]
        let deadline = Date().addingTimeInterval(3000)
        var label = ""
        var selected = false
        while Date() < deadline {
            if status.exists {
                label = status.label
                if label.hasPrefix("debug-done") || label.hasPrefix("debug-failed") { break }
            }
            answerHealthSheet(app, &selected)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTContext.runActivity(named: "HC_STATUS \(label)") { _ in }
        // Screenshots of the final screen, top and scrolled, for checking the layout.
        for n in 0..<3 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "screen-\(n)"
            shot.lifetime = .keepAlways
            add(shot)
            app.swipeUp()
        }
        XCTAssertTrue(label.hasPrefix("debug-done"), label)
    }

    /// Home screen scrolled to the bottom, for screenshots.
    @MainActor
    func testHomeBottom() throws {
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<3 { app.swipeUp() }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-bottom"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// iOS 17-26 say "Turn On All" and put Allow at the top; iOS 27 says "Select All N Topics",
    /// puts Continue and Allow below the list, and asks how much history to share. The sheet is
    /// drawn by another process and can change between two lookups, which ends the test;
    /// scripts/run.sh simply runs it again.
    @MainActor
    private func answerHealthSheet(_ app: XCUIApplication, _ selected: inout Bool) {
        let any = app.descendants(matching: .any)
        let all = any.matching(NSPredicate(format: "label == 'Turn On All' OR label BEGINSWITH 'Select All'")).firstMatch
        if all.exists && all.isHittable { all.tap(); selected = true; return }
        let allow = app.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == 'Continue'")).firstMatch
        let allowThere = allow.exists
        if allowThere && allow.isEnabled && allow.isHittable { allow.tap(); selected = false; return }
        let history = any.matching(NSPredicate(format: "label BEGINSWITH 'All Recorded Data'")).firstMatch
        if history.exists && history.isHittable { history.tap(); return }
        guard selected || allowThere else { return }
        // On iPhone Duo's inner display a swipe on the whole app doesn't scroll the sheet, so
        // fling from a point below the sheet's title, which stays put while the list scrolls.
        let title = app.staticTexts["Health Access"].firstMatch
        if title.exists {
            let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 450))
            for _ in 0..<5 {
                start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -350)),
                            withVelocity: .fast, thenHoldForDuration: 0)
            }
        } else {
            for _ in 0..<5 { app.swipeUp(velocity: XCUIGestureVelocity(6000)) }
        }
    }
}
