import Foundation
import Metal
import simd

/// Where the Hologram style is in its course, from the seconds since it was turned on.
///
/// Turning the style on plays an arrival of a few seconds, after the transporter of Star
/// Trek's films: two swirls of light start at the model's middle and wind around it, one
/// rising to its top and one sinking to its bottom, and build the model as they go. It
/// then settles into a see-through shell with two scan lines travelling from its middle
/// to opposite edges and back.
public struct HologramTimeline: Equatable, Sendable {
    public static let introSeconds = 4.0
    /// The arrival starts a moment after the model's first frame.
    public static let introDelay = 0.25
    public static let settleSeconds = 0.6
    /// Duration of a complete middle-to-edges-to-middle scan.
    public static let scanSeconds = 20.0
    /// The fronts end this far from the middle, in heights of the model: a little past
    /// its top and bottom, so nothing is left unbuilt.
    public static let builtWhole: Float = 0.56

    /// How far the model is built from its middle towards top and bottom, in heights of
    /// the model: 0 nothing, `builtWhole` all of it.
    public var built: Float
    /// 0 during the arrival, 1 once the shell has settled.
    public var settled: Float
    /// Distance of both scan lines from the middle, 0 together to 0.5 at the edges.
    /// Negative during the arrival, when the scan lines are hidden.
    public var beam: Float
    /// Strength of the two swirls.
    public var swirl: Float
    /// The swirls are still to be drawn.
    public var showsExtras: Bool

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The settled shell with the scan line at rest in the middle: what is shown when
    /// motion is to be reduced.
    public static let still = HologramTimeline(built: 1, settled: 1, beam: 0, swirl: 0, showsExtras: false)

    init(built: Float, settled: Float, beam: Float, swirl: Float, showsExtras: Bool) {
        self.built = built; self.settled = settled; self.beam = beam
        self.swirl = swirl; self.showsExtras = showsExtras
    }

    /// `seconds` since the style was turned on.
    public init(seconds: Double) {
        let intro = Self.introSeconds
        let elapsed = max(0, seconds - Self.introDelay)
        let t = min(1, elapsed / intro)
        // The swirls light up at the middle, climb at a steady pace, and go out as they
        // leave the model.
        built = Self.builtWhole * Float(min(1, max(0, (t - 0.06) / 0.86)))
        swirl = Float(Self.smooth(0, 0.08, t) * (1 - Self.smooth(0.9, 1, t)))
        let settled = Self.smooth(intro, intro + Self.settleSeconds, elapsed)
        self.settled = Float(settled)
        showsExtras = elapsed <= intro + 0.2

        // Both lines leave the middle together, reach opposite edges halfway through
        // the cycle, then return. The triangle wave is continuous across repeats.
        let after = max(0, elapsed - intro)
        let passes = after / Self.scanSeconds
        let inPass = passes - passes.rounded(.down)
        beam = elapsed < intro ? -1 : Float(min(inPass, 1 - inPass))
    }
}

struct HologramUniforms {
    var boxMin: SIMD4<Float>
    var boxSize: SIMD4<Float>
    var grid: SIMD4<Float>
    var state: SIMD4<Float>
    var extra: SIMD4<Float>
}

/// Draws the Hologram style: the layer with the shell and the lights of its arrival, its
/// glow, and both laid into the view's pass. Owned by `MetalRenderer`, made on first use.
final class Hologram {
    static let layerFormat = MTLPixelFormat.rgba16Float
    /// Points taken from the model's surface, one for each mote of the swirls.
    static let maxSamples = 4000
    /// Pieces of each swirl's ribbon; the shader's `holoSwirlSegments`.
    static let swirlSegments = 96
    /// Heights at which the model's width is measured for the swirls; the shader's `holoSwirlBands`.
    static let swirlBands = 16
    /// The glow is the bright parts blurred at these shares of the size, each added back
    /// by its weight. Gentle, as there is a background behind it.
    static let glowDivisors = [2, 4, 8, 16, 32]
    static let glowWeights: [Float] = [0.76, 0.68, 0.6, 0.52, 0.44].map { $0 * 0.1 }

    private let device: MTLDevice
    private let shell: MTLRenderPipelineState
    private let shellUV: MTLRenderPipelineState
    private let grains: MTLRenderPipelineState
    private let dots: MTLRenderPipelineState
    private let swirls: MTLRenderPipelineState
    private let bright: MTLRenderPipelineState
    private let blur: MTLRenderPipelineState
    private let output: MTLRenderPipelineState
    private let clamped: MTLSamplerState

