import Foundation

/// The FAA's published airport diagram for a field, where there is one.
///
/// ## What this is and is not
///
/// It is the real chart — the sheet in the Terminal Procedures Publication,
/// the one on a kneeboard — fetched as its own PDF and shown as a document you
/// open. It is **not** a layer on the map, and there is no aeroplane on it.
///
/// That is not a shortcut, it is the state of the data. The FAA added
/// georeferenced encoding to *instrument approach* charts, and only inside
/// their planview; airport diagrams carry none. The georeferenced taxi
/// diagrams in the certified apps come from a commercial chart house, which is
/// why those apps pay for them rather than pulling the free PDFs. So a diagram
/// laid over the map is not something that can be built out of what the FAA
/// publishes, and this does not pretend otherwise.
///
/// It is also US-only, for the same reason: FAA charts are public domain, and
/// every other country's AIP is its own ANSP's copyright. A field outside the
/// United States simply reports `.unavailable`, which is the honest answer.
///
/// ## Why there is no backend behind this
///
/// A chart's file name is an opaque FAA id — `00378AD.PDF` — and nothing about
/// it can be worked out from an ICAO code. The only way across is the cycle's
/// metafile, which indexes every chart the FAA publishes: some seventeen
/// thousand of them, most of a megabyte compressed.
///
/// The obvious answer is a server that reads that once and serves a row per
/// airport. The answer taken here is that the phone can do it, because almost
/// none of that file is wanted: airport diagrams are one chart per field, about
/// a thousand rows, and everything else in it — approaches, departures,
/// arrivals, minimums — is thrown away as it streams past. What is kept is a
/// few tens of kilobytes of ICAO against file name, held until the cycle turns
/// over twenty-eight days later. One download a month, no service to run, and
/// nothing that can go stale server-side without anyone noticing.
final class AirportChartStore: ObservableObject {

    static let shared = AirportChartStore()

    enum State: Equatable {
        case idle
        /// Working out which chart, or fetching it.
        case loading
        /// On disk and ready to open.
        case ready(URL)
        /// The FAA does not publish a diagram for this field — which includes
        /// every field outside the United States.
        case unavailable
        case failed
    }

    @Published private(set) var states: [String: State] = [:]

    private init() {}

    func state(for icao: String) -> State { states[icao.uppercased()] ?? .idle }

    // MARK: - The one thing this is asked for

    /// Resolves a field's diagram, fetching whatever is missing on the way.
    ///
    /// Safe to call whenever a field is opened: anything already resolved,
    /// already being resolved, or already known to have no chart does nothing.
    func load(_ icao: String) {
        let key = icao.uppercased()

        switch state(for: key) {
        case .ready, .loading, .unavailable: return
        case .idle, .failed: break
        }

        if let cached = cachedChartURL(key), FileManager.default.fileExists(atPath: cached.path) {
            states[key] = .ready(cached)
            return
        }

        states[key] = .loading

        Task { [weak self] in
            let resolved = await Self.resolve(key)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                switch resolved {
                case .some(let url): self.states[key] = .ready(url)
                case .none: self.states[key] = self.lastLookupFoundIndex ? .unavailable : .failed
                }
            }
        }
    }

    /// Whether the most recent lookup got as far as reading an index.
    ///
    /// It is what separates "this field has no diagram" from "we never found
    /// out" — the first is a fact about the field and the second is a network
    /// that was not there, and a panel should not tell somebody their airport
    /// has no chart because their train went into a tunnel.
    private var lastLookupFoundIndex = false

    private static func resolve(_ icao: String) async -> URL? {
        guard let index = await Index.current() else {
            await MainActor.run { shared.lastLookupFoundIndex = false }
            return nil
        }
        await MainActor.run { shared.lastLookupFoundIndex = true }

        guard let name = index.charts[icao] else { return nil }
        guard let url = URL(string: "\(Self.chartHost)/\(index.cycle)/\(name)") else { return nil }

        guard let data = await fetch(url), data.starts(with: Self.pdfMagic) else { return nil }
        guard let destination = shared.cachedChartURL(icao) else { return nil }
        try? data.write(to: destination, options: .atomic)
        return destination
    }

    /// A PDF starts `%PDF`. Checked because the FAA serves an HTML error page
    /// with a 200 when a chart moves between cycles, and a viewer handed that
    /// shows a blank sheet rather than saying anything went wrong.
    private static let pdfMagic: [UInt8] = [0x25, 0x50, 0x44, 0x46]

    private static let chartHost = "https://aeronav.faa.gov/d-tpp"

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Cache

    private func cacheDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("AirportCharts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cachedChartURL(_ icao: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("\(icao).pdf")
    }
}

