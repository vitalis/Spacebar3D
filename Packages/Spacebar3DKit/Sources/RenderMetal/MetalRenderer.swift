import CoreGraphics
import Foundation
import Metal
import ModelCore
import simd

/// What the model's surface shows (the three views of the looks bar; the wireframe is an
/// overlay on any of them).
public struct RenderLook: Equatable, Sendable {
    public enum View: Sendable, Equatable { case solid, textured, normal }
    public var view: View = .textured
    /// Polygon wire drawn over the view.
    public var wire = false
    /// Flat (one normal per face) instead of smooth shading.
    public var flat = false
    /// Textured view only: metallic-roughness lighting, or plain diffuse when false.
    public var pbr = true
    /// Textured view only: replace the material's own values; nil keeps them.
    public var metallic: Float?
    public var roughness: Float?

    /// Optional styles layered on the view. Anime and Cel-Shaded
    /// get an ink outline; unlit and cartoon use the solid colour in the solid view and the
    /// model's colours in the textured view; the normal view ignores unlit and cartoon.
    /// Hologram replaces any view too, with a see-through shell that is built up when
    /// the style is turned on (see `HologramTimeline`).
    public enum Style: Sendable, Equatable { case none, unlit, anime, celShaded, retro, voxel, hologram }
    public var style: Style = .none

    public init(view: View = .textured, wire: Bool = false, flat: Bool = false, pbr: Bool = true, metallic: Float? = nil, roughness: Float? = nil, style: Style = .none) {
        self.view = view; self.wire = wire; self.flat = flat; self.pbr = pbr; self.metallic = metallic; self.roughness = roughness; self.style = style
    }

    /// The shader mode a look resolves to and whether it draws the outline:
    /// 0 clay, 1 textured, 2 normal, 3 solid unlit, 4 solid toon,
    /// 6 textured unlit, 7 textured toon. Hologram (8) has shaders of its own.
    /// True when this look draws the ink outline, which needs `GPUScene.prepareOutline()` first.
    public var needsOutline: Bool { resolved.outline }

    var resolved: (mode: Int, outline: Bool) {
        if style == .retro { return (view == .textured ? 12 : 11, false) }
        if style == .celShaded { return (view == .textured ? 10 : 9, true) }
        if style == .hologram { return (8, false) }
        switch view {
        case .normal: return (2, false)
        case .solid:
            switch style { case .unlit: return (3, false); case .anime: return (4, true); default: return (0, false) }
        case .textured:
            switch style { case .unlit: return (6, false); case .anime: return (7, true); default: return (1, false) }
        }
    }
}

/// Parameters of one rendered frame that match the shaders' structs.
struct FrameUniforms {
    var viewProj: simd_float4x4
    var view: simd_float4x4
    var proj: simd_float4x4
    var invView: simd_float4x4
    var cameraPos: SIMD4<Float>
    var params: SIMD4<Float>
    var solidTint: SIMD4<Float>
    var bgCentre: SIMD4<Float>
    var bgBase: SIMD4<Float>
    var bgEdge: SIMD4<Float>
    var gridCentreLine: SIMD4<Float>
    var gridLine: SIMD4<Float>
    var gridAxisX: SIMD4<Float>
    var gridAxisZ: SIMD4<Float>
    var gridPlace: SIMD4<Float>
    var shadowPlace: SIMD4<Float>
    var sunDir: SIMD4<Float>
    var sunColor: SIMD4<Float>
    var fillDir: SIMD4<Float>
    var fillColor: SIMD4<Float>
    var envSky: SIMD4<Float>
    var envGround: SIMD4<Float>
    var envEven: SIMD4<Float>
    var envLow: SIMD4<Float>
    var envHigh: SIMD4<Float>
    var shadowSize: SIMD4<Float>
}

struct DrawUniforms {
    var model: simd_float4x4
    var normalMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var material: SIMD4<Float>
    var flags: SIMD4<Float>
    /// Linear light the surface gives off; w is one when an image multiplies it.
    var emissive = SIMD4<Float>(0, 0, 0, 0)
    /// Cartoon shading: the shade colour (linear), w one when the material is a cartoon one.
    var shade = SIMD4<Float>(0, 0, 0, 0)
    /// x the edge's shift, y its narrowness, z one when an image multiplies the shade,
    /// w the outline's width (metres; negative: a share of the view's height).
    var toon = SIMD4<Float>(0, 0, 0, 0)
    /// The outline's colour (linear), w how much of the surface's colour shows in it.
    var line = SIMD4<Float>(0, 0, 0, 0)
    /// The rim light's colour (linear), w how sharply it stays at the edge.
    var rim = SIMD4<Float>(0, 0, 0, 0)
    /// x the rim's lift, y how much the light dims rim and matcap, z the scale of the
    /// shift's image, w the images in use (1 matcap, 2 rim, 4 shift, 8 outline width).
    var rimMore = SIMD4<Float>(0, 0, 0, 0)
    /// What multiplies the matcap (linear).
    var matcap = SIMD4<Float>(0, 0, 0, 0)
    /// How far the images have slid (x, y, in their own widths) and turned (z, radians) by
    /// now; w one when an image says how much of that each place gets.
    var uvMove = SIMD4<Float>(0, 0, 0, 0)
    /// x scales the tangent-space normal's X/Y; the rest is reserved.
    var normalMap = SIMD4<Float>(1, 0, 0, 0)
}

