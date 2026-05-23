import Foundation
import Capacitor
import MapKit
import UIKit

@objc(InflightMapkitPlugin)
public class InflightMapkitPlugin: CAPPlugin {

    private var maps: [String: MapKitController] = [:]
    private let queue = DispatchQueue(label: "com.tracker.Inflight.mapkit")

    override public func load() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.bridge?.webView else { return }
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }
    }

    @objc func create(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId") else {
            call.reject("mapId required")
            return
        }
        let frame = self.rect(from: call.getObject("frame"))
        let center = self.coord(from: call.getObject("center")) ?? CLLocationCoordinate2D(latitude: 22.59, longitude: 78.96)
        let zoom = call.getDouble("zoom") ?? 2.0
        let mapTypeRaw = call.getString("mapType") ?? "standard"

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.bridge?.webView, let parent = webView.superview else {
                call.reject("WebView unavailable")
                return
            }

            let controller = MapKitController(frame: frame)
            controller.applyMapType(mapTypeRaw)
            controller.setCamera(center: center, zoom: zoom, pitch: 0, bearing: 0, animated: false)

            parent.insertSubview(controller.mapView, belowSubview: webView)
            self.queue.sync { self.maps[mapId] = controller }

            controller.onTap = { [weak self] coord in
                self?.notifyListeners("mapTap", data: [
                    "mapId": mapId,
                    "lat": coord.latitude,
                    "lng": coord.longitude
                ])
            }
            controller.onRegionChange = { [weak self] region in
                self?.notifyListeners("regionChange", data: [
                    "mapId": mapId,
                    "lat": region.center.latitude,
                    "lng": region.center.longitude,
                    "latDelta": region.span.latitudeDelta,
                    "lngDelta": region.span.longitudeDelta
                ])
            }
            controller.onAnnotationTap = { [weak self] markerId in
                self?.notifyListeners("annotationTap", data: [
                    "mapId": mapId,
                    "markerId": markerId
                ])
            }

            self.notifyListeners("load", data: ["mapId": mapId])
            call.resolve()
        }
    }

    @objc func destroy(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId") else { call.reject("mapId required"); return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let controller = self.queue.sync { self.maps.removeValue(forKey: mapId) }
            controller?.mapView.removeFromSuperview()
            call.resolve()
        }
    }

    @objc func setFrame(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found")
            return
        }
        let frame = self.rect(from: call.getObject("frame"))
        DispatchQueue.main.async {
            controller.mapView.frame = frame
            call.resolve()
        }
    }

    @objc func setCamera(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found"); return
        }
        let center = self.coord(from: call.getObject("center")) ?? controller.mapView.region.center
        let zoom = call.getDouble("zoom") ?? Double(controller.currentZoom())
        let pitch = call.getDouble("pitch") ?? 0
        let bearing = call.getDouble("bearing") ?? 0
        let animated = call.getBool("animated") ?? true

        DispatchQueue.main.async {
            controller.setCamera(center: center, zoom: zoom, pitch: pitch, bearing: bearing, animated: animated)
            call.resolve()
        }
    }

    @objc func fitBounds(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found"); return
        }
        guard let sw = self.coord(from: call.getObject("sw")),
              let ne = self.coord(from: call.getObject("ne")) else {
            call.reject("bounds required"); return
        }
        let paddingTop = call.getDouble("paddingTop") ?? 40
        let paddingRight = call.getDouble("paddingRight") ?? 40
        let paddingBottom = call.getDouble("paddingBottom") ?? 40
        let paddingLeft = call.getDouble("paddingLeft") ?? 40
        let animated = call.getBool("animated") ?? true

        DispatchQueue.main.async {
            let insets = UIEdgeInsets(top: paddingTop, left: paddingLeft, bottom: paddingBottom, right: paddingRight)
            controller.fitBounds(sw: sw, ne: ne, insets: insets, animated: animated)
            call.resolve()
        }
    }

    @objc func setMapType(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found"); return
        }
        let typeName = call.getString("mapType") ?? "standard"
        DispatchQueue.main.async {
            controller.applyMapType(typeName)
            call.resolve()
        }
    }

    @objc func setMarkers(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found"); return
        }
        let layerId = call.getString("layerId") ?? "default"
        let markers = call.getArray("markers", JSObject.self) ?? []

        let parsed: [MapKitController.MarkerSpec] = markers.compactMap { obj in
            guard let id = obj["id"] as? String,
                  let coord = self.coord(from: obj["coord"] as? JSObject) else { return nil }
            let title = obj["title"] as? String
            let color = obj["color"] as? String ?? "#3A8DFF"
            let rotation = obj["rotation"] as? Double ?? 0
            let glyph = obj["glyph"] as? String
            return MapKitController.MarkerSpec(
                id: id, coord: coord, title: title,
                color: color, rotation: rotation, glyph: glyph
            )
        }

        DispatchQueue.main.async {
            controller.setMarkers(layerId: layerId, markers: parsed)
            call.resolve()
        }
    }

    @objc func setPolylines(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found"); return
        }
        let layerId = call.getString("layerId") ?? "default"
        let lines = call.getArray("polylines", JSObject.self) ?? []

        var parsed: [MapKitController.PolylineSpec] = []
        for obj in lines {
            guard let id = obj["id"] as? String,
                  let coordsArr = obj["coords"] as? [JSObject] else { continue }
            var coords: [CLLocationCoordinate2D] = []
            for c in coordsArr {
                if let cc = self.coord(from: c) { coords.append(cc) }
            }
            if coords.count < 2 { continue }
            let color = obj["color"] as? String ?? "#3A8DFF"
            let width = obj["width"] as? Double ?? 3
            let dashed = obj["dashed"] as? Bool ?? false
            parsed.append(MapKitController.PolylineSpec(
                id: id, coords: coords, color: color, width: width, dashed: dashed
            ))
        }

        DispatchQueue.main.async {
            controller.setPolylines(layerId: layerId, polylines: parsed)
            call.resolve()
        }
    }

    @objc func setPolygons(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found"); return
        }
        let layerId = call.getString("layerId") ?? "default"
        let polys = call.getArray("polygons", JSObject.self) ?? []

        var parsed: [MapKitController.PolygonSpec] = []
        for obj in polys {
            guard let id = obj["id"] as? String,
                  let ringsArr = obj["rings"] as? [[JSObject]] else { continue }
            var rings: [[CLLocationCoordinate2D]] = []
            for ring in ringsArr {
                var coords: [CLLocationCoordinate2D] = []
                for c in ring {
                    if let cc = self.coord(from: c) { coords.append(cc) }
                }
                if coords.count >= 3 { rings.append(coords) }
            }
            if rings.isEmpty { continue }
            let fillColor = obj["fillColor"] as? String ?? "#3A8DFF33"
            let strokeColor = obj["strokeColor"] as? String ?? "#3A8DFF"
            let strokeWidth = obj["strokeWidth"] as? Double ?? 1
            parsed.append(MapKitController.PolygonSpec(
                id: id, rings: rings,
                fillColor: fillColor, strokeColor: strokeColor, strokeWidth: strokeWidth
            ))
        }

        DispatchQueue.main.async {
            controller.setPolygons(layerId: layerId, polygons: parsed)
            call.resolve()
        }
    }

    @objc func setVisible(_ call: CAPPluginCall) {
        guard let mapId = call.getString("mapId"),
              let controller = self.queue.sync(execute: { self.maps[mapId] }) else {
            call.reject("Map not found"); return
        }
        let layerId = call.getString("layerId") ?? "default"
        let visible = call.getBool("visible") ?? true
        DispatchQueue.main.async {
            controller.setLayerVisible(layerId: layerId, visible: visible)
            call.resolve()
        }
    }

    private func rect(from obj: JSObject?) -> CGRect {
        guard let obj = obj else {
            let bounds = bridge?.webView?.bounds ?? UIScreen.main.bounds
            return bounds
        }
        let x = (obj["x"] as? Double) ?? 0
        let y = (obj["y"] as? Double) ?? 0
        let w = (obj["width"] as? Double) ?? 0
        let h = (obj["height"] as? Double) ?? 0
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func coord(from obj: JSObject?) -> CLLocationCoordinate2D? {
        guard let obj = obj,
              let lat = obj["lat"] as? Double,
              let lng = obj["lng"] as? Double else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
