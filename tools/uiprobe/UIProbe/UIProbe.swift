import XCTest

/// Diagnostic only: the field pins, zoomed in over north-west Europe.
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
        sleep(20)
        shot("01-world")

        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.40))
        for step in 0..<5 {
            target.doubleTap()
            sleep(2)
            shot("02-zoom-\(step + 1)")
        }
        sleep(10)
        shot("03-settled")
        target.doubleTap()
        sleep(10)
        shot("04-closer")
    }
}
