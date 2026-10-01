import CoreLocation
import MapboxMaps
import UIKit

/// Every source and layer the map draws, and how each one looks.
///
/// ## Why the whole map is layers now
///
/// Under MapKit every aeroplane was a `UIView`, every route a renderer drawing
/// into tiles on the CPU, and every label a `UILabel` with a layer shadow. A
/// busy server put two thousand views on screen, and each pan and each pinch
/// moved all of them through Core Animation, re-culled them, re-rotated them
/// for the camera and re-rasterised the overlays underneath. That was the
/// ceiling on how smooth the map could ever be.
///
/// Here every one of those is a feature in a GeoJSON source and a style layer
/// over it. Mapbox tiles the data once on a worker thread and draws the lot on
/// the GPU in a single pass per layer — a pinch moves nothing but the camera.
/// The sprites turn with their heading *on the GPU*, against the map rather
/// than the screen, so a spun or tilted globe needs no correction pass at all;
/// the line widths that taper as you pull back are zoom expressions evaluated
/// per frame; the labels declutter in Mapbox's own collision pass.
///
/// ## Why they are written as JSON
///
/// The style specification is the contract Mapbox actually renders, and it is
/// the same on every platform. Writing the layers in it directly keeps each
/// one readable as a block — what it draws, how, and where in the stack —
/// and keeps what is drawn identical to what the specification says.
///
/// ## Order
///
/// `install(on:)` adds everything once, in the order below, every time a style
/// loads. Nothing is added or removed after that except the weather rasters:
/// switching a layer off sets its visibility, and new data replaces a source's
/// contents. So the stack can never come out in a different order depending on
/// what happened to be switched on first.
enum MapLayerStyle {

    // MARK: - Identifiers

    enum Source {
        static let night = "inflight-night"
        static let atc = "inflight-atc"
        static let ground = "inflight-ground"
        static let nat = "inflight-nat"
        static let plan = "inflight-plan"
        static let inferred = "inflight-inferred"
        static let direct = "inflight-direct"
        static let flown = "inflight-flown"
        static let flownHead = "inflight-flown-head"
        static let measure = "inflight-measure"
        static let barbs = "inflight-barbs"
        static let fields = "inflight-fields"
        static let fixes = "inflight-fixes"
        static let traffic = "inflight-traffic"
        static let replay = "inflight-replay"
        static let heat = "inflight-heat"
        static let particles = "inflight-particles"
        static let weather = "inflight-weather"
        static let terrain = "inflight-terrain"
    }

    enum Layer {
        static let wash = "inflight-wash"
        static let weather = "inflight-weather"
        static let heat = "inflight-heat"
        static let particles = "inflight-particles"
        static let night = "inflight-night"
        static let atcFill = "inflight-atc-fill"
        static let atcLine = "inflight-atc-line"
        static let groundArea = "inflight-ground-area"
        static let taxiwayBody = "inflight-taxiway-body"
        static let taxiwayEdge = "inflight-taxiway-edge"
        static let runwayBody = "inflight-runway-body"
        static let runwayEdge = "inflight-runway-edge"
        static let groundCentre = "inflight-ground-centre"
        static let groundHold = "inflight-ground-hold"
        static let nat = "inflight-nat"
        static let planCasing = "inflight-plan-casing"
        static let plan = "inflight-plan"
        static let inferred = "inflight-inferred"
        static let flownHalo = "inflight-flown-halo"
        static let flown = "inflight-flown"
        static let flownHeadHalo = "inflight-flown-head-halo"
        static let flownHead = "inflight-flown-head"
        static let direct = "inflight-direct"
        static let measureLine = "inflight-measure-line"
        static let barbs = "inflight-barbs"
        static let groundLabels = "inflight-ground-labels"
        static let atcLabels = "inflight-atc-labels"
        static let natLabels = "inflight-nat-labels"
        static let fields = "inflight-fields"
        static let fixes = "inflight-fixes"
        static let trafficModels = "inflight-traffic-models"
        static let traffic = "inflight-traffic"
        static let trafficMarks = "inflight-traffic-marks"
        static let trafficLabels = "inflight-traffic-labels"
        static let replay = "inflight-replay"
        static let selected = "inflight-selected"
        static let selectedMark = "inflight-selected-mark"
        static let selectedLabel = "inflight-selected-label"
        static let measurePins = "inflight-measure-pins"
        static let measureLetters = "inflight-measure-letters"
    }

