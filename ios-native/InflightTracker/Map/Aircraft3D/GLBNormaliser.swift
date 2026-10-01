import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// Turns somebody else's aircraft model into one Mapbox can draw on the map.
///
/// ## Why the models are rewritten rather than used as they come
///
/// The three sources were built for three different viewers, and Mapbox's
/// model loader is the narrowest of them:
///
/// - **FlightAirMap** points its noses wherever its exporter left them, keeps
///   its origin at the nose or the wingtip, and indexes most of its meshes with
///   single bytes.
/// - **Flightradar24** is glTF 1.0, which Mapbox does not read at all.
/// - **All of them** interleave vertex attributes in places, and Mapbox's
///   loader copies positions as one tight run of floats.
///
/// So every model goes through the same pass, on the phone, the first time it
/// is wanted: glTF 1.0 is read as well as 2.0, every node's transform is baked
/// into its vertices, the aeroplane is turned to face the way the map expects
/// (nose along −Z, up along +Y), centred, stood on Y = 0, kept in metres,
/// and written back out as the simplest glTF there is — one
/// buffer, tightly packed floats, 16-bit indices, one primitive per material.
/// That last part is also what keeps a few hundred of them cheap: a model that
/// arrived as five hundred primitives is drawn in a few dozen calls.
///
/// ## Textures
///
/// Each picture is written once however many materials share it, shrunk to
/// at most `maximumTextureSide` and re-encoded as plain 8-bit JPEG or PNG.
/// The first version copied a shared picture once per material: a Flightradar24
/// 737 shares one 2048-pixel livery between 94 materials, which is 94 copies
/// and over a gigabyte of graphics memory for one aeroplane — and iOS ends an
/// app that asks for that.
///
/// ## Licences
///
/// The models are GPL. The app never ships them: each is downloaded from the
/// repository it is published in, and this pass runs on the device, for that
/// device. The original copyright notice is carried into the rewritten file's
/// `asset.copyright`, and what was changed is recorded beside it, as the GPL
/// asks of a modified copy.
///
/// The design was prototyped and checked against every model in all three
/// sources — the Khronos validator, and Mapbox's own renderer — before it was
/// written here.
enum GLBNormaliser {

    enum Failure: Error {
        case notGLB
        case unsupportedVersion(Int)
        case noBinaryBody
        case noGeometry
    }

    /// A signed model axis.
    enum Axis: String {
        case px = "+x", nx = "-x", py = "+y", ny = "-y", pz = "+z", nz = "-z"

        var vector: SIMD3<Double> {
            switch self {
            case .px: return [1, 0, 0]
            case .nx: return [-1, 0, 0]
            case .py: return [0, 1, 0]
            case .ny: return [0, -1, 0]
            case .pz: return [0, 0, 1]
            case .nz: return [0, 0, -1]
            }
        }
    }

    struct Output {
        /// The rewritten model, in metres.
        let data: Data
        /// The aeroplane's real length.
        let lengthMetres: Double
        let spanMetres: Double
        let heightMetres: Double
    }

    /// Bumped whenever the output changes, so the cache throws away models
    /// rewritten by an older version of this pass.
    static let version = 4

    /// Which copy of the model to write.
    ///
    /// `near` is the model as published, cleaned up. `far` is the same model
    /// — every triangle of it — drawn larger than life when it is shorter
    /// than `farMinimumLength`: in true proportion to an airliner a light
    /// aircraft is a few points long on a zoomed-out map, and nobody can see
    /// it. The map draws light aircraft from this copy at every zoom.
    enum Detail {
        case near
        case far
    }

    static let farMinimumLength: Float = 16

    /// The longest side any texture is written at. A model on a map is never
    /// more than a few hundred points long, and 512 pixels across a fuselage
    /// is still more detail than that shows.
    static let maximumTextureSide = 512

    static func normalise(
        _ data: Data,
        forward: Axis,
        up: Axis,
        notice: String,
        detail: Detail = .near
    ) throws -> Output {
        var document = try Document(glb: data)
        if document.version == 1 { document.upgradeFromVersion1() }
        return try document.repack(forward: forward, up: up, notice: notice, detail: detail)
    }
}

// MARK: - The document

private struct Document {

    var version: Int
    var json: [String: Any]
    let body: [UInt8]

    // MARK: Reading the container

