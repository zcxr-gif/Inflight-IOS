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
            RootView()
                .environmentObject(feed)
        }
    }
}

/// Everything above the map, and the one job that has to happen outside it:
/// telling the appearance store what iOS is currently set to.
///
/// The app never calls `preferredColorScheme` — every surface stamps the
/// resolved scheme on itself instead, and the map is handed it directly. That
/// is deliberate: forcing the window's own trait would make the reading below
/// report back whatever the app had forced, so switching the setting to Auto
/// would leave it stuck on the last explicit choice until the phone's own
/// setting happened to change.
private struct RootView: View {

    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    var body: some View {
        ContentView()
            .onAppear { appearance.adopt(systemScheme: systemScheme) }
            .onChange(of: systemScheme) { _, scheme in
                appearance.adopt(systemScheme: scheme)
            }
    }
}
