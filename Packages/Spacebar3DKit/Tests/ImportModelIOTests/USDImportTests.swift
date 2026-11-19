import Foundation
import ImportRouter
import ModelCore
import RenderMetal
import simd
import XCTest

final class USDImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-usd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A quad and a triangle under a moved parent, Z up, with texture coordinates and a red material.
    private let usda = """
    #usda 1.0
    (
        upAxis = "Z"
        defaultPrim = "root"
    )

    def Xform "root"
    {
        double3 xformOp:translate = (10, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]

        def Mesh "shape" (
            prepend apiSchemas = ["MaterialBindingAPI"]
        )
        {
            int[] faceVertexCounts = [4, 3]
            int[] faceVertexIndices = [0, 1, 2, 3, 1, 4, 2]
            point3f[] points = [(0, 0, 0), (1, 0, 0), (1, 2, 0), (0, 2, 0), (2, 0, 3)]
            texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1), (1, 0), (1, 1), (1, 1)] (
                interpolation = "faceVarying"
            )
            rel material:binding = </root/red>
        }

        def Material "red"
        {
            token outputs:surface.connect = </root/red/surface.outputs:surface>

            def Shader "surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (1, 0, 0)
                float inputs:metallic = 0.25
                float inputs:roughness = 0.75
                token outputs:surface
            }
        }
    }
    """

    func testTextUSDKeepsPolygonsPlacementUpAxisAndMaterial() throws {
        // Under its own extension and under a wrong one: the content decides.
        for name in ["shape.usda", "shape.3ds", "shape.usd"] {
            let url = folder.appendingPathComponent(name)
            try Data(usda.utf8).write(to: url)
            XCTAssertEqual(FormatDetector.detect(Data(usda.utf8), ext: url.pathExtension), .usd, name)
            let scene = try ImportRouter.load(url, format: .usd)
            XCTAssertEqual(scene.topology.faces, 2, name)
            XCTAssertEqual(scene.topology.quads, 1)
            XCTAssertEqual(scene.topology.triangles, 1)
            XCTAssertEqual(scene.topology.label, "Mixed")
            let part = try XCTUnwrap(scene.meshes.first?.parts.first)
            XCTAssertEqual(part.triangleIndices.count, 9)
            XCTAssertEqual(part.faceSizes, [4, 3])
            XCTAssertEqual(part.uv0.count, part.positions.count)
            // Z up in the file, moved by 10 along x: (x, y, z) lands at (x + 10, z, -y).
            let bounds = try XCTUnwrap(scene.bounds)
            XCTAssertLessThan(simd_distance(bounds.min, SIMD3(10, 0, -2)), 1e-4, "\(bounds)")
            XCTAssertLessThan(simd_distance(bounds.max, SIMD3(12, 3, 0)), 1e-4, "\(bounds)")
            let material = try XCTUnwrap(part.material.map { scene.materials[$0] })
            XCTAssertLessThan(simd_distance(material.baseColor, SIMD4(1, 0, 0, 1)), 1e-3)
            XCTAssertEqual(material.metallic, 0.25, accuracy: 1e-4)
            XCTAssertEqual(material.roughness, 0.75, accuracy: 1e-4)
            XCTAssertTrue(material.authoredPBR)
            XCTAssertTrue(scene.hasTexturedAppearance)
            // And it goes onto the GPU.
            XCTAssertEqual(try MetalRenderer().makeScene(scene).triangleCount, 3)
        }
    }

    func testAFileWithoutGeometryFails() throws {
        let url = folder.appendingPathComponent("empty.usda")
        try Data("#usda 1.0\n\ndef Xform \"root\"\n{\n}\n".utf8).write(to: url)
        XCTAssertThrowsError(try ImportRouter.load(url, format: .usd))
        try Data("not a usd file at all".utf8).write(to: url)
        XCTAssertThrowsError(try ImportRouter.load(url, format: .usd))
    }

    /// One triangle on a two-joint skeleton whose upper joint turns a quarter turn about z in one second.
    private let skinned = """
    #usda 1.0
    (
        upAxis = "Y"
        startTimeCode = 0
        endTimeCode = 24
        timeCodesPerSecond = 24
        defaultPrim = "root"
    )

    def SkelRoot "root"
    {
        def Skeleton "skel" (
            prepend apiSchemas = ["SkelBindingAPI"]
        )
        {
            uniform token[] joints = ["a", "a/b"]
            uniform matrix4d[] bindTransforms = [( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) ), ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 1, 0, 1) )]
            uniform matrix4d[] restTransforms = [( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) ), ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 1, 0, 1) )]
            rel skel:animationSource = </root/skel/anim>

            def SkelAnimation "anim"
            {
                uniform token[] joints = ["a", "a/b"]
                float3[] translations = [(0, 0, 0), (0, 1, 0)]
                quatf[] rotations.timeSamples = {
                    0: [(1, 0, 0, 0), (1, 0, 0, 0)],
                    24: [(1, 0, 0, 0), (0.70710678, 0, 0, 0.70710678)],
                }
                half3[] scales = [(1, 1, 1), (1, 1, 1)]
            }
        }

        def Mesh "mesh" (
            prepend apiSchemas = ["SkelBindingAPI"]
        )
        {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 2, 0)]
            int[] primvars:skel:jointIndices = [0, 0, 1] (
                elementSize = 1
                interpolation = "vertex"
            )
            float[] primvars:skel:jointWeights = [1, 1, 1] (
                elementSize = 1
                interpolation = "vertex"
            )
            rel skel:skeleton = </root/skel>
        }
    }
    """

    func testASkinnedUSDBringsItsSkeletonSkinAndClip() throws {
        let url = folder.appendingPathComponent("skinned.usda")
        try Data(skinned.utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let skeleton = try XCTUnwrap(scene.skeletons.first)
        XCTAssertEqual(skeleton.joints.map(\.name), ["a", "b"])
        XCTAssertEqual(skeleton.joints.map(\.parent), [nil, 0])
        XCTAssertNotNil(skeleton.node)
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        let skin = try XCTUnwrap(part.skin)
        XCTAssertEqual(skin.joints.count, part.positions.count)
        // The corner at (0, 2, 0) follows the upper joint, the other two the lower one.
        for (i, p) in part.positions.enumerated() {
            XCTAssertEqual(skin.joints[i].x, p.y > 1 ? 1 : 0)
            XCTAssertEqual(skin.weights[i], SIMD4(1, 0, 0, 0))
        }
        let clip = try XCTUnwrap(scene.clips.first)
        XCTAssertEqual(clip.name, "anim")
        XCTAssertEqual(clip.duration, 1, accuracy: 1e-3)
        // At the end of the clip the corner has swung from above the joint to its left.
        let end = skeleton.skinMatrices(clip: clip, time: clip.duration)[1] * SIMD4(0, 2, 0, 1)
        XCTAssertLessThan(simd_distance(SIMD3(end.x, end.y, end.z), SIMD3(-1, 1, 0)), 1e-3, "\(end)")
        let start = skeleton.skinMatrices(clip: clip, time: 0)[1] * SIMD4(0, 2, 0, 1)
        XCTAssertLessThan(simd_distance(SIMD3(start.x, start.y, start.z), SIMD3(0, 2, 0)), 1e-3)
        let gpu = try MetalRenderer().makeScene(scene)
        XCTAssertTrue(gpu.isSkinned)
        XCTAssertEqual(gpu.clips.count, 1)
    }
}