    init(glb data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes[0] == 0x67, bytes[1] == 0x6C, bytes[2] == 0x54, bytes[3] == 0x46 else {
            throw GLBNormaliser.Failure.notGLB
        }
        let version = Int(Self.u32(bytes, 4))
        self.version = version

        switch version {
        case 2:
            var offset = 12
            var parsed: [String: Any]?
            var chunk: [UInt8] = []
            while offset + 8 <= bytes.count {
                let length = Int(Self.u32(bytes, offset))
                let type = Self.u32(bytes, offset + 4)
                let start = offset + 8
                let end = start + length
                guard length >= 0, end <= bytes.count else { break }
                if type == 0x4E4F_534A {
                    parsed = try JSONSerialization.jsonObject(with: Data(bytes[start..<end])) as? [String: Any]
                } else if type == 0x004E_4942 {
                    chunk = Array(bytes[start..<end])
                }
                offset = end
            }
            guard let parsed else { throw GLBNormaliser.Failure.notGLB }
            self.json = parsed
            self.body = chunk

        case 1:
            // KHR_binary_glTF: a 20-byte header, the JSON, then the body.
            let length = Int(Self.u32(bytes, 12))
            let end = 20 + length
            guard end <= bytes.count else { throw GLBNormaliser.Failure.notGLB }
            guard let parsed = try JSONSerialization.jsonObject(with: Data(bytes[20..<end])) as? [String: Any] else {
                throw GLBNormaliser.Failure.notGLB
            }
            self.json = parsed
            self.body = Array(bytes[end...])

        default:
            throw GLBNormaliser.Failure.unsupportedVersion(version)
        }
    }

    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    // MARK: glTF 1.0

    /// Rewrites a 1.0 document's JSON as 2.0 over the same body.
    ///
    /// 1.0 keys everything by name and 2.0 by index; 1.0 puts a stride on the
    /// accessor and 2.0 on the view, so every accessor gets a view of its own;
    /// 1.0 describes materials as shader parameters, of which only the
    /// diffuse colour or texture, transparency and emission are carried
    /// across. Animations, skins, cameras and lights are dropped.
    mutating func upgradeFromVersion1() {
        let buffers = json["buffers"] as? [String: [String: Any]] ?? [:]
        let bodyKey = buffers["binary_glTF"] != nil
            ? "binary_glTF"
            : buffers.first(where: { $0.key == "KHR_binary_glTF" || ($0.value["uri"] as? String ?? "") == "data:," })?.key

        let views1 = json["bufferViews"] as? [String: [String: Any]] ?? [:]
        var views: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var images: [[String: Any]] = []
        var samplers: [[String: Any]] = []
        var textures: [[String: Any]] = []
        var materials: [[String: Any]] = []
        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []

        func newView(_ id: String, stride: Int? = nil) -> Int? {
            guard let view = views1[id], let bodyKey, view["buffer"] as? String == bodyKey else { return nil }
            var out: [String: Any] = [
                "buffer": 0,
                "byteOffset": Self.int(view["byteOffset"]) ?? 0,
                "byteLength": Self.int(view["byteLength"]) ?? 0,
            ]
            if let stride { out["byteStride"] = stride }
            views.append(out)
            return views.count - 1
        }

        var accessorIndex: [String: Int] = [:]
        for (id, accessor) in json["accessors"] as? [String: [String: Any]] ?? [:] {
            guard let viewId = accessor["bufferView"] as? String,
                  let componentType = Self.int(accessor["componentType"]),
                  let componentSize = Accessor.componentSize(componentType),
                  let type = accessor["type"] as? String,
                  let components = Accessor.components(type) else { continue }
            let stride = Self.int(accessor["byteStride"]) ?? 0
            let element = componentSize * components
            guard let view = newView(viewId, stride: stride > 0 && stride != element ? stride : nil) else { continue }
            var out: [String: Any] = [
                "bufferView": view,
                "byteOffset": Self.int(accessor["byteOffset"]) ?? 0,
                "componentType": componentType,
                "count": Self.int(accessor["count"]) ?? 0,
                "type": type,
            ]
            if let min = accessor["min"], let max = accessor["max"] {
                out["min"] = min
                out["max"] = max
            }
            accessors.append(out)
            accessorIndex[id] = accessors.count - 1
        }

        var samplerIndex: [String: Int] = [:]
        for (id, sampler) in json["samplers"] as? [String: [String: Any]] ?? [:] {
            samplers.append(sampler.filter { ["magFilter", "minFilter", "wrapS", "wrapT"].contains($0.key) })
            samplerIndex[id] = samplers.count - 1
        }

        var imageIndex: [String: Int] = [:]
        for (id, image) in json["images"] as? [String: [String: Any]] ?? [:] {
            let extensions = image["extensions"] as? [String: Any]
            if let binary = extensions?["KHR_binary_glTF"] as? [String: Any],
               let viewId = binary["bufferView"] as? String,
               let view = newView(viewId) {
                images.append(["bufferView": view, "mimeType": binary["mimeType"] as? String ?? "image/png"])
            } else if let uri = image["uri"] as? String, uri.hasPrefix("data:image/") {
                images.append(["uri": uri])
            } else {
                continue
            }
            imageIndex[id] = images.count - 1
        }

        var textureIndex: [String: Int] = [:]
        for (id, texture) in json["textures"] as? [String: [String: Any]] ?? [:] {
            guard let source = texture["source"] as? String, let image = imageIndex[source] else { continue }
            var out: [String: Any] = ["source": image]
            if let sampler = texture["sampler"] as? String, let index = samplerIndex[sampler] { out["sampler"] = index }
            textures.append(out)
            textureIndex[id] = textures.count - 1
        }

        var materialIndex: [String: Int] = [:]
        for (id, material) in json["materials"] as? [String: [String: Any]] ?? [:] {
            var values = material["values"] as? [String: Any] ?? [:]
            if let common = (material["extensions"] as? [String: Any])?["KHR_materials_common"] as? [String: Any],
               let commonValues = common["values"] as? [String: Any] {
                values = commonValues
            }
            var pbr: [String: Any] = ["metallicFactor": 0.0, "roughnessFactor": 0.8]
            var out: [String: Any] = ["doubleSided": true]
            var alpha = 1.0
            if let name = values["diffuse"] as? String, let texture = textureIndex[name] {
                pbr["baseColorTexture"] = ["index": texture]
            } else if let colour = Self.doubles(values["diffuse"]), colour.count >= 3 {
                let rgba = Array(colour.prefix(4)) + Array(repeating: 1.0, count: max(0, 4 - colour.count))
                alpha = rgba[3]
                pbr["baseColorFactor"] = rgba
            }
            if let transparency = Self.double(values["transparency"]), transparency < 1 { alpha *= transparency }
            if alpha < 0.999 {
                var factor = Self.doubles(pbr["baseColorFactor"]) ?? [1, 1, 1, 1]
                factor[3] = alpha
                pbr["baseColorFactor"] = factor
                out["alphaMode"] = "BLEND"
            }
            if let emission = Self.doubles(values["emission"]), emission.count >= 3, emission.prefix(3).max() ?? 0 > 0 {
                out["emissiveFactor"] = Array(emission.prefix(3))
            }
            out["pbrMetallicRoughness"] = pbr
            materials.append(out)
            materialIndex[id] = materials.count - 1
        }

        var meshIndex: [String: Int] = [:]
        for (id, mesh) in json["meshes"] as? [String: [String: Any]] ?? [:] {
            var primitives: [[String: Any]] = []
            for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
                guard (Self.int(primitive["mode"]) ?? 4) == 4 else { continue }
                var attributes: [String: Int] = [:]
                for (name, accessor) in primitive["attributes"] as? [String: String] ?? [:] {
                    guard ["POSITION", "NORMAL", "TEXCOORD_0"].contains(name), let index = accessorIndex[accessor] else { continue }
                    attributes[name] = index
                }
                guard attributes["POSITION"] != nil else { continue }
                var out: [String: Any] = ["attributes": attributes, "mode": 4]
                if let indices = primitive["indices"] as? String {
                    guard let index = accessorIndex[indices] else { continue }
                    out["indices"] = index
                }
                if let material = primitive["material"] as? String, let index = materialIndex[material] {
                    out["material"] = index
                }
                primitives.append(out)
            }
            guard !primitives.isEmpty else { continue }
            meshes.append(["primitives": primitives])
            meshIndex[id] = meshes.count - 1
        }

