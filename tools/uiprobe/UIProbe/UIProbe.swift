import XCTest

/// Diagnostic only: windows growing out of the dock, frame by frame.
final class UIProbe: XCTestCase {

    func testProbe() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "/tmp/probe")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log = ""
        defer { try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8) }
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent("\(name).png"))
        }
        func burst(_ name: String, _ count: Int = 5) {
            for index in 0..<count { shot("\(name)-\(index)") }
        }

        let app = XCUIApplication()
        app.launch()
        let agree = app.buttons["Agree and continue"]
        if agree.waitForExistence(timeout: 15) { agree.tap() }
        sleep(30)
        shot("00-map")

        let style = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Map style'")).firstMatch
        log += "style exists \(style.exists)\n"
        if style.exists {
            style.tap()
            burst("01-modes-open")
            sleep(2)
            shot("02-modes-open-done")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            burst("03-modes-close")
            sleep(2)
            shot("04-modes-closed")
        }

        let field = app.textFields.firstMatch
        log += "field exists \(field.exists)\n"
        if field.exists {
            field.tap()
            sleep(1)
            field.typeText("EGLL")
            sleep(3)
            shot("05-search")
            let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS 'EGLL' OR label CONTAINS 'Heathrow'")).firstMatch
            let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Heathrow'")).firstMatch
            log += "hit \(hit.exists) text \(text.exists)\n"
            if hit.exists { hit.tap() } else if text.exists { text.tap() }
            burst("06-airport-open")
            sleep(3)
            shot("07-airport-open-done")
            let close = app.buttons["Close the airport panel"]
            let closeOther = app.otherElements["Close the airport panel"]
            log += "close \(close.exists) other \(closeOther.exists)\n"
            if close.exists { close.tap() } else if closeOther.exists { closeOther.tap() }
            burst("08-airport-close")
            sleep(2)
            shot("09-airport-closed")
        }
    }
}