    /// The layers a tap can open something from, in the order they are asked.
    static let tappableTraffic = [Layer.selected, Layer.replay, Layer.traffic]
    static let tappableFields = [Layer.fields]

    // MARK: - Installing

    /// The font every label on the map is set in. Mapbox's own, served with
    /// the style, with a fallback that covers every script a callsign or a
    /// station name has ever been typed in.
    static let boldFont = ["DIN Pro Bold", "Arial Unicode MS Bold"]
    static let mediumFont = ["DIN Pro Medium", "Arial Unicode MS Regular"]

    /// Adds every source and layer, empty and in order. Safe to call again on
    /// a style that already has them; anything already there is left alone.
    static func install(on map: MapboxMap, labelMinZoom: Double) {
        let frequent: Set<String> = [Source.traffic, Source.replay]
        for id in [
            Source.night, Source.atc, Source.ground, Source.nat, Source.plan,
            Source.inferred, Source.direct, Source.flown, Source.flownHead,
            Source.measure, Source.barbs, Source.fields, Source.fixes,
            Source.traffic, Source.replay,
        ] where !map.sourceExists(withId: id) {
            // A tight buffer on the point sources that are rewritten often, so
            // a packet or a frame costs as little tiling as it can. Points do
            // not need the default's slack: a symbol is drawn whole across a
            // tile edge, and only lines and fills are clipped to their tiles.
            var tuning = frequent.contains(id) ? #", "buffer": 16"# : ""
            // And no deeper tiles than the data has detail for. Past a
            // source's maxzoom Mapbox overzooms the deepest tiles it made
            // instead of cutting new ones — which for a world-sized night band
            // or a continent of airspace is the difference between clipping a
            // giant polygon for every tile of a street-level view and not.
            if let depth = tileDepth[id] { tuning += ", \"maxzoom\": \(depth)" }
            let text = #"{"type": "geojson", "data": {"type": "FeatureCollection", "features": []}"# + tuning + "}"
            guard let properties = parse(text) as? [String: Any] else { continue }
            try? map.addSource(withId: id, properties: properties)
        }

        for layer in layers(labelMinZoom: labelMinZoom) {
            guard let id = layer["id"] as? String, !map.layerExists(withId: id) else { continue }
            do {
                try map.addLayer(with: selfLit(layer), layerPosition: nil)
            } catch {
                NSLog("[Map] layer %@ could not be added: %@", id, String(describing: error))
            }
        }
    }

    /// How deep each source is tiled, where that is shallower than Mapbox's
    /// default of 18. Each figure is the zoom past which the shape has no more
    /// detail to give: the terminator is a fade hundreds of kilometres wide,
    /// a sector boundary or a track is good to ten metres at zoom 9, and a
    /// route is good to a third of a metre at 14. The traffic, the pavement and
    /// the fixes keep the default — an aircraft taxiing at street zoom is
    /// moved a fraction of a metre a frame and has to land where it was put.
    private static let tileDepth: [String: Int] = [
        Source.night: 6,
        Source.atc: 9,
        Source.nat: 9,
        Source.barbs: 10,
        Source.plan: 14,
        Source.inferred: 14,
        Source.direct: 14,
    ]

    /// Where the weather tiles go, which are added and taken away after the
    /// style has loaded: directly over the wash, under everything the app draws
    /// on top of the ground.
    static func weatherPosition(on map: MapboxMap) -> LayerPosition? {
        map.layerExists(withId: Layer.wash) ? .above(Layer.wash) : nil
    }

    /// Where an image raster goes: under a given layer, or at the top of the
    /// stack if that layer is missing.
    static func position(below id: String, on map: MapboxMap) -> LayerPosition? {
        map.layerExists(withId: id) ? .below(id) : nil
    }

    // MARK: - The layers