        let nodes1 = json["nodes"] as? [String: [String: Any]] ?? [:]
        let order = Array(nodes1.keys)
        var nodeIndex: [String: Int] = [:]
        for (offset, id) in order.enumerated() { nodeIndex[id] = offset }
        nodes = Array(repeating: [:], count: order.count)
        for id in order {
            guard let node1 = nodes1[id], let index = nodeIndex[id] else { continue }
            var node: [String: Any] = [:]
            if let matrix = Self.doubles(node1["matrix"]), matrix.count == 16 {
                node["matrix"] = matrix
            } else {
                for key in ["translation", "rotation", "scale"] { if let value = node1[key] { node[key] = value } }
            }
            var children = (node1["children"] as? [String] ?? []).compactMap { nodeIndex[$0] }
            let attached = (node1["meshes"] as? [String] ?? []).compactMap { meshIndex[$0] }
            if let first = attached.first {
                node["mesh"] = first
                for extra in attached.dropFirst() {
                    nodes.append(["mesh": extra])
                    children.append(nodes.count - 1)
                }
            }
            if !children.isEmpty { node["children"] = children }
            nodes[index] = node
        }

        let scenes = json["scenes"] as? [String: [String: Any]] ?? [:]
        let sceneId = json["scene"] as? String ?? scenes.keys.first
        let roots = (sceneId.flatMap { scenes[$0] }?["nodes"] as? [String] ?? []).compactMap { nodeIndex[$0] }

