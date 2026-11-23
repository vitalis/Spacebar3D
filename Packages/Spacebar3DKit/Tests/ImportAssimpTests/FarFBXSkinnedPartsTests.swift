import Foundation
import ImportAssimp
import Metal
import ModelCore
import RenderMetal
import simd
import XCTest

/// Far FBX models whose parts are skinned, brought near the origin as the app does
/// (`AssimpImporter.scene`, then `movedNearTheOrigin()`), then posed on the CPU path and read back
/// as the renderer places them: each part's `model` times its posed vertices, in Double.
///
/// Assimp hands the skeleton over without a node (`node: nil`), like glTF, so the same rebasing
/// of node-less skeletons in `ModelScene.movedNearTheOrigin` / `rebaseSkeletons` must apply.
/// This is the FBX twin of FarGLTFSkinnedPartsTests.
final class FarFBXSkinnedPartsTests: XCTestCase {
    // MARK: fixtures

    /// A text FBX with a flat strip up the y axis (0 to 2, 0.5 wide) skinned to two bones (lower half
    /// bone a, upper half bone b), the bone a node `far` out in every axis, the strip's vertices
    /// the same; an animation turns b a quarter turn about z over one second. With `still`, a
    /// separate unskinned quad (1 by 1) also stands four units to the right, `far` out in y and z
    /// and x too. Offsets are multiples of 0.25 and `far` a multiple of 2^20 below 2^22, so each
    /// value is an exact Float.
    private func fbx(far: Float, still: Bool = false) -> Data {
        let t = SIMD3<Float>(repeating: far)
        let strip: [SIMD3<Float>] = [SIMD3(-0.25, 0, 0), SIMD3(0.25, 0, 0), SIMD3(-0.25, 1, 0), SIMD3(0.25, 1, 0), SIMD3(-0.25, 2, 0), SIMD3(0.25, 2, 0)]
        let quad: [SIMD3<Float>] = [SIMD3(3.5, 0, 0), SIMD3(4.5, 0, 0), SIMD3(4.5, 1, 0), SIMD3(3.5, 1, 0)]
        for near in strip + quad { for k in 0..<3 { precondition(Double(near[k] + t[k]) == Double(near[k]) + Double(far), "fixture is not exact at \(far)") } }
        precondition(Double(t.y + 1) == Double(far) + 1, "fixture is not exact at \(far)")
        func list(_ points: [SIMD3<Float>]) -> String { points.map { "\($0.x + t.x),\($0.y + t.y),\($0.z + t.z)" }.joined(separator: ",") }
        func move(_ x: SIMD3<Float>) -> String { "1,0,0,0,0,1,0,0,0,0,1,0,\(x.x),\(x.y),\(x.z),1" }
        let second = "46186158000"
        var objects = ""
        var links = ""
        if still {
            objects += """
            	Geometry: 90, "Geometry::quad", "Mesh" {
            		Vertices: *12 {
            			a: \(list(quad))
            		}
            		PolygonVertexIndex: *4 {
            			a: 0,1,2,-4
            		}
            		GeometryVersion: 124
            	}
            	Model: 91, "Model::quad", "Mesh" {
            		Version: 232
            		Properties70:  {
            		}
            	}

            """
            links += "\tC: \"OO\",91,0\n\tC: \"OO\",90,91\n"
        }
        objects += """
        	Geometry: 100, "Geometry::strip", "Mesh" {
        		Vertices: *18 {
        			a: \(list(strip))
        		}
        		PolygonVertexIndex: *12 {
        			a: 0,1,-4,0,3,-3,2,3,-6,2,5,-5
        		}
        		GeometryVersion: 124
        	}
        	Model: 200, "Model::strip", "Mesh" {
        		Version: 232
        		Properties70:  {
        		}
        	}
        	Deformer: 500, "Deformer::", "Skin" {
        		Version: 101
        		Link_DeformAcuracy: 50
        	}
        	Deformer: 501, "SubDeformer::a", "Cluster" {
        		Version: 100
        		UserData: "", ""
        		Indexes: *4 {
        			a: 0,1,2,3
        		}
        		Weights: *4 {
        			a: 1,1,1,1
        		}
        		Transform: *16 {
        			a: \(move(.zero))
        		}
        		TransformLink: *16 {
        			a: \(move(t))
        		}
        	}
        	Deformer: 502, "SubDeformer::b", "Cluster" {
        		Version: 100
        		UserData: "", ""
        		Indexes: *2 {
        			a: 4,5
        		}
        		Weights: *2 {
        			a: 1,1
        		}
        		Transform: *16 {
        			a: \(move(.zero))
        		}
        		TransformLink: *16 {
        			a: \(move(t + SIMD3(0, 1, 0)))
        		}
        	}

        """
        links += "\tC: \"OO\",200,0\n\tC: \"OO\",100,200\n\tC: \"OO\",500,100\n\tC: \"OO\",501,500\n\tC: \"OO\",502,500\n\tC: \"OO\",300,501\n\tC: \"OO\",310,502\n"
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
        \(objects)	Model: 300, "Model::a", "LimbNode" {
        		Version: 232
        		Properties70:  {
        			P: "Lcl Translation", "Lcl Translation", "", "A",\(t.x),\(t.y),\(t.z)
        		}
        	}
        	Model: 310, "Model::b", "LimbNode" {
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
        	AnimationStack: 600, "AnimStack::bend", "" {
        		Properties70:  {
        			P: "LocalStop", "KTime", "Time", "",\(second)
        		}
        	}
        	AnimationLayer: 601, "AnimLayer::base", "" {
        	}
        	AnimationCurveNode: 602, "AnimCurveNode::R", "" {
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
        			a: 0,90
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
        \(links)	C: "OO",300,0
        	C: "OO",310,300
        	C: "OO",301,300
        	C: "OO",311,310
        	C: "OO",601,600
        	C: "OO",602,601
        	C: "OP",602,310, "Lcl Rotation"
        	C: "OP",603,602, "d|Z"
        }

        """.utf8)
    }

    // MARK: measuring

    private func scene(far: Float, still: Bool = false) throws -> ModelScene {
        try AssimpImporter.scene(from: fbx(far: far, still: still), format: .fbx).movedNearTheOrigin()
    }

    /// Every part's posed vertices in the scene's own frame, in Double, as the renderer holds them,
    /// in the order of the scene's parts (`scene.meshes.flatMap(\.parts)`).
    private func placed(_ scene: ModelScene, time: Float) throws -> [[SIMD3<Double>]] {
        let counts = scene.meshes.flatMap(\.parts).map(\.positions.count)
        let renderer = try MetalRenderer()
        renderer.skinsOnGPU = false
        renderer.showGrid = false
        let gpu = try renderer.makeScene(scene)
        renderer.show(gpu)
        gpu.pose(clip: 0, time: time)
        _ = try renderer.renderOffscreen(width: 32, height: 32)
        let parts = try XCTUnwrap(Mirror(reflecting: gpu).children.first { $0.label == "parts" }?.value as? [AnyObject])
        XCTAssertEqual(parts.count, counts.count, "parts drawn")
        return try zip(parts, counts).map { part, count in
            let fields = Mirror(reflecting: part).children
            let buffer = try XCTUnwrap(fields.first { $0.label == "vertexBuffer" }?.value as? MTLBuffer)
            let model = try XCTUnwrap(fields.first { $0.label == "model" }?.value as? simd_float4x4, "Part has no model: simd_float4x4")
            let floats = buffer.contents().assumingMemoryBound(to: Float.self)
            return (0..<count).map { i in
                let p = SIMD3<Double>(Double(floats[i * 6]), Double(floats[i * 6 + 1]), Double(floats[i * 6 + 2]))
                func col(_ c: SIMD4<Float>) -> SIMD3<Double> { SIMD3(Double(c.x), Double(c.y), Double(c.z)) }
                return col(model.columns.0) * p.x + col(model.columns.1) * p.y + col(model.columns.2) * p.z + col(model.columns.3)
            }
        }
    }

    private func centre(_ points: [SIMD3<Double>]) -> SIMD3<Double> { points.reduce(SIMD3<Double>.zero, +) / Double(points.count) }

    private func skinnedIndex(_ scene: ModelScene) throws -> Int {
        try XCTUnwrap(scene.meshes.flatMap(\.parts).firstIndex { $0.skin != nil }, "no skinned part")
    }

    // MARK: tests

    /// The same FBX file near the origin poses to a bent strip (so the test measures the move, not
    /// the reader): the top end turns a quarter about z at the joint, one unit up the strip.
    func testTheSameFBXNearTheOriginBendsAtItsJoint() throws {
        let near = try scene(far: 0)
        let strip = try placed(near, time: 1)[try skinnedIndex(near)]
        let width = (strip.map(\.x).max() ?? 0) - (strip.map(\.x).min() ?? 0)
        let height = (strip.map(\.y).max() ?? 0) - (strip.map(\.y).min() ?? 0)
        print("P3D-FARFBX near time 1: width \(width) height \(height)")
        // Straight, the strip is 0.5 wide and 2 high; bent, its upper half lies sideways, 1 wide at most.
        XCTAssertLessThan(height, 1.6, "the strip should be bent at time 1, not straight")
    }

    /// A skinned FBX rig three million units out, bent a quarter turn at its joint, must come out
    /// the shape the same rig has at the origin. Assimp hands the skeleton over without a node,
    /// so if it is not rebased the strip is posed by joint matrices whose far translations cancel
    /// in Float (steps of a quarter unit there): the user sees a jagged, sheared strip.
    func testAWhollySkinnedFarFBXPosesLikeOneAtTheOrigin() throws {
        let far = Float(3_145_728)
        for time in [Float(0), 0.5, 1] {
            let nearScene = try scene(far: 0), farScene = try scene(far: far)
            let near = try placed(nearScene, time: time)[try skinnedIndex(nearScene)]
            let moved = try placed(farScene, time: time)[try skinnedIndex(farScene)]
            XCTAssertEqual(near.count, moved.count)
            var worst = 0.0
            for i in 1..<min(near.count, moved.count) { worst = max(worst, simd_distance(moved[i] - moved[0], near[i] - near[0])) }
            print("P3D-FARFBX rig time \(time): worst shape error \(worst); near first \(near[0]) far first \(moved[0])")
            XCTAssertLessThan(worst, 1e-3, "time \(time)")
            // The fixture bites: posed where it was read, without the move, the far strip is deformed.
            let raw = try AssimpImporter.scene(from: fbx(far: far), format: .fbx)
            let unmoved = try placed(raw, time: time)[try skinnedIndex(raw)]
            var unmovedWorst = 0.0
            for i in 1..<min(near.count, unmoved.count) { unmovedWorst = max(unmovedWorst, simd_distance(unmoved[i] - unmoved[0], near[i] - near[0])) }
            print("P3D-FARFBX unmoved time \(time): worst shape error \(unmovedWorst); skeleton nodes \(raw.skeletons.map(\.node))")
            if time == 1 { XCTAssertGreaterThan(unmovedWorst, 1e-2, "without the move the far FBX is already exact: the test would prove nothing") }
        }
    }

    /// A far FBX with a still quad beside the skinned strip: after the app's move to the origin the
    /// strip must stand where it did against the quad. The quad moved with the far middle but the
    /// strip (a skinned part of the node-less skeleton) could stay out where it was, millions of
    /// units from its neighbour.
    func testASkinnedFBXBesideAStillMeshOnAFarFileKeepsItsGap() throws {
        let far = Float(3_145_728)
        for time in [Float(0), 1] {
            let nearScene = try scene(far: 0, still: true), farScene = try scene(far: far, still: true)
            let nearParts = try placed(nearScene, time: time), farParts = try placed(farScene, time: time)
            let ns = try skinnedIndex(nearScene), fs = try skinnedIndex(farScene)
            let nearGap = centre(nearParts[ns]) - centre(nearParts[1 - ns])
            let farGap = centre(farParts[fs]) - centre(farParts[1 - fs])
            print("P3D-FARFBX gap time \(time): near \(nearGap) far \(farGap)")
            XCTAssertEqual(simd_distance(farGap, nearGap), 0, accuracy: 1e-3, "time \(time): the strip is \(farGap) from the quad, near the origin \(nearGap)")
        }
    }
}