    /// The layers, as the style specification writes them.
    ///
    /// Middle is above the basemap's land, water and roads and below its
    /// place labels — where the overlays have always sat. Top is above the
    /// basemap's points of interest. The traffic and its labels go in no slot
    /// at all, which on Mapbox Standard means on top of everything, the
    /// basemap's own labels included.
    private static func layers(labelMinZoom: Double) -> [[String: Any]] {
        let flownWidth = json(zoomRamp { FlownPathStyle.width(forCameraDistance: $0) })
        let haloWidth = json(zoomRamp { FlownPathStyle.width(forCameraDistance: $0) * FlownPathStyle.glowSpread })
        let planWidth = json(zoomRamp { PlanStyle.lineWidth(forCameraDistance: $0) })
        let casingWidth = json(zoomRamp { PlanStyle.casingWidth(forCameraDistance: $0) })
        let inferredWidth = json(zoomRamp { PlanStyle.inferredWidth(forCameraDistance: $0) })
        let planDash = json(dash(PlanStyle.dash, forWidth: PlanStyle.lineWidth(forCameraDistance: 150_000)))
        let casingDash = json(dash(PlanStyle.dash, forWidth: PlanStyle.casingWidth(forCameraDistance: 150_000)))
        let inferredDash = json(dash([2, 7], forWidth: PlanStyle.inferredWidth(forCameraDistance: 150_000)))
        let measureDash = json(dash([6, 5], forWidth: 2.4))
        let pavement = json(groundWidth())
        let markOffsetWithLabel = -(FlightMarkStyle.markLift + FlightMarkStyle.callsignHeight + 3)
        let markOffset = -FlightMarkStyle.markLift
        let padding = FlightMarkStyle.callsignPadding
        let plate = FlightMarkStyle.plateImage(isLight: false)
        let bold = json(boldFont)
        let medium = json(mediumFont)
        let modelScale = json(AircraftModelStyle.scaleExpression())
        let modelLift = json(AircraftModelStyle.liftExpression())

        func traffic(_ icon: String) -> String {
            """
            {
                "icon-image": ["get", "\(icon)"],
                "icon-rotate": ["get", "heading"],
                "icon-rotation-alignment": "map",
                "icon-pitch-alignment": "map",
                "icon-allow-overlap": true,
                "icon-ignore-placement": true,
                "symbol-z-order": "source"
            }
            """
        }

        func label(_ property: String, overlap: Bool) -> String {
            """
            {
                "text-field": ["get", "\(property)"],
                "text-font": \(bold),
                "text-size": 10,
                "text-letter-spacing": 0.02,
                "text-anchor": "bottom",
                "text-offset": [0, -1.55],
                "text-max-width": 30,
                "icon-image": "\(plate)",
                "icon-text-fit": "both",
                "icon-text-fit-padding": [1.5, \(padding), 1.5, \(padding)],
                "text-allow-overlap": \(overlap),
                "icon-allow-overlap": \(overlap),
                "text-ignore-placement": \(overlap),
                "icon-ignore-placement": \(overlap),
                "text-padding": 1
            }
            """
        }

        func mark(_ property: String, labelledBy labelProperty: String) -> String {
            """
            {
                "icon-image": ["get", "\(property)"],
                "icon-anchor": "bottom",
                "icon-offset": ["case", ["has", "\(labelProperty)"], ["literal", [0, \(markOffsetWithLabel)]], ["literal", [0, \(markOffset)]]],
                "icon-allow-overlap": true,
                "icon-ignore-placement": true
            }
            """
        }

        let text = """
        [
            {
                "id": "\(Layer.wash)", "type": "background", "slot": "middle",
                "layout": {"visibility": "none"},
                "paint": {"background-color": "#000000", "background-opacity": 0}
            },
            {
                "id": "\(Layer.night)", "type": "fill", "source": "\(Source.night)", "slot": "middle",
                "paint": {"fill-color": ["get", "color"], "fill-antialias": false}
            },
            {
                "id": "\(Layer.atcFill)", "type": "fill", "source": "\(Source.atc)", "slot": "middle",
                "filter": ["==", ["geometry-type"], "Polygon"],
                "paint": {"fill-color": "rgba(33,196,94,0.12)", "fill-antialias": false}
            },
            {
                "id": "\(Layer.atcLine)", "type": "line", "source": "\(Source.atc)", "slot": "middle",
                "filter": ["==", ["geometry-type"], "Polygon"],
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": "rgba(102,232,250,0.7)", "line-width": \(AtcSectorStyle.borderWidth)}
            },
            {
                "id": "\(Layer.groundArea)", "type": "fill", "source": "\(Source.ground)", "slot": "middle",
                "filter": ["==", ["geometry-type"], "Polygon"],
                "paint": {"fill-color": ["get", "fill"]}
            },
            {
                "id": "\(Layer.taxiwayBody)", "type": "line", "source": "\(Source.ground)", "slot": "middle",
                "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], "taxiway"]],
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "fill"], "line-width": \(pavement)}
            },
            {
                "id": "\(Layer.taxiwayEdge)", "type": "line", "source": "\(Source.ground)", "slot": "middle",
                "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], "taxiway"]],
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "edge"], "line-width": ["get", "edgeWidth"], "line-gap-width": \(pavement)}
            },
            {
                "id": "\(Layer.runwayBody)", "type": "line", "source": "\(Source.ground)", "slot": "middle",
                "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], "runway"]],
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "fill"], "line-width": \(pavement)}
            },
            {
                "id": "\(Layer.runwayEdge)", "type": "line", "source": "\(Source.ground)", "slot": "middle",
                "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], "runway"]],
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "edge"], "line-width": ["get", "edgeWidth"], "line-gap-width": \(pavement)}
            },
            {
                "id": "\(Layer.groundCentre)", "type": "line", "source": "\(Source.ground)", "slot": "middle",
                "minzoom": 13.5,
                "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], "runway"]],
                "paint": {
                    "line-color": ["get", "centre"],
                    "line-width": ["interpolate", ["exponential", 2], ["zoom"], 13.5, 0.7, 17, 1.6, 20, 4],
                    "line-dasharray": [6, 4]
                }
            },
            {
                "id": "\(Layer.groundHold)", "type": "line", "source": "\(Source.ground)", "slot": "middle",
                "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], "holdShort"]],
                "layout": {"line-cap": "butt"},
                "paint": {
                    "line-color": "\(rgba(AirportGroundStyle.holdBar))",
                    "line-width": ["interpolate", ["exponential", 2], ["zoom"], 13, 2.2, 18, 3, 21, 6]
                }
            },
            {
                "id": "\(Layer.nat)", "type": "line", "source": "\(Source.nat)", "slot": "middle",
                "filter": ["==", ["geometry-type"], "LineString"],
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "color"], "line-width": 2.6}
            },
            {
                "id": "\(Layer.planCasing)", "type": "line", "source": "\(Source.plan)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": "\(rgba(PlanStyle.casing))", "line-width": \(casingWidth), "line-dasharray": \(casingDash)}
            },
            {
                "id": "\(Layer.plan)", "type": "line", "source": "\(Source.plan)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": "\(rgba(PlanStyle.line))", "line-width": \(planWidth), "line-dasharray": \(planDash)}
            },
            {
                "id": "\(Layer.inferred)", "type": "line", "source": "\(Source.inferred)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": "rgba(255,255,255,0.34)", "line-width": \(inferredWidth), "line-dasharray": \(inferredDash)}
            },
            {
                "id": "\(Layer.flownHalo)", "type": "line", "source": "\(Source.flown)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "halo"], "line-width": \(haloWidth), "line-opacity": \(FlownPathStyle.glowOpacity), "line-blur": 1}
            },
            {
                "id": "\(Layer.flownHeadHalo)", "type": "line", "source": "\(Source.flownHead)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "halo"], "line-width": \(haloWidth), "line-opacity": \(FlownPathStyle.glowOpacity), "line-blur": 1}
            },
            {
                "id": "\(Layer.flown)", "type": "line", "source": "\(Source.flown)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "color"], "line-width": \(flownWidth)}
            },
            {
                "id": "\(Layer.flownHead)", "type": "line", "source": "\(Source.flownHead)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": ["get", "color"], "line-width": \(flownWidth)}
            },
            {
                "id": "\(Layer.direct)", "type": "line", "source": "\(Source.direct)", "slot": "middle",
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": "rgba(255,255,255,0.34)", "line-width": \(inferredWidth), "line-dasharray": \(inferredDash)}
            },
            {
                "id": "\(Layer.measureLine)", "type": "line", "source": "\(Source.measure)", "slot": "middle",
                "filter": ["==", ["geometry-type"], "LineString"],
                "layout": {"line-cap": "round", "line-join": "round"},
                "paint": {"line-color": "rgb(255,115,166)", "line-width": 2.4, "line-dasharray": \(measureDash)}
            },
            {
                "id": "\(Layer.barbs)", "type": "symbol", "source": "\(Source.barbs)", "slot": "top",
                "layout": {
                    "icon-image": ["get", "icon"],
                    "icon-rotate": ["get", "direction"],
                    "icon-rotation-alignment": "map",
                    "icon-allow-overlap": true,
                    "icon-ignore-placement": true
                }
            },
            {
                "id": "\(Layer.groundLabels)", "type": "symbol", "source": "\(Source.ground)", "slot": "top",
                "filter": ["==", ["geometry-type"], "Point"],
                "layout": {
                    "text-field": ["get", "text"],
                    "text-font": \(bold),
                    "text-size": ["get", "size"],
                    "symbol-sort-key": ["get", "rank"],
                    "text-padding": 2
                },
                "paint": {
                    "text-color": "#ffffff",
                    "text-opacity": ["get", "alpha"],
                    "text-halo-color": "rgba(0,0,0,0.9)",
                    "text-halo-width": 1.4,
                    "text-halo-blur": 0.6
                }
            },
            {
                "id": "\(Layer.atcLabels)", "type": "symbol", "source": "\(Source.atc)", "slot": "top",
                "filter": ["==", ["geometry-type"], "Point"],
                "layout": {"text-field": ["get", "label"], "text-font": \(medium), "text-size": 10, "text-max-width": 14},
                "paint": {
                    "text-color": "rgb(158,240,255)",
                    "text-halo-color": "rgba(0,0,0,0.85)",
                    "text-halo-width": 1.5,
                    "text-halo-blur": 0.6
                }
            },
            {
                "id": "\(Layer.natLabels)", "type": "symbol", "source": "\(Source.nat)", "slot": "top",
                "filter": ["==", ["geometry-type"], "Point"],
                "layout": {"text-field": ["get", "label"], "text-font": \(bold), "text-size": 10.5},
                "paint": {
                    "text-color": "#ffffff",
                    "text-halo-color": "rgba(0,0,0,0.9)",
                    "text-halo-width": 1.4,
                    "text-halo-blur": 0.6
                }
            },
            {
                "id": "\(Layer.fields)", "type": "symbol", "source": "\(Source.fields)", "slot": "top",
                "layout": {
                    "icon-image": ["get", "icon"],
                    "icon-anchor": "bottom",
                    "icon-offset": [0, -5],
                    "text-field": ["format", ["get", "icao"], {"text-color": ["get", "category"]}, ["get", "conditions"], {"font-scale": 0.86, "text-color": "#ffffff"}],
                    "text-font": \(bold),
                    "text-size": 9.5,
                    "text-anchor": "top",
                    "text-offset": [0, -0.35],
                    "text-max-width": 12,
                    "text-optional": true,
                    "symbol-sort-key": ["get", "rank"],
                    "icon-padding": 1
                },
                "paint": {
                    "icon-opacity": ["get", "alpha"],
                    "text-opacity": ["get", "alpha"],
                    "text-halo-color": "rgba(0,0,0,0.85)",
                    "text-halo-width": 1.3,
                    "text-halo-blur": 0.6
                }
            },
            {
                "id": "\(Layer.fixes)", "type": "symbol", "source": "\(Source.fixes)", "slot": "top",
                "layout": {
                    "icon-image": ["get", "icon"],
                    "icon-allow-overlap": true,
                    "text-field": ["get", "name"],
                    "text-font": \(bold),
                    "text-size": 10,
                    "text-anchor": "top",
                    "text-offset": [0, 0.7],
                    "text-optional": true,
                    "symbol-sort-key": ["get", "rank"]
                },
                "paint": {
                    "icon-opacity": ["get", "alpha"],
                    "text-opacity": ["get", "alpha"],
                    "text-color": ["get", "color"],
                    "text-halo-color": "rgba(0,0,0,0.85)",
                    "text-halo-width": 1.3,
                    "text-halo-blur": 0.6
                }
            },
            {
                "id": "\(Layer.trafficModels)", "type": "model", "source": "\(Source.traffic)",
                "filter": ["has", "model"],
                "layout": {"model-id": ["get", "model"]},
                "paint": {
                    "model-type": "common-3d",
                    "model-rotation": ["get", "mrot"],
                    "model-scale": \(modelScale),
                    "model-translation": \(modelLift),
                    "model-cast-shadows": false,
                    "model-receive-shadows": false,
                    "model-emissive-strength": 0.8,
                    "model-color": "#ffffff",
                    "model-color-mix-intensity": 0
                }
            },
            {
                "id": "\(Layer.traffic)", "type": "symbol", "source": "\(Source.traffic)",
                "layout": \(traffic("icon")),
                "paint": {"icon-opacity": ["case", ["has", "model"], 0, 1]}
            },
            {
                "id": "\(Layer.trafficMarks)", "type": "symbol", "source": "\(Source.traffic)",
                "minzoom": \(labelMinZoom),
                "filter": ["has", "mark"],
                "layout": \(mark("mark", labelledBy: "label"))
            },
            {
                "id": "\(Layer.trafficLabels)", "type": "symbol", "source": "\(Source.traffic)",
                "minzoom": \(labelMinZoom),
                "filter": ["has", "label"],
                "layout": \(label("label", overlap: false)),
                "paint": {"text-color": "#ffffff"}
            },
            {
                "id": "\(Layer.replay)", "type": "symbol", "source": "\(Source.replay)",
                "layout": \(traffic("icon"))
            },
            {
                "id": "\(Layer.selected)", "type": "symbol", "source": "\(Source.traffic)",
                "filter": ["==", ["get", "fid"], ""],
                "layout": \(traffic("iconSelected")),
                "paint": {"icon-opacity": ["case", ["has", "model"], 0, 1]}
            },
            {
                "id": "\(Layer.selectedMark)", "type": "symbol", "source": "\(Source.traffic)",
                "filter": ["all", ["has", "selectedMark"], ["==", ["get", "fid"], ""]],
                "layout": \(mark("selectedMark", labelledBy: "selectedLabel"))
            },
            {
                "id": "\(Layer.selectedLabel)", "type": "symbol", "source": "\(Source.traffic)",
                "filter": ["all", ["has", "selectedLabel"], ["==", ["get", "fid"], ""]],
                "layout": \(label("selectedLabel", overlap: true)),
                "paint": {"text-color": "#ffffff"}
            },
            {
                "id": "\(Layer.measurePins)", "type": "circle", "source": "\(Source.measure)",
                "filter": ["==", ["geometry-type"], "Point"],
                "paint": {
                    "circle-radius": 10,
                    "circle-color": "rgba(26,26,26,0.95)",
                    "circle-stroke-color": "rgb(255,115,166)",
                    "circle-stroke-width": 2,
                    "circle-pitch-alignment": "map"
                }
            },
            {
                "id": "\(Layer.measureLetters)", "type": "symbol", "source": "\(Source.measure)",
                "filter": ["==", ["geometry-type"], "Point"],
                "layout": {
                    "text-field": ["get", "letter"],
                    "text-font": \(bold),
                    "text-size": 11,
                    "text-allow-overlap": true,
                    "text-ignore-placement": true
                },
                "paint": {"text-color": "rgb(255,115,166)"}
            }
        ]
        """

        guard let parsed = parse(text) as? [[String: Any]] else {
            assertionFailure("The map's layer definitions are not valid JSON.")
            return []
        }
        return parsed
    }

