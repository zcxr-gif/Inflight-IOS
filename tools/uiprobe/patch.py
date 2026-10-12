# Diagnostic only: forces the 3D buildings on and parks the camera over
# Midtown, logging what the style was actually configured with.
import os
kind = os.environ["PATCH"]

if kind == "motion":
    # The window's spring, slowed about ten times so a screenshot every
    # third of a second lands in the middle of it opening and closing.
    p = "Views/Motion.swift"
    s = open(p).read()
    old = "static let chrome = Animation.spring(response: 0.36, dampingFraction: 0.88)"
    assert old in s
    s = s.replace(old, "static let chrome = Animation.spring(response: 3.6, dampingFraction: 0.88)")
    open(p, "w").write(s)
    raise SystemExit(0)

p = "Map/MapLook.swift"
s = open(p).read()
assert "show3dObjects: custom.shows3DBuildings," in s
s = s.replace("show3dObjects: custom.shows3DBuildings,", "show3dObjects: true,")
if kind == "forced-default":
    assert "theme = isDetailed ? .default : .faded" in s
    s = s.replace("theme = isDetailed ? .default : .faded", "theme = .default")
open(p, "w").write(s)

p = "Map/TrackerMapView.swift"
s = open(p).read()
anchor = "            map.onMapLoaded.observeNext { _ in\n"
probe = r'''            map.onMapLoaded.observeNext { [weak mapView] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    guard let mapView, let map = mapView.mapboxMap else { return }
                    mapView.camera.cancelAnimations()
                    map.setCamera(to: CameraOptions(
                        center: CLLocationCoordinate2D(latitude: 40.7549, longitude: -73.9840),
                        zoom: 16.4, bearing: 28, pitch: 55))
                    NSLog("PROBE: imports %@", map.styleImports.map { $0.id }.description)
                    for imp in map.styleImports {
                        let config = (try? map.getStyleImportConfigProperties(for: imp.id)) ?? [:]
                        let flat = config.map { "\($0.key)=\($0.value.value)" }.sorted().joined(separator: " ")
                        NSLog("PROBE: config %@ %@", imp.id, flat)
                    }
                    let layers = map.allLayerIdentifiers.map { "\($0.id):\($0.type.rawValue)" }
                    NSLog("PROBE: layers %@", layers.joined(separator: ","))
                    NSLog("PROBE: camera pitch=%f zoom=%f", Double(map.cameraState.pitch), Double(map.cameraState.zoom))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                        NSLog("PROBE: camera later pitch=%f zoom=%f lat=%f",
                              Double(map.cameraState.pitch), Double(map.cameraState.zoom), map.cameraState.center.latitude)
                    }
                }
            }.store(in: &cancelables)
'''
assert anchor in s
s = s.replace(anchor, probe + anchor, 1)
open(p, "w").write(s)
