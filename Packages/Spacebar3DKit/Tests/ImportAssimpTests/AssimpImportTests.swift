import Foundation
@testable import ImportAssimp
import ImportRouter
import ModelCore
import RenderMetal
import simd
import XCTest

final class AssimpImportTests: XCTestCase {
    /// A clip of two keys half a year apart is those two keys, not samples of the time between.
    func testAVeryLongFBXClipIsItsTwoKeys() throws {
        let text = String(decoding: fbx(), as: UTF8.self).replacingOccurrences(of: "46186158000", with: "9000000000000000000")
        let scene = try AssimpImporter.scene(from: Data(text.utf8), format: .fbx)
        let clip = try XCTUnwrap(scene.clips.first)
        XCTAssertGreaterThan(clip.duration, 1000000)
        XCTAssertEqual(clip.linearTranslations.count, 1)
        let track = try XCTUnwrap(clip.linearTranslations.values.first)
        XCTAssertEqual(track.times.count, 2)
        XCTAssertTrue(track.times.allSatisfy(\.isFinite))
        XCTAssertEqual(track.times.last, clip.end)
        XCTAssertTrue(clip.translations.times.isEmpty, "nothing is sampled")
    }

    /// The fixture with other keys for the lift of its bone: `times` in FBX time (46,186,158,000 to the second).
    private func fbx(liftKeys times: [Int], values: [Int]) throws -> Data {
        var text = String(decoding: fbx(), as: UTF8.self)
        func swap(_ old: String, _ new: String, after marker: String) throws {
            let from = try XCTUnwrap(text.range(of: marker)).upperBound
            let found = try XCTUnwrap(text.range(of: old, range: from..<text.endIndex))
            text.replaceSubrange(found, with: new)
        }
        // The clip stops at its last key.
        try swap("46186158000", String(times[times.count - 1]), after: "LocalStop")
        try swap("KeyTime: *2", "KeyTime: *\(times.count)", after: "AnimationCurve: 603")
        try swap("a: 0,46186158000", "a: " + times.map(String.init).joined(separator: ","), after: "AnimationCurve: 603")
        try swap("KeyValueFloat: *2", "KeyValueFloat: *\(times.count)", after: "AnimationCurve: 603")
        try swap("a: 0,2", "a: " + values.map(String.init).joined(separator: ","), after: "KeyValueFloat: *")
        try swap("a: 2", "a: \(times.count)", after: "KeyAttrRefCount")
        return Data(text.utf8)
    }

    /// A key that falls between two thirtieths of a second is kept: the clip holds the
    /// file's own keys, not samples of them at a rate of its own.
    func testAnFBXKeyBetweenFramesIsKept() throws {
        // The lift is 6 a sixtieth of a second in, and 0 again by a thirtieth.
        let scene = try AssimpImporter.scene(from: try fbx(liftKeys: [0, 769769300, 1539538600, 46186158000], values: [0, 6, 0, 2]), format: .fbx)
        XCTAssertEqual(scene.clips.first?.duration ?? 0, 1, accuracy: 1e-3)
        XCTAssertEqual(try corner(scene, at: 1.0 / 60).y, 8, accuracy: 1e-3)
        XCTAssertEqual(try corner(scene, at: 1.0 / 30).y, 2, accuracy: 1e-3)
        XCTAssertEqual(try corner(scene, at: 1).y, 4, accuracy: 1e-3)
    }

    /// 5,000 keys a thirtieth of a second apart, up and down by turns: a clip of nearly
    /// three minutes moves at the rate it was made at.
    func testALongFBXClipKeepsEveryKey() throws {
        let frame = 1539538600
        let scene = try AssimpImporter.scene(from: try fbx(liftKeys: (0..<5000).map { $0 * frame }, values: (0..<5000).map { $0 % 2 }), format: .fbx)
        XCTAssertEqual(scene.clips.first?.duration ?? 0, 4999.0 / 30, accuracy: 1e-2)
        XCTAssertEqual(try corner(scene, at: 3000.0 / 30).y, 2, accuracy: 1e-2)
        XCTAssertEqual(try corner(scene, at: 3001.0 / 30).y, 3, accuracy: 1e-2)
        XCTAssertEqual(try corner(scene, at: 3000.5 / 30).y, 2.5, accuracy: 1e-2)
    }

