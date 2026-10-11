import XCTest

/// Diagnostic only: the dock at each stop with panels open.
final class UIProbe: XCTestCase {

    private var out: URL!
    private var log = ""

    private func note(_ line: String) {
        log += line + "\n"
        print("PROBE: " + line)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: out.appendingPathComponent("\(name).png"))
    }

    private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    func testProbe() throws {
        let path = ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "/tmp/probe"
        out = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8) }

        let app = XCUIApplication()
        app.launch()

        let agree = app.buttons["Agree and continue"]
        if agree.waitForExistence(timeout: 15) { agree.tap() }

        sleep(20)
        shot("01-map")
        note("hint on map: \(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hint'")).count)")

        button(app, "Settings").tap()
        sleep(2)
        shot("02-settings-half")

        let expand = app.buttons["Expand"]
        note("expand exists: \(expand.exists)")
        if expand.exists { expand.tap() }
        sleep(2)
        shot("03-settings-full")

        button(app, "Filters").tap()
        sleep(2)
        shot("04-filters-full")
        app.swipeUp()
        sleep(1)
        shot("05-filters-scrolled")

        button(app, "Filters").tap()
        sleep(2)
        shot("06-lists-full")

        let collapse = app.buttons["Collapse"]
        note("collapse exists: \(collapse.exists)")
        if collapse.exists { collapse.tap() }
        sleep(2)
        shot("07-collapsed")
    }
}