/// Colours the renderer derives from the background setting (pure, so it can be tested).
public struct BackgroundColors: Equatable, Sendable {
    /// sRGB.
    public var centre: SIMD3<Float>, base: SIMD3<Float>, edge: SIMD3<Float>
    /// A dark background gets light grid lines and the other way round.
    public var isDark: Bool
    /// sRGB. The floor's lines take the room's hue; the two through the middle are the
    /// colours of the axes they lie along (as on the view gizmo) in a dark room, and
    /// black in a light one.
    public var gridLine: SIMD3<Float>, axisX: SIMD3<Float>, axisZ: SIMD3<Float>

    /// The soft spotlight behind the model: 14% towards its light in the middle, 22% towards
    /// black at the corners, blended in linear light.
    public init(base sRGB: SIMD3<Float>) {
        let linear = srgbToLinear(sRGB)
        func toSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
            func f(_ x: Float) -> Float { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
            return SIMD3(f(c.x), f(c.y), f(c.z))
        }
        base = sRGB
        // The light takes half of the background's hue, so that a coloured room is lit in
        // its colour and not in grey; a grey or black one is lit white, as before.
        let peak = max(linear.x, linear.y, linear.z)
        let hue = peak > 0 ? linear / peak : SIMD3<Float>(repeating: 1)
        let light = (SIMD3<Float>(repeating: 1) + hue) / 2
        centre = toSRGB(linear + (light - linear) * 0.14)
        edge = toSRGB(linear * (1 - 0.22))
        isDark = (max(sRGB.x, sRGB.y, sRGB.z) + min(sRGB.x, sRGB.y, sRGB.z)) / 2 < 0.5
        let black = SIMD3<Float>(repeating: 0)
        gridLine = isDark ? toSRGB(light * 0.32) : black
        axisX = isDark ? SIMD3(0xff, 0x6a, 0x3d) / 255 : black
        axisZ = isDark ? SIMD3(0xb8, 0xd3, 0xff) / 255 : black
    }
}

/// An image read back from an offscreen render: BGRA, premultiplied alpha, row 0 on top.
public struct OffscreenImage: Sendable {
    public let width: Int, height: Int
    public let bytes: [UInt8]