        var upgraded: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": body.count]],
            "bufferViews": views,
            "accessors": accessors,
            "meshes": meshes,
            "nodes": nodes,
            "scenes": [["nodes": roots]],
            "scene": 0,
        ]
        if let copyright = (json["asset"] as? [String: Any])?["copyright"] {
            upgraded["asset"] = ["version": "2.0", "copyright": copyright]
        }
        if !materials.isEmpty { upgraded["materials"] = materials }
        if !textures.isEmpty { upgraded["textures"] = textures }
        if !images.isEmpty { upgraded["images"] = images }
        if !samplers.isEmpty { upgraded["samplers"] = samplers }
        json = upgraded
        version = 2
    }

    // MARK: Reading data

    private func array(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }

    /// An accessor as floats, `components` to an element. Normalised integers
    /// are scaled the way the spec says; anything else that is not a float is
    /// refused, because an unnormalised integer position is a quantised model
    /// this pass does not know the dequantisation of.
    func floats(_ index: Int, components: Int) -> [Float]? {
        guard let accessor = Accessor(document: self, index: index),
              accessor.components == components else { return nil }
        let scale: Float?
        switch accessor.componentType {
        case 5126: scale = nil
        case 5120 where accessor.normalized: scale = 127
        case 5121 where accessor.normalized: scale = 255
        case 5122 where accessor.normalized: scale = 32767
        case 5123 where accessor.normalized: scale = 65535
        default: return nil
        }
        var out = [Float]()
        out.reserveCapacity(accessor.count * components)
        for element in 0..<accessor.count {
            for component in 0..<components {
                guard let raw = accessor.value(element, component, in: body) else { return nil }
                out.append(scale.map { max(Float(raw) / $0, -1) } ?? Float(raw))
            }
        }
        return out
    }

    func indices(_ index: Int) -> [Int]? {
        guard let accessor = Accessor(document: self, index: index), accessor.components == 1,
              [5121, 5123, 5125].contains(accessor.componentType) else { return nil }
        var out = [Int]()
        out.reserveCapacity(accessor.count)
        for element in 0..<accessor.count {
            guard let raw = accessor.value(element, 0, in: body) else { return nil }
            out.append(Int(raw))
        }
        return out
    }

    // MARK: Walking the scene

    /// Every mesh in the default scene, with the transform it is drawn at.
    func meshInstances() -> [(mesh: [String: Any], world: simd_double4x4)] {
        let nodes = array("nodes")
        let meshes = array("meshes")
        let scenes = array("scenes")
        let sceneIndex = Self.int(json["scene"]) ?? 0
        guard sceneIndex < scenes.count else { return [] }
        let roots = scenes[sceneIndex]["nodes"] as? [Int] ?? (scenes[sceneIndex]["nodes"] as? [Any])?.compactMap { Self.int($0) } ?? []

        var out: [(mesh: [String: Any], world: simd_double4x4)] = []
        var stack: [(index: Int, parent: simd_double4x4, depth: Int)] = roots.map { ($0, matrix_identity_double4x4, 0) }
        var visits = 0
        while let entry = stack.popLast() {
            let (index, parent, depth) = entry
            visits += 1
            guard index >= 0, index < nodes.count, depth < 64, visits < 100_000 else { continue }
            let node = nodes[index]
            let world = parent * Self.localMatrix(node)
            if let mesh = Self.int(node["mesh"]), mesh >= 0, mesh < meshes.count {
                out.append((meshes[mesh], world))
            }
            for child in (node["children"] as? [Any] ?? []).compactMap({ Self.int($0) }) {
                stack.append((child, world, depth + 1))
            }
        }
        return out
    }

    static func localMatrix(_ node: [String: Any]) -> simd_double4x4 {
        if let m = doubles(node["matrix"]), m.count == 16 {
            return simd_double4x4(columns: (
                [m[0], m[1], m[2], m[3]], [m[4], m[5], m[6], m[7]],
                [m[8], m[9], m[10], m[11]], [m[12], m[13], m[14], m[15]]
            ))
        }
        let t = doubles(node["translation"]) ?? [0, 0, 0]
        let r = doubles(node["rotation"]) ?? [0, 0, 0, 1]
        let s = doubles(node["scale"]) ?? [1, 1, 1]
        guard t.count == 3, r.count == 4, s.count == 3 else { return matrix_identity_double4x4 }
        let rotation = simd_double3x3(simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
        let linear = rotation * simd_double3x3(diagonal: [s[0], s[1], s[2]])
        return simd_double4x4(columns: (
            SIMD4(linear.columns.0, 0), SIMD4(linear.columns.1, 0),
            SIMD4(linear.columns.2, 0), SIMD4(t[0], t[1], t[2], 1)
        ))
    }

    // MARK: Repacking

    private struct Group {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [Int] = []
        var everyPrimitiveHasUVs = true
    }

    func repack(
        forward: GLBNormaliser.Axis,
        up: GLBNormaliser.Axis,
        notice: String,
        detail: GLBNormaliser.Detail
    ) throws -> GLBNormaliser.Output {
        // Model axes to the map's: X right, Y up, the nose along −Z.
        let f = forward.vector
        let u = up.vector
        let right = simd_cross(f, u)
        let canonical = simd_double3x3(rows: [right, u, -f])

        var groups: [Int: Group] = [:]

        // Materials that would draw identically are drawn as one: the same
        // picture, colour, glow and transparency. Flightradar24's 737s carry
        // over ninety materials that come down to nine.
        var representative: [String: Int] = [:]
        var mergedMaterial: [Int: Int] = [:]
        func merged(_ material: Int) -> Int {
            if let known = mergedMaterial[material] { return known }
            let key = materialKey(material)
            let chosen = representative[key] ?? material
            representative[key] = chosen
            mergedMaterial[material] = chosen
            return chosen
        }

        for (mesh, world) in meshInstances() {
            let linear = canonical * simd_double3x3(
                SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)
            )
            let translation = canonical * SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            let normalMatrix = abs(linear.determinant) > 1e-12 ? linear.inverse.transpose : linear

            for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
                guard (Self.int(primitive["mode"]) ?? 4) == 4,
                      let attributes = primitive["attributes"] as? [String: Any],
                      let positionIndex = Self.int(attributes["POSITION"]),
                      let positions = floats(positionIndex, components: 3) else { continue }
                let vertexCount = positions.count / 3
                let normals = Self.int(attributes["NORMAL"]).flatMap { floats($0, components: 3) }
                let uvs = Self.int(attributes["TEXCOORD_0"]).flatMap { floats($0, components: 2) }
                var triangles: [Int]
                if let indicesIndex = Self.int(primitive["indices"]) {
                    guard let read = indices(indicesIndex) else { continue }
                    triangles = read
                } else {
                    triangles = Array(0..<vertexCount)
                }
                triangles.removeLast(triangles.count % 3)
                guard !triangles.isEmpty, triangles.allSatisfy({ $0 >= 0 && $0 < vertexCount }) else { continue }

                let material = merged(Self.int(primitive["material"]) ?? -1)
                var group = groups[material] ?? Group()
                let base = group.positions.count

                for v in 0..<vertexCount {
                    let p = SIMD3(Double(positions[v * 3]), Double(positions[v * 3 + 1]), Double(positions[v * 3 + 2]))
                    let moved = linear * p + translation
                    group.positions.append(SIMD3<Float>(Float(moved.x), Float(moved.y), Float(moved.z)))
                }

                if let normals, normals.count == positions.count {
                    for v in 0..<vertexCount {
                        let n = normalMatrix * SIMD3(Double(normals[v * 3]), Double(normals[v * 3 + 1]), Double(normals[v * 3 + 2]))
                        let length = simd_length(n)
                        let unit = length > 0 ? n / length : SIMD3(0, 1, 0)
                        group.normals.append(SIMD3<Float>(Float(unit.x), Float(unit.y), Float(unit.z)))
                    }
                } else {
                    // None given: the faces' own, summed at each corner.
                    var summed = Array(repeating: SIMD3<Float>(0, 0, 0), count: vertexCount)
                    for t in stride(from: 0, to: triangles.count, by: 3) {
                        let a = group.positions[base + triangles[t]]
                        let b = group.positions[base + triangles[t + 1]]
                        let c = group.positions[base + triangles[t + 2]]
                        let n = simd_cross(b - a, c - a)
                        for corner in triangles[t..<(t + 3)] { summed[corner] += n }
                    }
                    for n in summed {
                        let length = simd_length(n)
                        group.normals.append(length > 0 ? n / length : SIMD3<Float>(0, 1, 0))
                    }
                }

                if let uvs, uvs.count == vertexCount * 2 {
                    for v in 0..<vertexCount { group.uvs.append(SIMD2<Float>(uvs[v * 2], uvs[v * 2 + 1])) }
                } else {
                    group.uvs.append(contentsOf: Array(repeating: SIMD2<Float>(0, 0), count: vertexCount))
                    group.everyPrimitiveHasUVs = false
                }

                group.indices.append(contentsOf: triangles.map { base + $0 })
                groups[material] = group
            }
        }

        // The box, and the move that centres the aeroplane over its origin and
        // stands it on the ground.
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for group in groups.values {
            for p in group.positions {
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        guard low.x <= high.x else { throw GLBNormaliser.Failure.noGeometry }
        let size = high - low
        let length = Double(size.z)
        guard length > 0.01 else { throw GLBNormaliser.Failure.noGeometry }
        let offset = SIMD3<Float>(-(low.x + high.x) / 2, -low.y, -(low.z + high.z) / 2)

        // The far copy: light aircraft drawn larger than life.
        let boost = detail == .far ? max(1, GLBNormaliser.farMinimumLength / Float(length)) : 1
        let textureSide = GLBNormaliser.maximumTextureSide

        var writer = Writer()
        let sourceMaterials = array("materials")
        var textureCache: [Int: Int?] = [:]
        var imageCache: [Int: Int?] = [:]

        for material in groups.keys.sorted() {
            guard let group = groups[material], !group.indices.isEmpty else { continue }
            let source = material >= 0 && material < sourceMaterials.count ? sourceMaterials[material] : [:]
            var texture: Int?
            if group.everyPrimitiveHasUVs,
               let pbr = source["pbrMetallicRoughness"] as? [String: Any],
               let reference = pbr["baseColorTexture"] as? [String: Any],
               let index = Self.int(reference["index"]) {
                if let cached = textureCache[index] {
                    texture = cached
                } else {
                    texture = copyTexture(index, into: &writer, images: &imageCache, side: textureSide)
                    textureCache[index] = texture
                }
            }
            let materialIndex = writer.addMaterial(from: source, texture: texture)

            // Chunks of at most 65,535 vertices, so every index fits in 16 bits.
            var cursor = 0
            var remap = Array(repeating: -1, count: group.positions.count)
            while cursor < group.indices.count {
                var used: [Int] = []
                var chunk: [UInt16] = []
                while cursor < group.indices.count {
                    let triangle = group.indices[cursor..<(cursor + 3)]
                    let fresh = Set(triangle.filter { remap[$0] < 0 }).count
                    if used.count + fresh > 65_535 { break }
                    for vertex in triangle {
                        if remap[vertex] < 0 {
                            remap[vertex] = used.count
                            used.append(vertex)
                        }
                        chunk.append(UInt16(remap[vertex]))
                    }
                    cursor += 3
                }
                for vertex in used { remap[vertex] = -1 }
                guard !chunk.isEmpty else { break }

                let positions = used.map { (group.positions[$0] + offset) * boost }
                writer.addPrimitive(
                    positions: positions,
                    normals: used.map { group.normals[$0] },
                    uvs: texture == nil ? nil : used.map { group.uvs[$0] },
                    indices: chunk,
                    material: materialIndex
                )
            }
        }

        var asset: [String: Any] = [
            "version": "2.0",
            "generator": "Inflight model normaliser \(GLBNormaliser.version)",
            "extras": ["inflight": notice],
        ]
        if let copyright = (json["asset"] as? [String: Any])?["copyright"] as? String {
            asset["copyright"] = copyright
        }
        return GLBNormaliser.Output(
            data: try writer.glb(asset: asset),
            lengthMetres: length,
            spanMetres: Double(size.x),
            heightMetres: Double(size.y)
        )
    }

    /// What a material looks like, as far as the rewritten model draws it.
    private func materialKey(_ index: Int) -> String {
        let materials = array("materials")
        guard index >= 0, index < materials.count else { return "none" }
        let material = materials[index]
        let pbr = material["pbrMetallicRoughness"] as? [String: Any] ?? [:]
        var picture = "-"
        if let reference = pbr["baseColorTexture"] as? [String: Any], let texture = Self.int(reference["index"]) {
            let textures = array("textures")
            picture = texture >= 0 && texture < textures.count
                ? "\(Self.int(textures[texture]["source"]) ?? -1)"
                : "-"
        }
        func rounded(_ values: [Double]?) -> String {
            (values ?? []).map { String(format: "%.2f", $0) }.joined(separator: ",")
        }
        return [
            picture,
            rounded(Self.doubles(pbr["baseColorFactor"])),
            rounded(Self.doubles(material["emissiveFactor"])),
            material["alphaMode"] as? String ?? "OPAQUE",
            (material["doubleSided"] as? Bool ?? false) ? "2" : "1",
        ].joined(separator: "|")
    }

    /// Copies one base colour texture across, and its picture the first time
    /// any texture uses it. Nothing if the picture is not a PNG or a JPEG held
    /// in the file, or cannot be read.
    private func copyTexture(
        _ index: Int,
        into writer: inout Writer,
        images imageCache: inout [Int: Int?],
        side: Int
    ) -> Int? {
        let textures = array("textures")
        let images = array("images")
        guard index >= 0, index < textures.count,
              let source = Self.int(textures[index]["source"]), source >= 0, source < images.count else { return nil }

        let samplers = array("samplers")
        let samplerIndex = Self.int(textures[index]["sampler"])
        let sampler = samplerIndex.flatMap { $0 >= 0 && $0 < samplers.count ? samplers[$0] : nil } ?? [:]

        if let cached = imageCache[source] {
            return cached.map { writer.addTexture(image: $0, sampler: sampler) }
        }
        let written = readImage(images[source], side: side).map { writer.addImage($0.bytes, mimeType: $0.mimeType) }
        imageCache[source] = written
        return written.map { writer.addTexture(image: $0, sampler: sampler) }
    }

    /// A picture from the file, shrunk and re-encoded.
    private func readImage(_ image: [String: Any], side: Int) -> (bytes: Data, mimeType: String)? {
        var bytes: [UInt8]?
        var mime = image["mimeType"] as? String ?? "image/png"
        if let viewIndex = Self.int(image["bufferView"]) {
            let views = array("bufferViews")
            if viewIndex >= 0, viewIndex < views.count {
                let start = Self.int(views[viewIndex]["byteOffset"]) ?? 0
                let length = Self.int(views[viewIndex]["byteLength"]) ?? 0
                if start >= 0, length > 0, start + length <= body.count { bytes = Array(body[start..<(start + length)]) }
            }
        } else if let uri = image["uri"] as? String, uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
            mime = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]).components(separatedBy: ";").first ?? mime
            bytes = Data(base64Encoded: String(uri[uri.index(after: comma)...])).map { [UInt8]($0) }
        }
        guard let bytes, mime == "image/png" || mime == "image/jpeg" else { return nil }
        return Self.shrink(Data(bytes), maximumSide: side)
    }

    /// Re-encodes a picture as 8-bit RGB(A), no larger than `maximumSide`:
    /// a JPEG when it is opaque, a PNG when it is not. Whatever bit depth,
    /// palette or colour model the source used, what comes out is the most
    /// ordinary image there is.
    static func shrink(_ data: Data, maximumSide: Int) -> (bytes: Data, mimeType: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let width = thumbnail.width
        let height = thumbnail.height
        guard width > 0, height > 0 else { return nil }
        let opaque: Bool
        switch thumbnail.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else { return nil }

        let out = NSMutableData()
        let type = opaque ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, flattened, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, opaque ? "image/jpeg" : "image/png")
    }

    // MARK: Loose JSON

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    static func doubles(_ value: Any?) -> [Double]? {
        guard let list = value as? [Any] else { return nil }
        let out = list.compactMap { double($0) }
        return out.count == list.count ? out : nil
    }
}

