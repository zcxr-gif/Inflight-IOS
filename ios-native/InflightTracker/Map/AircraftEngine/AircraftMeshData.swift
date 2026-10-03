import Foundation
import simd

/// One aircraft model as the engine draws it: read back out of the file
/// `GLBNormaliser` wrote, into plain arrays the GPU can take.
///
/// The file is always the normaliser's own, so this reads exactly that and
/// nothing else: one binary chunk, tightly packed float positions, normals and
/// texture coordinates, 16-bit indices, a primitive per material, pictures held
/// in the file. Anything else is refused rather than guessed at.
///
/// The model is in metres, nose along −Z, up along +Y, right wing along +X,
/// centred over its origin and standing on Y = 0.
struct AircraftMeshData {

    struct Material {
        var baseColor: SIMD4<Float>
        var emissive: SIMD3<Float>
        /// Index into `images`, for a model with a base colour picture.
        var image: Int?
        /// Drawn see-through, after everything solid.
        var blends: Bool
        /// For a cut-out material: below this alpha nothing is drawn.
        var cutoff: Float?
    }

    /// Everything drawn with one material, as one indexed triangle list.
    struct Part {
        var material: Int
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
    }

    var parts: [Part]
    var materials: [Material]
    /// The pictures, as the PNG or JPEG bytes they were written as.
    var images: [Data]
    var lengthMetres: Float

    enum Failure: Error {
        case notGLB
        case malformed
    }

    // MARK: - Reading

    static func read(_ data: Data) throws -> AircraftMeshData {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes[0] == 0x67, bytes[1] == 0x6C, bytes[2] == 0x54, bytes[3] == 0x46,
              u32(bytes, 4) == 2 else { throw Failure.notGLB }

        var json: [String: Any]?
        var body: [UInt8] = []
        var offset = 12
        while offset + 8 <= bytes.count {
            let length = Int(u32(bytes, offset))
            let type = u32(bytes, offset + 4)
            let start = offset + 8
            let end = start + length
            guard end <= bytes.count else { break }
            if type == 0x4E4F_534A {
                json = try JSONSerialization.jsonObject(with: Data(bytes[start..<end])) as? [String: Any]
            } else if type == 0x004E_4942 {
                body = Array(bytes[start..<end])
            }
            offset = end
        }
        guard let json else { throw Failure.notGLB }
        return try Reader(json: json, body: body).mesh()
    }

    fileprivate static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    // MARK: - The far copy

    /// The same aeroplane in far fewer triangles, for when it is a few dozen
    /// points long: every vertex snapped to a grid `length / cells` across and
    /// merged with the others in its cell, at their average position and
    /// normal, and every triangle that collapsed or now repeats another
    /// dropped. At the size it is drawn at the two cannot be told apart.
    func reduced(cells: Float) -> AircraftMeshData {
        let cell = max(lengthMetres / cells, 0.05)
        var out = self
        out.parts = parts.map { Self.reduced($0, cell: cell) }.filter { !$0.indices.isEmpty }
        return out
    }

    private static func reduced(_ part: Part, cell: Float) -> Part {
        var slot: [SIMD3<Int32>: Int] = [:]
        var sums: [SIMD3<Float>] = []
        var normalSums: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var counts: [Float] = []
        var remap: [Int] = []
        remap.reserveCapacity(part.positions.count)

        for (index, position) in part.positions.enumerated() {
            let scaled = position / cell
            let key = SIMD3<Int32>(
                Int32(scaled.x.rounded(.down)),
                Int32(scaled.y.rounded(.down)),
                Int32(scaled.z.rounded(.down))
            )
            if let existing = slot[key] {
                sums[existing] += position
                normalSums[existing] += part.normals[index]
                counts[existing] += 1
                remap.append(existing)
            } else {
                slot[key] = sums.count
                remap.append(sums.count)
                sums.append(position)
                normalSums.append(part.normals[index])
                uvs.append(part.uvs[index])
                counts.append(1)
            }
        }

        var out = Part(material: part.material)
        out.positions = zip(sums, counts).map { $0 / $1 }
        out.normals = normalSums.map { sum in
            let length = simd_length(sum)
            return length > 0 ? sum / length : SIMD3<Float>(0, 1, 0)
        }
        out.uvs = uvs

        var seen = Set<SIMD3<UInt32>>()
        for t in stride(from: 0, to: part.indices.count - 2, by: 3) {
            let a = UInt32(remap[Int(part.indices[t])])
            let b = UInt32(remap[Int(part.indices[t + 1])])
            let c = UInt32(remap[Int(part.indices[t + 2])])
            guard a != b, b != c, a != c else { continue }
            let sorted = [a, b, c].sorted()
            guard seen.insert(SIMD3<UInt32>(sorted[0], sorted[1], sorted[2])).inserted else { continue }
            out.indices.append(contentsOf: [a, b, c])
        }
        return out
    }

