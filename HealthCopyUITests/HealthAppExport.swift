import XCTest

/// Makes Apple's own export (Health > profile > Export All Health Data) in the simulator, so
/// the Apple export reader can be tested on the real thing. scripts/apple-export.sh runs it
/// and collects export.zip afterwards.
final class HealthAppExport: XCTestCase {
    @MainActor
    func testHealthAppExport() throws {
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        health.launch()
        let deadline = Date().addingTimeInterval(900)
        var exported = false
        var lastDump = Date.distantPast
        while Date() < deadline {
            if Date().timeIntervalSince(lastDump) > 10 {
                lastDump = Date()
                let labels = health.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }
                print("HCX buttons: \(labels)")
                let texts = health.staticTexts.allElementsBoundByIndex.prefix(20).map { $0.label }
                print("HCX texts: \(texts)")
            }
            // A share sheet means the export is written.
            if exported, health.otherElements["ActivityListView"].exists || health.buttons["Save to Files"].exists
                || health.cells["Save to Files"].exists || health.navigationBars["UIActivityContentView"].exists {
                print("HCX share sheet up")
                Thread.sleep(forTimeInterval: 3)
                return
            }
            if tapFirst(health, ["Export", "Export All Health Data"]) {
                print("HCX tapped export")
                exported = true
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            if !exported, tapFirst(health, ["Continue", "Get Started", "Next", "Not Now", "Set Up Later", "Skip", "Done", "OK", "Allow", "Don't Allow", "Turn On", "Later"]) {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            // Profile picture, top right of Summary.
            let profile = health.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'profile' OR label CONTAINS[c] 'account' OR identifier CONTAINS[c] 'profile'")).firstMatch
            if !exported, profile.exists, profile.isHittable { print("HCX tapped profile"); profile.tap(); Thread.sleep(forTimeInterval: 1); continue }
            let summary = health.buttons["Summary"]
            if !exported, summary.exists, summary.isHittable, !profile.exists { summary.tap(); Thread.sleep(forTimeInterval: 1); continue }
            if !exported { health.swipeUp() }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("export never finished")
    }

    @MainActor
    private func tapFirst(_ app: XCUIApplication, _ labels: [String]) -> Bool {
        for l in labels {
            for q in [app.buttons[l], app.staticTexts[l], app.cells[l]] where q.exists && q.isHittable {
                print("HCX tap \(l)")
                q.tap()
                return true
            }
        }
        return false
    }
}