// MARK: - Accessors

private struct Accessor {
    let componentType: Int
    let components: Int
    let count: Int
    let normalized: Bool
    let start: Int
    let stride: Int
    let componentSize: Int

    init?(document: Document, index: Int) {
        let accessors = document.json["accessors"] as? [[String: Any]] ?? []
        let views = document.json["bufferViews"] as? [[String: Any]] ?? []
        guard index >= 0, index < accessors.count else { return nil }
        let accessor = accessors[index]
        guard let viewIndex = Document.int(accessor["bufferView"]), viewIndex >= 0, viewIndex < views.count,
              let componentType = Document.int(accessor["componentType"]),
              let componentSize = Self.componentSize(componentType),
              let type = accessor["type"] as? String,
              let components = Self.components(type),
              let count = Document.int(accessor["count"]), count >= 0 else { return nil }
        let view = views[viewIndex]
        self.componentType = componentType
        self.components = components
        self.count = count
        self.normalized = accessor["normalized"] as? Bool ?? false
        self.componentSize = componentSize
        self.start = (Document.int(view["byteOffset"]) ?? 0) + (Document.int(accessor["byteOffset"]) ?? 0)
        let declared = Document.int(view["byteStride"]) ?? 0
        self.stride = declared > 0 ? declared : componentSize * components
    }