    /// A layer that ignores the basemap's lighting and shows its own colours.
    ///
    /// Mapbox Standard lights everything placed in its slots, and lines,
    /// fills, circles, rasters and backgrounds take none of their own light
    /// by default. Under the night preset — the Black palette, and Auto in
    /// dark mode — that shades every track, taxiway and runway down to near
    /// black. An emissive strength of one draws the colour as written.
    /// Symbols already default to one.
    static func selfLit(_ layer: [String: Any]) -> [String: Any] {
        guard let type = layer["type"] as? String,
              ["line", "fill", "circle", "raster", "background"].contains(type)
        else { return layer }
        var lit = layer
        var paint = layer["paint"] as? [String: Any] ?? [:]
        paint["\(type)-emissive-strength"] = 1
        lit["paint"] = paint
        return lit
    }

    /// JSON text to Foundation objects, the form Mapbox's style calls take.
    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    /// Foundation objects to JSON text, for splicing a computed expression
    /// into a layer definition.
    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    // MARK: - Expressions

    /// A width that tapers as the camera pulls back, from a ramp written
    /// against the camera's distance.
    ///
    /// The styles here were tuned against MapKit's camera distance, and the
    /// numbers are good ones; rather than re-tune them, each is sampled at a
    /// spread of zooms and handed to Mapbox as a linear interpolation, which
    /// the GPU evaluates on every frame of a pinch. A track that fattens as you
    /// zoom in now fattens *with* the fingers rather than on the settle.
    static func zoomRamp(_ width: (CLLocationDistance) -> CGFloat) -> [Any] {
        var expression: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for zoom in stride(from: 1.0, through: 16.0, by: 1.5) {
            expression.append(zoom)
            expression.append(Double(width(cameraDistance(forZoom: zoom))))
        }
        return expression
    }

