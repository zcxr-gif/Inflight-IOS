import CoreLocation
import Metal
import MetalKit
import QuartzCore
import UIKit
import simd
@_spi(Experimental) import MapboxMaps

/// The 3D aircraft, drawn by the app itself rather than by Mapbox.
///
/// ## Why its own
///
/// Mapbox's model layer cannot size a model by the zoom on a GeoJSON source:
/// it fixes the size when it lays a tile out. Every way round that — writing a
/// size into each feature as the map moves — arrives frames late, and on a
/// zoomed-out map with thousands of aeroplanes, seconds late. So the models
/// are drawn here, in a Mapbox custom layer: on every frame the map draws,
/// every aeroplane's place, attitude and size are worked out afresh from that
/// frame's camera. Nothing is written anywhere, and nothing lags.
///
/// ## What it draws
///
/// - Each aeroplane at its real position and real height — on the terrain,
///   where the map has terrain — turned to its heading, pitch and bank.
/// - At the size `AircraftModelStyle.magnification` gives for how large a
///   metre is on screen *at that aeroplane*. That is measured, not assumed,
///   so it holds on the flat map, on the globe, through the change between
///   them, and down a tilted view, where an aeroplane far off is drawn
///   smaller than one close by.
/// - From one of two copies of its model: the whole thing close in, and one
///   reduced to a few hundred triangles while it is a few dozen points long
///   (`AircraftMeshData.reduced`). Every aeroplane of a type is drawn in one
///   instanced call per material, so thousands cost little more than dozens.
///
/// ## How it is fed
///
/// The map's frame clock hands it the aircraft to draw (`update`) and asks
/// Mapbox to repaint; Mapbox calls `render` when it does. The two may be on
/// different threads, so what crosses between them is under one lock.
/// Taps are answered from where each aeroplane was last drawn (`hitTest`).
final class AircraftEngine: NSObject, CustomLayerHost {

    /// One aeroplane to draw.
    struct Aircraft {
        var id: String
        /// The model it is drawn from — see `load`.
        var model: String
        var coordinate: CLLocationCoordinate2D
        /// Above the ground under it, in metres.
        var heightMetres: Double
        /// Above the sea, in metres — what is drawn over real terrain. See
        /// `AircraftFrame.altitude`.
        var seaAltitudeMetres: Double
        /// Degrees: heading clockwise from north, nose up, right wing down.
        var heading: Double
        var pitch: Double
        var bank: Double
        /// A colour mixed into the model (rgb) and how much of it (a).
        var tint: SIMD4<Float>
    }

    /// Called on the main thread when a model has been loaded and can be
    /// drawn.
    var onModelReady: ((String) -> Void)?

    // MARK: - Shared between the map and the renderer

    private let lock = NSLock()
    private var aircraft: [Aircraft] = []
    private var path: AircraftPath?
    private var drawn: [(id: String, point: CGPoint, radius: CGFloat)] = []
    private var models: [String: Model] = [:]
    private var loading: Set<String> = []
    private var waiting: [String: URL] = [:]
    private var device: MTLDevice?
    private var isLight = false

    // MARK: - The renderer's own

    private var opaquePipeline: MTLRenderPipelineState?
    private var blendPipeline: MTLRenderPipelineState?
    private var pathPipeline: MTLRenderPipelineState?
    private var opaqueDepth: MTLDepthStencilState?
    private var blendDepth: MTLDepthStencilState?
    private var sampler: MTLSamplerState?
    private var white: MTLTexture?

    // MARK: - Feeding it

    /// The aircraft to draw on the next frame, replacing the last set.
    func update(_ aircraft: [Aircraft]) {
        lock.lock()
        self.aircraft = aircraft
        lock.unlock()
    }

    /// The open aircraft's flown path, or nil for none — see `AircraftPath`.
    /// Its end is joined to the aeroplane on every frame, so this is only
    /// handed over when the track itself changes.
    func setPath(_ path: AircraftPath?) {
        lock.lock()
        self.path = path
        lock.unlock()
    }

    /// Whether a model is loaded and will be drawn.
    func isReady(_ model: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return models[model] != nil
    }

    /// Starts loading a model from the file `AircraftModelStore` wrote, once.
    func load(_ model: String, file: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard models[model] == nil, !loading.contains(model) else { return }
        guard let device else {
            waiting[model] = file
            return
        }
        startLoading(model, file: file, device: device)
    }

