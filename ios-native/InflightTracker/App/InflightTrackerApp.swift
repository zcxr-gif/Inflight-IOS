import SwiftUI

@main
struct InflightTrackerApp: App {

    /// APNs hands device tokens and notification taps to a
    /// `UIApplicationDelegate` and nowhere else, so the SwiftUI app keeps one
    /// for that alone — see `AppDelegate` in PushService.swift.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
