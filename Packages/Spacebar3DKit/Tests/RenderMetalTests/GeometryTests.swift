import ModelCore
import RenderMetal
import simd
import ImportSTL
import XCTest

final class CameraTests: XCTestCase {
    func testFramingDistanceFitsTheLargestSideWithMargin() {
        let f = Framing(min: SIMD3(-1, 0, -0.5), max: SIMD3(1, 4, 0.5))
        XCTAssertEqual(f.center, SIMD3(0, 2, 0))
        XCTAssertEqual(f.size, SIMD3(2, 4, 1))
        XCTAssertEqual(f.distance, 4 / 2 / tan(Float.pi / 12) * 1.4, accuracy: 1e-4)
    }

    func testPortraitRenderFitsBothHorizontalEdges() throws {
        let scene = try STLReader.scene(from: Data("""
        solid t
        facet normal 0 0 1
        outer loop
        vertex -1 -1 0
        vertex 1 -1 0
        vertex 0 1 0
        endloop
        endfacet
        endsolid t
        """.utf8))
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        let image = try renderer.renderOffscreen(width: 100, height: 200)
        XCTAssertGreaterThan(image.pixel(50,100).a, 0)
        XCTAssertTrue((0..<200).allSatisfy { image.pixel(0,$0).a == 0 && image.pixel(99,$0).a == 0 })
    }

    func testFittedBoundsInPortraitLandscapeAndAxisPresets() {
        for size: SIMD3<Float> in [SIMD3(6,2,2), SIMD3(2,6,1), SIMD3(2,1,10)] {
            let framing = Framing(min: -size / 2, max: size / 2)
            for aspect: Float in [0.25, 0.5, 1, 2] {
                let home = OrbitCamera.home(for: framing, aspect: aspect)
                let cameras = [home, OrbitCamera(yaw: 0.8, pitch: 0.4).fitted(to: framing, aspect: aspect)]
                    + ViewPreset.allCases.map { OrbitCamera.preset($0, framing: framing, like: home, aspect: aspect) }
                for camera in cameras {
                    let m = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix
                    for x: Float in [-0.5,0.5] { for y: Float in [-0.5,0.5] { for z: Float in [-0.5,0.5] {
                        let p = m * SIMD4(size * SIMD3(x,y,z), 1)
                        XCTAssertLessThan(abs(p.x / p.w), 1)
                        XCTAssertLessThan(abs(p.y / p.w), 1)
                        XCTAssertGreaterThan(p.z / p.w, 0); XCTAssertLessThan(p.z / p.w, 1)
                    } } }
                }
            }
        }
    }

    func testResizeUpdatesHomeButPreservesUserZoomAndPan() throws {
        let renderer = try MetalRenderer()
        renderer.setViewportSize(CGSize(width: 100, height: 200))
        XCTAssertEqual(renderer.camera, renderer.homeCamera)
        var chosen = renderer.camera
        chosen.distance *= 0.6; chosen.target += SIMD3(1,2,3); chosen.yaw = 0.8
        renderer.camera = chosen
        renderer.setViewportSize(CGSize(width: 400, height: 200))
        XCTAssertEqual(renderer.camera, chosen)
        XCTAssertNotEqual(renderer.homeCamera, chosen)
    }

    func testHomeCameraLooksFromFrontAndLittleAbove() {
        let f = Framing(min: SIMD3(-1, 0, -1), max: SIMD3(1, 2, 1))
        let c = OrbitCamera.home(for: f)
        XCTAssertEqual(c.target, f.center)
        XCTAssertEqual(c.position.x, f.center.x, accuracy: 1e-5)
        XCTAssertEqual(c.position.y, f.center.y + 2 * 0.05, accuracy: 1e-4)
        XCTAssertEqual(c.position.z, f.center.z + f.distance, accuracy: 1e-4)
        XCTAssertEqual(c.near, f.distance / 100, accuracy: 1e-6)
        XCTAssertEqual(c.far, f.distance * 100, accuracy: 1e-3)
    }

