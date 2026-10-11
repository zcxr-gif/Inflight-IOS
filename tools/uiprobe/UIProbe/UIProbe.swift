import XCTest

/// Diagnostic only: the field pins, close in over Dublin.
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
        for _ in 0..<4 { europe.doubleTap(); sleep(2) }
        sleep(4)
        shot("01-ireland")
        let dublin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.67, dy: 0.24))
        dublin.doubleTap()
        sleep(12)
        shot("02-dublin-z6.8")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        sleep(12)
        shot("03-z7.8")
    }
}
