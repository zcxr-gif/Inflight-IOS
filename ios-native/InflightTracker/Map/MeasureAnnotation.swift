import UIKit

/// How a measured leg is drawn, in a colour nothing else on the map uses.
///
/// It has to be unmistakable — a ruler is a thing you put down and pick up
/// again, and for the moments it is there it should be the most obvious line
/// on screen. That is the opposite of every other overlay here, which are all
/// deliberately quiet.
enum MeasureStyle {

    static let line = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.85, green: 0.20, blue: 0.45, alpha: 1)
            : UIColor(red: 1.00, green: 0.45, blue: 0.65, alpha: 1)
    }

    static let pinFill = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(white: 1, alpha: 0.95)
            : UIColor(white: 0.10, alpha: 0.95)
    }
}