    /// The triangles in the model, for choosing whether a far copy is worth
    /// having at all.
    var triangleCount: Int { parts.reduce(0) { $0 + $1.indices.count / 3 } }
}

// MARK: - The file

private struct Reader {

    let json: [String: Any]
    let body: [UInt8]

    private func array(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func floats(_ value: Any?) -> [Float]? {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
    }

    /// Where an accessor's data starts in the body, and how many elements it
    /// holds.
    private func span(_ accessorIndex: Int, componentType: Int, components: Int, size: Int) -> (start: Int, count: Int)? {
        let accessors = array("accessors")
        let views = array("bufferViews")
        guard accessorIndex >= 0, accessorIndex < accessors.count else { return nil }
        let accessor = accessors[accessorIndex]
        guard Self.int(accessor["componentType"]) == componentType,
              let viewIndex = Self.int(accessor["bufferView"]), viewIndex >= 0, viewIndex < views.count,
              let count = Self.int(accessor["count"]) else { return nil }
        let view = views[viewIndex]
        let start = (Self.int(view["byteOffset"]) ?? 0) + (Self.int(accessor["byteOffset"]) ?? 0)
        guard count >= 0, start >= 0, start + count * components * size <= body.count else { return nil }
        return (start, count)
    }

    private func copy<T>(_ type: T.Type, start: Int, count: Int) -> [T] {
        guard count > 0 else { return [] }
        var out = [T]()
        body.withUnsafeBytes { raw in
            let source = UnsafeRawBufferPointer(rebasing: raw[start..<(start + count * MemoryLayout<T>.size)])
            out = [T](unsafeUninitializedCapacity: count) { buffer, initialised in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: source)
                initialised = count
            }
        }
        return out
    }

    private func vectors3(_ accessor: Int) -> [SIMD3<Float>]? {
        guard let found = span(accessor, componentType: 5126, components: 3, size: 4) else { return nil }
        let flat = copy(Float.self, start: found.start, count: found.count * 3)
        return (0..<found.count).map { SIMD3<Float>(flat[$0 * 3], flat[$0 * 3 + 1], flat[$0 * 3 + 2]) }
    }

    private func vectors2(_ accessor: Int) -> [SIMD2<Float>]? {
        guard let found = span(accessor, componentType: 5126, components: 2, size: 4) else { return nil }
        let flat = copy(Float.self, start: found.start, count: found.count * 2)
        return (0..<found.count).map { SIMD2<Float>(flat[$0 * 2], flat[$0 * 2 + 1]) }
    }

    private func indices(_ accessor: Int) -> [UInt32]? {
        if let found = span(accessor, componentType: 5123, components: 1, size: 2) {
            return copy(UInt16.self, start: found.start, count: found.count).map { UInt32($0) }
        }
        if let found = span(accessor, componentType: 5125, components: 1, size: 4) {
            return copy(UInt32.self, start: found.start, count: found.count)
        }
        return nil
    }

