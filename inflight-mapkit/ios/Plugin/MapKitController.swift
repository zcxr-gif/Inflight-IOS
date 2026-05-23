import Foundation
import MapKit
import UIKit

final class MapKitController: NSObject, MKMapViewDelegate {

    struct MarkerSpec {
        let id: String
        let coord: CLLocationCoordinate2D
        let title: String?
        let color: String
        let rotation: Double
        let glyph: String?
    }

    struct PolylineSpec {
        let id: String
        let coords: [CLLocationCoordinate2D]
        let color: String
        let width: Double
        let dashed: Bool
    }

    struct PolygonSpec {
        let id: String
        let rings: [[CLLocationCoordinate2D]]
        let fillColor: String
        let strokeColor: String
        let strokeWidth: Double
    }

    let mapView: MKMapView
    var onTap: ((CLLocationCoordinate2D) -> Void)?
    var onRegionChange: ((MKCoordinateRegion) -> Void)?
    var onAnnotationTap: ((String) -> Void)?

    // layerId -> annotations / overlays / etc.
    private var markerLayers: [String: [String: TaggedAnnotation]] = [:]
    private var polylineLayers: [String: [String: TaggedPolyline]] = [:]
    private var polygonLayers: [String: [String: TaggedPolygon]] = [:]
    private var hiddenLayers: Set<String> = []

    init(frame: CGRect) {
        let mv = MKMapView(frame: frame)
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = false
        mv.showsScale = false
        mv.showsTraffic = false
        mv.isPitchEnabled = true
        mv.isRotateEnabled = true
        mv.mapType = .standard
        self.mapView = mv
        super.init()
        mv.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        mv.addGestureRecognizer(tap)
    }

    // MARK: - Camera

    func currentZoom() -> Double {
        let span = mapView.region.span
        let mapWidth = max(mapView.bounds.width, 1)
        let zoom = log2(360.0 * (Double(mapWidth) / 256.0) / max(span.longitudeDelta, 0.0001))
        return max(0, min(20, zoom))
    }

    func setCamera(center: CLLocationCoordinate2D, zoom: Double, pitch: Double, bearing: Double, animated: Bool) {
        let camera = MKMapCamera()
        camera.centerCoordinate = center
        camera.pitch = CGFloat(max(0, min(80, pitch)))
        camera.heading = bearing
        let altitude = altitudeForZoom(zoom, latitude: center.latitude)
        camera.altitude = altitude
        mapView.setCamera(camera, animated: animated)
    }