    func testAFlatModelIsFirstSeenFromAbove() throws {
        // A plate on the ground: edge-on from the front it would be a line.
        let plate = Framing(min: SIMD3(0, 0, -4), max: SIMD3(2, 0, 0))
        let c = OrbitCamera.home(for: plate)
        XCTAssertEqual(c.pitch, OrbitCamera.flatPitch)
        XCTAssertEqual(c.target, plate.center)
        let m = c.projectionMatrix(aspect: 1) * c.viewMatrix
        var ys: [Float] = []
        for x in [0, 2] as [Float] {
            for z in [-4, 0] as [Float] {
                let p = m * SIMD4(x, 0, z, 1)
                XCTAssertLessThan(abs(p.x / p.w), 1)
                XCTAssertLessThan(abs(p.y / p.w), 1)
                ys.append(p.y / p.w)
            }
        }
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.3, "the plate has a visible depth")
        // A low model that is not flat keeps the view from the front.
        let low = Framing(min: SIMD3(0, 0, 0), max: SIMD3(10, 1, 10))
        XCTAssertLessThan(OrbitCamera.home(for: low).pitch, 0.01)
        // A wall is thin, not flat.
        XCTAssertLessThan(OrbitCamera.home(for: Framing(min: SIMD3(0, 0, 0), max: SIMD3(4, 3, 0))).pitch, 0.02)