    static func componentSize(_ type: Int) -> Int? {
        switch type {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return nil
        }
    }

    static func components(_ type: String) -> Int? {
        ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16][type]
    }

    /// One component as a Double, or nil when it would read past the body.
    func value(_ element: Int, _ component: Int, in body: [UInt8]) -> Double? {
        let at = start + element * stride + component * componentSize
        guard at >= 0, at + componentSize <= body.count else { return nil }
        switch componentType {
        case 5126: return Double(Float(bitPattern: Document.u32(body, at)))
        case 5125: return Double(Document.u32(body, at))
        case 5123: return Double(UInt16(body[at]) | UInt16(body[at + 1]) << 8)
        case 5122: return Double(Int16(bitPattern: UInt16(body[at]) | UInt16(body[at + 1]) << 8))
        case 5121: return Double(body[at])
        case 5120: return Double(Int8(bitPattern: body[at]))
        default: return nil
        }
    }
}

// MARK: - Writing

private struct Writer {
    private var body = Data()
    private var views: [[String: Any]] = []
    private var accessors: [[String: Any]] = []
    private var materials: [[String: Any]] = []
    private var primitives: [[String: Any]] = []
    private var textures: [[String: Any]] = []
    private var images: [[String: Any]] = []
    private var samplers: [[String: Any]] = []