    func fitBounds(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, insets: UIEdgeInsets, animated: Bool) {
        let center = CLLocationCoordinate2D(
            latitude: (sw.latitude + ne.latitude) / 2,
            longitude: (sw.longitude + ne.longitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: abs(ne.latitude - sw.latitude) * 1.2,
            longitudeDelta: abs(ne.longitude - sw.longitude) * 1.2
        )
        let region = MKCoordinateRegion(center: center, span: span)
        mapView.setVisibleMapRect(
            mapView.mapRectThatFits(MKMapRect(region: region), edgePadding: insets),
            animated: animated
        )
    }

    private func altitudeForZoom(_ zoom: Double, latitude: Double) -> CLLocationDistance {
        // Web mercator approximation: altitude such that one tile spans the viewport at given zoom.
        let earthCircumference: Double = 40075016.686
        let metersPerPixel = earthCircumference * cos(latitude * .pi / 180.0) / pow(2.0, zoom + 8.0)
        let viewWidthPixels = max(Double(mapView.bounds.width), 256)
        let metersAcross = metersPerPixel * viewWidthPixels
        // MKMapCamera altitude roughly equals horizontal distance for the visible region.
        return max(500, metersAcross)
    }

    // MARK: - Map type

    func applyMapType(_ name: String) {
        switch name.lowercased() {
        case "satellite":
            mapView.mapType = .satellite
        case "hybrid", "traffic-night", "traffic-day":
            mapView.mapType = .hybrid
            mapView.showsTraffic = name.lowercased().contains("traffic")
        case "outdoors":
            if #available(iOS 16.0, *) {
                let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)
                mapView.preferredConfiguration = config
            } else {
                mapView.mapType = .standard
            }
        case "dark", "nav-dark":
            if #available(iOS 13.0, *) {
                mapView.overrideUserInterfaceStyle = .dark
            }
            mapView.mapType = .mutedStandard
        case "light", "nav-light":
            if #available(iOS 13.0, *) {
                mapView.overrideUserInterfaceStyle = .light
            }
            mapView.mapType = .standard
        default:
            mapView.mapType = .standard
        }
    }

    // MARK: - Markers

    func setMarkers(layerId: String, markers: [MarkerSpec]) {
        let existing = markerLayers[layerId] ?? [:]
        var updated: [String: TaggedAnnotation] = [:]

        // Update or add
        for spec in markers {
            if let ann = existing[spec.id] {
                ann.coordinate = spec.coord
                ann.title = spec.title
                ann.colorHex = spec.color
                ann.rotation = spec.rotation
                ann.glyph = spec.glyph
                if let view = mapView.view(for: ann) {
                    apply(view: view, annotation: ann)
                }
                updated[spec.id] = ann
            } else {
                let ann = TaggedAnnotation(id: spec.id, layerId: layerId)
                ann.coordinate = spec.coord
                ann.title = spec.title
                ann.colorHex = spec.color
                ann.rotation = spec.rotation
                ann.glyph = spec.glyph
                mapView.addAnnotation(ann)
                updated[spec.id] = ann
            }
        }

        // Remove stale
        for (id, ann) in existing where updated[id] == nil {
            mapView.removeAnnotation(ann)
        }

        markerLayers[layerId] = updated
        applyVisibilityToLayer(layerId)
    }

    // MARK: - Polylines

    func setPolylines(layerId: String, polylines: [PolylineSpec]) {
        let existing = polylineLayers[layerId] ?? [:]
        var updated: [String: TaggedPolyline] = [:]

        for spec in polylines {
            if let old = existing[spec.id] {
                mapView.removeOverlay(old)
            }
            var coords = spec.coords
            let poly = TaggedPolyline(coordinates: &coords, count: coords.count)
            poly.id = spec.id
            poly.layerId = layerId
            poly.colorHex = spec.color
            poly.width = spec.width
            poly.dashed = spec.dashed
            mapView.addOverlay(poly)
            updated[spec.id] = poly
        }

        for (id, poly) in existing where updated[id] == nil {
            mapView.removeOverlay(poly)
        }

        polylineLayers[layerId] = updated
        applyVisibilityToLayer(layerId)
    }

    // MARK: - Polygons

    func setPolygons(layerId: String, polygons: [PolygonSpec]) {
        let existing = polygonLayers[layerId] ?? [:]
        var updated: [String: TaggedPolygon] = [:]

        for spec in polygons {
            if let old = existing[spec.id] {
                mapView.removeOverlay(old)
            }
            guard let outer = spec.rings.first else { continue }
            var outerCoords = outer
            let interiors = spec.rings.dropFirst().map { ring -> MKPolygon in
                var r = ring
                return MKPolygon(coordinates: &r, count: r.count)
            }
            let poly = TaggedPolygon(coordinates: &outerCoords, count: outerCoords.count, interiorPolygons: interiors)
            poly.id = spec.id
            poly.layerId = layerId
            poly.fillColorHex = spec.fillColor
            poly.strokeColorHex = spec.strokeColor
            poly.strokeWidth = spec.strokeWidth
            mapView.addOverlay(poly)
            updated[spec.id] = poly
        }

        for (id, poly) in existing where updated[id] == nil {
            mapView.removeOverlay(poly)
        }

        polygonLayers[layerId] = updated
        applyVisibilityToLayer(layerId)
    }

    // MARK: - Visibility

    func setLayerVisible(layerId: String, visible: Bool) {
        if visible {
            hiddenLayers.remove(layerId)
        } else {
            hiddenLayers.insert(layerId)
        }
        applyVisibilityToLayer(layerId)
    }

    private func applyVisibilityToLayer(_ layerId: String) {
        let hidden = hiddenLayers.contains(layerId)
        if let markers = markerLayers[layerId] {
            for ann in markers.values {
                mapView.view(for: ann)?.isHidden = hidden
            }
        }
        if let lines = polylineLayers[layerId] {
            for line in lines.values {
                if let renderer = mapView.renderer(for: line) {
                    renderer.alpha = hidden ? 0 : 1
                }
            }
        }
        if let polys = polygonLayers[layerId] {
            for poly in polys.values {
                if let renderer = mapView.renderer(for: poly) {
                    renderer.alpha = hidden ? 0 : 1
                }
            }
        }
    }

    // MARK: - Delegates

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let tagged = annotation as? TaggedAnnotation else { return nil }
        let identifier = "InflightMarker"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            ?? MKAnnotationView(annotation: tagged, reuseIdentifier: identifier)
        view.annotation = tagged
        view.canShowCallout = tagged.title != nil
        apply(view: view, annotation: tagged)
        return view
    }

    private func apply(view: MKAnnotationView, annotation: TaggedAnnotation) {
        let size = CGSize(width: 28, height: 28)
        view.frame = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size)
        let color = UIColor(hex: annotation.colorHex) ?? UIColor.systemBlue
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: CGFloat(annotation.rotation) * .pi / 180.0)
            cg.translateBy(x: -size.width / 2, y: -size.height / 2)
            color.setFill()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: size.width / 2, y: 2))
            path.addLine(to: CGPoint(x: size.width - 4, y: size.height - 4))
            path.addLine(to: CGPoint(x: size.width / 2, y: size.height - 8))
            path.addLine(to: CGPoint(x: 4, y: size.height - 4))
            path.close()
            path.fill()
            cg.restoreGState()
        }
        view.image = img
        view.isHidden = hiddenLayers.contains(annotation.layerId)
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if let tagged = view.annotation as? TaggedAnnotation {
            onAnnotationTap?(tagged.id)
            mapView.deselectAnnotation(tagged, animated: false)
        }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        onRegionChange?(mapView.region)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let line = overlay as? TaggedPolyline {
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = UIColor(hex: line.colorHex) ?? .systemBlue
            r.lineWidth = CGFloat(line.width)
            r.lineCap = .round
            r.lineJoin = .round
            if line.dashed {
                r.lineDashPattern = [6, 6]
            }
            r.alpha = hiddenLayers.contains(line.layerId) ? 0 : 1
            return r
        }
        if let poly = overlay as? TaggedPolygon {
            let r = MKPolygonRenderer(polygon: poly)
            r.fillColor = UIColor(hex: poly.fillColorHex) ?? UIColor.systemBlue.withAlphaComponent(0.2)
            r.strokeColor = UIColor(hex: poly.strokeColorHex) ?? .systemBlue
            r.lineWidth = CGFloat(poly.strokeWidth)
            r.alpha = hiddenLayers.contains(poly.layerId) ? 0 : 1
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let point = gr.location(in: mapView)
        let coord = mapView.convert(point, toCoordinateFrom: mapView)
        onTap?(coord)
    }
}

