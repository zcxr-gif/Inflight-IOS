import Foundation

/// On-screen text in the reader's language.
///
/// SwiftUI translates a string *literal* handed to `Text` by itself, but most
/// of this app's text is not a literal at the point it is drawn: a row is
/// given its title as a `String`, an enum returns its label, a computed
/// property picks one of two sentences. `Text(someString)` draws a `String`
/// verbatim, so all of that stayed in English. Every place that draws text
/// passes it through this instead.
///
/// A string with no entry in the tables comes back unchanged, which is what
/// makes it safe to wrap everything: a callsign, an airport name, a number
/// with a unit — none of them are keys, so all of them draw as they are.
///
/// Compiled into the widget extension too (it lives in `Shared/`), where
/// `Bundle.main` is the extension's own bundle and carries the same tables.
func L(_ text: String) -> String {
    Bundle.main.localizedString(forKey: text, value: text, table: nil)
}

/// Anything that isn't a plain `String` — a `LocalizedStringKey`, an
/// `AttributedString`, a `Substring`, an `Image` — passes straight through, so
/// wrapping a call site never changes what it compiles to.
@_disfavoredOverload
func L<Value>(_ value: Value) -> Value { value }

/// A sentence with values in it. The key carries a `%@` for each value, in
/// order, and every value is passed as text — a count included — so a
/// translation never has to match a format specifier to a Swift type.
///
///     Lf("%@ aircraft", String(count))
///     Lf("Passing %@", airport.icao)
func Lf(_ key: String, _ values: String...) -> String {
    String(format: L(key), arguments: values.map { $0 as CVarArg })
}