    /// Roughly how far back a camera stands, in metres, to show a given zoom
    /// on a phone — the bridge between the old camera-distance ramps and
    /// Mapbox's zoom levels. Exact at no latitude and close enough at all of
    /// them for a line width.
    static func cameraDistance(forZoom zoom: Double) -> CLLocationDistance {
        77_500_000 / pow(2, zoom)
    }

    /// A dash given in points, in the units Mapbox measures one in: multiples
    /// of the line's own width.
    static func dash(_ points: [Double], forWidth width: CGFloat) -> [Double] {
        let unit = max(Double(width), 0.5)
        return points.map { $0 / unit }
    }

    /// The width of a run of pavement: to scale, floored at something you can
    /// see.
    ///
    /// Each feature carries its real width in metres (`width`), the pixels a
    /// metre covers at zoom zero where it is (`scale`), and its floor in points
    /// (`minimum`). The true width doubles with every zoom, which is what the
    /// exponential interpolation between whole zooms reproduces.
    private static func groundWidth() -> [Any] {
        var expression: [Any] = ["interpolate", ["exponential", 2], ["zoom"]]
        for zoom in stride(from: 10.0, through: 22.0, by: 1.0) {
            let scaled: [Any] = ["*", ["get", "width"], ["get", "scale"], pow(2, zoom)]
            let floored: [Any] = ["max", ["get", "minimum"], scaled]
            expression.append(zoom)
            expression.append(floored)
        }
        return expression
    }

