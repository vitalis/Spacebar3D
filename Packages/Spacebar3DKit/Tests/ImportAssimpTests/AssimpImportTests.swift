import Foundation
import ImportAssimp
import ImportRouter
import ModelCore
import RenderMetal
import simd
import XCTest

final class AssimpImportTests: XCTestCase {
    func testLongFBXAnimationSamplingStaysBounded() throws {
        let text = String(decoding: fbx(), as: UTF8.self).replacingOccurrences(of: "46186158000", with: "9000000000000000000")
        let scene = try AssimpImporter.scene(from: Data(text.utf8), format: .fbx)
        let clip = try XCTUnwrap(scene.clips.first)
        XCTAssertGreaterThan(clip.duration, 1000000)
        XCTAssertEqual(clip.translations.times.count, 3600)
        XCTAssertTrue(clip.translations.times.allSatisfy(\.isFinite))
        XCTAssertEqual(clip.translations.times.last, clip.end)
    }

    /// A 3D Studio file holding one box of 1 x 2 x 3.
    private var box3DS: Data {
        func put16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
        func chunk(_ id: Int, _ payload: Data) -> Data {
            var d = Data()
            put16(id, &d)
            let length = payload.count + 6
            put16(length & 0xffff, &d); put16(length >> 16, &d)
            return d + payload
        }
        let corners: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 2, 0), SIMD3(0, 2, 0), SIMD3(0, 0, 3), SIMD3(1, 0, 3), SIMD3(1, 2, 3), SIMD3(0, 2, 3)]
        let faces = [3, 2, 1, 1, 0, 3, 4, 5, 6, 6, 7, 4, 0, 1, 5, 5, 4, 0, 1, 2, 6, 6, 5, 1, 2, 3, 7, 7, 6, 2, 3, 0, 4, 4, 7, 3]
        var points = Data()
        put16(corners.count, &points)
        for corner in corners { for value in [corner.x, corner.y, corner.z] { withUnsafeBytes(of: value.bitPattern.littleEndian) { points.append(contentsOf: $0) } } }
        var triangles = Data()
        put16(faces.count / 3, &triangles)
        for t in 0..<(faces.count / 3) { for k in 0..<3 { put16(faces[t * 3 + k], &triangles) }; put16(0, &triangles) }
        let mesh = chunk(0x4100, chunk(0x4110, points) + chunk(0x4120, triangles))
        let object = chunk(0x4000, Data("box".utf8) + Data([0]) + mesh)
        return chunk(0x4d4d, chunk(0x3d3d, object))
    }

    func testA3DStudioBoxLoadsWithItsTrianglesTurnedYUp() throws {
        let data = box3DS
        XCTAssertEqual(FormatDetector.detect(data, ext: "3ds"), .threeDS)
        let scene = try AssimpImporter.scene(from: data, format: .threeDS)
        XCTAssertEqual(scene.topology.faces, 12)
        XCTAssertEqual(scene.topology.label, "Triangle")
        // Z up in the file; Assimp turns it, so the box's 3 stands upright.
        let bounds = try XCTUnwrap(scene.bounds)
        XCTAssertLessThan(simd_distance(bounds.max - bounds.min, SIMD3(1, 3, 2)), 1e-4, "\(bounds)")
        let gpu = try MetalRenderer().makeScene(scene)
        XCTAssertEqual(gpu.triangleCount, 12)
    }

    func testTheRouterReadsA3DStudioFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-box-\(UUID().uuidString).3ds")
        defer { try? FileManager.default.removeItem(at: url) }
        try box3DS.write(to: url)
        XCTAssertEqual(try ImportRouter.load(url, format: .threeDS).topology.faces, 12)
    }

    func testDamagedFilesFailCleanly() throws {
        XCTAssertThrowsError(try AssimpImporter.scene(from: Data(), format: .threeDS))
        XCTAssertThrowsError(try AssimpImporter.scene(from: Data("not a model at all".utf8), format: .threeDS))
        XCTAssertThrowsError(try AssimpImporter.scene(from: Data([0x4d, 0x4d, 0xff, 0xff, 0xff, 0x7f, 1, 2, 3]), format: .threeDS))
        XCTAssertThrowsError(try AssimpImporter.scene(from: box3DS.prefix(40), format: .threeDS))
        // Formats that are read elsewhere are refused here.
        XCTAssertThrowsError(try AssimpImporter.scene(from: box3DS, format: .obj))
        XCTAssertThrowsError(try AssimpImporter.scene(from: box3DS, format: .threeMF))
    }

    // MARK: FBX

    /// A text FBX: a square of one polygon on a node moved to (1, 2, 3), in a red material,
    /// held by one bone; an animation lifts the bone by two over one second.
    private func fbx(skinned: Bool = true, mesh: Bool = true, shaped: Bool = false, image: String? = nil, second clip: Bool = false,
                     materialProps: String = "", extraObjects: String = "", extraLinks: String = "") -> Data {
        let second = "46186158000"
        let identity = "1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1"
        var objects = ""
        var links = ""
        if mesh {
            objects += """
            	Geometry: 100, "Geometry::square", "Mesh" {
            		Vertices: *12 {
            			a: 0,0,0,1,0,0,1,1,0,0,1,0
            		}
            		PolygonVertexIndex: *4 {
            			a: 0,1,2,-4
            		}
            		GeometryVersion: 124
            		LayerElementNormal: 0 {
            			Version: 101
            			Name: ""
            			MappingInformationType: "ByPolygonVertex"
            			ReferenceInformationType: "Direct"
            			Normals: *12 {
            				a: 0,0,1,0,0,1,0,0,1,0,0,1
            			}
            		}
            		LayerElementUV: 0 {
            			Version: 101
            			Name: "UVMap"
            			MappingInformationType: "ByPolygonVertex"
            			ReferenceInformationType: "Direct"
            			UV: *8 {
            				a: 0,0,1,0,1,1,0,1
            			}
            		}
            		LayerElementMaterial: 0 {
            			Version: 101
            			Name: ""
            			MappingInformationType: "AllSame"
            			ReferenceInformationType: "IndexToDirect"
            			Materials: *1 {
            				a: 0
            			}
            		}
            		Layer: 0 {
            			Version: 100
            			LayerElement:  {
            				Type: "LayerElementNormal"
            				TypedIndex: 0
            			}
            			LayerElement:  {
            				Type: "LayerElementMaterial"
            				TypedIndex: 0
            			}
            			LayerElement:  {
            				Type: "LayerElementUV"
            				TypedIndex: 0
            			}
            		}
            	}
            	Model: 200, "Model::square", "Mesh" {
            		Version: 232
            		Properties70:  {
            			P: "Lcl Translation", "Lcl Translation", "", "A",1,2,3
            		}
            	}
            	Material: 400, "Material::red", "" {
            		Version: 102
            		ShadingModel: "phong"
            		Properties70:  {
            			P: "DiffuseColor", "Color", "", "A",1,0,0
            			\(materialProps)
            		}
            	}

            """
            links += "\tC: \"OO\",200,0\n\tC: \"OO\",100,200\n\tC: \"OO\",400,200\n"
        }
        if mesh && skinned {
            objects += """
            	Deformer: 500, "Deformer::", "Skin" {
            		Version: 101
            		Link_DeformAcuracy: 50
            	}
            	Deformer: 501, "SubDeformer::", "Cluster" {
            		Version: 100
            		UserData: "", ""
            		Indexes: *4 {
            			a: 0,1,2,3
            		}
            		Weights: *4 {
            			a: 1,1,1,1
            		}
            		Transform: *16 {
            			a: 1,0,0,0,0,1,0,0,0,0,1,0,1,2,3,1
            		}
            		TransformLink: *16 {
            			a: \(identity)
            		}
            	}

            """
            links += "\tC: \"OO\",500,100\n\tC: \"OO\",501,500\n\tC: \"OO\",300,501\n"
        }
        if mesh && shaped {
            // Another shape of the square, one further out, shown more and more over the second.
            objects += """
            	Geometry: 110, "Geometry::out", "Shape" {
            		Version: 100
            		Indexes: *4 {
            			a: 0,1,2,3
            		}
            		Vertices: *12 {
            			a: 0,0,1,0,0,1,0,0,1,0,0,1
            		}
            		Normals: *12 {
            			a: 0,0,0,0,0,0,0,0,0,0,0,0
            		}
            	}
            	Deformer: 520, "Deformer::", "BlendShape" {
            		Version: 100
            	}
            	Deformer: 521, "SubDeformer::out", "BlendShapeChannel" {
            		Version: 100
            		DeformPercent: 0
            		FullWeights: *1 {
            			a: 100
            		}
            	}
            	AnimationCurveNode: 612, "AnimCurveNode::DeformPercent", "" {
            		Properties70:  {
            			P: "d|DeformPercent", "Number", "", "A",0
            		}
            	}
            	AnimationCurve: 613, "AnimCurve::", "" {
            		Default: 0
            		KeyVer: 4008
            		KeyTime: *2 {
            			a: 0,\(second)
            		}
            		KeyValueFloat: *2 {
            			a: 0,100
            		}
            		KeyAttrFlags: *1 {
            			a: 24836
            		}
            		KeyAttrDataFloat: *4 {
            			a: 0,0,0,0
            		}
            		KeyAttrRefCount: *1 {
            			a: 2
            		}
            	}

            """
            links += "\tC: \"OO\",520,100\n\tC: \"OO\",521,520\n\tC: \"OO\",110,521\n\tC: \"OO\",612,601\n\tC: \"OP\",612,521, \"DeformPercent\"\n\tC: \"OP\",613,612, \"d|DeformPercent\"\n"
        }
        if mesh, let image {
            // The material's colour image, named the way a Windows tool writes it.
            objects += """
            	Texture: 700, "Texture::colour", "" {
            		Type: "TextureVideoClip"
            		Version: 202
            		TextureName: "Texture::colour"
            		FileName: "C:\\\\work\\\\\(image)"
            		RelativeFilename: "\(image)"
            	}

            """
            links += "\tC: \"OP\",700,400, \"DiffuseColor\"\n"
        }
        if clip {
            // A second animation: the bone goes down by two over two seconds.
            objects += """
            	AnimationStack: 620, "AnimStack::drop", "" {
            		Properties70:  {
            			P: "LocalStop", "KTime", "Time", "",92372316000
            		}
            	}
            	AnimationLayer: 621, "AnimLayer::base2", "" {
            	}
            	AnimationCurveNode: 622, "AnimCurveNode::T", "" {
            		Properties70:  {
            			P: "d|X", "Number", "", "A",0
            			P: "d|Y", "Number", "", "A",0
            			P: "d|Z", "Number", "", "A",0
            		}
            	}
            	AnimationCurve: 623, "AnimCurve::", "" {
            		Default: 0
            		KeyVer: 4008
            		KeyTime: *2 {
            			a: 0,92372316000
            		}
            		KeyValueFloat: *2 {
            			a: 0,-2
            		}
            		KeyAttrFlags: *1 {
            			a: 24836
            		}
            		KeyAttrDataFloat: *4 {
            			a: 0,0,0,0
            		}
            		KeyAttrRefCount: *1 {
            			a: 2
            		}
            	}

            """
            links += "\tC: \"OO\",621,620\n\tC: \"OO\",622,621\n\tC: \"OP\",622,300, \"Lcl Translation\"\n\tC: \"OP\",623,622, \"d|Y\"\n"
        }
        return Data("""
        ; FBX 7.4.0 project file
        FBXHeaderExtension:  {
        	FBXHeaderVersion: 1003
        	FBXVersion: 7400
        }
        GlobalSettings:  {
        	Version: 1000
        	Properties70:  {
        		P: "UpAxis", "int", "Integer", "",1
        		P: "UnitScaleFactor", "double", "Number", "",1
        	}
        }
        Objects:  {
        \(objects)\(extraObjects)	Model: 300, "Model::bone", "LimbNode" {
        		Version: 232
        		Properties70:  {
        		}
        	}
        	Model: 310, "Model::tip", "LimbNode" {
        		Version: 232
        		Properties70:  {
        			P: "Lcl Translation", "Lcl Translation", "", "A",0,1,0
        		}
        	}
        	NodeAttribute: 301, "NodeAttribute::", "LimbNode" {
        		TypeFlags: "Skeleton"
        	}
        	NodeAttribute: 311, "NodeAttribute::", "LimbNode" {
        		TypeFlags: "Skeleton"
        	}
        	AnimationStack: 600, "AnimStack::lift", "" {
        		Properties70:  {
        			P: "LocalStop", "KTime", "Time", "",\(second)
        		}
        	}
        	AnimationLayer: 601, "AnimLayer::base", "" {
        	}
        	AnimationCurveNode: 602, "AnimCurveNode::T", "" {
        		Properties70:  {
        			P: "d|X", "Number", "", "A",0
        			P: "d|Y", "Number", "", "A",0
        			P: "d|Z", "Number", "", "A",0
        		}
        	}
        	AnimationCurve: 603, "AnimCurve::", "" {
        		Default: 0
        		KeyVer: 4008
        		KeyTime: *2 {
        			a: 0,\(second)
        		}
        		KeyValueFloat: *2 {
        			a: 0,2
        		}
        		KeyAttrFlags: *1 {
        			a: 24836
        		}
        		KeyAttrDataFloat: *4 {
        			a: 0,0,0,0
        		}
        		KeyAttrRefCount: *1 {
        			a: 2
        		}
        	}
        }
        Connections:  {
        \(links)\(extraLinks)	C: "OO",300,0
        	C: "OO",310,300
        	C: "OO",301,300
        	C: "OO",311,310
        	C: "OO",601,600
        	C: "OO",602,601
        	C: "OP",602,300, "Lcl Translation"
        	C: "OP",603,602, "d|Y"
        }

        """.utf8)
    }

    /// Where the first vertex of the first skinned part is at a moment of the first clip.
    private func corner(_ scene: ModelScene, at time: Float) throws -> SIMD3<Float> {
        let part = try XCTUnwrap(scene.meshes.flatMap(\.parts).first { $0.skin != nil })
        let skin = try XCTUnwrap(part.skin)
        let matrices = scene.skeletons[skin.skeleton].skinMatrices(clip: scene.clips.first, time: time)
        let p = matrices[Int(skin.joints[0].x)] * SIMD4(part.positions[0], 1)
        return SIMD3(p.x, p.y, p.z)
    }

    func testAnFBXMeshWithItsMaterialBoneAndAnimation() throws {
        let scene = try AssimpImporter.scene(from: fbx(), format: .fbx)
        XCTAssertEqual(scene.topology.faces, 1)
        XCTAssertEqual(scene.topology.quads, 1, "the polygon is kept")
        XCTAssertEqual(scene.topology.vertices, 4)
        let material = try XCTUnwrap(scene.meshes.flatMap(\.parts).first?.material.map { scene.materials[$0] })
        XCTAssertEqual(material.name, "red")
        XCTAssertEqual(material.baseColor, SIMD4(1, 0, 0, 1))
        XCTAssertEqual(scene.clips.count, 1)
        XCTAssertEqual(scene.clips[0].duration, 1, accuracy: 1e-3)
        // The bone holds the square where its node had it, then lifts it by two.
        var at = try corner(scene, at: 0)
        XCTAssertEqual(simd_length(at - SIMD3(1, 2, 3)), 0, accuracy: 1e-4)
        at = try corner(scene, at: 0.5)
        XCTAssertEqual(simd_length(at - SIMD3(1, 3, 3)), 0, accuracy: 1e-2)
        at = try corner(scene, at: 1)
        XCTAssertEqual(simd_length(at - SIMD3(1, 4, 3)), 0, accuracy: 1e-4)
    }

    func testAnFBXMeshWithNoBonesStaysAndMotionWithNoMeshIsShownOnItsSkeleton() throws {
        // The animation moves a bone the square is not bound to: the square is still.
        let loose = try AssimpImporter.scene(from: fbx(skinned: false), format: .fbx)
        XCTAssertTrue(loose.meshes.flatMap(\.parts).allSatisfy { $0.skin == nil })
        XCTAssertEqual(try XCTUnwrap(loose.bounds).min, SIMD3(1, 2, 3))

        let bare = try AssimpImporter.scene(from: fbx(mesh: false), format: .fbx)
        XCTAssertEqual(bare.topology.faces, 0)
        XCTAssertEqual(bare.clips.count, 1)
        // One bone, from the bone's node to its tip one above, lifted with it.
        XCTAssertEqual(bare.meshes.flatMap(\.parts).filter { $0.skin != nil }.count, 1)
        XCTAssertEqual(try corner(bare, at: 1).y, 2, accuracy: 1e-3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-square-\(UUID().uuidString).fbx")
        defer { try? FileManager.default.removeItem(at: url) }
        try fbx().write(to: url)
        XCTAssertEqual(try ImportRouter.load(url, format: .fbx).topology.faces, 1)
    }

    func testAnFBXBlendShapeAndItsAnimation() throws {
        let scene = try AssimpImporter.scene(from: fbx(skinned: false, shaped: true), format: .fbx)
        let index = try XCTUnwrap(scene.meshes.firstIndex { !$0.morphWeights.isEmpty })
        let mesh = scene.meshes[index]
        XCTAssertEqual(mesh.morphWeights, [0], "at rest the other shape does not show")
        let part = mesh.parts[0]
        XCTAssertEqual(part.morphTargets.count, 1)
        XCTAssertEqual(part.morphTargets[0].positions, [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4), "what the shape adds")
        XCTAssertNotNil(part.skin, "shown through a skin, bound whole to its node")
        XCTAssertFalse(scene.diagnostics.skippedFeatures.contains("blend shapes"))
        // The clip brings the shape in over its second, and still lifts the bone.
        let clip = try XCTUnwrap(scene.clips.first)
        let channel = try XCTUnwrap(clip.morphs.first)
        XCTAssertEqual(channel.mesh, index)
        XCTAssertEqual(try XCTUnwrap(channel.weights(at: 0))[0], 0, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(channel.weights(at: 0.5))[0], 0.5, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(channel.weights(at: 1))[0], 1, accuracy: 1e-4)
        // Without the shape the same file has no such thing.
        XCTAssertTrue(try AssimpImporter.scene(from: fbx(), format: .fbx).meshes.allSatisfy { $0.morphWeights.isEmpty })
    }

    /// A picture of one red pixel.
    private var png: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")! }

    func testAnFBXImageIsFoundBesideTheFileInATextureFolderAndInItsMediaFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-fbx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        /// The square's material after the file is read from a folder holding the image at `place`.
        func load(image: String, at place: String?) throws -> (texture: ModelScene.TextureRef?, missing: [String]) {
            let inside = folder.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            if let place {
                let file = inside.appendingPathComponent(place)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: file)
            }
            let url = inside.appendingPathComponent("square.fbx")
            try fbx(image: image).write(to: url)
            let scene = try ImportRouter.load(url, format: .fbx)
            let material = try XCTUnwrap(scene.meshes.flatMap(\.parts).first?.material.map { scene.materials[$0] })
            XCTAssertEqual(scene.meshes.flatMap(\.parts).first?.uv0.count, 4)
            return (material.baseColorTexture.map { scene.textures[$0] }, scene.diagnostics.missingResources)
        }
        // Beside the model; where the file says, in a folder of its own; in a usual
        // texture folder though the file names another; and in the folder FBX tools unpack to.
        for (image, place) in [("dot.png", "dot.png"), ("maps\\\\dot.png", "maps/dot.png"), ("C:\\\\gone\\\\dot.png", "textures/dot.png"), ("dot.png", "square.fbm/dot.png")] {
            let found = try load(image: image, at: place)
            XCTAssertNotNil(found.texture, "\(image) at \(place)")
            XCTAssertEqual(found.missing, [], "\(image) at \(place)")
        }
        // Not there: the model still loads, and says which image it lacks.
        let lacking = try load(image: "C:\\\\gone\\\\dot.png", at: nil)
        XCTAssertNil(lacking.texture)
        XCTAssertEqual(lacking.missing, ["dot.png"])
        // Another model's media folder is not this one's.
        XCTAssertNil(try load(image: "dot.png", at: "other.fbm/dot.png").texture)
    }

    func testEveryAnimationOfAnFBXIsAClip() throws {
        let scene = try AssimpImporter.scene(from: fbx(second: true), format: .fbx)
        XCTAssertEqual(scene.clips.count, 2)
        XCTAssertEqual(Set(scene.clips.map(\.name)), ["lift", "drop"])
        let lift = try XCTUnwrap(scene.clips.first { $0.name == "lift" }), drop = try XCTUnwrap(scene.clips.first { $0.name == "drop" })
        XCTAssertEqual(lift.duration, 1, accuracy: 1e-3)
        XCTAssertEqual(drop.duration, 2, accuracy: 1e-3)
        let part = try XCTUnwrap(scene.meshes.flatMap(\.parts).first { $0.skin != nil }), skin = try XCTUnwrap(part.skin)
        func height(_ clip: ModelScene.AnimationClip, _ time: Float) -> Float {
            (scene.skeletons[skin.skeleton].skinMatrices(clip: clip, time: time)[Int(skin.joints[0].x)] * SIMD4(part.positions[0], 1)).y
        }
        XCTAssertEqual(height(lift, 1), 4, accuracy: 1e-3)
        XCTAssertEqual(height(drop, 2), 0, accuracy: 1e-3)
        XCTAssertEqual(height(drop, 1), 1, accuracy: 0.05)
    }
}

