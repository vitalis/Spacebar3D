import CoreGraphics
import Foundation
import ImageIO
import ImportRouter
import ModelCore
import simd
import XCTest
import zlib

/// USD materials with images, several materials on one mesh, and the zip package reader.
final class USDMaterialTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-usdm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A 2 x 2 PNG, red on top and blue below.
    private func png() throws -> Data {
        var pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A zip of stored entries, each starting on a 64-byte boundary as a `.usdz` wants.
    private func usdz(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(), directory = Data()
        func put16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
        func put32(_ v: Int, _ d: inout Data) { put16(v & 0xffff, &d); put16((v >> 16) & 0xffff, &d) }
        for file in files {
            let name = Array(file.name.utf8), body = [UInt8](file.data)
            let crc = Int(body.withUnsafeBufferPointer { crc32(0, $0.baseAddress, UInt32($0.count)) })
            let offset = out.count
            let pad = (64 - (offset + 30 + name.count + 4) % 64) % 64
            put32(0x0403_4b50, &out); put16(20, &out); put16(0, &out); put16(0, &out); put16(0, &out); put16(0, &out)
            put32(crc, &out); put32(body.count, &out); put32(body.count, &out); put16(name.count, &out); put16(pad + 4, &out)
            out.append(contentsOf: name)
            put16(0x1986, &out); put16(pad, &out); out.append(Data(count: pad))
            out.append(contentsOf: body)
            put32(0x0201_4b50, &directory); put16(20, &directory); put16(20, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory)
            put32(crc, &directory); put32(body.count, &directory); put32(body.count, &directory); put16(name.count, &directory)
            put16(0, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory); put32(0, &directory); put32(offset, &directory)
            directory.append(contentsOf: name)
        }
        let start = out.count
        out.append(directory)
        put32(0x0605_4b50, &out); put16(0, &out); put16(0, &out); put16(files.count, &out); put16(files.count, &out)
        put32(directory.count, &out); put32(start, &out); put16(0, &out)
        return out
    }

    /// A quad with texture coordinates, its material's colour taken from the image at `path`.
    private func textured(_ path: String, extra: String = "", shaders: String = "") -> String {
        """
        #usda 1.0
        (
            upAxis = "Y"
            defaultPrim = "root"
        )

        def Xform "root"
        {
            def Mesh "quad" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                int[] faceVertexCounts = [4]
                int[] faceVertexIndices = [0, 1, 2, 3]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)]
                texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
                    interpolation = "vertex"
                )
                rel material:binding = </root/mat>
            }

            def Material "mat"
            {
                token outputs:surface.connect = </root/mat/surface.outputs:surface>

                def Shader "surface"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor.connect = </root/mat/tex.outputs:rgb>
                    \(extra)
                    token outputs:surface
                }

                def Shader "tex"
                {
                    uniform token info:id = "UsdUVTexture"
                    asset inputs:file = @\(path)@
                    float2 inputs:st.connect = </root/mat/st.outputs:result>
                    float3 outputs:rgb
                }

                \(shaders)

                def Shader "st"
                {
                    uniform token info:id = "UsdPrimvarReader_float2"
                    token inputs:varname = "st"
                    float2 outputs:result
                }
            }
        }
        """
    }

    func testAnImageBesideTheFileComesInAsItsBytes() throws {
        try png().write(to: folder.appendingPathComponent("red.png"))
        let url = folder.appendingPathComponent("tex.usda")
        try Data(textured("./red.png").utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        let material = try XCTUnwrap(part.material.map { scene.materials[$0] })
        // The image supplies the colour; the material's own is white.
        XCTAssertEqual(material.baseColor, SIMD4(1, 1, 1, 1))
        let index = try XCTUnwrap(material.baseColorTexture, "\(scene.materials) \(scene.diagnostics)")
        switch scene.textures[index] {
        case .embedded(let bytes, _): XCTAssertEqual(Data(bytes), try png())
        case .pixels(let width, let height, let rgba): XCTAssertEqual(rgba.count, width * height * 4)
        default: XCTFail("unexpected texture kind")
        }
        XCTAssertTrue(scene.diagnostics.missingResources.isEmpty)
    }

    func testAnImageThatIsNotThereIsReportedAndTheSurfaceStaysPlain() throws {
        let url = folder.appendingPathComponent("lost.usda")
        try Data(textured("./nowhere.png").utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        let material = try XCTUnwrap(part.material.map { scene.materials[$0] })
        XCTAssertNil(material.baseColorTexture)
        XCTAssertEqual(material.baseColor, SIMD4(0.8, 0.8, 0.8, 1))
    }

    func testAPackageGivesItsImageWithoutDecodingIt() throws {
        let image = try png()
        let package = usdz([("model.usda", Data(textured("textures/red.png").utf8)), ("textures/red.png", image)])
        let url = folder.appendingPathComponent("pack.usdz")
        try package.write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        let material = try XCTUnwrap(part.material.map { scene.materials[$0] })
        let index = try XCTUnwrap(material.baseColorTexture, "\(scene.diagnostics)")
        switch scene.textures[index] {
        case .embedded(let bytes, _): XCTAssertEqual(Data(bytes), image)
        case .pixels(let width, _, _): XCTAssertEqual(width, 2)
        default: XCTFail("unexpected texture kind")
        }
    }

    func testMetallicRoughnessAndNormalImagesAndAnOpacity() throws {
        try png().write(to: folder.appendingPathComponent("red.png"))
        let extra = """
        float inputs:opacity = 0.5
        float inputs:metallic.connect = </root/mat/m.outputs:r>
        float inputs:roughness.connect = </root/mat/r.outputs:g>
        normal3f inputs:normal.connect = </root/mat/n.outputs:rgb>
        """
        func shader(_ name: String, _ type: String, _ output: String) -> String {
            "def Shader \"\(name)\"\n{\nuniform token info:id = \"UsdUVTexture\"\nasset inputs:file = @./red.png@\n\(type) outputs:\(output)\n}\n"
        }
        let url = folder.appendingPathComponent("maps.usda")
        try Data(textured("./red.png", extra: extra, shaders: shader("m", "float", "r") + shader("r", "float", "g") + shader("n", "float3", "rgb")).utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        let material = try XCTUnwrap(part.material.map { scene.materials[$0] })
        XCTAssertEqual(material.opacity, 0.5, accuracy: 1e-4)
        // An image each: the number stays at 1 so the image decides.
        XCTAssertNotNil(material.metallicTexture)
        XCTAssertNotNil(material.roughnessTexture)
        XCTAssertEqual(material.metallic, 1)
        XCTAssertEqual(material.roughness, 1)
        XCTAssertTrue(material.authoredPBR)
        XCTAssertNotNil(material.normalTexture)
    }

    /// A model with a baked ambient-occlusion image in UsdPreviewSurface's `occlusion`
    /// input lost it on opening: the crevices (under a collar, between folds) came out as
    /// bright as open surfaces, because the importer read colour, metallic, roughness and
    /// normal images but never the occlusion one. Its strength is 1: USD has no strength.
    func testAUSDOcclusionImageIsKeptWithFullStrength() throws {
        try png().write(to: folder.appendingPathComponent("red.png"))
        let extra = "float inputs:occlusion.connect = </root/mat/o.outputs:r>"
        let occlusion = "def Shader \"o\"\n{\nuniform token info:id = \"UsdUVTexture\"\nasset inputs:file = @./red.png@\nfloat outputs:r\n}\n"
        let url = folder.appendingPathComponent("occlusion.usda")
        try Data(textured("./red.png", extra: extra, shaders: occlusion).utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        let material = try XCTUnwrap(part.material.map { scene.materials[$0] })
        let index = try XCTUnwrap(material.occlusionTexture, "no occlusion image in \(material)")
        XCTAssertLessThan(index, scene.textures.count)
        XCTAssertEqual(material.occlusionStrength, 1)
        // Without the input there is none.
        let plain = folder.appendingPathComponent("plain.usda")
        try Data(textured("./red.png").utf8).write(to: plain)
        let without = try ImportRouter.load(plain, format: .usd)
        XCTAssertNil(without.materials.first?.occlusionTexture)
    }

    /// USD keeps a colour as an amount of light; the scene keeps what is seen on screen,
    /// which for half the light is nearly three quarters of the way to white. A colour
    /// at a vertex is brought over as a material's colour is.
    func testAColourAtAVertexIsBroughtFromLightToWhatIsSeen() throws {
        let usda = """
        #usda 1.0
        (
            upAxis = "Y"
            defaultPrim = "tri"
        )

        def Mesh "tri"
        {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            color3f[] primvars:displayColor = [(0.5, 0.5, 0.5), (0.2140411, 0.0, 1.0), (0.0513, 0.5, 0.0)] (
                interpolation = "vertex"
            )
        }
        """
        let url = folder.appendingPathComponent("coloured.usda")
        try Data(usda.utf8).write(to: url)
        let part = try XCTUnwrap(try ImportRouter.load(url, format: .usd).meshes.first?.parts.first)
        XCTAssertEqual(part.colors.count, 3)
        for (colour, expected) in zip(part.colors, [SIMD3<Float>(0.7354, 0.7354, 0.7354), SIMD3(0.5, 0, 1), SIMD3(0.25, 0.7354, 0)]) {
            XCTAssertEqual(simd_distance(SIMD3(colour.x, colour.y, colour.z), expected), 0, accuracy: 2e-3)
            XCTAssertEqual(colour.w, 1)
        }
    }

    func testSeveralMaterialsOnOneMeshBecomeSeveralParts() throws {
        // Two triangles, each in its own subset with its own colour.
        let usda = """
        #usda 1.0
        (
            upAxis = "Y"
            defaultPrim = "root"
        )

        def Xform "root"
        {
            def Mesh "two" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                int[] faceVertexCounts = [3, 3]
                int[] faceVertexIndices = [0, 1, 2, 1, 3, 2]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0)]
                normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                    interpolation = "vertex"
                )
                texCoord2f[] primvars:st = [(0, 0), (1, 0), (0, 1), (1, 1)] (
                    interpolation = "vertex"
                )
                color3f[] primvars:displayColor = [(1, 0, 0), (1, 0, 0), (0, 1, 0), (0, 1, 0)] (
                    interpolation = "vertex"
                )
                uniform token subsetFamily:materialBind:familyType = "partition"

                def GeomSubset "first" (
                    prepend apiSchemas = ["MaterialBindingAPI"]
                )
                {
                    uniform token elementType = "face"
                    uniform token familyName = "materialBind"
                    int[] indices = [0]
                    rel material:binding = </root/red>
                }

                def GeomSubset "second" (
                    prepend apiSchemas = ["MaterialBindingAPI"]
                )
                {
                    uniform token elementType = "face"
                    uniform token familyName = "materialBind"
                    int[] indices = [1]
                    rel material:binding = </root/blue>
                }
            }

            def Material "red"
            {
                token outputs:surface.connect = </root/red/s.outputs:surface>
                def Shader "s"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (1, 0, 0)
                    token outputs:surface
                }
            }

            def Material "blue"
            {
                token outputs:surface.connect = </root/blue/s.outputs:surface>
                def Shader "s"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0, 0, 1)
                    token outputs:surface
                }
            }
        }
        """
        let url = folder.appendingPathComponent("subsets.usda")
        try Data(usda.utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(scene.topology.faces, 2)
        // Each part keeps only the corners it uses, with their attributes alongside.
        for part in parts {
            XCTAssertEqual(part.positions.count, 3)
            XCTAssertEqual(part.triangleIndices.count, 3)
            XCTAssertEqual(part.normals.count, 3)
            XCTAssertEqual(part.uv0.count, 3)
        }
        XCTAssertEqual(Set(parts.compactMap(\.material)).count, 2)
    }

    /// Two triangles on a two-joint skeleton, each in its own subset; `influences` joints per corner.
    private func skinnedSubsets(influences: Int) -> String {
        let indices = (0..<4).flatMap { corner in (0..<influences).map { $0 == 0 ? corner % 2 : 0 } }
        let weights = (0..<4).flatMap { _ in (0..<influences).map { $0 == 0 ? "1" : "0" } }
        return """
        #usda 1.0
        (
            upAxis = "Y"
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
            }

            def Mesh "mesh" (
                prepend apiSchemas = ["SkelBindingAPI", "MaterialBindingAPI"]
            )
            {
                int[] faceVertexCounts = [3, 3]
                int[] faceVertexIndices = [0, 1, 2, 1, 3, 2]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 2, 0), (1, 2, 0)]
                int[] primvars:skel:jointIndices = [\(indices.map(String.init).joined(separator: ", "))] (
                    elementSize = \(influences)
                    interpolation = "vertex"
                )
                float[] primvars:skel:jointWeights = [\(weights.joined(separator: ", "))] (
                    elementSize = \(influences)
                    interpolation = "vertex"
                )
                rel skel:skeleton = </root/skel>
                uniform token subsetFamily:materialBind:familyType = "partition"

                def GeomSubset "first" (
                    prepend apiSchemas = ["MaterialBindingAPI"]
                )
                {
                    uniform token elementType = "face"
                    uniform token familyName = "materialBind"
                    int[] indices = [0]
                    rel material:binding = </root/red>
                }

                def GeomSubset "second" (
                    prepend apiSchemas = ["MaterialBindingAPI"]
                )
                {
                    uniform token elementType = "face"
                    uniform token familyName = "materialBind"
                    int[] indices = [1]
                    rel material:binding = </root/blue>
                }
            }

            def Material "red"
            {
                token outputs:surface.connect = </root/red/s.outputs:surface>
                def Shader "s"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (1, 0, 0)
                    token outputs:surface
                }
            }

            def Material "blue"
            {
                token outputs:surface.connect = </root/blue/s.outputs:surface>
                def Shader "s"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (0, 0, 1)
                    token outputs:surface
                }
            }
        }
        """
    }

    func testASkinnedMeshInSeveralPartsGivesEachPartItsOwnCorners() throws {
        let url = folder.appendingPathComponent("skinparts.usda")
        try Data(skinnedSubsets(influences: 1).utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .usd)
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            let skin = try XCTUnwrap(part.skin)
            XCTAssertEqual(skin.joints.count, part.positions.count)
            XCTAssertEqual(skin.weights.count, part.positions.count)
        }
    }

    func testMoreInfluencesThanFourPerCornerAreLeftUnskinned() throws {
        let url = folder.appendingPathComponent("skinmany.usda")
        try Data(skinnedSubsets(influences: 6).utf8).write(to: url)
        // The skin is dropped with a note; the mesh still shows.
        let scene = try ImportRouter.load(url, format: .usd)
        XCTAssertEqual(scene.topology.faces, 2)
        let skinned = scene.meshes.flatMap(\.parts).contains { $0.skin != nil }
        let noted = scene.diagnostics.skippedFeatures.contains { $0.hasPrefix("skinning of") }
        XCTAssertFalse(skinned)
        XCTAssertTrue(noted)
    }

    // MARK: The zip reader on its own

    func testAZipStoreWithoutAnEndRecordGivesNothing() throws {
        // Not a package: the file is plain text. The scene still reads, and no image is found.
        try png().write(to: folder.appendingPathComponent("red.png"))
        let url = folder.appendingPathComponent("plain.usda")
        try Data(textured("./red.png").utf8).write(to: url)
        XCTAssertNoThrow(try ImportRouter.load(url, format: .usd))
    }

    func testDamagedPackagesFailCleanly() throws {
        let good = usdz([("model.usda", Data(textured("a.png").utf8)), ("a.png", try png())])
        // Cut anywhere, a package either reads or throws: it never crashes.
        for cut in stride(from: 0, to: good.count, by: max(1, good.count / 25)) {
            let url = folder.appendingPathComponent("cut\(cut).usdz")
            try good.prefix(cut).write(to: url)
            _ = try? ImportRouter.load(url, format: .usd)
        }
    }
}
