import SwiftUI
import UIKit

/// Airline logos for the Flight Center, by ICAO code.
///
/// The same open logo sets the web Flight Center reads (see
/// `AirlineDirectory.logoURLs`), tried in order until one answers with a
/// picture. An airline none of them has gets its monogram on its own colour
/// instead, which is what every badge in the app looked like before this.
///
/// ## Takedowns
///
/// Airline names and logos are their owners' trademarks, shown only to say
/// whose livery a virtual flight is wearing. A takedown is honoured through the
/// backend's blocklist — the same `/api/airline-logos/blocklist` every surface
/// of the web tracker applies — and nothing is fetched for a code until that
/// list has been asked about. A blocked code is never requested at all.
///
/// Hits and misses are both remembered for the life of the process: the same
/// two dozen airlines are on every page, and asking GitHub again for a logo it
/// has already said it does not have is the common case being avoided.
@MainActor
final class AirlineLogoStore: ObservableObject {

    static let shared = AirlineLogoStore()

    @Published private(set) var images: [String: UIImage] = [:]

    private var misses: Set<String> = []
    private var pending: Set<String> = []
    private var blocked: Set<String> = []
    private var blocklist: Task<Void, Never>?

    private init() {}

    func image(for icao: String?) -> UIImage? {
        guard let icao, !icao.isEmpty else { return nil }
        return images[icao.uppercased()]
    }

    /// Fetches the logo for a code once, if it has not been asked for already.
    func request(_ icao: String?) {
        guard let icao, !icao.isEmpty else { return }
        let code = icao.uppercased()
        guard images[code] == nil, !misses.contains(code), !pending.contains(code) else { return }
        pending.insert(code)

        Task { [weak self] in
            guard let self else { return }
            await self.loadBlocklist()

            guard !self.blocked.contains(code) else {
                self.pending.remove(code)
                self.misses.insert(code)
                return
            }

            let image = await AirlineLogoStore.fetch(AirlineDirectory.logoURLs(for: code))
            self.pending.remove(code)
            if let image {
                self.images[code] = image
            } else {
                self.misses.insert(code)
            }
        }
    }

    private func loadBlocklist() async {
        if blocklist == nil {
            blocklist = Task { [weak self] in
                let codes = await AirlineLogoStore.fetchBlocklist()
                self?.blocked = codes
            }
        }
        await blocklist?.value
    }

    /// Either a bare array of codes or `{ "blocked": [...] }`, as the web
    /// reads it. A failure is an empty list, the same as on the web.
    nonisolated private static func fetchBlocklist() async -> Set<String> {
        guard let url = URL(string: AppConfig.socketURLString + "/api/airline-logos/blocklist") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let list: [Any]
        if let array = json as? [Any] {
            list = array
        } else if let object = json as? [String: Any], let array = object["blocked"] as? [Any] {
            list = array
        } else {
            list = []
        }
        return Set(list.compactMap { ($0 as? String)?.uppercased() })
    }

    nonisolated private static func fetch(_ urls: [URL]) async -> UIImage? {
        for url in urls {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = DecodedImage.from(data, longestSide: 256) else { continue }
            return image
        }
        return nil
    }
}

/// An airline's mark: its logo on white where there is one, its letters on its
/// own colour where there is not.
///
/// White under a logo because that is what every one of these was drawn for;
/// on the app's dark glass a navy wordmark simply disappears. The fallback is
/// the dock's own airline badge, so a row in the Flight Center and a row in the
/// dock read as the same airline.
struct AirlineLogoMark: View {

    let icao: String?

    /// For the airline's colour behind the fallback letters.
    var livery: String = ""

    /// The letters drawn when there is no logo: the callsign's, normally.
    var fallback: String = ""

    var side: CGFloat = 38

    @ObservedObject private var store = AirlineLogoStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    private var corner: CGFloat { side * 0.3 }

    private var letters: String {
        if !fallback.isEmpty { return String(fallback.prefix(3)) }
        return String((icao ?? "?").prefix(3))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let colours = AirlineAccent.colours(forLivery: livery, isLight: theme.isLight)

        Group {
            if let image = store.image(for: icao) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(side * 0.12)
                    .frame(width: side, height: side)
                    .background(Color.white)
            } else {
                Text(L(letters))
                    .font(.system(size: side * (letters.count > 2 ? 0.29 : 0.34), weight: .heavy, design: .rounded))
                    .foregroundStyle(colours?.ink ?? theme.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(side * 0.1)
                    .frame(width: side, height: side)
                    .background(colours?.tint ?? theme.textPrimary.opacity(0.1))
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(theme.stroke, lineWidth: 0.8) }
        .motion(Motion.content, value: store.image(for: icao) != nil)
        .accessibilityHidden(true)
        .onAppear { store.request(icao) }
        .onChange(of: icao) { _, code in store.request(code) }
    }
}