        // Drawn, it is there.
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.backgroundAlpha = 0
        let stl = "solid t\n facet normal 0 0 0\n  outer loop\n   vertex 0 0 0\n   vertex 2 0 0\n   vertex 0 4 0\n  endloop\n endfacet\nendsolid t\n"
        renderer.show(try renderer.makeScene(STLReader.scene(from: Data(stl.utf8))))
        let image = try renderer.renderOffscreen(width: 96, height: 96)
        var covered = 0
        for i in stride(from: 3, to: image.bytes.count, by: 4) where image.bytes[i] > 128 { covered += 1 }
        XCTAssertGreaterThan(covered, 200)
    }

    func testTheFittedModelIsInsideTheView() {
        let f = Framing(min: SIMD3(-3, -1, -1), max: SIMD3(3, 1, 1))
        let c = OrbitCamera.home(for: f)
        let m = c.projectionMatrix(aspect: 1) * c.viewMatrix
        for x in [-3, 3] as [Float] {
            for y in [-1, 1] as [Float] {
                let p = m * SIMD4(x, y, 1, 1)
                XCTAssertLessThan(abs(p.x / p.w), 1)
                XCTAssertLessThan(abs(p.y / p.w), 1)
                XCTAssertTrue(p.z / p.w > 0 && p.z / p.w < 1)
            }
        }
    }

    func testReversedDepthMapsNearToOneAndFarToZero() {
        let c = OrbitCamera(target: .zero, distance: 5, near: 0.5, far: 50)
        let p = c.projectionMatrix(aspect: 1)
        let near = p * SIMD4(0, 0, -0.5, 1), far = p * SIMD4(0, 0, -50, 1)
        XCTAssertEqual(near.z / near.w, 1, accuracy: 1e-5)
        XCTAssertEqual(far.z / far.w, 0, accuracy: 1e-5)
    }

    func testOrbitAndPanMoveInTheExpectedDirections() {
        var c = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0)
        c.orbit(dx: 100, dy: 0, viewHeight: 400)       // drag right: camera goes left
        for _ in 0..<600 { c.step(dt: 1 / 60) }
        XCTAssertEqual(c.yaw, -2 * .pi * 100 / 400, accuracy: 1e-2)
        XCTAssertFalse(c.isMoving)

        var d = OrbitCamera(target: .zero, distance: 4)
        d.orbit(dx: 0, dy: 50, viewHeight: 400)        // drag down: camera goes up
        for _ in 0..<600 { d.step(dt: 1 / 60) }
        XCTAssertGreaterThan(d.pitch, 0.5)

        var p = OrbitCamera(target: .zero, distance: 4)
        p.pan(dx: 10, dy: 0, viewHeight: 400)          // drag right: the target moves left
        for _ in 0..<600 { p.step(dt: 1 / 60) }
        XCTAssertLessThan(p.target.x, 0)
        XCTAssertEqual(p.target.y, 0, accuracy: 1e-6)
    }

    func testPitchIsClampedAndZoomIsLimited() {
        var c = OrbitCamera(target: .zero, distance: 4)
        c.orbit(dx: 0, dy: 100000, viewHeight: 400)
        for _ in 0..<600 { c.step(dt: 1 / 60) }
        XCTAssertLessThanOrEqual(c.pitch, OrbitCamera.maxPitch)
        c.zoom(scale: 1e-3)
        for _ in 0..<600 { c.step(dt: 1 / 60, distanceLimits: 1...10) }
        XCTAssertEqual(c.distance, 1, accuracy: 1e-4)
    }

    func testPresetsLookFromTheirAxis() {
        let f = Framing(min: .zero, max: SIMD3(2, 2, 2))
        let base = OrbitCamera.home(for: f)
        for preset in ViewPreset.allCases {
            let c = OrbitCamera.preset(preset, framing: f, like: base)
            let direction = simd_normalize(c.position - f.center)
            XCTAssertGreaterThan(simd_dot(direction, preset.direction), 0.999, "\(preset)")
            XCTAssertEqual(simd_length(c.position - f.center), f.distance, accuracy: 1e-4)
        }
    }

    /// At its closest the camera is a fiftieth of the fitting distance from what it looks
    /// at, and the near plane used to stay a hundredth away: the nearer half of that was cut
    /// open. The near plane comes in with the camera, and from further off is where it was.
    func testTheNearPlaneComesInWithTheCamera() {
        let f = Framing(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1))
        var c = OrbitCamera.home(for: f)
        /// Whether a point this share of the way from the camera to what it looks at is drawn.
        func drawn(_ share: Float) -> Bool {
            let clip = c.projectionMatrix(aspect: 1) * c.viewMatrix * SIMD4(c.position + (c.target - c.position) * share, 1)
            return clip.w > 0 && clip.z >= 0 && clip.z <= clip.w
        }
        let fromHome = f.distance / 100 / c.distance
        XCTAssertTrue(drawn(fromHome * 1.01))
        XCTAssertFalse(drawn(fromHome * 0.99), "the near plane is where it was")
        c.distance = f.distance * 0.02
        XCTAssertTrue(drawn(0.3), "close up, what stands a third of the way to the camera is still there")
        XCTAssertTrue(drawn(0.11))
        XCTAssertFalse(drawn(0.09), "a tenth of the way is where it ends")
    }

    /// Turning on and on (auto-rotate left running for days) kept adding to one angle, until
    /// it was so large that a frame's turn was less than it could tell apart, and the model
    /// stopped or jerked. The angle is kept within one turn.
    func testTheAngleStaysWithinOneTurnHoweverFarItHasTurned() {
        var c = OrbitCamera(target: .zero, distance: 4)
        c.rotate(yaw: 1_000_000.25, pitch: 0)
        XCTAssertLessThanOrEqual(abs(c.yaw), .pi + 1e-4)
        let before = c.position
        c.rotate(yaw: 0.001, pitch: 0)
        XCTAssertEqual(simd_distance(c.position, before), 0.004, accuracy: 0.0004, "a small turn still turns it")
        // The same by dragging: the turn is taken in over a few frames.
        var dragged = OrbitCamera(target: .zero, distance: 4, yaw: 3.1)
        dragged.orbit(dx: -200, dy: 0, viewHeight: 400)
        for _ in 0..<600 { dragged.step(dt: 1 / 60) }
        XCTAssertLessThanOrEqual(abs(dragged.yaw), .pi + 1e-4)
    }

    func testBlendTakesTheShortWayRound() {
        let a = OrbitCamera(yaw: 3.0), b = OrbitCamera(yaw: -3.0)
        let mid = OrbitCamera.blend(a, b, 0.5)
        XCTAssertEqual(cos(mid.yaw), -1, accuracy: 0.01)   // through pi, not through 0
    }

    /// A move from near to far changes the model's size on the screen evenly: halfway
    /// through, it is as many times smaller than at the start as it will yet become. The
    /// distance itself taken halfway did nearly all its shrinking in the first frames.
    func testAMoveChangesTheSizeOnTheScreenEvenly() {
        let near = OrbitCamera(distance: 1), far = OrbitCamera(distance: 100)
        XCTAssertEqual(OrbitCamera.blend(near, far, 0.5).distance, 10, accuracy: 1e-3)
        XCTAssertEqual(OrbitCamera.blend(far, near, 0.25).distance, 31.6228, accuracy: 1e-2)
        XCTAssertEqual(OrbitCamera.blend(near, far, 0).distance, 1, accuracy: 1e-6)
        XCTAssertEqual(OrbitCamera.blend(near, far, 1).distance, 100, accuracy: 1e-4)
        // A distance of nothing has no ratio to anything: the move is then even in distance.
        XCTAssertEqual(OrbitCamera.blend(OrbitCamera(distance: 0), OrbitCamera(distance: 4), 0.5).distance, 2, accuracy: 1e-6)
    }

    func testGridCellIsARoundNumberNearAFifthOfTheModel() {
        let g = GridPlacement(framing: Framing(min: .zero, max: SIMD3(1.7, 1, 1)))
        XCTAssertEqual(g.cell, 0.5, accuracy: 1e-6)      // rough 0.34 -> 0.5
        XCTAssertEqual(g.center.y, 0, accuracy: 1e-6)    // under the model
        let big = GridPlacement(framing: Framing(min: SIMD3(-50, 10, -50), max: SIMD3(50, 30, 50)))
        XCTAssertEqual(big.cell, 20, accuracy: 1e-4)
        XCTAssertEqual(big.center.y, 10, accuracy: 1e-4)
    }

    func testBackgroundColoursAndGridContrast() {
        XCTAssertTrue(BackgroundColors(base: SIMD3(0x1c, 0x1c, 0x1e) / 255).isDark)
        XCTAssertFalse(BackgroundColors(base: SIMD3(0.9, 0.9, 0.9)).isDark)
        // A coloured room is lit in its own colour: the middle of a green one stays green.
        let green = BackgroundColors(base: SIMD3(0x07, 0x11, 0x0c) / 255)
        XCTAssertTrue(green.isDark)
        XCTAssertGreaterThan(green.centre.y, green.centre.x + 0.03)
        XCTAssertGreaterThan(green.centre.y, green.centre.z)
        // Its floor is green too, and the lines through the middle are the axes' colours.
        XCTAssertGreaterThan(green.gridLine.y, green.gridLine.x)
        XCTAssertEqual(green.axisX, SIMD3(0xff, 0x6a, 0x3d) / 255)
        XCTAssertEqual(green.axisZ, SIMD3(0xb8, 0xd3, 0xff) / 255)
        // A light room has black lines throughout.
        let light = BackgroundColors(base: SIMD3(0.9, 0.9, 0.9))
        XCTAssertEqual([light.gridLine, light.axisX, light.axisZ], Array(repeating: SIMD3<Float>(repeating: 0), count: 3))
        let grey = BackgroundColors(base: SIMD3(0.2, 0.2, 0.2)).centre
        XCTAssertEqual(grey.x, grey.y, accuracy: 1e-5)
        XCTAssertEqual(grey.y, grey.z, accuracy: 1e-5)
        let c = BackgroundColors(base: SIMD3(0.2, 0.2, 0.2))
        XCTAssertGreaterThan(c.centre.x, c.base.x)
        XCTAssertLessThan(c.edge.x, c.base.x)
    }
}