    /// A colour as the style specification writes one.
    static func rgba(_ colour: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "rgba(255,255,255,1)"
        }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let a = String(format: "%.3f", Double(min(max(alpha, 0), 1)))
        return "rgba(\(channel(red)),\(channel(green)),\(channel(blue)),\(a))"
    }

    /// A dynamic colour, resolved for one way round the map.
    static func rgba(_ colour: UIColor, isLight: Bool) -> String {
        rgba(colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: isLight ? .light : .dark)))
    }

    // MARK: - The scheme

    /// Re-colours every layer whose colour depends on which way round the map
    /// is drawn. Cheap: a handful of paint properties, no data touched.
    static func applyScheme(isLight: Bool, on map: MapboxMap) {
        func set(_ layer: String, _ property: String, _ value: Any) {
            guard map.layerExists(withId: layer) else { return }
            try? map.setLayerProperty(for: layer, property: property, value: value)
        }

        set(Layer.atcFill, "fill-color", rgba(AtcSectorStyle.fill, isLight: isLight))
        set(Layer.atcLine, "line-color", rgba(AtcSectorStyle.border, isLight: isLight))
        set(Layer.atcLabels, "text-color", rgba(AtcSectorStyle.label, isLight: isLight))

        let inferred = isLight ? "rgba(51,51,51,0.34)" : "rgba(255,255,255,0.34)"
        set(Layer.inferred, "line-color", inferred)
        set(Layer.direct, "line-color", inferred)

        set(Layer.measureLine, "line-color", rgba(MeasureStyle.line, isLight: isLight))
        set(Layer.measurePins, "circle-stroke-color", rgba(MeasureStyle.line, isLight: isLight))
        set(Layer.measurePins, "circle-color", rgba(MeasureStyle.pinFill, isLight: isLight))
        set(Layer.measureLetters, "text-color", rgba(MeasureStyle.line, isLight: isLight))

        // Lit by the style's own light, which at night is very little. The
        // models carry some light of their own so they stay aeroplanes rather
        // than silhouettes, and more of it on the dark map.
        set(Layer.trafficModels, "model-emissive-strength", isLight ? 0.3 : 0.8)

        // The callsign's plate and its ink follow the map underneath, so the
        // label is dark on a light map and light on a dark one.
        let plate = FlightMarkStyle.plateImage(isLight: isLight)
        let ink = isLight ? "rgba(20,20,20,1)" : "#ffffff"
        for layer in [Layer.trafficLabels, Layer.selectedLabel] {
            set(layer, "icon-image", plate)
            set(layer, "text-color", ink)
        }
    }

    /// Lays the brightness wash over the cartography, or takes it off.
    static func applyWash(_ wash: MapWash, on map: MapboxMap) {
        guard map.layerExists(withId: Layer.wash) else { return }
        try? map.setLayerProperty(for: Layer.wash, property: "visibility", value: wash.isVisible ? "visible" : "none")
        guard wash.isVisible else { return }
        try? map.setLayerProperty(for: Layer.wash, property: "background-color", value: wash.depth >= 0 ? "#000000" : "#ffffff")
        try? map.setLayerProperty(for: Layer.wash, property: "background-opacity", value: Double(wash.alpha))
    }

    static func setVisible(_ visible: Bool, layers ids: [String], on map: MapboxMap) {
        for id in ids where map.layerExists(withId: id) {
            try? map.setLayerProperty(for: id, property: "visibility", value: visible ? "visible" : "none")
        }
    }
}