    private mutating func view(_ bytes: Data) -> Int {
        while body.count % 4 != 0 { body.append(0) }
        views.append(["buffer": 0, "byteOffset": body.count, "byteLength": bytes.count])
        body.append(bytes)
        return views.count - 1
    }

    private mutating func accessor(_ bytes: Data, componentType: Int, count: Int, type: String,
                                   min: [Double]? = nil, max: [Double]? = nil) -> Int {
        var out: [String: Any] = ["bufferView": view(bytes), "componentType": componentType, "count": count, "type": type]
        if let min, let max {
            out["min"] = min
            out["max"] = max
        }
        accessors.append(out)
        return accessors.count - 1
    }

    mutating func addImage(_ bytes: Data, mimeType: String) -> Int {
        let bufferView = view(bytes)
        images.append(["bufferView": bufferView, "mimeType": mimeType])
        return images.count - 1
    }

    mutating func addTexture(image: Int, sampler: [String: Any]) -> Int {
        samplers.append(sampler.filter { ["magFilter", "minFilter", "wrapS", "wrapT"].contains($0.key) })
        textures.append(["source": image, "sampler": samplers.count - 1])
        return textures.count - 1
    }

    /// The source material, reduced to what Mapbox draws: a base colour or
    /// texture, how see-through it is, and whether it glows. Factors are
    /// clamped to the range glTF allows — one of the sources writes an
    /// emission of 2.
    mutating func addMaterial(from source: [String: Any], texture: Int?) -> Int {
        let pbr = source["pbrMetallicRoughness"] as? [String: Any] ?? [:]
        func clamp(_ values: [Double]?, count: Int, fallback: Double) -> [Double] {
            let list = (values ?? []).prefix(count).map { Swift.min(Swift.max($0, 0), 1) }
            return list.count == count ? list : Array(repeating: fallback, count: count)
        }
        var outPbr: [String: Any] = [
            "baseColorFactor": clamp(Document.doubles(pbr["baseColorFactor"]), count: 4, fallback: 1),
            "metallicFactor": Swift.min(Document.double(pbr["metallicFactor"]) ?? 0, 0.3),
            "roughnessFactor": Swift.max(Document.double(pbr["roughnessFactor"]) ?? 0.8, 0.5),
        ]
        if let texture { outPbr["baseColorTexture"] = ["index": texture] }
        var out: [String: Any] = [
            "pbrMetallicRoughness": outPbr,
            "doubleSided": source["doubleSided"] as? Bool ?? false,
        ]
        if let mode = source["alphaMode"] as? String, ["OPAQUE", "MASK", "BLEND"].contains(mode) { out["alphaMode"] = mode }
        if let cutoff = Document.double(source["alphaCutoff"]) { out["alphaCutoff"] = Swift.max(cutoff, 0) }
        if let emissive = Document.doubles(source["emissiveFactor"]), emissive.count == 3 {
            out["emissiveFactor"] = clamp(emissive, count: 3, fallback: 0)
        }
        materials.append(out)
        return materials.count - 1
    }

