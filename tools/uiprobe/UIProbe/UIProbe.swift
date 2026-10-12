import XCTest

/// Diagnostic only: the two weather pills.
final class UIProbe: XCTestCase {

    func testProbe() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "/tmp/probe")
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
        sleep(30)

        let europe = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.36))
        for _ in 0..<5 { europe.doubleTap(); sleep(2) }
        sleep(10)
        shot("01-map-pill")

        try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        let field = app.textFields.firstMatch
        log += "field \(field.exists)\n"
        if field.exists {
            field.tap()
            sleep(1)
            field.typeText("EGLL")
            sleep(3)
            shot("02-search")
            let flight = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Airbus' OR label CONTAINS 'Boeing'")).firstMatch
            log += "flight row \(flight.exists)\n"
            if flight.exists { flight.tap() }
            sleep(10)
            shot("03-flight-chip")
        }
        try? app.debugDescription.write(to: out.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
    }
}
