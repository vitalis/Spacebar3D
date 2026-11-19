import Darwin
import Foundation
import ModelCore
@testable import RenderMetal
import simd
import XCTest
@testable import ImportGLTF

/// More of glTF: odd accessor types, interpolation between keys, old-style VRM materials,
/// and files that ask for what is not read.
final class GLTFMoreTests: XCTestCase {
    private func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

    /// Binary chunks, each in a buffer view of its own, and the accessors that read them.
    private struct Pack {
        var data = Data()
        var views: [String] = []
        var accessors: [String] = []

        /// Returns the accessor's index.
        mutating func add(_ chunk: Data, component: Int, type: String, count: Int, normalized: Bool = false) -> Int {
            while data.count % 4 != 0 { data.append(0) }
            views.append("{\"buffer\": 0, \"byteOffset\": \(data.count), \"byteLength\": \(chunk.count)}")
            data += chunk
            accessors.append("{\"bufferView\": \(views.count - 1), \"componentType\": \(component), \"count\": \(count), \"type\": \"\(type)\"\(normalized ? ", \"normalized\": true" : "")}")
            return accessors.count - 1
        }

        mutating func floats(_ values: [Float], type: String) -> Int {
            let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][type]!
            return add(Data(buffer: values.withUnsafeBufferPointer { $0 }), component: 5126, type: type, count: values.count / width)
        }

        func json(_ body: String) -> Data {
            let text = "{\"asset\": {\"version\": \"2.0\"}, \(body), \"accessors\": [\(accessors.joined(separator: ","))], \"bufferViews\": [\(views.joined(separator: ","))], \"buffers\": [{\"uri\": \"data:application/octet-stream;base64,\(data.base64EncodedString())\", \"byteLength\": \(data.count)}]}"
            return Data(text.utf8)
        }
    }

    private let triangle: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]

    func testIndicesAndJointsRejectFloatSignedAndNormalizedAccessors() throws {
        let invalid: [(Int, Data, Bool)] = [
            (5120, bytes([Int8](repeating: 0, count: 12)), false),
            (5122, bytes([Int16](repeating: 0, count: 12)), false),
            (5123, bytes([UInt16](repeating: 0, count: 12)), true),
        ] + [Float(0), Float(UInt32.max), Float.infinity, Float.nan].map {
            (5126, bytes([Float](repeating: $0, count: 12)), false)
        }
        for (component, data, normalized) in invalid {
            for joints in [false, true] {
                var pack = Pack()
                let position = pack.floats(triangle, type: "VEC3")
                let accessor = pack.add(data, component: component, type: joints ? "VEC4" : "SCALAR", count: 3, normalized: normalized)
                let weights = pack.floats([Float](repeating: 0.25, count: 12), type: "VEC4")
                let attributes = joints ? ", \"JOINTS_0\": \(accessor), \"WEIGHTS_0\": \(weights)" : ""
                let indices = joints ? "" : ", \"indices\": \(accessor)"
                let body = """
                "nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": \(position)\(attributes)}\(indices)}]}]
                """
                XCTAssertThrowsError(try GLTFReader.scene(from: pack.json(body))) {
                    XCTAssertEqual($0 as? GLTFReader.Failure, .damaged("indices must use unsigned integers"))
                }
            }
        }
    }

    func testAllUnsignedIndexWidthsStillLoad() throws {
        for (component, data) in [(5121, bytes([UInt8](arrayLiteral: 0, 1, 2))),
                                  (5123, bytes([UInt16](arrayLiteral: 0, 1, 2))),
                                  (5125, bytes([UInt32](arrayLiteral: 0, 1, 2)))] {
            var pack = Pack()
            let position = pack.floats(triangle, type: "VEC3")
            let indices = pack.add(data, component: component, type: "SCALAR", count: 3)
            let body = """
            "nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": \(position)}, "indices": \(indices)}]}]
            """
            let scene = try GLTFReader.scene(from: pack.json(body))
            XCTAssertEqual(scene.meshes.first?.parts.first?.triangleIndices, [0, 1, 2])
        }
    }

    func testInvalidAccessorExtentsAreRejectedBeforeOutputAllocation() throws {
        struct Source: SidecarSource {
            let baseline: Int
            func data(named name: String) -> Data? {
                var stats = malloc_statistics_t()
                malloc_zone_statistics(nil, &stats)
                // A claimed 8M-position output alone would allocate 96 MB here.
                XCTAssertLessThan(Int(stats.size_in_use) - baseline, 16_000_000)
                return Data(repeating: 0, count: 36)
            }
        }
        for whole in [false, true] {
            let json = Data("""
            {"asset":{"version":"2.0"},"buffers":[{"uri":"test.bin","byteLength":36}],
             "bufferViews":[{"buffer":0,"byteLength":36}],
             "accessors":[{"bufferView":0,"componentType":\(whole ? 5125 : 5126),"count":8000000,"type":"\(whole ? "SCALAR" : "VEC3")"}]}
            """.utf8)
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            var document = try Document(data: json, sidecars: Source(baseline: Int(stats.size_in_use)))
            XCTAssertThrowsError(try whole ? document.wholes(0).count : document.floats(0).count) {
                XCTAssertEqual($0 as? GLTFReader.Failure, .damaged("an accessor runs past its data"))
            }
        }
    }

    func testSparseExtentsAreCheckedBeforeAllocatingTheZeroBase() throws {
        let json = Data("""
        {"asset":{"version":"2.0"},"buffers":[{"uri":"data:application/octet-stream;base64,AAAAAA==","byteLength":4}],
         "bufferViews":[{"buffer":0,"byteLength":4}],
         "accessors":[{"componentType":5126,"count":8000000,"type":"VEC3","sparse":{"count":8000000,
         "indices":{"bufferView":0,"componentType":5125},"values":{"bufferView":0}}}]}
        """.utf8)
        var document = try Document(data: json, sidecars: nil)
        XCTAssertThrowsError(try document.floats(0)) {
            XCTAssertEqual($0 as? GLTFReader.Failure, .damaged("an accessor runs past its data"))
        }
    }

    func testLinearKeysPreserveShortPeaksAndLongClips() throws {
        for end: Float in [1,10000] {
            var p = Pack()
            let position = p.floats(triangle,type:"VEC3")
            let times = p.floats([0,1.0/60,1.0/30,end],type:"SCALAR")
            let translation = p.floats([0,0,0,10,0,0,0,0,0,0,0,0],type:"VEC3")
            let scale = p.floats([1,1,1,2,2,2,1,1,1,1,1,1],type:"VEC3")
            let rotation = p.floats([0,0,0,1,0,0,1,0,0,0,0,1,0,0,0,1],type:"VEC4")
            let weights = p.floats([0,1,0,0],type:"SCALAR")
            let data = p.json("""
            "nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":\(position)},"targets":[{"POSITION":\(position)}]}]}],
            "animations":[{"samplers":[{"input":\(times),"output":\(translation)},{"input":\(times),"output":\(scale)},
            {"input":\(times),"output":\(rotation)},{"input":\(times),"output":\(weights)}],
            "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}},{"sampler":1,"target":{"node":0,"path":"scale"}},
            {"sampler":2,"target":{"node":0,"path":"rotation"}},{"sampler":3,"target":{"node":0,"path":"weights"}}]}]
            """)
            let scene = try GLTFReader.scene(from:data), clip = try XCTUnwrap(scene.clips.first)
            for (time,share): (Float,Float) in [(1.0/120,0.5),(1.0/60,1),(1.0/40,0.5),(1.0/30,0)] {
                let pose = ModelScene.Skeleton.decompose(scene.skeletons[0].localMatrices(clip:clip,time:time)[0])
                XCTAssertEqual(pose.translation.x,10*share,accuracy:1e-4)
                XCTAssertEqual(pose.scale.x,1+share,accuracy:1e-4)
                XCTAssertEqual(abs(pose.rotation.imag.z),sin(.pi/2*share),accuracy:1e-4)
                XCTAssertEqual(try XCTUnwrap(clip.morphs.first?.weights(at:time)?.first),share,accuracy:1e-4)
            }
        }
    }

    func testStepKeysHoldAndShortPulsesSurviveImport() throws {
        var pack = Pack()
        let position = pack.floats(triangle, type: "VEC3")
        let times = pack.floats([0, 0.505, 0.515, 1], type: "SCALAR")
        let translation = pack.floats([0,0,0, 1,0,0, 0,0,0, 2,0,0], type: "VEC3")
        let scale = pack.floats([1,1,1, 2,2,2, 1,1,1, 3,3,3], type: "VEC3")
        let rotation = pack.floats([0,0,0,1, 0,0,1,0, 0,0,0,1, 0,0,1,0], type: "VEC4")
        let weights = pack.floats([0,1,0,1], type: "SCALAR")
        let body = """
        "nodes":[{"mesh":0},{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":\(position)},"targets":[{"POSITION":\(position)}]}]}],
        "animations":[{"samplers":[
        {"input":\(times),"output":\(translation),"interpolation":"STEP"},
        {"input":\(times),"output":\(scale),"interpolation":"STEP"},
        {"input":\(times),"output":\(rotation),"interpolation":"STEP"},
        {"input":\(times),"output":\(weights),"interpolation":"STEP"},
        {"input":\(times),"output":\(translation)}],
        "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}},
        {"sampler":1,"target":{"node":0,"path":"scale"}},
        {"sampler":2,"target":{"node":0,"path":"rotation"}},
        {"sampler":3,"target":{"node":0,"path":"weights"}},
        {"sampler":4,"target":{"node":1,"path":"translation"}}]}]
        """
        let scene = try GLTFReader.scene(from: pack.json(body))
        let clip = try XCTUnwrap(scene.clips.first)
        for (time, x, size, turned, weight): (Float, Float, Float, Bool, Float) in [
            (0.504,0,1,false,0), (0.505,1,2,true,1), (0.51,1,2,true,1),
            (0.515,0,1,false,0), (0.99,0,1,false,0), (1,2,3,true,1), (2,2,3,true,1)
        ] {
            let pose = ModelScene.Skeleton.decompose(scene.skeletons[0].localMatrices(clip: clip, time: time)[0])
            XCTAssertEqual(pose.translation.x, x, accuracy: 1e-5)
            XCTAssertEqual(pose.scale.x, size, accuracy: 1e-5)
            XCTAssertEqual(abs(pose.rotation.imag.z), turned ? 1 : 0, accuracy: 1e-5)
            XCTAssertEqual(clip.morphs.first?.weights(at: time), [weight])
        }
        // A smooth track on another joint still interpolates independently.
        XCTAssertEqual(scene.skeletons[0].localMatrices(clip: clip, time: 0.25)[1].columns.3.x, 0.25 / 0.505, accuracy: 1e-5)
    }

    func testImportedTextureRotationsFollowSpecifiedMatrix() throws {
        for (rotation, expected) in [(Float.pi / 2, SIMD2<Float>(0.125, 0.6)), (-Float.pi / 2, SIMD2<Float>(0.875, -0.4))] {
            var pack = Pack()
            let position = pack.floats(triangle, type: "VEC3")
            let uv = pack.floats([0.25, 0.125, 0, 0, 1, 1], type: "VEC2")
            let body = """
            "nodes":[{"mesh":0}], "meshes":[{"primitives":[{"attributes":{"POSITION":\(position),"TEXCOORD_0":\(uv)},"material":0}]}],
            "materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0,"extensions":{"KHR_texture_transform":
            {"rotation":\(rotation),"offset":[0.5,0.1],"scale":[2,3]}}}}}],
            "textures":[{"source":0}],"images":[{"uri":"data:image/png;base64,AAAA"}]
            """
            let scene = try GLTFReader.scene(from: pack.json(body))
            let actual = try XCTUnwrap(scene.meshes.first?.parts.first?.uv0.first)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-6)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-6)
        }
    }


    func testAnimatedPropertiesKeepAuthoredScaleSigns() throws {
        let scales: [[Float]] = [[1,-1,1], [1,1,-1], [-1,-1,1], [1,0,1]]
        for scale in scales {
            for path in ["rotation", "scale"] {
                for interpolation in ["LINEAR", "STEP"] {
                    for vrm in [false, true] {
                        var pack = Pack()
                        let position = pack.floats(triangle, type: "VEC3")
                        let times = pack.floats([0,1], type: "SCALAR")
                        let rotation: [Float] = [0,0,sin(0.2),cos(0.2)]
                        let value = path == "rotation" ? rotation : scale
                        let output = pack.floats(value + value, type: path == "rotation" ? "VEC4" : "VEC3")
                        let body = """
                        "nodes":[{"mesh":0,"translation":[1,2,3],"rotation":\(rotation),"scale":\(scale)}],
                        "meshes":[{"primitives":[{"attributes":{"POSITION":\(position)}}]}],
                        "animations":[{"samplers":[{"input":\(times),"output":\(output),"interpolation":"\(interpolation)"}],
                        "channels":[{"sampler":0,"target":{"node":0,"path":"\(path)"}}]}]
                        \(vrm ? ",\"extensions\":{\"VRM\":{}}" : "")
                        """
                        let scene = try GLTFReader.scene(from: pack.json(body))
                        for time: Float in [0, 0.5, 1] {
                            let actual = scene.skeletons[0].localMatrices(clip: scene.clips[0], time: time)[0]
                            for c in 0..<4 { XCTAssertLessThan(simd_distance(actual[c], scene.nodes[0].transform[c]), 1e-5, "\(scale), \(path), \(interpolation), VRM \(vrm)") }
                        }
                    }
                }
            }
        }
    }

    func testIndexedPointsSelectAllMatchingAttributesAndFrameOnlyThosePoints() throws {
        for indices: [UInt16] in [[2], [2,2,0]] {
            var pack = Pack()
            let positions: [Float] = [0,0,0, 1000,1000,1000, 2,3,4, -1000,-1000,-1000]
            let position = pack.floats(positions, type: "VEC3")
            let uv = pack.floats([0,0, 1,0, 0,1, 1,1], type: "VEC2")
            let color = pack.floats([1,0,0,1, 0,1,0,1, 0,0,1,1, 1,1,1,1], type: "VEC4")
            let normal = pack.floats([0,0,1, 0,1,0, 1,0,0, 0,0,-1], type: "VEC3")
            let index = pack.add(bytes(indices), component: 5123, type: "SCALAR", count: indices.count)
            let scene = try GLTFReader.scene(from: pack.json("""
            "nodes":[{"mesh":0}],"meshes":[{"primitives":[{"mode":0,"indices":\(index),
            "attributes":{"POSITION":\(position),"NORMAL":\(normal),"TEXCOORD_0":\(uv),"COLOR_0":\(color)}}]}]
            """))
            let part = scene.meshes[0].parts[0]
            XCTAssertEqual(part.positions, indices.map { let i = Int($0) * 3; return SIMD3(positions[i], positions[i+1], positions[i+2]) })
            XCTAssertEqual(part.uv0, indices.map { $0 == 2 ? SIMD2<Float>(0,1) : .zero })
            XCTAssertEqual(part.colors, indices.map { $0 == 2 ? SIMD4<Float>(0,0,1,1) : SIMD4<Float>(1,0,0,1) })
            XCTAssertEqual(part.normals, indices.map { $0 == 2 ? SIMD3<Float>(1,0,0) : SIMD3<Float>(0,0,1) })
            let gpu = try MetalRenderer().makeScene(scene)
            XCTAssertEqual(gpu.parts[0].vertexCount, indices.count)
            XCTAssertLessThan(simd_length(gpu.framing.size), 10)
            XCTAssertEqual(try XCTUnwrap(scene.bounds).max, SIMD3(2,3,4))
        }
    }

    func testPointsKeepNodeSkinAndMorphAnimation() throws {
        for jointSkin in [false, true] {
            var pack = Pack()
            let position = pack.floats([0,0,0, 1,0,0], type: "VEC3")
            let delta = pack.floats([0,2,0, 0,2,0], type: "VEC3")
            let joints = pack.add(bytes([UInt16](repeating: 0, count: 8)), component: 5123, type: "VEC4", count: 2)
            let weights = pack.floats([1,0,0,0, 1,0,0,0], type: "VEC4")
            let times = pack.floats([0,1], type: "SCALAR")
            let translations = pack.floats([3,0,0, 5,0,0], type: "VEC3")
            let morphs = pack.floats([0.25,1], type: "SCALAR")
            let attributes = jointSkin ? ",\"JOINTS_0\":\(joints),\"WEIGHTS_0\":\(weights)" : ""
            let nodes = jointSkin ? "{\"mesh\":0,\"skin\":0},{\"translation\":[3,0,0]}" : "{\"mesh\":0,\"translation\":[3,0,0]}"
            let skins = jointSkin ? ",\"skins\":[{\"joints\":[1]}]" : ""
            let scene = try GLTFReader.scene(from: pack.json("""
            "nodes":[\(nodes)],"meshes":[{"weights":[0.25],"primitives":[{"mode":0,
            "attributes":{"POSITION":\(position)\(attributes)},"targets":[{"POSITION":\(delta)}]}]}]\(skins),
            "animations":[{"samplers":[{"input":\(times),"output":\(translations)},{"input":\(times),"output":\(morphs)}],
            "channels":[{"sampler":0,"target":{"node":\(jointSkin ? 1 : 0),"path":"translation"}},
            {"sampler":1,"target":{"node":0,"path":"weights"}}]}]
            """))
            let renderer = try MetalRenderer()
            renderer.showGrid = false; renderer.showShadow = false
            let gpu = try renderer.makeScene(scene)
            XCTAssertTrue(gpu.isSkinned, "Point-only clips must be available to the viewer")
            XCTAssertEqual(gpu.clips.count, 1)
            XCTAssertGreaterThanOrEqual(gpu.framing.size.x, 3)
            let part = try XCTUnwrap(gpu.parts.first)
            func check(_ x: Float, _ y: Float) {
                let values = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
                for i in 0..<2 {
                    XCTAssertEqual(values[i * 6], x + Float(i), accuracy: 0.0001)
                    XCTAssertEqual(values[i * 6 + 1], y, accuracy: 0.0001)
                }
            }
            check(3, 0.5) // Authored translation and default morph weight before any frame.
            for onGPU in [false, true] {
                renderer.skinsOnGPU = onGPU; renderer.show(gpu)
                for time: Float in [0, 0.5, 1, 0] {
                    gpu.pose(clip: 0, time: time)
                    _ = try renderer.renderOffscreen(width: 96, height: 96)
                    check(3 + time * 2, 0.5 + time * 1.5)
                }
            }
        }
    }

    func testImplicitMaterialCullsLikeAnEmptyExplicitMaterial() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        for scale in [1, -1] {
            var pictures: [[UInt8]] = []
            for explicit in [true, false] {
                var pack = Pack()
                let position = pack.floats([-1,-1,0, 1,-1,0, 0,1,0], type: "VEC3")
                let material = explicit ? ",\"material\":0" : ""
                let scene = try GLTFReader.scene(from: pack.json("""
                "nodes":[{"mesh":0,"scale":[\(scale),1,1]}],"materials":[{}],
                "meshes":[{"primitives":[{"attributes":{"POSITION":\(position)}\(material)}]}]
                """))
                XCTAssertTrue(scene.materials[scene.meshes[0].parts[0].material!].oneSided)
                renderer.show(try renderer.makeScene(scene))
                renderer.camera.pitch = 0
                for yaw: Float in [0, .pi] {
                    renderer.camera.yaw = yaw
                    let image = try renderer.renderOffscreen(width: 96, height: 96)
                    XCTAssertEqual(image.pixel(48,48).a > 0, yaw == 0)
                    if explicit { pictures.append(image.bytes) }
                    else { XCTAssertTrue(image.bytes == pictures[yaw == 0 ? 0 : 1]) }
                }
            }
        }
    }

    func testMirroredMorphAndAnimatedMeshesKeepFacingness() throws {
        func model(_ kind: String) throws -> ModelScene {
            var pack = Pack()
            let position = pack.floats([-1,-1,0, 1,-1,0, 0,1,0], type: "VEC3")
            let delta = pack.floats([Float](repeating: 0, count: 9), type: "VEC3")
            let times = pack.floats([0,1], type: "SCALAR")
            let scales = pack.floats([-1,1,1, 1,1,1], type: "VEC3")
            let target = kind == "morph" ? ",\"targets\":[{\"POSITION\":\(delta)}]" : ""
            let animation = kind == "animation" ? """
            ,"animations":[{"samplers":[{"input":\(times),"output":\(scales)}],"channels":[{"sampler":0,"target":{"node":0,"path":"scale"}}]}]
            """ : ""
            return try GLTFReader.scene(from: pack.json("""
            "nodes":[{"mesh":0,"scale":[-1,1,1]}],"meshes":[{"primitives":[{"attributes":{"POSITION":\(position)},"material":0\(target)}]}],
            "materials":[{"extensions":{"KHR_materials_unlit":{}},"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1]}}]\(animation)
            """))
        }
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        let reference = try renderer.makeScene(model("static"))
        renderer.show(reference)
        var camera = renderer.camera
        camera.yaw = 0; camera.pitch = 0
        for yaw: Float in [0, .pi] {
            camera.yaw = yaw; renderer.camera = camera
            let expected = try renderer.renderOffscreen(width: 96, height: 96)
            if yaw == 0 { XCTAssertGreaterThan(expected.pixel(48,48).a, 0) }
            else { XCTAssertEqual(expected.pixel(48,48).a, 0) }
            for kind in ["morph", "animation"] {
                let gpu = try renderer.makeScene(model(kind))
                for onGPU in [false, true] {
                    renderer.skinsOnGPU = onGPU; renderer.show(gpu); renderer.camera = camera
                    gpu.pose(clip: kind == "animation" ? 0 : nil, time: 0)
                    XCTAssertEqual(try renderer.renderOffscreen(width: 96, height: 96).bytes, expected.bytes, "\(kind), GPU \(onGPU), yaw \(yaw)")
                    XCTAssertTrue(gpu.parts[0].mirrored)
                    if kind == "animation" {
                        gpu.pose(clip: 0, time: 1)
                        let positive = try renderer.renderOffscreen(width: 96, height: 96)
                        XCTAssertFalse(gpu.parts[0].mirrored)
                        XCTAssertEqual(positive.pixel(48,48).a, expected.pixel(48,48).a)
                    }
                }
            }
            renderer.show(reference)
        }
    }


    func testSkinWindingUsesItsRootOrCommonAncestor() throws {
        for explicitRoot in [false, true] {
            var pack = Pack()
            let position = pack.floats(triangle, type: "VEC3")
            let joints = pack.add(bytes([UInt16](repeating: 0, count: 12)), component: 5123, type: "VEC4", count: 3)
            let weights = pack.floats([1,0,0,0, 1,0,0,0, 1,0,0,0], type: "VEC4")
            let scene = try GLTFReader.scene(from: pack.json("""
            "nodes":[{"scale":[-1,1,1],"children":[1,2]},{},{},{"mesh":0,"skin":0}],
            "skins":[{"joints":[1,2]\(explicitRoot ? ",\"skeleton\":0" : "")}],
            "meshes":[{"primitives":[{"attributes":{"POSITION":\(position),"JOINTS_0":\(joints),"WEIGHTS_0":\(weights)}}]}]
            """))
            let part = scene.meshes[try XCTUnwrap(scene.nodes.last?.mesh)].parts[0]
            XCTAssertEqual(part.skin?.windingJoint, 0)
            let gpu = try MetalRenderer().makeScene(scene)
            XCTAssertTrue(gpu.parts[0].mirrored)
        }
    }

    // MARK: Keys

    func testKeysAreBlendedBySplineSlerpAndPlainSteps() throws {
        var pack = Pack()
        let position = pack.floats(triangle, type: "VEC3")
        let times = pack.floats([0, 1], type: "SCALAR")
        // A spline key is its arriving slope, its value, and its leaving slope.
        let spline = pack.floats([0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0], type: "VEC3")
        let quarterTurn: Float = 0.70710678
        let turn = pack.floats([0, 0, 0, 1, 0, 0, quarterTurn, quarterTurn], type: "VEC4")
        let growth = pack.floats([1, 1, 1, 3, 3, 3], type: "VEC3")
        // A rotation of nothing at all has no direction: it falls back to no turn.
        let nothing = pack.floats([0, 0, 0, 0, 0, 0, 0, 0], type: "VEC4")
        let body = """
        "scenes": [{"nodes": [0, 1, 2]}],
         "nodes": [{"name": "slide", "mesh": 0}, {"name": "spin", "mesh": 0}, {"name": "void", "mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": \(position)}}]}],
         "animations": [{"name": "all", "channels": [
            {"sampler": 0, "target": {"node": 0, "path": "translation"}},
            {"sampler": 1, "target": {"node": 1, "path": "rotation"}},
            {"sampler": 2, "target": {"node": 1, "path": "scale"}},
            {"sampler": 3, "target": {"node": 2, "path": "rotation"}}],
          "samplers": [{"input": \(times), "output": \(spline), "interpolation": "CUBICSPLINE"}, {"input": \(times), "output": \(turn)},
                       {"input": \(times), "output": \(growth)}, {"input": \(times), "output": \(nothing), "interpolation": "STEP"}]}]
        """
        let scene = try GLTFReader.scene(from: pack.json(body))
        let clip = try XCTUnwrap(scene.clips.first)
        XCTAssertEqual(clip.name, "all")
        XCTAssertEqual(clip.duration, 1, accuracy: 1e-5)
        // Thirty keys a second, three joints; the middle key is the 15th.
        XCTAssertEqual(clip.translations.times.count, 31)
        let middle = 15 * 3
        XCTAssertEqual(clip.translations.values[middle].x, 1.0, accuracy: 1e-4, "the Hermite curve with a steep leaving slope")
        XCTAssertEqual(clip.translations.values[30 * 3].x, 1.0, accuracy: 1e-4)
        let locals = scene.skeletons[0].localMatrices(clip: clip, time: 0.5)
        let half = ModelScene.Skeleton.decompose(locals[1]).rotation
        XCTAssertEqual(half.imag.z, sin(Float.pi / 8), accuracy: 1e-4, "half way round the quarter turn")
        XCTAssertEqual(half.real, cos(Float.pi / 8), accuracy: 1e-4)
        XCTAssertEqual(ModelScene.Skeleton.decompose(locals[1]).scale.x, 2, accuracy: 1e-4)
        XCTAssertEqual(simd_length(ModelScene.Skeleton.decompose(locals[2]).rotation.vector), 1, accuracy: 1e-5)
        XCTAssertEqual(ModelScene.Skeleton.decompose(locals[2]).rotation.real, 1, accuracy: 1e-5)
    }

    // MARK: Accessors

    func testSmallIntegersAreScaledWhenNormalisedAndKeptWhenNot() throws {
        var pack = Pack()
        let position = pack.add(bytes([Int16](arrayLiteral: 0, 0, 0, 32767, 0, 0, 0, -32768, 0)), component: 5122, type: "VEC3", count: 3, normalized: true)
        let normal = pack.add(Data([0, 0, 127, 0, 0, 0x80, 0, 0, 127]), component: 5120, type: "VEC3", count: 3, normalized: true)
        let uv = pack.add(bytes([UInt32](arrayLiteral: 0, 0, 1, 0, 0, 1)), component: 5125, type: "VEC2", count: 3)
        // A shape moving the second corner, with its normal.
        let move = pack.floats([0, 0, 0, 0, 0, 5, 0, 0, 0], type: "VEC3")
        let tilt = pack.floats([0, 0, 0, 1, 0, 0, 0, 0, 0], type: "VEC3")
        let body = """
        "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": \(position), "NORMAL": \(normal), "TEXCOORD_0": \(uv)},
                                    "targets": [{"POSITION": \(move), "NORMAL": \(tilt)}]}]}]
        """
        let scene = try GLTFReader.scene(from: pack.json(body))
        let part = scene.meshes[try XCTUnwrap(scene.nodes[0].mesh)].parts[0]
        XCTAssertEqual(part.positions, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0)])
        XCTAssertEqual(part.normals, [SIMD3(0, 0, 1), SIMD3(0, 0, -1), SIMD3(0, 0, 1)])
        XCTAssertEqual(part.uv0, [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)])
        let shape = try XCTUnwrap(part.morphTargets.first)
        XCTAssertEqual(shape.positions[1], SIMD3(0, 0, 5))
        XCTAssertEqual(shape.normals[1], SIMD3(1, 0, 0))
    }

    // MARK: Placement and images

    func testAMatrixPlacesANodeAndImagesComeFromTextOrFromTheBuffer() throws {
        var pack = Pack()
        let position = pack.floats(triangle, type: "VEC3")
        let image = pack.add(Data("PNGX".utf8), component: 5121, type: "SCALAR", count: 4)
        _ = image
        let material = """
        {"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}, "emissiveTexture": {"index": 1}, "emissiveFactor": [1, 1, 1]}
        """
        let body = """
        "scenes": [{"nodes": [0]}],
         "nodes": [{"mesh": 0, "matrix": [1,0,0,0, 0,1,0,0, 0,0,1,0, 5,0,0,1]}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": \(position)}, "material": 0}]}],
         "materials": [\(material)],
         "textures": [{"source": 0}, {"source": 1}],
         "images": [{"uri": "data:image/png,abc%20d"}, {"bufferView": 1, "mimeType": "image/png"}]
        """
        let scene = try GLTFReader.scene(from: pack.json(body))
        XCTAssertEqual(scene.nodes[0].transform.columns.3.x, 5)
        XCTAssertEqual(try XCTUnwrap(scene.bounds).min.x, 5)
        let found = scene.materials[0]
        guard case .embedded(let text, _) = scene.textures[try XCTUnwrap(found.baseColorTexture)] else { return XCTFail("not embedded") }
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "abc d", "text in a data address is percent-decoded")
        guard case .embedded(let inside, _) = scene.textures[try XCTUnwrap(found.emissiveTexture)] else { return XCTFail("not embedded") }
        XCTAssertEqual(String(decoding: inside, as: UTF8.self), "PNGX")
    }

    // MARK: Files that ask for more

    func testExtensionsThatAreRequiredButNotReadFailByName() throws {
        var pack = Pack()
        let position = pack.floats(triangle, type: "VEC3")
        func model(required: String, primitive: String = "") -> Data {
            pack.json("\"extensionsRequired\": [\(required)], \"scenes\": [{\"nodes\": [0]}], \"nodes\": [{\"mesh\": 0}], \"meshes\": [{\"primitives\": [{\"attributes\": {\"POSITION\": \(position)}\(primitive)}]}]")
        }
        XCTAssertThrowsError(try GLTFReader.scene(from: model(required: "\"VENDOR_magic\""))) {
            XCTAssertEqual($0 as? GLTFReader.Failure, .unsupported("it needs VENDOR_magic, which is not read"))
        }
        XCTAssertThrowsError(try GLTFReader.scene(from: model(required: "\"EXT_meshopt_compression\""))) {
            XCTAssertEqual($0 as? GLTFReader.Failure, .unsupported("Meshopt-compressed models are not supported"))
        }
        // A primitive that is Draco-compressed, though the file did not say it must be read so.
        XCTAssertThrowsError(try GLTFReader.scene(from: model(required: "", primitive: ", \"extensions\": {\"KHR_draco_mesh_compression\": {}}"))) {
            XCTAssertEqual($0 as? GLTFReader.Failure, .unsupported("Draco-compressed models are not supported"))
        }
        // A version other than 2 is refused.
        XCTAssertThrowsError(try GLTFReader.scene(from: Data("{\"asset\": {\"version\": \"1.0\"}}".utf8)))
    }

    // MARK: VRM 0.x materials

    private func oldVRM(_ properties: String, textures: Bool = true) throws -> ModelScene {
        var pack = Pack()
        let position = pack.floats(triangle, type: "VEC3")
        let images = textures ? ", \"textures\": [{\"source\": 0}], \"images\": [{\"uri\": \"data:image/png,xx\"}]" : ""
        let body = """
        "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": \(position)}, "material": 0}]}], "materials": [{}]\(images),
         "extensions": {"VRM": {"materialProperties": [\(properties)]}}
        """
        return try GLTFReader.scene(from: pack.json(body))
    }

    func testOldCartoonMaterialsCutOutBlendGlowAndLightTheirImages() throws {
        // Cut out: the coverage threshold, scaled by the colour's own alpha.
        let cut = try oldVRM("""
        {"shader": "VRM/MToon", "floatProperties": {"_BlendMode": 1, "_Cutoff": 0.25, "_CullMode": 0},
         "vectorProperties": {"_Color": [1, 0.5, 0.25, 0.5], "_EmissionColor": [1, 0, 0, 1]}, "textureProperties": {"_MainTex": 0, "_EmissionMap": 0}}
        """)
        let first = cut.materials[0]
        XCTAssertEqual(try XCTUnwrap(first.alphaCutoff), 0.5, accuracy: 1e-5)
        XCTAssertEqual(first.opacity, 1)
        XCTAssertTrue(first.doubleSided)
        XCTAssertNotNil(first.baseColorTexture)
        XCTAssertNotNil(first.emissiveTexture)
        XCTAssertEqual(first.emissive.x, 1, accuracy: 1e-5)
        XCTAssertEqual(first.emissive.y, 0)

        // BLEND remains explicit even with a fully opaque material factor.
        let blended = try oldVRM("""
        {"shader": "VRM/MToon", "floatProperties": {"_BlendMode": 2}, "vectorProperties": {"_Color": [1, 1, 1, 1]}, "textureProperties": {"_MainTex": 0}}
        """)
        XCTAssertEqual(blended.materials[0].opacity, 1)
        XCTAssertTrue(blended.materials[0].alphaBlend)
        let faded = try oldVRM("{\"shader\": \"VRM/MToon\", \"floatProperties\": {\"_BlendMode\": 3}, \"vectorProperties\": {\"_Color\": [1, 1, 1, 0.4]}}", textures: false)
        XCTAssertEqual(faded.materials[0].opacity, 0.4, accuracy: 1e-5)

        // The plain shader of the older form shows no light at all.
        let flat = try oldVRM("{\"shader\": \"VRM/UnlitTexture\"}", textures: false)
        XCTAssertTrue(flat.materials[0].unlit)
    }

    // MARK: New cartoon maps

    func testShadingShiftImageOfTheNewCartoonMaterial() throws {
        var pack = Pack()
        let position = pack.floats(triangle, type: "VEC3")
        let body = """
        "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": \(position)}, "material": 0}]}],
         "materials": [{"extensions": {"VRMC_materials_mtoon": {"shadingShiftTexture": {"index": 0, "scale": 0.5}}}}],
         "textures": [{"source": 0}], "images": [{"uri": "data:image/png,xx"}]
        """
        let scene = try GLTFReader.scene(from: pack.json(body))
        let toon = try XCTUnwrap(scene.materials[0].toon)
        XCTAssertNotNil(toon.shiftTexture)
        XCTAssertEqual(toon.shiftTextureScale, 0.5)
    }

    func testPartsThatDisagreeOnTheirOtherShapesHaveNone() throws {
        var pack = Pack()
        let position = pack.floats(triangle, type: "VEC3")
        let move = pack.floats([0, 0, 1, 0, 0, 1, 0, 0, 1], type: "VEC3")
        let body = """
        "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": \(position)}, "targets": [{"POSITION": \(move)}]},
                                    {"attributes": {"POSITION": \(position)}}]}]
        """
        let scene = try GLTFReader.scene(from: pack.json(body))
        let parts = scene.meshes[try XCTUnwrap(scene.nodes[0].mesh)].parts
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.morphTargets.isEmpty })
    }
}