extension AssimpImportTests {
    /// A texture object and, optionally, a picture held inside the file for it.
    private func textureObject(_ id: Int, name: String, video: Bool) -> String {
        var text = """
        \tTexture: \(id), "Texture::\(name)", "" {
        \t\tType: "TextureVideoClip"
        \t\tVersion: 202
        \t\tTextureName: "Texture::\(name)"
        \t\tFileName: "\(name).png"
        \t\tRelativeFilename: "\(name).png"
        \t}

        """
        if video {
            text += """
            \tVideo: \(id + 10), "Video::\(name)", "Clip" {
            \t\tType: "Clip"
            \t\tFileName: "\(name).png"
            \t\tRelativeFilename: "\(name).png"
            \t\tContent: "\(png.base64EncodedString())"
            \t}

            """
        }
        return text
    }

    func testAnFBXMaterialsNumbersAndImagesHeldInsideTheFile() throws {
        let data = fbx(materialProps: "P: \"Maya|metallic\", \"Number\", \"\", \"A\",0.5\n\t\t\tP: \"Maya|roughness\", \"Number\", \"\", \"A\",0.25",
                       extraObjects: textureObject(710, name: "nrm", video: true) + textureObject(711, name: "glow", video: true),
                       extraLinks: "\tC: \"OP\",710,400, \"NormalMap\"\n\tC: \"OP\",711,400, \"EmissiveColor\"\n\tC: \"OO\",720,710\n\tC: \"OO\",721,711\n")
        let scene = try AssimpImporter.scene(from: data, format: .fbx)
        let material = try XCTUnwrap(scene.meshes.flatMap(\.parts).first?.material.map { scene.materials[$0] })
        XCTAssertEqual(material.metallic, 0.5, accuracy: 1e-4)
        XCTAssertEqual(material.roughness, 0.25, accuracy: 1e-4)
        XCTAssertTrue(material.authoredPBR)
        XCTAssertNotNil(material.normalTexture)
        XCTAssertNotNil(material.emissiveTexture)
        XCTAssertEqual(material.emissive, SIMD3(1, 1, 1), "an image that glows lights the surface")
        if let index = material.normalTexture, case .embedded(let bytes, _) = scene.textures[index] { XCTAssertEqual(Data(bytes), png) }
    }

    func testEveryFailureHasAMessage() {
        XCTAssertEqual(AssimpImporter.Failure.tooLarge.errorDescription, "The file is too large to show.")
        XCTAssertEqual(AssimpImporter.Failure.unreadable("").errorDescription, "The file could not be read.")
        XCTAssertEqual(AssimpImporter.Failure.unreadable("bad").errorDescription, "The file could not be read: bad")
        XCTAssertEqual(AssimpImporter.Failure.empty.errorDescription, "The file contains no geometry.")
    }
}

