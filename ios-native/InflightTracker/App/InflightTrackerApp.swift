import SwiftUI

@main
struct InflightTrackerApp: App {

    @StateObject private var feed = LiveFeed()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(feed)
        }
    }
}
