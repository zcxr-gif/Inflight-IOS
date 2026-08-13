import SwiftUI

@main
struct InflightTrackerApp: App {

    @StateObject private var feed = LiveFeed()

    init() {
        // Parses the 17k-airport table off the main thread so the first flight
        // the user taps has its route ready.
        AirportStore.shared.preload()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(feed)
        }
    }
}