// MARK: - The cycle's index

extension AirportChartStore {

    /// Which airport diagram belongs to which field, for one 28-day cycle.
    struct Index {

        let cycle: String
        /// ICAO against the chart's file name. Airport diagrams only.
        let charts: [String: String]

        /// Where the FAA publishes the current cycle's catalogue.
        ///
        /// The *current* one rather than a cycle we worked out: the cycle
        /// rolls every twenty-eight days from an epoch nothing here should be
        /// trying to track, and the file names its own cycle, so asking is
        /// both simpler and right on the day it turns over.
        static let source = URL(string: "https://nfdc.faa.gov/webContent/dtpp/current.xml")!

        private static var held: Index?

        /// The index, from memory, from disk, or from the FAA in that order.
        static func current() async -> Index? {
            if let held = held { return held }
            if let disk = readCache() {
                held = disk
                return disk
            }

            var request = URLRequest(url: source)
            request.timeoutInterval = 60
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            guard let parsed = Parser.parse(data) else { return nil }
            held = parsed
            writeCache(parsed)
            return parsed
        }

        // MARK: Cache

        private static var cacheURL: URL? {
            guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            let directory = base.appendingPathComponent("AirportCharts", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("index.json")
        }

        /// Held for a cycle less a day, so the app asks again just before the
        /// charts it is holding stop being the current ones.
        private static let lifetime: TimeInterval = 27 * 24 * 3600

        private static func readCache() -> Index? {
            guard let url = cacheURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let written = attributes[.modificationDate] as? Date,
                  Date().timeIntervalSince(written) < lifetime,
                  let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cycle = root["cycle"] as? String,
                  let charts = root["charts"] as? [String: String] else { return nil }
            return Index(cycle: cycle, charts: charts)
        }

        private static func writeCache(_ index: Index) {
            guard let url = cacheURL,
                  let data = try? JSONSerialization.data(
                    withJSONObject: ["cycle": index.cycle, "charts": index.charts]
                  ) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Reading the metafile

extension AirportChartStore.Index {

    /// Streams the FAA's catalogue and keeps the thousandth of it that is an
    /// airport diagram.
    ///
    /// `XMLParser` in its event form rather than anything that builds a tree:
    /// the document is most of a megabyte and all but a few hundred of its
    /// records are approaches and departures this does not want, so they are
    /// recognised and dropped as they go past rather than held.
    ///
    /// The shape being read is
    ///
    ///     <digital_tpp cycle="…">
    ///       <state_code …>
    ///         <city_name …>
    ///           <airport_name icao_ident="KSFO" apt_ident="SFO" …>
    ///             <record>
    ///               <chart_code>APD</chart_code>
    ///               <pdf_name>00375AD.PDF</pdf_name>
    ///
    /// `APD` is the airport diagram. `icao_ident` is empty at the many US
    /// fields that have no ICAO code, and those fall back to the FAA
    /// identifier — which is what the app's own airport list calls them too.
    final class Parser: NSObject, XMLParserDelegate {

        private var cycle: String?
        private var charts: [String: String] = [:]

        private var airport: String?
        private var chartCode: String?
        private var pdfName: String?
        private var element: String?
        private var text = ""

        static func parse(_ data: Data) -> AirportChartStore.Index? {
            let parser = Parser()
            let xml = XMLParser(data: data)
            xml.delegate = parser
            guard xml.parse(), let cycle = parser.cycle, !parser.charts.isEmpty else { return nil }
            return AirportChartStore.Index(cycle: cycle, charts: parser.charts)
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            element = elementName
            text = ""

            switch elementName {
            case "digital_tpp":
                cycle = attributes["cycle"]?.trimmingCharacters(in: .whitespacesAndNewlines)

            case "airport_name":
                let icao = attributes["icao_ident"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let faa = attributes["apt_ident"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                airport = (icao?.isEmpty == false ? icao : faa)?.uppercased()

            case "record":
                chartCode = nil
                pdfName = nil

            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""

            switch elementName {
            case "chart_code":
                chartCode = value.uppercased()

            case "pdf_name":
                pdfName = value

            case "record":
                // The only records kept. A field can carry a couple of
                // diagrams — a second one for the airport's own use — and the
                // first is the one the publication leads with.
                if chartCode == "APD",
                   let airport = airport, !airport.isEmpty,
                   let name = pdfName, !name.isEmpty,
                   charts[airport] == nil {
                    charts[airport] = name
                }
                chartCode = nil
                pdfName = nil

            case "airport_name":
                airport = nil

            default:
                break
            }
        }
    }
}