    /// A clip of more keys than may be held keeps the first of each track, every nth after
    /// it, and the last, so it still ends where the file ends it.
    func testAClipTooLargeToHoldKeepsEveryNthKeyAndTheLast() {
        XCTAssertEqual(AssimpImporter.kept(3, every: 1), [0, 1, 2])
        XCTAssertEqual(AssimpImporter.kept(10, every: 4), [0, 4, 8, 9])
        XCTAssertEqual(AssimpImporter.kept(9, every: 4), [0, 4, 8])
        XCTAssertEqual(AssimpImporter.kept(1, every: 5), [0])
        XCTAssertEqual(AssimpImporter.kept(0, every: 3), [])
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
                     materialProps: String = "", extraObjects: String = "", extraLinks: String = "", imageProps: String = "", creator: String? = nil) -> Data {
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
            		Properties70:  {
            \(imageProps)
            		}
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
        \(creator.map { "\tCreator: \"\($0)\"" } ?? "")
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

    /// A polygon with a corner pushed in is split along a diagonal that stays inside it,
    /// whichever corner the file starts it at: its triangles cover it once, all one way round.
    func testAConcaveFBXPolygonIsSplitInsideItself() throws {
        // A dart of area 1 that starts at the corner before the one pushed in: a fan from
        // there would lay a triangle of area 2 over the notch.
        let square = "a: 0,0,0,1,0,0,1,1,0,0,1,0", dart = "a: 2,0,0,0.5,0.5,0,0,2,0,0,0,0"
        let text = String(decoding: fbx(skinned: false), as: UTF8.self)
        XCTAssertTrue(text.contains(square))
        let scene = try AssimpImporter.scene(from: Data(text.replacingOccurrences(of: square, with: dart).utf8), format: .fbx)
        let part = try XCTUnwrap(scene.meshes.flatMap(\.parts).first)
        XCTAssertEqual(part.faceSizes, [4])
        XCTAssertEqual(part.triangleIndices.count, 6)
        var covered: Float = 0, signed = SIMD3<Float>.zero
        for i in stride(from: 0, to: part.triangleIndices.count, by: 3) {
            let a = part.positions[Int(part.triangleIndices[i])], b = part.positions[Int(part.triangleIndices[i + 1])], c = part.positions[Int(part.triangleIndices[i + 2])]
            let area = simd_cross(b - a, c - a) / 2
            covered += simd_length(area); signed += area
        }
        XCTAssertEqual(covered, 1, accuracy: 1e-4, "no triangle reaches outside the polygon")
        XCTAssertEqual(simd_length(signed), 1, accuracy: 1e-4, "and none is turned over")
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

    /// An FBX image says how many times it is repeated across the surface and how far it is
    /// moved along it. The square's corners are at 0 and 1 of the image each way, counted
    /// from its bottom left in the file and from its top left here.
    func testAnFBXImagesTilingIsApplied() throws {
        let tiling = "\t\t\tP: \"Scaling\", \"Vector\", \"\", \"A\",2,4,1\n\t\t\tP: \"Translation\", \"Vector\", \"\", \"A\",0.25,0.5,0"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-fbx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        /// The square's corners in its image, read from a folder that holds the image.
        func corners(_ data: Data) throws -> [SIMD2<Float>] {
            let inside = folder.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            try png.write(to: inside.appendingPathComponent("a.png"))
            let url = inside.appendingPathComponent("square.fbx")
            try data.write(to: url)
            let scene = try ImportRouter.load(url, format: .fbx)
            let part = try XCTUnwrap(scene.meshes.flatMap(\.parts).first)
            XCTAssertNotNil(part.material.flatMap { scene.materials[$0].baseColorTexture })
            return part.uv0
        }
        func assertEqual(_ uvs: [SIMD2<Float>], _ expected: [SIMD2<Float>], line: UInt = #line) {
            XCTAssertEqual(uvs.count, expected.count, line: line)
            for (uv, e) in zip(uvs, expected) { XCTAssertEqual(simd_distance(uv, e), 0, accuracy: 1e-5, "\(uvs)", line: line) }
        }
        assertEqual(try corners(fbx(image: "a.png")), [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)])
        // Twice across and four times up, a quarter along and a half up.
        assertEqual(try corners(fbx(image: "a.png", imageProps: tiling)), [SIMD2(0.25, 0.5), SIMD2(2.25, 0.5), SIMD2(2.25, -3.5), SIMD2(0.25, -3.5)])
        // Blender writes how large the image is, not how many times it is repeated: one over
        // the number it shows, which its own reader turns back. A file it wrote is read so too.
        assertEqual(try corners(fbx(image: "a.png", imageProps: tiling, creator: "Blender (stable FBX IO) - 5.2.2 LTS - 5.15.0")),
                    [SIMD2(0.25, 0.5), SIMD2(0.75, 0.5), SIMD2(0.75, 0.25), SIMD2(0.25, 0.25)])
    }

    /// Where a mapping that turns the image has the square's corners lie in it. When a
    /// texture is turned in Blender (a Mapping node's Rotation) the picture on the model
    /// turned too; the importer read only the repeat and the move, so the picture stayed
    /// square to the model. Source: Blender 5.2.2's own FBX exporter (io_scene_fbx
    /// export_fbx_bin.py, fbx_data_texture_file_elements) writes the Texture's
    /// `Translation` = the node's Location, `Scaling` = 1 / the node's Scale and
    /// `Rotation` = minus the node's Rotation (radians, as the node holds it, not degrees);
    /// its importer undoes each of them. The Mapping node (Blender manual, Point type)
    /// is "Scale, then Rotate (about the origin of the space), then Translate". The numbers
    /// below are what that exporter wrote for scale (0.6, 0.3), location (0.2, 0.3) and a
    /// turn of 30 degrees about Z, a plane with corners (0,0) (1,0) (1,1) (0,1).
    func testAnFBXImagesRotationIsAppliedLikeBlenderDoes() throws {
        let theta: Float = 30 * .pi / 180
        let props = "\t\t\tP: \"Scaling\", \"Vector\", \"\", \"A\",1.6666666666666667,3.3333333333333335,1\n"
            + "\t\t\tP: \"Rotation\", \"Vector\", \"\", \"A\",0,0,\(-theta)\n"
            + "\t\t\tP: \"Translation\", \"Vector\", \"\", \"A\",0.2,0.3,0"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-fbxrot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try png.write(to: folder.appendingPathComponent("a.png"))
        let url = folder.appendingPathComponent("square.fbx")
        try fbx(image: "a.png", imageProps: props, creator: "Blender (stable FBX IO) - 5.2.2 LTS - 5.15.0").write(to: url)
        let scene = try ImportRouter.load(url, format: .fbx)
        let part = try XCTUnwrap(scene.meshes.flatMap(\.parts).first)
        // Blender samples the image at L + R(theta) * (S * corner), from the image's bottom
        // left; the scene counts from the top left.
        let s = SIMD2<Float>(0.6, 0.3), l = SIMD2<Float>(0.2, 0.3)
        let expected: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].map { c in
            let a = s * c
            let p = l + SIMD2(cos(theta) * a.x - sin(theta) * a.y, sin(theta) * a.x + cos(theta) * a.y)
            return SIMD2(p.x, 1 - p.y)
        }
        XCTAssertEqual(part.uv0.count, 4)
        for (uv, e) in zip(part.uv0, expected) { XCTAssertEqual(simd_distance(uv, e), 0, accuracy: 2e-4, "\(part.uv0) expected \(expected)") }
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

    /// An FBX from Maya's Stingray PBS shader (or 3ds Max's physical material) carries a
    /// baked occlusion image in its own slot; it was dropped, so crevices lost their
    /// darkening. Only that slot is read: an image in another slot is not occlusion.
    func testAnFBXOcclusionImageIsKeptWithFullStrength() throws {
        for slot in ["Maya|TEX_ao_map", "3dsMax|main|ao_map"] {
            let data = fbx(extraObjects: textureObject(712, name: "ao", video: true),
                           extraLinks: "\tC: \"OP\",712,400, \"\(slot)\"\n\tC: \"OO\",722,712\n")
            let scene = try AssimpImporter.scene(from: data, format: .fbx)
            let material = try XCTUnwrap(scene.meshes.flatMap(\.parts).first?.material.map { scene.materials[$0] })
            let index = try XCTUnwrap(material.occlusionTexture, "\(slot): no occlusion image in \(material)")
            if case .embedded(let bytes, _) = scene.textures[index] { XCTAssertEqual(Data(bytes), png, slot) }
            XCTAssertEqual(material.occlusionStrength, 1, slot)
            XCTAssertNil(material.normalTexture, slot)
            XCTAssertNil(material.emissiveTexture, slot)
        }
        let plain = try AssimpImporter.scene(from: fbx(), format: .fbx)
        XCTAssertNil(plain.materials.first?.occlusionTexture)
    }
}