final class MeshProcessingTests: XCTestCase {
    func testWelderFindsSamePositionsIncludingNegativeZero() {
        let ids = PositionWelder.canonicalIDs([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(-0.0, 0, 0), SIMD3(1, 0, 0)])
        XCTAssertEqual(ids, [0, 1, 0, 1])
    }

    private let square: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]

    private func pairs(_ edges: [UInt32], _ indices: [UInt32]) -> Set<[UInt32]> {
        var out = Set<[UInt32]>()
        for i in stride(from: 0, to: edges.count, by: 2) {
            out.insert([indices[Int(edges[i])], indices[Int(edges[i + 1])]].sorted())
        }
        return out
    }

    func testWireOfTrianglesWithoutFaceSizesIsEveryEdgeOnce() {
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let e = WireLines.edges(triangleIndices: indices, faceSizes: nil)
        XCTAssertEqual(e.count, 10)   // 5 edges, the shared diagonal once
        XCTAssertEqual(pairs(e, indices), [[0, 1], [1, 2], [0, 2], [2, 3], [0, 3]])
    }

    func testWireOfAQuadHasNoDiagonal() {
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let e = WireLines.edges(triangleIndices: indices, faceSizes: [4])
        XCTAssertEqual(pairs(e, indices), [[0, 1], [1, 2], [2, 3], [0, 3]])
        XCTAssertEqual(e.count, 8)
    }

    func testWireOfTrianglesAndQuadsMixed() {
        // A triangle (0 1 2) next to a quad (1 3 4 2) split along 1-4.
        let indices: [UInt32] = [0, 1, 2, 1, 3, 4, 1, 4, 2]
        let e = WireLines.edges(triangleIndices: indices, faceSizes: [3, 4])
        XCTAssertEqual(pairs(e, indices), [[0, 1], [1, 2], [0, 2], [1, 3], [3, 4], [2, 4]])
    }

    func testWireOfAPentagonIsItsFiveSides() {
        // Fan 0-1-2, 0-2-3, 0-3-4.
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3, 0, 3, 4]
        let e = WireLines.edges(triangleIndices: indices, faceSizes: [5])
        XCTAssertEqual(pairs(e, indices), [[0, 1], [1, 2], [2, 3], [3, 4], [0, 4]])
    }

    func testWireOfAnNGonWithManySides() {
        let n = 40
        var indices: [UInt32] = []
        for k in 1..<(n - 1) { indices += [0, UInt32(k), UInt32(k + 1)] }
        let e = WireLines.edges(triangleIndices: indices, faceSizes: [UInt32(n)])
        XCTAssertEqual(e.count / 2, n)
    }

    func testWireMergesPositionsThatAreTheSamePoint() {
        // Two separate triangles (soup) forming a quad; keys say corners 0/3 and 2/5 coincide.
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5]
        let keys: [UInt32] = [0, 1, 2, 0, 2, 5]   // vertex 3 == 0, vertex 4 == 2
        let e = WireLines.edges(triangleIndices: indices, faceSizes: [4], vertexKeys: keys)
        XCTAssertEqual(e.count / 2, 4)
        let none = WireLines.edges(triangleIndices: indices, faceSizes: nil, vertexKeys: keys)
        XCTAssertEqual(none.count / 2, 5)
    }

    /// A flat sheet of four by four squares two units wide, each split from its first
    /// corner to the one opposite; `middle` is the vertex all sixteen surround.
    private func sheet() -> (positions: [SIMD3<Float>], indices: [UInt32], middle: Int) {
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for y in 0...4 { for x in 0...4 { positions.append(SIMD3(Float(x), Float(y), 0) * 2) } }
        for y in 0..<UInt32(4) {
            for x in 0..<UInt32(4) {
                let i = y * 5 + x
                indices += [i, i + 1, i + 6, i, i + 6, i + 5]
            }
        }
        return (positions, indices, 12)
    }

    private func spacing(_ sheet: (positions: [SIMD3<Float>], indices: [UInt32], middle: Int), faceSizes: [UInt32]?) -> Float {
        let lines = WireLines.edges(triangleIndices: sheet.indices, faceSizes: faceSizes).map { sheet.indices[Int($0)] }
        return WireLines.spacing(vertexCount: sheet.positions.count, triangleIndices: sheet.indices, lines: lines) { sheet.positions[$0] }[sheet.middle]
    }

    /// The lines of a sheet of squares are half a square apart: each square has its own
    /// width of line along and as much across (every side is shared with a neighbour).
    func testTheLinesOfSquaresAreHalfASquareApart() {
        XCTAssertEqual(spacing(sheet(), faceSizes: [UInt32](repeating: 4, count: 16)), 1, accuracy: 1e-5)
    }

    /// With every square's diagonal drawn too, there is more line on the same area.
    func testTheLinesOfTrianglesAreCloserThanThoseOfTheirSquares() {
        XCTAssertEqual(spacing(sheet(), faceSizes: nil), 2 / (2 + Float(2).squareRoot()), accuracy: 1e-5)
    }

    /// Vertices at one position are one point of the surface, whichever triangles each
    /// of them is a corner of.
    func testVerticesAtOnePositionHaveTheSameSpacing() {
        // Two separate triangles that make a unit square: vertex 3 is at 0 and vertex 4 at 2.
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5], keys: [UInt32] = [0, 1, 2, 0, 2, 5]
        let lines = WireLines.edges(triangleIndices: indices, faceSizes: [4], vertexKeys: keys).map { indices[Int($0)] }
        let apart = WireLines.spacing(vertexCount: 6, triangleIndices: indices, lines: lines, vertexKeys: keys) { positions[$0] }
        XCTAssertEqual(apart[0], apart[3]); XCTAssertEqual(apart[2], apart[4])
        // A third of both triangles' area (1/6 + 1/6) over half of the two sides that meet there (1).
        XCTAssertEqual(apart[0], 1.0 / 3, accuracy: 1e-5)
    }

    /// A cube of eight shared corners, each face two triangles, counter-clockwise from outside.
    private var sharedCube: (positions: [SIMD3<Float>], indices: [UInt32]) {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
        let quads: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
        return (positions, quads.flatMap { [$0[0], $0[1], $0[2], $0[0], $0[2], $0[3]] })
    }

    /// Two squares that meet at a bend of twenty degrees. The two vertices of the bend
    /// are in the file twice, once for each square (4 and 5 are where 1 and 2 are).
    private var bentSeam: (positions: [SIMD3<Float>], indices: [UInt32]) {
        let far = SIMD3<Float>(1 + cos(20 * .pi / 180), 0, sin(20 * .pi / 180))
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                                         SIMD3(1, 0, 0), SIMD3(1, 1, 0), far, far + SIMD3(0, 1, 0)]
        return (positions, [0, 1, 2, 0, 2, 3, 4, 6, 7, 4, 7, 5])
    }

    /// `SmoothNormals.indexed` with what it writes in place and what it leaves unsaid:
    /// which of the file's vertices each vertex is.
    private func indexedNormals(_ positions: [SIMD3<Float>], _ triangles: [UInt32]) -> (normals: [SIMD3<Float>], sources: [UInt32], indices: [UInt32]) {
        var indices = [UInt32](repeating: 0, count: triangles.count)
        let made = indices.withUnsafeMutableBufferPointer { SmoothNormals.indexed(positions: positions, triangleIndices: triangles, indices: $0.baseAddress!) }
        return (made.normals, (0..<UInt32(positions.count)).map { $0 } + made.repeated, indices)
    }

    /// A mesh too large to give every corner a vertex of its own gets the normals a small
    /// one gets, corner for corner.
    func testNormalsOfSharedVerticesAreThoseOfSeparateCorners() {
        let flat = sheet()
        for (positions, indices) in [sharedCube, bentSeam, (flat.positions, flat.indices)] {
            let corner = SmoothNormals.generate(positions: positions, triangleIndices: indices)
            let made = indexedNormals(positions, indices)
            XCTAssertEqual(made.indices.count, indices.count)
            XCTAssertEqual(made.normals.count, made.sources.count)
            for i in indices.indices {
                let vertex = Int(made.indices[i])
                XCTAssertEqual(simd_distance(made.normals[vertex], corner[i]), 0, accuracy: 1e-4, "corner \(i)")
                XCTAssertEqual(positions[Int(made.sources[vertex])], positions[Int(indices[i])], "corner \(i)")
            }
        }
    }

    /// A vertex is repeated only where its corners need different normals: each corner of
    /// a cube three times, no vertex of a flat sheet.
    func testOnlyAVertexOnASharpEdgeIsRepeated() {
        let cube = indexedNormals(sharedCube.positions, sharedCube.indices)
        XCTAssertEqual(cube.normals.count, 24)
        XCTAssertEqual(Array(cube.sources.prefix(8)), Array(0..<8), "the file's vertices keep their places")
        let flat = sheet()
        let made = indexedNormals(flat.positions, flat.indices)
        XCTAssertEqual(made.normals.count, flat.positions.count)
        XCTAssertEqual(made.indices, flat.indices)
    }

    /// Vertices at one position share a normal across the seam that keeps them apart in
    /// the file, so the surface is lit as one.
    func testNormalsAreSharedAcrossASeamOfRepeatedVertices() {
        let made = indexedNormals(bentSeam.positions, bentSeam.indices)
        XCTAssertEqual(made.normals.count, 8)
        XCTAssertEqual(simd_distance(made.normals[1], made.normals[4]), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(made.normals[2], made.normals[5]), 0, accuracy: 1e-5)
        // Halfway between the two squares' own normals, ten degrees from each.
        XCTAssertEqual(simd_dot(made.normals[1], SIMD3(0, 0, 1)), cos(10 * .pi / 180), accuracy: 1e-4)
    }

    func testPolygonListShorterThanTheTrianglesDrawsTheRest() {
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3, 3, 2, 4]
        let e = WireLines.edges(triangleIndices: indices, faceSizes: [4])
        XCTAssertEqual(pairs(e, indices), [[0, 1], [1, 2], [2, 3], [0, 3], [3, 4], [2, 4]])
    }

    func testConcavePolygonWireKeepsOnlyItsBoundary() throws {
        let polygon: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(3,0,0), SIMD3(3,3,0), SIMD3(2,3,0), SIMD3(2,1,0), SIMD3(1,1,0), SIMD3(1,3,0), SIMD3(0,3,0)]
        let triangles = try XCTUnwrap(PolygonTriangulation.indices(count: polygon.count) { polygon[$0] }).map(UInt32.init)
        let edges = WireLines.edges(triangleIndices: triangles, faceSizes: [8])
        let expected = Set((0..<8).map { [UInt32($0),UInt32(($0 + 1) % 8)].sorted() })
        XCTAssertEqual(pairs(edges, triangles), expected)
    }

    func testSmoothNormalsOfAFlatSquareAllPointUp() {
        let tri: [UInt32] = [0, 1, 2, 0, 2, 3]
        let n = SmoothNormals.generate(positions: square, triangleIndices: tri)
        XCTAssertEqual(n.count, 6)
        for v in n { XCTAssertEqual(v, SIMD3(0, 0, 1)) }
    }

    func testSmoothNormalsKeepACubeSharpButRoundASphere() {
        // Cube as a soup: corners at the same position must keep their own face normal.
        let p: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
        let faces: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [0, 4, 7, 3], [1, 2, 6, 5]]
        var tri: [UInt32] = []
        for f in faces { tri += [f[0], f[1], f[2], f[0], f[2], f[3]] }
        let n = SmoothNormals.generate(positions: p, triangleIndices: tri)
        for t in 0..<(tri.count / 3) {
            let a = p[Int(tri[t * 3])], b = p[Int(tri[t * 3 + 1])], c = p[Int(tri[t * 3 + 2])]
            let face = simd_normalize(simd_cross(b - a, c - a))
            for k in 0..<3 { XCTAssertGreaterThan(simd_dot(n[t * 3 + k], face), 0.999) }
        }

        // A 12-sided ring of quads around Y (30 degree steps): corners share one normal that
        // points away from the axis.
        var ring: [SIMD3<Float>] = [], idx: [UInt32] = []
        let steps = 12
        for i in 0..<steps {
            let a0 = Float(i) / Float(steps) * 2 * .pi, a1 = Float((i + 1) % steps) / Float(steps) * 2 * .pi
            let base = UInt32(ring.count)
            ring += [SIMD3(cos(a0), 0, sin(a0)), SIMD3(cos(a1), 0, sin(a1)), SIMD3(cos(a1), 1, sin(a1)), SIMD3(cos(a0), 1, sin(a0))]
            idx += [base, base + 2, base + 1, base, base + 3, base + 2]
        }
        let rn = SmoothNormals.generate(positions: ring, triangleIndices: idx)
        for (i, corner) in idx.enumerated() {
            let radial = simd_normalize(SIMD3(ring[Int(corner)].x, 0, ring[Int(corner)].z))
            XCTAssertGreaterThan(simd_dot(rn[i], radial), 0.999, "corner \(i)")
        }
    }

    func testSmoothNormalsOfDegenerateTrianglesDoNotBreak() {
        let n = SmoothNormals.generate(positions: [SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 0)], triangleIndices: [0, 1, 2])
        XCTAssertEqual(n.count, 3)
        for v in n { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite) }
    }
}
