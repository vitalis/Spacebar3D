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

    func testBlendTakesTheShortWayRound() {
        let a = OrbitCamera(yaw: 3.0), b = OrbitCamera(yaw: -3.0)
        let mid = OrbitCamera.blend(a, b, 0.5)
        XCTAssertEqual(cos(mid.yaw), -1, accuracy: 0.01)   // through pi, not through 0
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