// MARK: - Tagged subclasses

final class TaggedAnnotation: NSObject, MKAnnotation {
    let id: String
    let layerId: String
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var title: String?
    var colorHex: String = "#3A8DFF"
    var rotation: Double = 0
    var glyph: String?

    init(id: String, layerId: String) {
        self.id = id
        self.layerId = layerId
        super.init()
    }
}

final class TaggedPolyline: MKPolyline {
    var id: String = ""
    var layerId: String = ""
    var colorHex: String = "#3A8DFF"
    var width: Double = 3
    var dashed: Bool = false
}

final class TaggedPolygon: MKPolygon {
    var id: String = ""
    var layerId: String = ""
    var fillColorHex: String = "#3A8DFF33"
    var strokeColorHex: String = "#3A8DFF"
    var strokeWidth: Double = 1
}

// MARK: - Color helpers

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard [6, 8].contains(s.count), let n = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((n >> 24) & 0xFF) / 255
            g = CGFloat((n >> 16) & 0xFF) / 255
            b = CGFloat((n >> 8) & 0xFF) / 255
            a = CGFloat(n & 0xFF) / 255
        } else {
            r = CGFloat((n >> 16) & 0xFF) / 255
            g = CGFloat((n >> 8) & 0xFF) / 255
            b = CGFloat(n & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
