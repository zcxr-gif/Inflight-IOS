import XCTest

/// Diagnostic only: field pins over the traffic.
final class UIProbe: XCTestCase {

    func testProbe() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "/tmp/probe")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent("\(name).png"))
        }

        let app = XCUIApplication()
        app.launch()
        let agree = app.buttons["Agree and continue"]
        if agree.waitForExistence(timeout: 15) { agree.tap() }
        sleep(40)
        let europe = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.36))
        for _ in 0..<5 { europe.doubleTap(); sleep(2) }
        sleep(12)
        shot("01-z6.8")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.12)).doubleTap()
        sleep(12)
        shot("02-z7.8")
    }
}
