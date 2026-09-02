import SwiftUI
import WidgetKit

/// Everything the extension publishes: four home-screen tiles and the live
/// banner.
@main
struct InflightWidgetBundle: WidgetBundle {

    var body: some Widget {
        FlightWidget()
        FriendsWidget()
        AirportWidget()
        VaWidget()
        InflightLiveActivity()
    }
}
