import XCTest

/// Diagnostic only: launches the app, waits for traffic, screenshots, and taps
/// every bar item and corner control, writing what it saw to $PROBE_OUT.
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
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testProbe() throws {
        let path = ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "/tmp/probe"
        out = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer {
            try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
            let attachment = XCTAttachment(string: log)
            attachment.name = "log"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let app = XCUIApplication()
        app.launch()

        let agree = app.buttons["Agree and continue"]
        if agree.waitForExistence(timeout: 15) {
            note("terms gate shown, agreeing")
            agree.tap()
        }

        sleep(25)
        shot("01-map")
        try? app.debugDescription.write(to: out.appendingPathComponent("tree-map.txt"), atomically: true, encoding: .utf8)

        for label in ["Friends", "ATC", "Airports", "Filters", "Settings"] {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            guard button.exists else {
                note("\(label): MISSING")
                continue
            }
            note("\(label): exists hittable=\(button.isHittable) frame=\(button.frame)")
            if button.isHittable {
                button.tap()
                sleep(2)
                shot("02-\(label)")
                try? app.debugDescription.write(to: out.appendingPathComponent("tree-\(label).txt"), atomically: true, encoding: .utf8)
                // Same item again puts it away.
                if button.isHittable { button.tap() }
                sleep(2)
            }
        }

        for label in ["Map style", "Measure a distance", "Point the camera at the sky", "Show 3D aircraft"] {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            guard button.exists else {
                note("\(label): MISSING")
                continue
            }
            note("\(label): exists hittable=\(button.isHittable) frame=\(button.frame)")
        }

        let style = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Map style")).firstMatch
        if style.exists, style.isHittable {
            style.tap()
            sleep(2)
            shot("03-map-style")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            sleep(2)
        }

        // Zoom in on a place, for the weather pill.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
        sleep(8)
        shot("04-zoomed")
        try? app.debugDescription.write(to: out.appendingPathComponent("tree-zoomed.txt"), atomically: true, encoding: .utf8)

        // Tap empty map: chrome should go away.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        sleep(2)
        shot("05-bare")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        sleep(2)
        shot("06-back")
    }
}