    mutating func addPrimitive(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        uvs: [SIMD2<Float>]?,
        indices: [UInt16],
        material: Int
    ) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        var attributes: [String: Any] = [
            "POSITION": accessor(
                Self.packed(positions.flatMap { [$0.x, $0.y, $0.z] }), componentType: 5126, count: positions.count,
                type: "VEC3", min: [Double(low.x), Double(low.y), Double(low.z)],
                max: [Double(high.x), Double(high.y), Double(high.z)]
            ),
            "NORMAL": accessor(Self.packed(normals.flatMap { [$0.x, $0.y, $0.z] }), componentType: 5126,
                               count: normals.count, type: "VEC3"),
        ]
        if let uvs {
            attributes["TEXCOORD_0"] = accessor(Self.packed(uvs.flatMap { [$0.x, $0.y] }), componentType: 5126,
                                                count: uvs.count, type: "VEC2")
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexAccessor = accessor(indexData, componentType: 5123, count: indices.count, type: "SCALAR")
        primitives.append([
            "attributes": attributes,
            "indices": indexAccessor,
            "material": material,
            "mode": 4,
        ])
    }

    /// Little-endian floats, which is what every device this runs on is.
    private static func packed(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func glb(asset: [String: Any]) throws -> Data {
        var json: [String: Any] = [
            "asset": asset,
            "buffers": [["byteLength": body.count]],
            "bufferViews": views,
            "accessors": accessors,
            "materials": materials,
            "meshes": [["primitives": primitives]],
            "nodes": [["mesh": 0]],
            "scenes": [["nodes": [0]]],
            "scene": 0,
        ]
        if !textures.isEmpty {
            json["textures"] = textures
            json["images"] = images
            json["samplers"] = samplers
        }

        var text = try JSONSerialization.data(withJSONObject: json, options: [])
        while text.count % 4 != 0 { text.append(0x20) }
        var binary = body
        while binary.count % 4 != 0 { binary.append(0) }

        var out = Data()
        func u32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
        u32(2)
        u32(12 + 8 + text.count + 8 + binary.count)
        u32(text.count)
        u32(0x4E4F_534A)
        out.append(text)
        u32(binary.count)
        u32(0x004E_4942)
        out.append(binary)
        return out
    }
}