/// How the marks over an aeroplane are drawn: the VA's logo and the callsign
/// on its plate, in the row above it.
///
/// The plate rather than a stroke or a halo on the glyphs: a stroke centred on
/// the outline eats the counters of a, e, 6, 8, 9 and 0 at ten points, and a
/// white label with a dark edge is very nearly nothing on the Light palette.
/// The plate is a stretchable image Mapbox fits to the text, so it costs one
/// texture for every callsign on the map.
enum FlightMarkStyle {

    /// How far above the sprite's top edge the marks sit, and the logo's side.
    static let markGap: CGFloat = 5
    static let markSide: CGFloat = 18

    /// From the aeroplane's centre to the bottom of the row of marks.
    static var markLift: CGFloat { AppConfig.iconPointSize / 2 + markGap + 4 }

    /// The plate's height, how far the text sits in from each end, and how
    /// round its corners are.
    static let callsignHeight: CGFloat = 15
    static let callsignPadding: CGFloat = 5
    static let callsignRadius: CGFloat = 4.5

    static func plateImage(isLight: Bool) -> String {
        isLight ? "inflight-plate-light" : "inflight-plate-dark"
    }

    /// The plate itself, drawn once per scheme.
    static func plate(isLight: Bool) -> UIImage {
        let side: CGFloat = 16
        let colour = isLight ? UIColor(white: 1, alpha: 0.80) : UIColor(white: 0, alpha: 0.62)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            colour.setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                cornerRadius: callsignRadius
            ).fill()
        }
    }
}