    public func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    /// An sRGB CGImage, for writing a PNG.
    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The Metal renderer: owns the pipelines and the view state (camera, look, light, grid,
/// background), and draws a `GPUScene` into any render pass. Use it from one thread at a
/// time; building a `GPUScene` may happen anywhere.
public final class MetalRenderer: @unchecked Sendable {
    public static let sampleCount = 4
    public static let colorFormat = MTLPixelFormat.bgra8Unorm
    public static let depthFormat = MTLPixelFormat.depth32Float
    /// How far the wire is pulled towards the camera, as a share of the distance.
    static let wirePull: Float = 3e-4

    public let device: MTLDevice
    let queue: MTLCommandQueue
    private let background: MTLRenderPipelineState
    /// The surface pipelines, by what a vertex hands on: 0 smooth, 1 flat (a position
    /// only), 2 and 3 the same with a colour, 4 and 5 the same with a texture coordinate.
    private let opaquePipelines: [MTLRenderPipelineState]
    /// The same six, blending over what is already drawn.
    private let blendedPipelines: [MTLRenderPipelineState]
    private let points: MTLRenderPipelineState
    private let blendedPoints: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    /// Samplers for materials whose images do not simply repeat, made as they are met.
    private var samplers: [ModelScene.TextureSampling: MTLSamplerState] = [:]

    private func sampler(for sampling: ModelScene.TextureSampling) -> MTLSamplerState {
        if sampling == ModelScene.TextureSampling() { return sampler }
        if let known = samplers[sampling] { return known }
        func mode(_ wrap: ModelScene.TextureWrap) -> MTLSamplerAddressMode {
            switch wrap {
            case .repeat: return .repeat
            case .clamp: return .clampToEdge
            case .mirror: return .mirrorRepeat
            }
        }
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = sampling.sharp ? .nearest : .linear; d.mipFilter = .linear
        d.sAddressMode = mode(sampling.wrapS); d.tAddressMode = mode(sampling.wrapT)
        d.maxAnisotropy = sampling.sharp ? 1 : 8
        let made = device.makeSamplerState(descriptor: d) ?? sampler
        samplers[sampling] = made
        return made
    }
    /// Stands in for an image a part does not have.
    private let white: MTLTexture
    private let wire: MTLRenderPipelineState
    private let outline: MTLRenderPipelineState
    private let toonOutline: MTLRenderPipelineState
    private let toonOutlineUV: MTLRenderPipelineState
    private let grid: MTLRenderPipelineState
    private let shadow: MTLRenderPipelineState
    private let veil: MTLRenderPipelineState
    private let cover: MTLRenderPipelineState
    /// The model as seen from straight above: how much it keeps from each spot of the floor.
    private let coverMap: MTLTexture
    static let coverSide = 256
    /// How dark the shadow under the model is where the model stands on the floor.
    static let shadowDarkness: Float = 0.72
    /// How bright the pool of light on the floor is at its middle, as a part of the
    /// spotlight's colour. A light room has none: its floor is lit already.
    static let poolLight: Float = 0.6
    private let depthOff: MTLDepthStencilState
    private let depthWrite: MTLDepthStencilState
    private let depthTest: MTLDepthStencilState
    private let library: MTLLibrary
    /// Moves skinned vertices to their pose on the GPU; nil where that cannot be set up,
    /// and the CPU does it.
    private let skinning: MTLComputePipelineState?
    /// Made when the Hologram style is first drawn; nil again if that fails.
    private var hologram: Hologram?
    private var hologramFailed = false

    public private(set) var scene: GPUScene?
    public private(set) var framing = Framing.unit
    public private(set) var gridPlacement = GridPlacement(framing: .unit)
    public private(set) var homeCamera = OrbitCamera.home(for: .unit)
    public private(set) var viewportAspect: Float = 1

    public var camera = OrbitCamera.home(for: .unit)
    public var look = RenderLook()
    /// 1 is the default lighting.
    public var lightIntensity: Float = 1
    /// Where the model's light comes from, and how far it is turned round the upright
    /// axis (radians).
    public var surrounding = Surrounding.glasshouse
    public var lightRotation: Float = 0
    public var showGrid = true
    /// The soft shadow on the floor under the model.
    public var showShadow = true
    /// sRGB.
    public var backgroundColor = SIMD3<Float>(0x07, 0x11, 0x0c) / 255
    /// 0 makes the view see-through (Quick Look composites it over what is behind).
    public var backgroundAlpha: Float = 1
    /// Diameter of a point cloud's dots, in points of the screen.
    public static let pointSize: Float = 2
    /// Pixels per point of the target, so dots keep their size on a Retina display.
    public var pixelsPerPoint: Float = 1
    /// Off only to compare against in tests: back faces that cannot be seen are then drawn too.
    public var cullsHiddenFaces = true
    /// Off only to compare against in tests: skinned vertices are then moved by the CPU.
    public var skinsOnGPU = true
    /// sRGB; tints the solid view.
    public var solidColor = SIMD3<Float>(0xb4, 0xb4, 0xb8) / 255
    /// Seconds since the Hologram style was turned on; the host advances it every frame.
    public var hologramSeconds: Double = 0
    /// The time materials that move their images are shown at, in seconds.
    public var materialSeconds: Double = 0
    /// The share of the view's height, from its bottom edge, that controls cover.
    public var bottomInset: Float = 0
    static let largestInset: Float = 0.4
    /// Whether the picture changes with `materialSeconds`: the scene has such a material
    /// and the model's own look is showing.
    public var showsMovingTextures: Bool { look.resolved.mode == 1 && scene?.hasMovingTextures == true }
    /// Shows the settled hologram at rest, with no intro (for reduced motion).
    public var hologramStill = false

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Shaders.source + HologramShaders.source, options: nil) } catch { throw RenderError.shaders("\(error)") }
        self.library = library
        skinning = library.makeFunction(name: "skinVertices").flatMap { try? device.makeComputePipelineState(function: $0) }

