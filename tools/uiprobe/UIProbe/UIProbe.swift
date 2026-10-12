import XCTest

/// Diagnostic only: 3D buildings over Midtown, and the flight window opening
/// and closing on a slowed spring.
final class UIProbe: XCTestCase {

    func testProbe() throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["PROBE_OUT"] ?? "/tmp/probe")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log = ""
        defer { try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8) }
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent("\(name).png"))
        }

        let app = XCUIApplication()
        app.launch()
        let agree = app.buttons["Agree and continue"]
        if agree.waitForExistence(timeout: 15) { agree.tap() }

        guard env["PROBE_KIND"] == "motion" else {
            // The app moves the camera to Midtown itself, 30s after the map loads.
            sleep(55)
            shot("01-midtown")
            return
        }

        sleep(30)
        let field = app.textFields.firstMatch
        log += "field \(field.exists)\n"
        guard field.exists else { shot("00-no-field"); return }
        for _ in 0..<4 where app.keyboards.count == 0 {
            field.tap()
            sleep(2)
        }
        log += "keyboard \(app.keyboards.count)\n"
        guard app.keyboards.count > 0 else { shot("00-no-keyboard"); return }
        field.typeText("EGLL")
        sleep(4)
        let flight = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Airbus' OR label CONTAINS 'Boeing'")).firstMatch
        log += "flight row \(flight.exists)\n"
        guard flight.exists else {
            shot("00-no-flight")
            try? app.debugDescription.write(to: out.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
            return
        }
        flight.tap()
        for i in 0..<7 { shot("10-open-\(i)"); usleep(300_000) }
        sleep(6)
        shot("19-open-done")

        let grabber = app.buttons["Close the flight window"]
        log += "grabber \(grabber.exists)\n"
        guard grabber.exists else {
            try? app.debugDescription.write(to: out.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
            return
        }
        grabber.tap()
        for i in 0..<7 { shot("20-close-\(i)"); usleep(300_000) }
        sleep(6)
        shot("29-close-done")
    }
}
