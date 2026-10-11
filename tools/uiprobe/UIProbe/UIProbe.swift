import XCTest

/// Diagnostic only: is the traffic drawn?
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
        sleep(25)
        shot("01-25s")
        sleep(15)
        shot("02-40s")
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.36))
        for _ in 0..<4 { target.doubleTap(); sleep(2) }
        sleep(10)
        shot("03-zoomed")
    }
}