        func pipeline(_ vertex: String, _ fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = Self.sampleCount
            d.colorAttachments[0].pixelFormat = Self.colorFormat
            d.depthAttachmentPixelFormat = Self.depthFormat
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        do {
            background = try pipeline("bgVertex", "bgFragment", blend: false)
            let surfaces = [("meshVertex", "meshFragment"), ("flatVertex", "flatFragment"), ("meshColorVertex", "meshColorFragment"),
                            ("flatColorVertex", "flatColorFragment"), ("meshUVVertex", "meshUVFragment"), ("flatUVVertex", "flatUVFragment")]
            opaquePipelines = try surfaces.map { try pipeline($0.0, $0.1, blend: false) }
            blendedPipelines = try surfaces.map { try pipeline($0.0, $0.1, blend: true) }
            points = try pipeline("pointVertex", "pointFragment", blend: false)
            blendedPoints = try pipeline("pointVertex", "pointFragment", blend: true)
            outline = try pipeline("outlineVertex", "outlineFragment", blend: false)
            toonOutline = try pipeline("toonOutlineVertex", "toonOutlineFragment", blend: false)
            toonOutlineUV = try pipeline("toonOutlineUVVertex", "toonOutlineUVFragment", blend: false)
            wire = try pipeline("wireVertex", "wireFragment", blend: true)
            grid = try pipeline("gridVertex", "gridFragment", blend: true)
            shadow = try pipeline("shadowVertex", "shadowFragment", blend: true)
            veil = try pipeline("veilVertex", "veilFragment", blend: true)
            // One number a point, no depth: where several parts cover a spot, the most counts.
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "coverVertex")
            d.fragmentFunction = library.makeFunction(name: "coverFragment")
            let c = d.colorAttachments[0]!
            c.pixelFormat = .r8Unorm
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .max; c.alphaBlendOperation = .max
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .one
            cover = try device.makeRenderPipelineState(descriptor: d)
        } catch { throw RenderError.shaders("\(error)") }

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare; d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear; samplerDescriptor.magFilter = .linear; samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat; samplerDescriptor.tAddressMode = .repeat
        samplerDescriptor.maxAnisotropy = 8
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { throw RenderError.noDevice }
        self.sampler = sampler
        guard let white = TextureUpload.solid([255, 255, 255, 255], device: device) else { throw RenderError.noDevice }
        let map = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.coverSide, height: Self.coverSide, mipmapped: false)
        map.usage = [.renderTarget, .shaderRead]
        map.storageMode = .private
        guard let coverMap = device.makeTexture(descriptor: map) else { throw RenderError.noDevice }
        self.coverMap = coverMap
        self.white = white
        depthOff = depth(.always, write: false)
        depthWrite = depth(.greater, write: true)       // reversed depth: larger is nearer
        depthTest = depth(.greaterEqual, write: false)
    }

    /// Uploads a scene; safe to call off the main thread.
    /// Longest side of a colour image on the GPU; larger ones are scaled down as they are
    /// decoded. 4096 costs 85 MB per image with its smaller versions, 2048 a quarter of that.
    public var maxTextureSide = TextureUpload.maxSide

    public func makeScene(_ scene: ModelScene) throws -> GPUScene { try GPUScene(device: device, scene: scene, maxTextureSide: maxTextureSide) }

    /// Shows an uploaded scene: frames it and puts the camera at its first position.
    public func show(_ scene: GPUScene) {
        self.scene = scene
        framing = scene.framing
        gridPlacement = GridPlacement(framing: framing)
        homeCamera = OrbitCamera.home(for: framing, aspect: viewportAspect)
        camera = homeCamera
    }

    /// Updates fitted framing on resize. A camera the user has moved keeps its exact pose;
    /// the next explicit Fit uses the new aspect. Offscreen rendering uses this path too.
    public func setViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let aspect = Float(size.width / size.height)
        guard aspect.isFinite, aspect > 0, aspect != viewportAspect else { return }
        let wasHome = camera == homeCamera
        viewportAspect = aspect
        homeCamera = OrbitCamera.home(for: framing, aspect: aspect)
        if wasHome { camera = homeCamera }
    }

    /// Drops the shown scene (after a failed load), leaving background and grid.
    public func clearScene() {
        scene = nil
        framing = .unit
        gridPlacement = GridPlacement(framing: .unit)
        homeCamera = OrbitCamera.home(for: .unit, aspect: viewportAspect)
        camera = homeCamera
    }

    /// The distance range the camera may be zoomed within.
    public var distanceLimits: ClosedRange<Float> { (framing.distance * 0.02)...(framing.distance * 40) }

    // MARK: Drawing

    func frameUniforms(size: CGSize) -> FrameUniforms {
        let view = camera.viewMatrix
        var proj = camera.projectionMatrix(aspect: Float(size.width / max(size.height, 1)))
        // Kept clear of what covers the bottom of the view: the picture is made that much
        // smaller and moved up, so that what the camera looks at is in the middle of the rest.
        let covered = bottomInset.isFinite ? min(max(bottomInset, 0), Self.largestInset) : 0
        if covered > 0 {
            proj.columns.0.x *= 1 - covered
            proj.columns.1.y *= 1 - covered
            proj.columns.2.y -= covered
        }
        let colors = BackgroundColors(base: backgroundColor)
        // Tint of the clay view: the chosen colour relative to the neutral grey it was drawn in.
        let neutral = srgbToLinear(SIMD3(0xb4, 0xb4, 0xb8) / 255)
        let tint = simd_min(srgbToLinear(solidColor) / neutral, SIMD3<Float>(repeating: 1.4))
        let dark = colors.isDark
        let p = gridPlacement
        let light = surrounding.light(turned: lightRotation)
        return FrameUniforms(
            viewProj: proj * view, view: view, proj: proj, invView: simd_inverse(view),
            cameraPos: SIMD4(camera.position, 1),
            params: SIMD4(lightIntensity, Self.wirePull, Float(size.width), Float(size.height)),
            solidTint: SIMD4(tint, 1),
            bgCentre: SIMD4(colors.centre, 1), bgBase: SIMD4(colors.base, backgroundAlpha), bgEdge: SIMD4(colors.edge, 1),
            gridCentreLine: SIMD4(dark ? SIMD3(1, 1, 1) : SIMD3(0, 0, 0), 0.45),
            gridLine: SIMD4(colors.gridLine, 0.45),
            gridAxisX: SIMD4(colors.axisX, 1), gridAxisZ: SIMD4(colors.axisZ, 1),
            gridPlace: SIMD4(p.center, p.cell * Float(GridPlacement.divisions)),
            shadowPlace: SIMD4(SIMD3(framing.center.x, p.center.y, framing.center.z), Self.shadowDarkness),
            sunDir: SIMD4(light.sun, light.glow), sunColor: SIMD4(light.sunColor, 0),
            fillDir: SIMD4(light.fill, 0), fillColor: SIMD4(light.fillColor, 0),
            envSky: SIMD4(light.sky, 0), envGround: SIMD4(light.ground, 0), envEven: SIMD4(light.even, 0),
            envLow: SIMD4(light.low, 0), envHigh: SIMD4(light.high, 0),
            shadowSize: SIMD4(max(framing.size.x, framing.size.z * 0.35) / 2, max(framing.size.z, framing.size.x * 0.35) / 2,
                              framing.size.y, dark ? Self.poolLight : 0))
    }

    /// Encodes one frame into the render pass. The pass's colour target must be
    /// `colorFormat` with `sampleCount` samples (resolving to the drawable), and its depth
    /// target `depthFormat`. Clear and store actions are set here.
    /// Draws the model as seen from straight above into the small picture the shadow is
    /// made from. Every frame: a model that moves takes its shadow with it.
    private func encodeCover(of parts: [GPUScene.Part], frame: inout FrameUniforms, into commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = coverMap
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(cover)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        let showsColors = [1, 6, 7, 10, 12].contains(look.resolved.mode)
        for part in parts where !part.isPoints {
            var draw = drawUniforms(for: part, blended: showsColors && part.material.isBlended)
            if showsColors, part.texture != nil, part.uvBuffer != nil { draw.flags.y += 64 }
            if !showsColors {
                // Solid and Normal show the complete geometry.
                draw.flags.y = 0; draw.flags.w = 0; draw.baseColor.w = 1
            }
            encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(part.colorBuffer ?? part.vertexBuffer, offset: 0, index: 4)
            encoder.setVertexBuffer(part.uvBuffer ?? part.vertexBuffer, offset: 0, index: 5)
            encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            encoder.setFragmentTexture(part.texture ?? white, index: 0)
            encoder.setFragmentTexture(part.uvMaskTexture ?? white, index: 1)
            encoder.setFragmentSamplerState(sampler(for: part.material.sampling), index: 0)
            if let indices = part.indexBuffer {
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
            } else {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: part.vertexCount)
            }
        }
        encoder.endEncoding()
    }

    public func encode(into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) {
        setViewportSize(size)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        var frame = frameUniforms(size: size)
        // Skinned parts are moved to their pose before anything draws them.
        scene?.encodePose(into: commandBuffer, pipeline: skinsOnGPU ? skinning : nil, voxel: look.style == .voxel)
        // The Hologram style draws the model into a layer of its own first.
        var holo: Hologram?
        if look.style == .hologram, let scene, let effect = hologramEffect() {
            let timeline = hologramStill ? HologramTimeline.still : HologramTimeline(seconds: hologramSeconds)
            // At rest nothing moves, the shell's slow breathing included.
            if effect.encodeLayer(into: commandBuffer, scene: scene, frame: frame, timeline: timeline, seconds: hologramStill ? 0 : hologramSeconds,
                                  pixelsPerPoint: pixelsPerPoint, white: white, sampler: sampler, pointSize: Self.pointSize * pixelsPerPoint) {
                holo = effect
            }
        }
        let parts = look.style == .voxel ? scene?.partsForVoxels() ?? [] : scene?.parts ?? []
        let shadowed = showShadow && holo == nil && camera.position.y > gridPlacement.center.y
        if shadowed { encodeCover(of: parts, frame: &frame, into: commandBuffer) }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        encoder.setRenderPipelineState(background)
        encoder.setDepthStencilState(depthOff)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        if let scene, holo == nil {
            encoder.setDepthStencilState(depthWrite)
            // Through the floor: up is down, about the floor's height.
            var mirror = matrix_identity_float4x4
            mirror.columns.1.y = -1
            // (A hair lower, so that what stands on the floor does not meet itself in it.)
            mirror.columns.3.y = 2 * gridPlacement.center.y - 0.004 * max(framing.size.x, framing.size.y, framing.size.z)
            // Vertex colours are part of the model's own appearance: Textured and its styles.
            let showsColors = [1, 6, 7, 10, 12].contains(look.resolved.mode)
            // See-through surfaces exist only where the model's own colours show; they are
            // drawn after everything opaque, farthest first.
            func isSeeThrough(_ part: GPUScene.Part) -> Bool { (showsColors || part.isPoints) && part.material.isBlended }
            func drawMesh(_ part: GPUScene.Part, blended: Bool, reflected: Bool = false) {
                let flatShaded = look.flat || part.faceted
                let kind: Int
                if showsColors, let uvs = part.uvBuffer, part.texture != nil || part.mapsTexture != nil || part.normalTexture != nil || part.emissiveTexture != nil || part.shadeTexture != nil
                    || part.matcapTexture != nil || part.rimTexture != nil || part.shiftTexture != nil {
                    // (An image that only says where the others move is nothing without them.)
                    kind = flatShaded ? 5 : 4
                    encoder.setVertexBuffer(uvs, offset: 0, index: 5)
                    encoder.setFragmentTexture(part.texture ?? white, index: 0)
                    encoder.setFragmentTexture(part.mapsTexture ?? white, index: 1)
                    encoder.setFragmentTexture(part.normalTexture ?? white, index: 2)
                    encoder.setFragmentTexture(part.emissiveTexture ?? white, index: 3)
                    encoder.setFragmentTexture(part.shadeTexture ?? white, index: 4)
                    encoder.setFragmentTexture(part.matcapTexture ?? white, index: 5)
                    encoder.setFragmentTexture(part.rimTexture ?? white, index: 6)
                    encoder.setFragmentTexture(part.shiftTexture ?? white, index: 7)
                    encoder.setFragmentTexture(part.uvMaskTexture ?? white, index: 8)
                    encoder.setFragmentSamplerState(sampler(for: part.material.sampling), index: 0)
                    encoder.setFragmentSamplerState(sampler(for: part.material.metallicRoughnessSampling ?? part.material.sampling), index: 1)
                    encoder.setFragmentSamplerState(sampler(for: part.material.normalSampling ?? part.material.sampling), index: 2)
                    encoder.setFragmentSamplerState(sampler(for: part.material.emissiveSampling ?? part.material.sampling), index: 3)
                    // Vertex colours tint the image; without them the buffer is not read.
                    encoder.setVertexBuffer(part.colorBuffer ?? uvs, offset: 0, index: 4)
                } else if showsColors, let colors = part.colorBuffer {
                    kind = flatShaded ? 3 : 2
                    encoder.setVertexBuffer(colors, offset: 0, index: 4)
                } else {
                    kind = flatShaded ? 1 : 0
                }
                encoder.setRenderPipelineState((blended ? blendedPipelines : opaquePipelines)[kind])
                if blended {
                    // Seen through, a surface's far side shows: only a one-sided material loses it.
                    encoder.setCullMode(part.material.doubleSided ? .none : (part.mirrored ? .front : .back))
                } else {
                    let hidden = part.material.oneSided || hidesBackFaces(of: part, aspect: frame.proj.columns.1.y / frame.proj.columns.0.x)
                    encoder.setCullMode(hidden ? (part.mirrored ? .front : .back) : .none)
                }
                var draw = drawUniforms(for: part, blended: blended)
                if reflected {
                    // Upside down under the floor; which way a face winds is turned with it.
                    encoder.setCullMode(.none)
                    draw.model = mirror * draw.model
                    draw.normalMatrix = mirror * draw.normalMatrix
                }
                encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                if let indices = part.indexBuffer {
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
                } else {
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: part.vertexCount)
                }
            }
            // The sheen of the floor: the model upside down under it, then the floor over that,
            // then the shadow and the pool of light on the floor.
            if shadowed {
                if backgroundAlpha >= 1 {
                    for part in parts where !part.isPoints && !isSeeThrough(part) { drawMesh(part, blended: false, reflected: true) }
                    encoder.setCullMode(.none)
                    encoder.setDepthStencilState(depthTest)
                    encoder.setRenderPipelineState(veil)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                encoder.setDepthStencilState(depthOff)
                encoder.setRenderPipelineState(shadow)
                encoder.setFragmentTexture(coverMap, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.setDepthStencilState(depthWrite)
            }
            func drawPoints(_ part: GPUScene.Part, blended: Bool) {
                var draw = drawUniforms(for: part, blended: blended)
                if part.uvBuffer != nil { draw.flags.y += 64 }
                encoder.setRenderPipelineState(blended ? blendedPoints : points)
                encoder.setDepthStencilState(blended ? depthTest : depthWrite)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(part.colorBuffer ?? part.vertexBuffer, offset: 0, index: 4)
                encoder.setVertexBuffer(part.uvBuffer ?? part.vertexBuffer, offset: 0, index: 5)
                encoder.setFragmentTexture(part.texture ?? white, index: 0)
                encoder.setFragmentTexture(part.uvMaskTexture ?? white, index: 1)
                encoder.setFragmentSamplerState(sampler(for: part.material.sampling), index: 0)
                encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                if blended, let indices = scene.orderedPointIndices(for: part, camera: camera) {
                    encoder.drawIndexedPrimitives(type: .point, indexCount: part.vertexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
                } else {
                    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: part.vertexCount)
                }
            }
            for part in parts where !isSeeThrough(part) {
                if part.isPoints { drawPoints(part, blended: false) }
                else { drawMesh(part, blended: false) }
            }
            let eye = camera.position
            for part in parts.filter(isSeeThrough).sorted(by: { simd_dot($0.worldCenter - eye, camera.basis.back) < simd_dot($1.worldCenter - eye, camera.basis.back) }) {
                if part.isPoints { drawPoints(part, blended: true) }
                else {
                    encoder.setDepthStencilState(depthWrite)
                    drawMesh(part, blended: true)
                }
            }
            encoder.setCullMode(.none)
            // The outlines cartoon materials carry: each part's hull, pushed out by the
            // material's own width, its far faces only. Where the model's own look shows.
            if look.resolved.mode == 1 && look.style != .voxel {
                encoder.setDepthStencilState(depthWrite)
                for part in parts where !part.isPoints && (part.material.toon?.outlineWidth ?? 0) > 0 {
                    var draw = drawUniforms(for: part)
                    encoder.setRenderPipelineState(part.uvBuffer != nil ? toonOutlineUV : toonOutline)
                    encoder.setCullMode(part.mirrored ? .back : .front)
                    encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    if let uvs = part.uvBuffer {
                        encoder.setVertexBuffer(uvs, offset: 0, index: 5)
                        encoder.setFragmentTexture(part.texture ?? white, index: 0)
                        encoder.setFragmentSamplerState(sampler(for: part.material.sampling), index: 0)
                        encoder.setFragmentTexture(part.uvMaskTexture ?? white, index: 1)
                        encoder.setVertexTexture(part.outlineWidthTexture ?? white, index: 0)
                        encoder.setVertexSamplerState(sampler(for: part.material.sampling), index: 0)
                    }
                    if let indices = part.indexBuffer {
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
                    } else {
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: part.vertexCount)
                    }
                }
                encoder.setCullMode(.none)
            }
            if look.resolved.outline && scene.isOutlineReady {
                encoder.setRenderPipelineState(outline)
                encoder.setDepthStencilState(depthTest)
                encoder.setCullMode(.front)           // only the back faces of the hull
                for part in parts where !part.isPoints {
                    guard let normals = part.outlineNormals else { continue }
                    var draw = drawUniforms(for: part)
                    encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    encoder.setVertexBuffer(normals, offset: 0, index: 3)
                    if let indices = part.indexBuffer {
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
                    } else {
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: part.vertexCount)
                    }
                }
                encoder.setCullMode(.none)
            }
            if look.wire && (look.style == .voxel || scene.isWireReady) {
                encoder.setRenderPipelineState(wire)
                encoder.setDepthStencilState(depthTest)
                for part in parts {
                    guard let lines = part.wireIndexBuffer, part.wireIndexCount > 0 else { continue }
                    var draw = drawUniforms(for: part)
                    encoder.setVertexBuffer(part.vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    encoder.drawIndexedPrimitives(type: .line, indexCount: part.wireIndexCount, indexType: .uint32, indexBuffer: lines, indexBufferOffset: 0)
                }
            }
        }
        if showGrid {
            encoder.setRenderPipelineState(grid)
            encoder.setDepthStencilState(depthTest)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 2 * 21 * 2)
        }
        if let holo {
            encoder.setDepthStencilState(depthOff)
            holo.composite(into: encoder)
        }
        encoder.endEncoding()
    }

    private func hologramEffect() -> Hologram? {
        if hologram == nil, !hologramFailed {
            hologram = try? Hologram(device: device, library: library)
            hologramFailed = hologram == nil
        }
        return hologram
    }

    /// Back faces of a closed part are left out, which halves what the GPU has to keep for
    /// the frame, unless the camera is in or near the part's box: only there could the near
    /// plane cut the surface open and show its inside.
    private func hidesBackFaces(of part: GPUScene.Part, aspect: Float) -> Bool {
        guard cullsHiddenFaces, part.closed else { return false }
        let t = tan(camera.fovY / 2)
        // Distance from the camera to the corners of the near plane, with a little to spare.
        let reach = camera.near * (1 + t * t * (1 + aspect * aspect)).squareRoot() * 1.05
        let p = camera.position
        let outside = simd_max(part.worldBounds.min - p, p - part.worldBounds.max)
        return simd_reduce_max(outside) > reach
    }

    private func drawUniforms(for part: GPUScene.Part, blended: Bool = false) -> DrawUniforms {
        let view = Float(look.resolved.mode)
        let metallic = look.metallic ?? part.material.metallic
        let roughness = look.roughness ?? part.material.roughness
        // A value set in the view settings replaces the material's map, not just its number.
        var maps: Float = 0
        if part.mapsTexture != nil {
            if look.metallic == nil { maps += 1 }
            if look.roughness == nil { maps += 2 }
        }
        if part.normalTexture != nil { maps += 4 }
        if blended { maps += 8 }
        if part.material.unlit { maps += 32 }
        // A cut-out is solid where it is there at all; the threshold rides in the alpha.
        var alpha = blended ? part.material.opacity : 1
        if !blended, let cutoff = part.material.alphaCutoff {
            maps += 16
            alpha = cutoff
        }
        var uniforms = DrawUniforms(
            model: part.model, normalMatrix: part.normalMatrix,
            baseColor: SIMD4(part.material.baseColor, alpha),
            material: SIMD4(metallic, roughness, Self.pointSize * pixelsPerPoint, look.metallic != nil || look.roughness != nil ? 1 : 0),
            flags: SIMD4(view, maps, look.pbr ? 1 : 0, part.colorBuffer != nil ? 1 : 0),
            emissive: SIMD4(part.material.emissive, part.emissiveTexture != nil && part.uvBuffer != nil ? 1 : 0))
        uniforms.normalMap.x = part.material.normalScale
        uniforms.normalMap.y = part.material.normalYSign
        if let toon = part.material.toon {
            uniforms.shade = SIMD4(toon.shadeColor, 1)
            uniforms.toon = SIMD4(toon.shift, toon.toony, part.shadeTexture != nil && part.uvBuffer != nil ? 1 : 0, toon.outlineOnScreen ? -toon.outlineWidth : toon.outlineWidth)
            uniforms.line = SIMD4(toon.outlineColor, toon.outlineLightingMix)
            let mapped = part.uvBuffer != nil
            let images: Float = (mapped && part.matcapTexture != nil ? 1 : 0) + (mapped && part.rimTexture != nil ? 2 : 0)
                + (mapped && part.shiftTexture != nil ? 4 : 0) + (mapped && part.outlineWidthTexture != nil ? 8 : 0)
            uniforms.rim = SIMD4(toon.rimColor, toon.rimFresnelPower)
            uniforms.rimMore = SIMD4(toon.rimLift, toon.rimLightingMix, toon.shiftTextureScale, images)
            uniforms.matcap = SIMD4(toon.matcapColor, 0)
            if mapped, toon.uvScroll != .zero || toon.uvRotation != 0 {
                // Kept short, so that hours on the offsets are as exact as the first second.
                let t = Float(materialSeconds.truncatingRemainder(dividingBy: 3600))
                uniforms.uvMove = SIMD4(toon.uvScroll.x * t, toon.uvScroll.y * t, toon.uvRotation * t, part.uvMaskTexture != nil ? 1 : 0)
            }
        }
        return uniforms
    }

    // MARK: Targets of its own

    private var transient: (width: Int, height: Int, color: MTLTexture, depth: MTLTexture)?

    /// The multisampled colour and depth a frame is drawn into before it is resolved.
    /// They are needed only while the frame is drawn, so on Apple GPUs they live in the
    /// GPU's tile memory and take none of the process's (64 MB for a 1620 x 1244 view).
    private func transientTargets(width: Int, height: Int) -> (color: MTLTexture, depth: MTLTexture)? {
        if let t = transient, t.width == width, t.height == height { return (t.color, t.depth) }
        transient = nil
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = .type2DMultisample
            d.sampleCount = Self.sampleCount
            d.usage = [.renderTarget]
            d.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private
            return device.makeTexture(descriptor: d)
        }
        guard width > 0, height > 0, let color = texture(Self.colorFormat), let depth = texture(Self.depthFormat) else { return nil }
        transient = (width, height, color, depth)
        return (color, depth)
    }

    /// Encodes one frame that ends up in `target`: a single-sample `colorFormat` texture,
    /// such as a drawable's. Returns false when the frame could not be set up.
    @discardableResult
    public func encode(into commandBuffer: MTLCommandBuffer, target: MTLTexture) -> Bool {
        guard let targets = transientTargets(width: target.width, height: target.height) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.color
        pass.colorAttachments[0].resolveTexture = target
        pass.depthAttachment.texture = targets.depth
        encode(into: commandBuffer, pass: pass, size: CGSize(width: target.width, height: target.height))
        return true
    }

    // MARK: Offscreen

    /// Renders one frame to memory (for tests and previews). Builds the wire first if it is on.
    public func renderOffscreen(width: Int, height: Int) throws -> OffscreenImage {
        if look.wire { scene?.prepareWire() }
        if look.resolved.outline { scene?.prepareOutline() }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let resolve = device.makeTexture(descriptor: d), let commands = queue.makeCommandBuffer(),
              encode(into: commands, target: resolve) else { throw RenderError.tooLarge }
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return OffscreenImage(width: width, height: height, bytes: bytes)
    }
}