    func mesh() throws -> AircraftMeshData {
        // Pictures, by image index.
        var images: [Data] = []
        var imageIndex: [Int: Int] = [:]
        let views = array("bufferViews")
        for (index, image) in array("images").enumerated() {
            guard let viewIndex = Self.int(image["bufferView"]), viewIndex >= 0, viewIndex < views.count else { continue }
            let view = views[viewIndex]
            let start = Self.int(view["byteOffset"]) ?? 0
            let length = Self.int(view["byteLength"]) ?? 0
            guard length > 0, start >= 0, start + length <= body.count else { continue }
            imageIndex[index] = images.count
            images.append(Data(body[start..<(start + length)]))
        }
        let textures = array("textures")

        var materials: [AircraftMeshData.Material] = []
        for source in array("materials") {
            let pbr = source["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let base = Self.floats(pbr["baseColorFactor"]) ?? [1, 1, 1, 1]
            let emissive = Self.floats(source["emissiveFactor"]) ?? [0, 0, 0]
            var image: Int?
            if let reference = pbr["baseColorTexture"] as? [String: Any],
               let texture = Self.int(reference["index"]), texture >= 0, texture < textures.count,
               let picture = Self.int(textures[texture]["source"]) {
                image = imageIndex[picture]
            }
            let mode = source["alphaMode"] as? String ?? "OPAQUE"
            materials.append(AircraftMeshData.Material(
                baseColor: base.count == 4 ? SIMD4<Float>(base[0], base[1], base[2], base[3]) : SIMD4<Float>(1, 1, 1, 1),
                emissive: emissive.count == 3 ? SIMD3<Float>(emissive[0], emissive[1], emissive[2]) : .zero,
                image: image,
                blends: mode == "BLEND",
                cutoff: mode == "MASK" ? ((source["alphaCutoff"] as? NSNumber)?.floatValue ?? 0.5) : nil
            ))
        }
        if materials.isEmpty {
            materials.append(AircraftMeshData.Material(
                baseColor: SIMD4<Float>(0.92, 0.93, 0.95, 1), emissive: .zero, image: nil, blends: false, cutoff: nil
            ))
        }

        // Every primitive, gathered into one part per material.
        var parts: [Int: AircraftMeshData.Part] = [:]
        for mesh in array("meshes") {
            for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
                guard let attributes = primitive["attributes"] as? [String: Any],
                      let positionIndex = Self.int(attributes["POSITION"]),
                      let positions = vectors3(positionIndex),
                      let indexAccessor = Self.int(primitive["indices"]),
                      let triangles = indices(indexAccessor) else { continue }
                let normals = Self.int(attributes["NORMAL"]).flatMap { vectors3($0) }
                let uvs = Self.int(attributes["TEXCOORD_0"]).flatMap { vectors2($0) }
                guard triangles.allSatisfy({ Int($0) < positions.count }) else { continue }

                let material = min(max(Self.int(primitive["material"]) ?? 0, 0), materials.count - 1)
                var part = parts[material] ?? AircraftMeshData.Part(material: material)
                let base = UInt32(part.positions.count)
                part.positions.append(contentsOf: positions)
                if let normals, normals.count == positions.count {
                    part.normals.append(contentsOf: normals)
                } else {
                    part.normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: positions.count))
                }
                if let uvs, uvs.count == positions.count {
                    part.uvs.append(contentsOf: uvs)
                } else {
                    part.uvs.append(contentsOf: Array(repeating: SIMD2<Float>(0, 0), count: positions.count))
                }
                let whole = triangles.count - triangles.count % 3
                part.indices.append(contentsOf: triangles[0..<whole].map { $0 + base })
                parts[material] = part
            }
        }
        let ordered = parts.keys.sorted().compactMap { parts[$0] }.filter { !$0.indices.isEmpty }
        guard !ordered.isEmpty else { throw AircraftMeshData.Failure.malformed }

        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for part in ordered {
            for p in part.positions {
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        let length = max(high.z - low.z, 0.5)

        return AircraftMeshData(parts: ordered, materials: materials, images: images, lengthMetres: length)
    }
}