    private struct Targets { var width = 0, height = 0; var samples: MTLTexture?, layer: MTLTexture?; var blurs: [(a: MTLTexture, b: MTLTexture)] = [] }
    private var targets = Targets()

    /// The model the grains and beams were prepared for.
    private weak var prepared: GPUScene?
    private var grainBuffer: MTLBuffer?
    private var outlineBuffer: MTLBuffer?
    private var grainCount = 0
    private var random = Xorshift(state: 0x9e37_79b9_7f4a_7c15)

    struct Xorshift {
        var state: UInt64
        mutating func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        enum Blend { case none, over, added }
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, samples: Int, depth: MTLPixelFormat = .invalid, blend: Blend) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = samples
            d.depthAttachmentPixelFormat = depth
            let c = d.colorAttachments[0]!
            c.pixelFormat = format
            switch blend {
            case .none: break
            case .over:
                // Colour not yet multiplied by its alpha; the layer keeps it multiplied.
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .added:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let n = MetalRenderer.sampleCount
        shell = try pipeline("holoVertex", "holoFragment", format: Self.layerFormat, samples: n, blend: .over)
        shellUV = try pipeline("holoUVVertex", "holoFragment", format: Self.layerFormat, samples: n, blend: .over)
        grains = try pipeline("holoGrainVertex", "holoDotFragment", format: Self.layerFormat, samples: n, blend: .added)
        dots = try pipeline("holoPointVertex", "holoPointFragment", format: Self.layerFormat, samples: n, blend: .over)
        swirls = try pipeline("holoSwirlVertex", "holoSwirlFragment", format: Self.layerFormat, samples: n, blend: .added)
        bright = try pipeline("bgVertex", "holoBrightFragment", format: Self.layerFormat, samples: 1, blend: .none)
        blur = try pipeline("bgVertex", "holoBlurFragment", format: Self.layerFormat, samples: 1, blend: .none)
        // Into the view's own pass, over the background: already multiplied by its coverage.
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "bgVertex")
        d.fragmentFunction = library.makeFunction(name: "holoOutputFragment")
        d.rasterSampleCount = n
        d.depthAttachmentPixelFormat = MetalRenderer.depthFormat
        let c = d.colorAttachments[0]!
        c.pixelFormat = MetalRenderer.colorFormat
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        output = try device.makeRenderPipelineState(descriptor: d)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let clamped = device.makeSamplerState(descriptor: s) else { throw RenderError.noDevice }
        self.clamped = clamped
    }

    // MARK: The model's surface, for the motes

    /// Takes up to `maxSamples` of the model's vertices, where they are in the scene now.
    private func prepare(_ scene: GPUScene) {
        prepared = scene
        grainBuffer = nil
        outlineBuffer = nil
        grainCount = 0
        let total = scene.parts.reduce(0) { $0 + $1.vertexCount }
        guard total > 0 else { return }
        let every = max(1, (total + Self.maxSamples - 1) / Self.maxSamples)
        let low = scene.framing.center.y - scene.framing.size.y / 2
        let height = max(scene.framing.size.y, 1e-6)
        var grains: [SIMD4<Float>] = []
        let stride = GPUScene.vertexStride / 4
        for part in scene.parts {
            let floats = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
            for i in Swift.stride(from: 0, to: part.vertexCount, by: every) {
                let w = part.model * SIMD4(floats[i * stride], floats[i * stride + 1], floats[i * stride + 2], 1)
                guard w.x.isFinite, w.y.isFinite, w.z.isFinite else { continue }
                let h = min(1, max(0, (w.y - low) / height))
                grains.append(SIMD4(w.x, w.y, w.z, h))
                grains.append(SIMD4(random.next(), 0, 0, 0))
            }
        }
        grainCount = grains.count / 2
        outlineBuffer = Self.outline(of: grains, framing: scene.framing).withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        if grainCount > 0 {
            grainBuffer = grains.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
    }

    /// How wide the model is at each of `swirlBands` heights, bottom to top: the centre (x, z)
    /// and the half widths (x, z) of the sampled surface points near that height. Heights
    /// with no points (the sides of a box have none) take theirs from the nearest that have.
    static func outline(of grains: [SIMD4<Float>], framing: Framing) -> [SIMD4<Float>] {
        let n = swirlBands
        var low = [SIMD2<Float>](repeating: SIMD2(repeating: .infinity), count: n)
        var high = [SIMD2<Float>](repeating: SIMD2(repeating: -.infinity), count: n)
        for i in Swift.stride(from: 0, to: grains.count, by: 2) {
            let g = grains[i], at = g.w * Float(n - 1), xz = SIMD2(g.x, g.z)
            // A point counts for the heights just below and just above it.
            for band in [Int(at.rounded(.down)), Int(at.rounded(.up))] where band >= 0 && band < n {
                low[band] = simd_min(low[band], xz)
                high[band] = simd_max(high[band], xz)
            }
        }
        let filled = (0..<n).filter { low[$0].x <= high[$0].x }
        let reach = max(framing.size.x, framing.size.y, framing.size.z, 1e-6)
        let whole = SIMD4(framing.center.x, framing.center.z, framing.size.x / 2, framing.size.z / 2)
        var bands = [SIMD4<Float>](repeating: whole, count: n)
        guard !filled.isEmpty else { return bands }
        for band in 0..<n {
            let below = filled.last { $0 <= band }, above = filled.first { $0 >= band }
            func measure(_ i: Int) -> SIMD4<Float> {
                let centre = (low[i] + high[i]) / 2, half = (high[i] - low[i]) / 2
                return SIMD4(centre.x, centre.y, half.x, half.y)
            }
            var value: SIMD4<Float>
            switch (below, above) {
            case let (b?, a?) where a != b: value = simd_mix(measure(b), measure(a), SIMD4(repeating: Float(band - b) / Float(a - b)))
            case let (b?, _): value = measure(b)
            case let (nil, a?): value = measure(a)
            default: value = whole
            }
            // Never thinner than a ribbon can wind around.
            value.z = max(value.z, reach * 0.04)
            value.w = max(value.w, reach * 0.04)
            bands[band] = value
        }
        return bands
    }

    // MARK: Targets

    private func makeTargets(width: Int, height: Int) -> Bool {
        if targets.width == width, targets.height == height, targets.layer != nil { return true }
        targets = Targets()
        func texture(_ w: Int, _ h: Int, samples: Int = 1) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.layerFormat, width: max(1, w), height: max(1, h), mipmapped: false)
            d.usage = samples > 1 ? [.renderTarget] : [.renderTarget, .shaderRead]
            d.storageMode = .private
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
                // The samples are needed only while the pass runs; Apple GPUs keep them in the tile.
                if device.supportsFamily(.apple1) { d.storageMode = .memoryless }
            }
            return device.makeTexture(descriptor: d)
        }
        guard let samples = texture(width, height, samples: MetalRenderer.sampleCount), let layer = texture(width, height) else { return false }
        var blurs: [(a: MTLTexture, b: MTLTexture)] = []
        for divisor in Self.glowDivisors {
            guard let a = texture(width / divisor, height / divisor), let b = texture(width / divisor, height / divisor) else { return false }
            blurs.append((a, b))
        }
        targets = Targets(width: width, height: height, samples: samples, layer: layer, blurs: blurs)
        return true
    }

    // MARK: Drawing

    /// Draws the layer and its glow, before the view's own pass. Returns false when there
    /// is nothing to lay into that pass.
    func encodeLayer(into commands: MTLCommandBuffer, scene: GPUScene, frame: FrameUniforms, timeline: HologramTimeline,
                     seconds: Double, pixelsPerPoint: Float, white: MTLTexture, sampler: MTLSamplerState, pointSize: Float) -> Bool {
        let width = Int(frame.params.z), height = Int(frame.params.w)
        guard width > 0, height > 0, makeTargets(width: width, height: height), let samples = targets.samples, let layer = targets.layer else { return false }
        if prepared !== scene { prepare(scene) }
        var frame = frame

        let framing = scene.framing
        let size = simd_max(framing.size, SIMD3<Float>(repeating: 1e-6))
        let reach = max(size.x, size.y, size.z)
        let low = framing.center - framing.size / 2
        // Square grid cells, about 44 across the model's longest side; one scan line per
        // eighth of that side, neither crowded nor sparse.
        let lines = min(10, max(2, (size.y / (reach * 0.125)).rounded()))
        var u = HologramUniforms(
            boxMin: SIMD4(low, reach), boxSize: SIMD4(size, Float(seconds.truncatingRemainder(dividingBy: 3600))),
            grid: SIMD4(size * (44 / reach), lines),
            state: SIMD4(timeline.built, timeline.settled, timeline.beam, 0),
            extra: SIMD4(min(pixelsPerPoint, 3), timeline.swirl, 0, 0))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = samples
        pass.colorAttachments[0].resolveTexture = layer
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setVertexBytes(&u, length: MemoryLayout<HologramUniforms>.stride, index: 3)
        encoder.setFragmentBytes(&u, length: MemoryLayout<HologramUniforms>.stride, index: 3)
        encoder.setFragmentSamplerState(sampler, index: 0)

        // The shell is see-through and writes no depth: inner parts and the far side
        // show and add up, as in an X-ray.
        for part in scene.parts {
            var draw = DrawUniforms(model: part.model, normalMatrix: part.normalMatrix, baseColor: SIMD4(part.material.baseColor, 1),
                                    material: SIMD4(0, 0, pointSize, 0), flags: SIMD4(part.faceted ? 1 : 0, 0, 0, 0))
            encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            if part.isPoints {
                encoder.setRenderPipelineState(dots)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: part.vertexCount)
                continue
            }
            if let uvs = part.uvBuffer, let texture = part.texture {
                encoder.setRenderPipelineState(shellUV)
                encoder.setVertexBuffer(uvs, offset: 0, index: 5)
                encoder.setFragmentTexture(texture, index: 0)
            } else {
                encoder.setRenderPipelineState(shell)
                encoder.setFragmentTexture(white, index: 0)
            }
            if let indices = part.indexBuffer {
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
            } else {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: part.vertexCount)
            }
        }

        if timeline.showsExtras {
            if let outlineBuffer {
                encoder.setRenderPipelineState(swirls)
                encoder.setVertexBuffer(outlineBuffer, offset: 0, index: 4)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.swirlSegments * 6 * 2)
            }
            if let grainBuffer, grainCount > 0 {
                encoder.setRenderPipelineState(grains)
                encoder.setVertexBuffer(grainBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: grainCount)
            }
        }
        encoder.endEncoding()

        // Glow: what is bright, at half size, blurred; then again and again at half of that.
        func full(_ pipeline: MTLRenderPipelineState, from source: MTLTexture, to target: MTLTexture, step: SIMD2<Float> = .zero) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            var step = SIMD4(step.x, step.y, 0, 0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&step, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(clamped, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        guard targets.blurs.count == Self.glowDivisors.count else { return false }
        // Each level blurs wider than the one before, also in its own pixels (reaches of
        // 3, 5, 7, 9 and 11 pixels with a blur that spans 4), so the widest veils the view.
        func across(_ t: MTLTexture, _ reach: Float) -> SIMD2<Float> { SIMD2(reach / 4 / Float(t.width), 0) }
        func down(_ t: MTLTexture, _ reach: Float) -> SIMD2<Float> { SIMD2(0, reach / 4 / Float(t.height)) }
        // The first level ends in its `a`, the others in their `b`.
        let half = targets.blurs[0]
        full(bright, from: layer, to: half.a)
        full(blur, from: half.a, to: half.b, step: across(half.a, 3))
        full(blur, from: half.b, to: half.a, step: down(half.a, 3))
        var source = half.a
        for (i, level) in targets.blurs.enumerated().dropFirst() {
            let reach = Float(3 + 2 * i)
            full(blur, from: source, to: level.a, step: across(level.a, reach))
            full(blur, from: level.a, to: level.b, step: down(level.a, reach))
            source = level.b
        }
        return true
    }

    /// Lays layer and glow over what the view's pass holds so far.
    func composite(into encoder: MTLRenderCommandEncoder) {
        guard let layer = targets.layer, targets.blurs.count == Self.glowDivisors.count else { return }
        let w = Self.glowWeights
        var glow = (SIMD4(w[0], w[1], w[2], w[3]), SIMD4(w[4], 0, 0, 0))
        encoder.setRenderPipelineState(output)
        encoder.setFragmentBytes(&glow, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        encoder.setFragmentTexture(layer, index: 0)
        for (i, level) in targets.blurs.enumerated() { encoder.setFragmentTexture(i == 0 ? level.a : level.b, index: i + 1) }
        encoder.setFragmentSamplerState(clamped, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Bytes the layer and its glow hold on the GPU (the multisampled target not counted
    /// where the GPU keeps it in the tile).
    var targetBytes: Int {
        guard let layer = targets.layer else { return 0 }
        return targets.blurs.reduce(layer.width * layer.height * 8) { $0 + $1.a.width * $1.a.height * 16 }
    }
}