    /// The light map wants the models less bright than the dark one does.
    func setLightScheme(_ light: Bool) {
        lock.lock()
        isLight = light
        lock.unlock()
    }

    /// The aeroplane drawn nearest a point on screen, if one was drawn close
    /// enough to it to have been what was tapped.
    func hitTest(_ point: CGPoint) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var best: (id: String, distance: CGFloat)?
        for mark in drawn {
            let distance = hypot(mark.point.x - point.x, mark.point.y - point.y)
            guard distance <= mark.radius else { continue }
            if best == nil || distance < best!.distance { best = (mark.id, distance) }
        }
        return best?.id
    }

    /// Must be called with the lock held.
    private func startLoading(_ model: String, file: URL, device: MTLDevice) {
        loading.insert(model)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var loaded: Model?
            do {
                loaded = try Model(file: file, device: device)
            } catch {
                NSLog("[Engine] %@ could not be loaded: %@", model, String(describing: error))
            }
            guard let self else { return }
            self.lock.lock()
            self.loading.remove(model)
            if let loaded { self.models[model] = loaded }
            self.lock.unlock()
            if loaded != nil {
                DispatchQueue.main.async { self.onModelReady?(model) }
            }
        }
    }

    // MARK: - CustomLayerHost

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        do {
            let library = try metalDevice.makeLibrary(source: AircraftShaders.source, options: nil)
            guard let vertex = library.makeFunction(name: "aircraftVertex"),
                  let fragment = library.makeFunction(name: "aircraftFragment"),
                  let pathVertex = library.makeFunction(name: "pathVertex"),
                  let pathFragment = library.makeFunction(name: "pathFragment") else { return }

            func pipeline(
                _ label: String,
                vertex: MTLFunction,
                fragment: MTLFunction
            ) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = label
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                if let colour = MTLPixelFormat(rawValue: colorPixelFormat), let attachment = descriptor.colorAttachments[0] {
                    attachment.pixelFormat = colour
                    attachment.isBlendingEnabled = true
                    attachment.rgbBlendOperation = .add
                    attachment.alphaBlendOperation = .add
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                if let depth = MTLPixelFormat(rawValue: depthStencilPixelFormat), depth != .invalid {
                    descriptor.depthAttachmentPixelFormat = depth
                    if [.depth32Float_stencil8, .x32_stencil8, .stencil8].contains(depth) {
                        descriptor.stencilAttachmentPixelFormat = depth
                    }
                }
                return try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            }
            opaquePipeline = try pipeline("Aircraft", vertex: vertex, fragment: fragment)
            blendPipeline = try pipeline("Aircraft (see-through)", vertex: vertex, fragment: fragment)
            pathPipeline = try pipeline("Flown path", vertex: pathVertex, fragment: pathFragment)
        } catch {
            NSLog("[Engine] could not build its pipelines: %@", String(describing: error))
            return
        }

        let solid = MTLDepthStencilDescriptor()
        solid.depthCompareFunction = .lessEqual
        solid.isDepthWriteEnabled = true
        opaqueDepth = metalDevice.makeDepthStencilState(descriptor: solid)

        let glass = MTLDepthStencilDescriptor()
        glass.depthCompareFunction = .lessEqual
        glass.isDepthWriteEnabled = false
        blendDepth = metalDevice.makeDepthStencilState(descriptor: glass)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        samplerDescriptor.maxAnisotropy = 4
        sampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor)

        let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        white = metalDevice.makeTexture(descriptor: whiteDescriptor)
        var pixel: [UInt8] = [255, 255, 255, 255]
        white?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)

        lock.lock()
        device = metalDevice
        let pending = waiting
        waiting.removeAll()
        for (model, file) in pending where models[model] == nil && !loading.contains(model) {
            startLoading(model, file: file, device: metalDevice)
        }
        lock.unlock()
    }

    func render(
        _ parameters: CustomLayerRenderParameters,
        mtlCommandBuffer: MTLCommandBuffer,
        mtlRenderPassDescriptor: MTLRenderPassDescriptor
    ) {
        lock.lock()
        let aircraft = self.aircraft
        let path = self.path
        let models = self.models
        let isLight = self.isLight
        let device = self.device
        lock.unlock()

        guard let device, let opaquePipeline, let blendPipeline, let sampler, let white else { return }

        let frame = AircraftFrame(parameters)
        var marks: [(id: String, point: CGPoint, radius: CGFloat)] = []
        var groups: [GroupKey: [AircraftShaders.Instance]] = [:]
        var head: AircraftPathMesh.Head?

        for plane in aircraft {
            guard let model = models[plane.model] else { continue }
            let elevation = frame.elevation(at: plane.coordinate)
            let placement = frame.place(
                plane,
                groundMetres: elevation,
                lengthMetres: Double(model.lengthMetres)
            )

            // The path ends in the middle of the model as it is drawn.
            if plane.id == path?.aircraftId {
                let middle = Double(model.lengthMetres) * Self.middleShare * (placement?.magnification ?? 1)
                head = AircraftPathMesh.Head(
                    coordinate: plane.coordinate,
                    altitude: frame.altitude(
                        ground: elevation,
                        height: plane.heightMetres,
                        sea: plane.seaAltitudeMetres
                    ) + middle,
                    ground: elevation
                )
            }

            guard let placed = placement else { continue }

            let lod = placed.screenLength < Self.farDetailBelowPoints && model.meshes.count > 1 ? 1 : 0
            groups[GroupKey(model: plane.model, lod: lod), default: []].append(placed.instance)
            let radius = CGFloat(max(placed.screenLength * 0.55, Self.smallestTapRadius))
            marks.append((plane.id, placed.screenPoint, radius))
        }

        lock.lock()
        drawn = marks
        lock.unlock()

        let haloColour = isLight ? SIMD4<Float>(1, 1, 1, 0.55) : SIMD4<Float>(0, 0, 0, 0.45)
        let pathMesh = path.map { AircraftPathMesh($0, head: head, frame: frame, halo: haloColour) } ?? AircraftPathMesh()

        let total = groups.values.reduce(0) { $0 + $1.count }
        guard total > 0 || !pathMesh.isEmpty else { return }

        // One buffer for every instance on the frame, each group a run of it.
        let stride = MemoryLayout<AircraftShaders.Instance>.stride
        var instances: MTLBuffer?
        var runs: [(key: GroupKey, offset: Int, count: Int)] = []
        if total > 0, let buffer = device.makeBuffer(length: total * stride, options: .storageModeShared) {
            var cursor = 0
            let base = buffer.contents()
            for (key, list) in groups {
                list.withUnsafeBytes { bytes in
                    base.advanced(by: cursor * stride).copyMemory(from: bytes.baseAddress!, byteCount: list.count * stride)
                }
                runs.append((key, cursor, list.count))
                cursor += list.count
            }
            instances = buffer
        }

        guard let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Aircraft"
        if let target = mtlRenderPassDescriptor.colorAttachments[0].texture {
            encoder.setViewport(MTLViewport(
                originX: 0, originY: 0,
                width: Double(target.width), height: Double(target.height),
                znear: 0, zfar: 1
            ))
        }
        encoder.setCullMode(.none)
        encoder.setFragmentSamplerState(sampler, index: 0)

        var uniforms = AircraftShaders.FrameUniforms(
            transition: Float(frame.transition),
            ambient: isLight ? 0.62 : 0.52,
            diffuse: isLight ? 0.45 : 0.55,
            emission: isLight ? 0.3 : 0.8,
            light: SIMD4<Float>(simd_normalize(SIMD3<Float>(0.35, -0.3, 0.88)), 0)
        )
        // The path first, under the aeroplanes: curtain, halo, line.
        if !pathMesh.isEmpty, let pathPipeline, let blendDepth,
           let pathVertices = device.makeBuffer(
               bytes: pathMesh.vertices,
               length: pathMesh.vertices.count * MemoryLayout<AircraftShaders.PathVertex>.stride,
               options: .storageModeShared
           ) {
            encoder.setRenderPipelineState(pathPipeline)
            encoder.setDepthStencilState(blendDepth)
            encoder.setVertexBuffer(pathVertices, offset: 0, index: 0)
            for indices in [pathMesh.curtain, pathMesh.halo, pathMesh.line] where !indices.isEmpty {
                guard let indexBuffer = device.makeBuffer(
                    bytes: indices,
                    length: indices.count * MemoryLayout<UInt32>.stride,
                    options: .storageModeShared
                ) else { continue }
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: indices.count,
                    indexType: .uint32,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
            }
        }

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<AircraftShaders.FrameUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AircraftShaders.FrameUniforms>.stride, index: 1)

        for blending in [false, true] where instances != nil {
            encoder.setRenderPipelineState(blending ? blendPipeline : opaquePipeline)
            if let state = blending ? blendDepth : opaqueDepth { encoder.setDepthStencilState(state) }
            for run in runs {
                guard let model = models[run.key.model], run.key.lod < model.meshes.count else { continue }
                let mesh = model.meshes[run.key.lod]
                encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(instances!, offset: run.offset * stride, index: 1)
                for part in mesh.parts {
                    let material = model.materials[part.material]
                    guard material.blends == blending else { continue }
                    var values = material.uniforms
                    encoder.setFragmentBytes(&values, length: MemoryLayout<AircraftShaders.MaterialUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(material.texture ?? white, index: 0)
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: part.indexCount,
                        indexType: .uint32,
                        indexBuffer: mesh.indices,
                        indexBufferOffset: part.indexStart * MemoryLayout<UInt32>.stride,
                        instanceCount: run.count
                    )
                }
            }
        }
        encoder.endEncoding()
    }

    func renderingWillEnd() {}

    // MARK: - Tuning

    /// Below this length on screen an aeroplane is drawn from its reduced copy.
    private static let farDetailBelowPoints = 70.0

    /// Where the middle of a model is, as a share of its length above the
    /// ground it stands on — roughly the fuselage's centre line.
    private static let middleShare = 0.08

    /// However small an aeroplane is drawn, a tap this close to it finds it.
    private static let smallestTapRadius = 18.0

    // MARK: - On the GPU

    fileprivate struct GroupKey: Hashable {
        let model: String
        let lod: Int
    }

    fileprivate struct Material {
        let uniforms: AircraftShaders.MaterialUniforms
        let texture: MTLTexture?
        let blends: Bool
    }

    fileprivate struct Mesh {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let parts: [(material: Int, indexStart: Int, indexCount: Int)]
    }

    /// A model, ready to draw: its whole mesh, its reduced one when that is
    /// worth having, and the materials and pictures they share.
    fileprivate final class Model {
        let meshes: [Mesh]
        let materials: [Material]
        let lengthMetres: Float

        enum Failure: Error { case buffer }

        init(file: URL, device: MTLDevice) throws {
            let data = try AircraftMeshData.read(Data(contentsOf: file))
            lengthMetres = data.lengthMetres

            let loader = MTKTextureLoader(device: device)
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .allocateMipmaps: true,
                .generateMipmaps: true,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ]
            let textures: [MTLTexture?] = data.images.map { try? loader.newTexture(data: $0, options: options) }

            materials = data.materials.map { source in
                let texture = source.image.flatMap { $0 < textures.count ? textures[$0] : nil }
                return Material(
                    uniforms: AircraftShaders.MaterialUniforms(
                        baseColor: source.baseColor,
                        emissive: SIMD4<Float>(source.emissive, texture == nil ? 0 : 1),
                        alpha: SIMD4<Float>(source.cutoff ?? -1, source.blends ? 1 : 0, 0, 0)
                    ),
                    texture: texture,
                    blends: source.blends
                )
            }

            var meshes = [try Self.mesh(data, device: device)]
            // Only worth a second copy when it actually comes out smaller.
            let far = data.reduced(cells: 28)
            if far.triangleCount > 0, Double(far.triangleCount) < Double(data.triangleCount) * 0.7 {
                meshes.append(try Self.mesh(far, device: device))
            }
            self.meshes = meshes
        }

        private static func mesh(_ data: AircraftMeshData, device: MTLDevice) throws -> Mesh {
            var vertices: [Float] = []
            var indices: [UInt32] = []
            var parts: [(material: Int, indexStart: Int, indexCount: Int)] = []
            for part in data.parts {
                let base = UInt32(vertices.count / 8)
                vertices.reserveCapacity(vertices.count + part.positions.count * 8)
                for i in 0..<part.positions.count {
                    let p = part.positions[i]
                    let n = part.normals[i]
                    let t = part.uvs[i]
                    vertices.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z, t.x, t.y])
                }
                parts.append((part.material, indices.count, part.indices.count))
                indices.append(contentsOf: part.indices.map { $0 + base })
            }
            guard !vertices.isEmpty, !indices.isEmpty,
                  let vertexBuffer = device.makeBuffer(
                      bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: .storageModeShared
                  ),
                  let indexBuffer = device.makeBuffer(
                      bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared
                  ) else { throw Failure.buffer }
            return Mesh(vertices: vertexBuffer, indices: indexBuffer, parts: parts)
        }
    }
}
