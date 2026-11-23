import ImportPLY
import ImportOBJ
import Metal
import ModelCore
@testable import RenderMetal
import simd
import XCTest

final class PointCloudRegressionTests: XCTestCase {
    private func cloud(_ positions: [SIMD3<Float>]) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.primitive = .points; part.positions = positions; part.material = 0
        var scene = ModelScene(), material = ModelScene.Material()
        material.baseColor = SIMD4(1, 1, 1, 1); material.opacity = 0.5
        scene.materials = [material]; scene.meshes = [.init(parts: [part])]
        scene.nodes = [.init(mesh: 0)]
        return scene
    }

    private func indices(_ buffer: MTLBuffer, count: Int) -> [UInt32] {
        Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt32.self), count: count))
    }

    func testFallbackPointColorsKeepTheirSourceBrightness() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        for colored in [false, true] {
            let properties = colored ? "property uchar red\nproperty uchar green\nproperty uchar blue\n" : ""
            let values = colored ? " 255 128 64" : ""
            let text = "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\n" + properties + "end_header\n0 0 0" + values + "\n"
            let imported = try PLYReader.scene(from: Data(text.utf8))
            for noMaterial in [false, true] {
                var source = imported
                if noMaterial { source.materials = []; source.meshes[0].parts[0].material = nil }
                renderer.show(try renderer.makeScene(source)); renderer.camera = OrbitCamera()
                let p = try renderer.renderOffscreen(width: 128, height: 128).pixel(64, 64)
                let expected = colored ? [255, 128, 64, 255] : [180, 180, 184, 255]
                for (actual, wanted) in zip([Int(p.r), Int(p.g), Int(p.b), Int(p.a)], expected) {
                    XCTAssertEqual(actual, wanted, accuracy: 1, "colored \(colored), no material \(noMaterial)")
                }
            }
        }
    }

    /// Faces with colours of their own and no material are those colours, as points are:
    /// the stand-in grey is for what has neither.
    func testFallbackFaceColorsAreNotTintedByTheStandInGrey() throws {
        let renderer = try MetalRenderer()
        for colored in [false, true] {
            var part = ModelScene.MeshPart()
            part.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
            part.triangleIndices = [0, 1, 2]
            if colored { part.colors = [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1)] }
            var scene = ModelScene()
            scene.meshes = [.init(parts: [part])]
            scene.nodes = [.init(mesh: 0)]
            let material = try XCTUnwrap(renderer.makeScene(scene).parts.first?.material)
            XCTAssertEqual(material.baseColor, colored ? SIMD3(1, 1, 1) : RenderMaterial.plain.baseColor, "colored \(colored)")
        }
    }

    func testOBJPointColorsKeepTheirSourceBrightness() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        for colored in [false, true] {
            let values = colored ? " 1 0.5019607843137255 0.25098039215686274" : ""
            let source = try OBJReader.scene(from: Data(("v 0 0 0" + values + "\n").utf8))
            renderer.show(try renderer.makeScene(source)); renderer.camera = OrbitCamera()
            let p = try renderer.renderOffscreen(width: 128, height: 128).pixel(64, 64)
            let expected = colored ? [255, 128, 64, 255] : [200, 200, 204, 255]
            for (actual, wanted) in zip([Int(p.r), Int(p.g), Int(p.b), Int(p.a)], expected) {
                XCTAssertEqual(actual, wanted, accuracy: 1, "colored \(colored)")
            }
        }
    }

    func testPointOrderReusesBufferUntilCameraDirectionChanges() throws {
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(cloud([SIMD3(0, 0, 1), SIMD3(0, 0, -1), .zero]))
        let part = gpu.parts[0]
        var camera = OrbitCamera()
        let first = try XCTUnwrap(gpu.orderedPointIndices(for: part, camera: camera))
        XCTAssertEqual(indices(first, count: 3), [1, 2, 0])
        renderer.show(gpu); renderer.camera = camera
        renderer.showGrid = false; renderer.showShadow = false
        renderer.lightRotation = 1.5; renderer.lightIntensity = 2
        _ = try renderer.renderOffscreen(width: 32, height: 32)
        XCTAssertTrue(first === gpu.orderedPointIndices(for: part, camera: camera), "lighting-only redraw reuses order")
        camera.distance = 50; camera.target = SIMD3(10, 20, 30)
        let translated = try XCTUnwrap(gpu.orderedPointIndices(for: part, camera: camera))
        XCTAssertTrue(first === translated, "pan and dolly do not change depth order")
        camera.yaw = .pi
        let reversed = try XCTUnwrap(gpu.orderedPointIndices(for: part, camera: camera))
        XCTAssertFalse(first === reversed)
        XCTAssertEqual(indices(reversed, count: 3), [0, 2, 1])
        XCTAssertEqual(indices(first, count: 3), [1, 2, 0], "queued frames keep their original order")
    }

    func testPointOrderTracksActualJointAndMorphChanges() throws {
        for morph in [false, true] { for onGPU in [false, true] {
            let renderer = try MetalRenderer()
            renderer.showGrid = false; renderer.showShadow = false; renderer.skinsOnGPU = onGPU
            var source = cloud([SIMD3(0, 0, 1), .zero])
            source.meshes[0].parts[0].skin = .init(skeleton: 0, joints: [SIMD4(0,0,0,0), SIMD4(1,0,0,0)], weights: [SIMD4(1,0,0,0), SIMD4(1,0,0,0)])
            source.skeletons = [.init(joints: [.init(), .init()])]
            var clip = ModelScene.AnimationClip(skeleton: 0, end: 1)
            if morph {
                source.meshes[0].parts[0].morphTargets = [.init(positions: [SIMD3(0,0,-2), .zero])]
                clip.morphs = [.init(mesh: 0, targetCount: 1, times: [0,1], values: [0,1])]
            } else { clip.linearTranslations[0] = .init(times: [0,1], values: [.zero, SIMD3(0,0,-2)]) }
            source.clips = [clip]
            let gpu = try renderer.makeScene(source), camera = OrbitCamera()
            renderer.show(gpu); renderer.camera = camera
            let part = gpu.parts[0]
            let first = try XCTUnwrap(gpu.orderedPointIndices(for: part, camera: camera))
            gpu.pose(clip: 0, time: 0)
            _ = try renderer.renderOffscreen(width: 32, height: 32)
            XCTAssertTrue(first === gpu.orderedPointIndices(for: part, camera: camera), "unchanged pose must reuse its order")
            gpu.pose(clip: 0, time: 1)
            _ = try renderer.renderOffscreen(width: 32, height: 32)
            let moved = try XCTUnwrap(gpu.orderedPointIndices(for: part, camera: camera))
            XCTAssertFalse(first === moved)
            XCTAssertEqual(indices(moved, count: 2), [0, 1])
            XCTAssertEqual(indices(first, count: 2), [1, 0])
            gpu.pose(clip: 0, time: 1)
            _ = try renderer.renderOffscreen(width: 32, height: 32)
            XCTAssertTrue(moved === gpu.orderedPointIndices(for: part, camera: camera))
        } }
    }

    func testPointOrderMatchesStableDepthSortForLargeCloud() throws {
        var seed: UInt32 = 12345
        var positions: [SIMD3<Float>] = []
        for _ in 0..<20_000 {
            seed = seed &* 1664525 &+ 1013904223
            positions.append(SIMD3(0, 0, Float(Int(seed % 4096) - 2048) / 16))
        }
        // Equal depths, including signed zero, retain source order.
        positions += [SIMD3(0, 0, -Float.zero), .zero]
        let expected = positions.indices.sorted {
            positions[$0].z == positions[$1].z ? $0 < $1 : positions[$0].z < positions[$1].z
        }.map(UInt32.init)
        let renderer = try MetalRenderer(), gpu = try renderer.makeScene(cloud(positions))
        let buffer = try XCTUnwrap(gpu.orderedPointIndices(for: gpu.parts[0], camera: OrbitCamera()))
        XCTAssertEqual(indices(buffer, count: positions.count), expected)
    }
}
