import Foundation
import ImportGLTF
import ImportOBJ
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// Which way the green channel of a glTF normal map tilts a surface, on both of the renderer's
/// paths (a tangent stored in the file, and one the renderer works out from the texture
/// coordinates). Reference: Blender 5.2.2 (OpenGL convention, as the glTF specification and the
/// Khronos sample viewer have it: green+ points to the top of the image, toward decreasing glTF v).
///
/// Fixtures: `planeWithTangents` and `planeWithoutTangents` are the .glb files Blender's own glTF
/// exporter (v5.2.40; `export_tangents` True and False) wrote for one plane facing the camera, UVs
/// standard (u right, v up in Blender, so v down in the file), carrying a normal map of one texel
/// colour (128, 200, 255). Blender's own evaluation of that material (a Cycles EMIT bake of the
/// Normal Map node's world normal) gave (0.003, 0.494 up, 0.869 toward the viewer) for the plane:
/// the map tilts the plane's normal UP, toward the top of the picture. The exported tangent is
/// (1, 0, 0, +1) at every corner.
final class GLTFNormalMapGreenTests: XCTestCase {
    private let planeWithTangents = Data(base64Encoded:
        "Z2xURgIAAACcBwAAsAUAAEpTT057ImFzc2V0Ijp7ImdlbmVyYXRvciI6Iktocm9ub3MgZ2xURiBCbGVuZGVyIEkvTyB2NS4yLjQwIiwidmVyc2lvbiI6IjIu" +
        "MCJ9LCJzY2VuZSI6MCwic2NlbmVzIjpbeyJuYW1lIjoiU2NlbmUiLCJub2RlcyI6WzBdfV0sIm5vZGVzIjpbeyJtZXNoIjowLCJuYW1lIjoiUGxhbmUifV0s" +
        "Im1hdGVyaWFscyI6W3siZG91YmxlU2lkZWQiOnRydWUsIm5hbWUiOiJtIiwibm9ybWFsVGV4dHVyZSI6eyJpbmRleCI6MH0sInBick1ldGFsbGljUm91Z2hu" +
        "ZXNzIjp7ImJhc2VDb2xvckZhY3RvciI6WzAuODAwMDAwMDExOTIwOTI5LDAuODAwMDAwMDExOTIwOTI5LDAuODAwMDAwMDExOTIwOTI5LDFdLCJtZXRhbGxp" +
        "Y0ZhY3RvciI6MCwicm91Z2huZXNzRmFjdG9yIjowLjV9fV0sIm1lc2hlcyI6W3sibmFtZSI6IlBsYW5lIiwicHJpbWl0aXZlcyI6W3siYXR0cmlidXRlcyI6" +
        "eyJQT1NJVElPTiI6MCwiTk9STUFMIjoxLCJURVhDT09SRF8wIjoyLCJUQU5HRU5UIjozfSwiaW5kaWNlcyI6NCwibWF0ZXJpYWwiOjB9XX1dLCJ0ZXh0dXJl" +
        "cyI6W3sic2FtcGxlciI6MCwic291cmNlIjowfV0sImltYWdlcyI6W3siYnVmZmVyVmlldyI6NSwibWltZVR5cGUiOiJpbWFnZS9wbmciLCJuYW1lIjoibiJ9" +
        "XSwiYWNjZXNzb3JzIjpbeyJidWZmZXJWaWV3IjowLCJjb21wb25lbnRUeXBlIjo1MTI2LCJjb3VudCI6NCwibWF4IjpbMSwxLDQuMzcxMTM4ODI4NjczNzkz" +
        "ZS0wOF0sIm1pbiI6Wy0xLC0xLC00LjM3MTEzODgyODY3Mzc5M2UtMDhdLCJ0eXBlIjoiVkVDMyJ9LHsiYnVmZmVyVmlldyI6MSwiY29tcG9uZW50VHlwZSI6" +
        "NTEyNiwiY291bnQiOjQsInR5cGUiOiJWRUMzIn0seyJidWZmZXJWaWV3IjoyLCJjb21wb25lbnRUeXBlIjo1MTI2LCJjb3VudCI6NCwidHlwZSI6IlZFQzIi" +
        "fSx7ImJ1ZmZlclZpZXciOjMsImNvbXBvbmVudFR5cGUiOjUxMjYsImNvdW50Ijo0LCJ0eXBlIjoiVkVDNCJ9LHsiYnVmZmVyVmlldyI6NCwiY29tcG9uZW50" +
        "VHlwZSI6NTEyMywiY291bnQiOjYsInR5cGUiOiJTQ0FMQVIifV0sImJ1ZmZlclZpZXdzIjpbeyJidWZmZXIiOjAsImJ5dGVMZW5ndGgiOjQ4LCJieXRlT2Zm" +
        "c2V0IjowLCJ0YXJnZXQiOjM0OTYyfSx7ImJ1ZmZlciI6MCwiYnl0ZUxlbmd0aCI6NDgsImJ5dGVPZmZzZXQiOjQ4LCJ0YXJnZXQiOjM0OTYyfSx7ImJ1ZmZl" +
        "ciI6MCwiYnl0ZUxlbmd0aCI6MzIsImJ5dGVPZmZzZXQiOjk2LCJ0YXJnZXQiOjM0OTYyfSx7ImJ1ZmZlciI6MCwiYnl0ZUxlbmd0aCI6NjQsImJ5dGVPZmZz" +
        "ZXQiOjEyOCwidGFyZ2V0IjozNDk2Mn0seyJidWZmZXIiOjAsImJ5dGVMZW5ndGgiOjEyLCJieXRlT2Zmc2V0IjoxOTIsInRhcmdldCI6MzQ5NjN9LHsiYnVm" +
        "ZmVyIjowLCJieXRlTGVuZ3RoIjoyNTksImJ5dGVPZmZzZXQiOjIwNH1dLCJzYW1wbGVycyI6W3sibWFnRmlsdGVyIjo5NzI5LCJtaW5GaWx0ZXIiOjk5ODd9" +
        "XSwiYnVmZmVycyI6W3siYnl0ZUxlbmd0aCI6NDY0fV19ICAg0AEAAEJJTgAAAIC/AACAvy69O7MAAIA/AACAvy69O7MAAIC/AACAPy69OzMAAIA/AACAPy69" +
        "OzMAAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAACAPwAAgD8AAIA/AAAAAAAAAAAAAIA/AAAAAAAAgD8AAAAA" +
        "AAAAAAAAgD8AAIA/AAAAAAAAAAAAAIA/AACAPwAAAAAAAAAAAACAPwAAgD8AAAAAAAAAAAAAgD8AAAEAAwAAAAMAAgCJUE5HDQoaCgAAAA1JSERSAAAABAAA" +
        "AAQIAgAAACaTCSkAAAABc1JHQgM3x01TAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAANmVY" +
        "SWZNTQAqAAAAGAAAAEgAAAABAAAASAAAAAEAAgEaAAUAAAABAAAACAEbAAUAAAABAAAAEAAAAACQeO+8AAAACW9GRnMAAAAAAAAAAADaKrbOAAAACXBIWXMA" +
        "AAsSAAALEgHS3X78AAAAFUlEQVQIHWNsOPGfAQaYYAwQjZsDAHJjAk+Ubmh6AAAAAElFTkSuQmCCAA==")!

    private let planeWithoutTangents = Data(base64Encoded:
        "Z2xURgIAAADUBgAAKAUAAEpTT057ImFzc2V0Ijp7ImdlbmVyYXRvciI6Iktocm9ub3MgZ2xURiBCbGVuZGVyIEkvTyB2NS4yLjQwIiwidmVyc2lvbiI6IjIu" +
        "MCJ9LCJzY2VuZSI6MCwic2NlbmVzIjpbeyJuYW1lIjoiU2NlbmUiLCJub2RlcyI6WzBdfV0sIm5vZGVzIjpbeyJtZXNoIjowLCJuYW1lIjoiUGxhbmUifV0s" +
        "Im1hdGVyaWFscyI6W3siZG91YmxlU2lkZWQiOnRydWUsIm5hbWUiOiJtIiwibm9ybWFsVGV4dHVyZSI6eyJpbmRleCI6MH0sInBick1ldGFsbGljUm91Z2hu" +
        "ZXNzIjp7ImJhc2VDb2xvckZhY3RvciI6WzAuODAwMDAwMDExOTIwOTI5LDAuODAwMDAwMDExOTIwOTI5LDAuODAwMDAwMDExOTIwOTI5LDFdLCJtZXRhbGxp" +
        "Y0ZhY3RvciI6MCwicm91Z2huZXNzRmFjdG9yIjowLjV9fV0sIm1lc2hlcyI6W3sibmFtZSI6IlBsYW5lIiwicHJpbWl0aXZlcyI6W3siYXR0cmlidXRlcyI6" +
        "eyJQT1NJVElPTiI6MCwiTk9STUFMIjoxLCJURVhDT09SRF8wIjoyfSwiaW5kaWNlcyI6MywibWF0ZXJpYWwiOjB9XX1dLCJ0ZXh0dXJlcyI6W3sic2FtcGxl" +
        "ciI6MCwic291cmNlIjowfV0sImltYWdlcyI6W3siYnVmZmVyVmlldyI6NCwibWltZVR5cGUiOiJpbWFnZS9wbmciLCJuYW1lIjoibiJ9XSwiYWNjZXNzb3Jz" +
        "IjpbeyJidWZmZXJWaWV3IjowLCJjb21wb25lbnRUeXBlIjo1MTI2LCJjb3VudCI6NCwibWF4IjpbMSwxLDQuMzcxMTM4ODI4NjczNzkzZS0wOF0sIm1pbiI6" +
        "Wy0xLC0xLC00LjM3MTEzODgyODY3Mzc5M2UtMDhdLCJ0eXBlIjoiVkVDMyJ9LHsiYnVmZmVyVmlldyI6MSwiY29tcG9uZW50VHlwZSI6NTEyNiwiY291bnQi" +
        "OjQsInR5cGUiOiJWRUMzIn0seyJidWZmZXJWaWV3IjoyLCJjb21wb25lbnRUeXBlIjo1MTI2LCJjb3VudCI6NCwidHlwZSI6IlZFQzIifSx7ImJ1ZmZlclZp" +
        "ZXciOjMsImNvbXBvbmVudFR5cGUiOjUxMjMsImNvdW50Ijo2LCJ0eXBlIjoiU0NBTEFSIn1dLCJidWZmZXJWaWV3cyI6W3siYnVmZmVyIjowLCJieXRlTGVu" +
        "Z3RoIjo0OCwiYnl0ZU9mZnNldCI6MCwidGFyZ2V0IjozNDk2Mn0seyJidWZmZXIiOjAsImJ5dGVMZW5ndGgiOjQ4LCJieXRlT2Zmc2V0Ijo0OCwidGFyZ2V0" +
        "IjozNDk2Mn0seyJidWZmZXIiOjAsImJ5dGVMZW5ndGgiOjMyLCJieXRlT2Zmc2V0Ijo5NiwidGFyZ2V0IjozNDk2Mn0seyJidWZmZXIiOjAsImJ5dGVMZW5n" +
        "dGgiOjEyLCJieXRlT2Zmc2V0IjoxMjgsInRhcmdldCI6MzQ5NjN9LHsiYnVmZmVyIjowLCJieXRlTGVuZ3RoIjoyNTksImJ5dGVPZmZzZXQiOjE0MH1dLCJz" +
        "YW1wbGVycyI6W3sibWFnRmlsdGVyIjo5NzI5LCJtaW5GaWx0ZXIiOjk5ODd9XSwiYnVmZmVycyI6W3siYnl0ZUxlbmd0aCI6NDAwfV19ICCQAQAAQklOAAAA" +
        "gL8AAIC/Lr07swAAgD8AAIC/Lr07swAAgL8AAIA/Lr07MwAAgD8AAIA/Lr07MwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAA" +
        "AACAPwAAAAAAAIA/AACAPwAAgD8AAAAAAAAAAAAAgD8AAAAAAAABAAMAAAADAAIAiVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAAXNSR0ID" +
        "N8dNUwAAAARnQU1BAACxjwv8YQUAAAAgY0hSTQAAeiYAAICEAAD6AAAAgOgAAHUwAADqYAAAOpgAABdwnLpRPAAAADZlWElmTU0AKgAAABgAAABIAAAAAQAA" +
        "AEgAAAABAAIBGgAFAAAAAQAAAAgBGwAFAAAAAQAAABAAAAAAkHjvvAAAAAlvRkZzAAAAAAAAAAAA2iq2zgAAAAlwSFlzAAALEgAACxIB0t1+/AAAABVJREFU" +
        "CB1jbDjxnwEGmGAMEI2bAwByYwJPlG5oegAAAABJRU5ErkJgggA=")!

    /// The texel's tilt in tangent space, then the world normal for a plane facing +z with u to the
    /// right and the top of the picture up: red along +x, green along the picture's up (+y), blue out.
    private let texel: [UInt8] = [128, 200, 255]
    private func tilted(up: Bool) -> SIMD3<Float> {
        let r = Float(texel[0]) / 255 * 2 - 1, g = Float(texel[1]) / 255 * 2 - 1, b = Float(texel[2]) / 255 * 2 - 1
        return simd_normalize(SIMD3(r, up ? g : -g, b))
    }

    private func draw(_ scene: ModelScene) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured)
        renderer.camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100)
        return try renderer.renderOffscreen(width: 96, height: 96)
    }

    private func worst(_ a: OffscreenImage, _ b: OffscreenImage, over limit: Int = 4) -> (worst: Int, x: Int, y: Int, many: Int) {
        var result = (worst: 0, x: 0, y: 0, many: 0)
        for y in 0..<a.height { for x in 0..<a.width {
            let p = a.pixel(x, y), q = b.pixel(x, y)
            let d = max(abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b)), abs(Int(p.a) - Int(q.a)))
            if d > result.worst { result.worst = d; result.x = x; result.y = y }
            if d > limit { result.many += 1 }
        } }
        return result
    }

    /// The same plane with no map and `normal` in every vertex normal.
    private func baked(_ scene: ModelScene, normal: SIMD3<Float>) -> ModelScene {
        var out = scene
        for m in out.meshes.indices { for p in out.meshes[m].parts.indices {
            out.meshes[m].parts[p].normals = [SIMD3<Float>](repeating: normal, count: out.meshes[m].parts[p].positions.count)
            out.meshes[m].parts[p].tangents = []
            if let id = out.meshes[m].parts[p].material { out.materials[id].normalTexture = nil }
        } }
        return out
    }

    private func checkPlane(_ scene: ModelScene, file: String) throws {
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        XCTAssertEqual(part.positions.count, 4)
        for n in part.normals { XCTAssertEqual(simd_distance(n, SIMD3(0, 0, 1)), 0, accuracy: 1e-5, "\(file) faces the camera") }
        XCTAssertNotNil(scene.materials[try XCTUnwrap(part.material)].normalTexture, "\(file) has its normal map")
    }

    /// A glTF plane with a normal map and the file's own tangents, lit from one side, must show
    /// the picture of the plane whose normals already tilt toward the top of the image (what
    /// Blender makes of the same file). With the green of the map tilting toward the bottom the
    /// bumps would look dented where they stand out.
    func testAGLTFNormalMapWithFileTangentsTiltsGreenTowardTheTopOfTheImage() throws {
        let scene = try GLTFReader.scene(from: planeWithTangents)
        try checkPlane(scene, file: "tangent file")
        XCTAssertEqual(try XCTUnwrap(scene.meshes.first?.parts.first?.tangents.first), SIMD4(1, 0, 0, 1))
        let mapped = try draw(scene)
        let up = try draw(baked(scene, normal: tilted(up: true)))
        let down = try draw(baked(scene, normal: tilted(up: false)))
        XCTAssertGreaterThan(worst(up, down, over: 8).many, 1000, "the direction must show in the picture, or this test proves nothing")
        let r = worst(mapped, up)
        let wrong = worst(mapped, down)
        print("P3D-NMGREEN tangents: vs up worst \(r.worst) many \(r.many); vs down worst \(wrong.worst) many \(wrong.many)")
        XCTAssertEqual(r.many, 0, "tilt toward the image top: \(r.many) pixels differ, worst \(r.worst) at \(r.x),\(r.y); against the other way \(wrong.many)")
    }

    /// The same file without tangents: the renderer works the frame out from the texture
    /// coordinates, and must agree with the file that has them (and with Blender).
    func testAGLTFNormalMapWithoutTangentsTiltsGreenTowardTheTopOfTheImage() throws {
        let scene = try GLTFReader.scene(from: planeWithoutTangents)
        try checkPlane(scene, file: "no-tangent file")
        XCTAssertTrue(try XCTUnwrap(scene.meshes.first?.parts.first).tangents.isEmpty)
        let mapped = try draw(scene)
        let up = try draw(baked(scene, normal: tilted(up: true)))
        let down = try draw(baked(scene, normal: tilted(up: false)))
        XCTAssertGreaterThan(worst(up, down, over: 8).many, 1000, "the direction must show in the picture, or this test proves nothing")
        let r = worst(mapped, up)
        let wrong = worst(mapped, down)
        print("P3D-NMGREEN no tangents: vs up worst \(r.worst) many \(r.many); vs down worst \(wrong.worst) many \(wrong.many)")
        XCTAssertEqual(r.many, 0, "tilt toward the image top: \(r.many) pixels differ, worst \(r.worst) at \(r.x),\(r.y); against the other way \(wrong.many)")
    }

    /// The two glTF files are one plane: with and without tangents they must light alike.
    func testTheSameGLTFPlaneLightsAlikeWithAndWithoutTangents() throws {
        let a = try draw(try GLTFReader.scene(from: planeWithTangents))
        let b = try draw(try GLTFReader.scene(from: planeWithoutTangents))
        let r = worst(a, b)
        XCTAssertEqual(r.many, 0, "\(r.many) pixels differ, worst \(r.worst) at \(r.x),\(r.y)")
    }

    private struct Folder: SidecarSource {
        func data(named name: String) -> Data? {
            name.hasSuffix(".mtl") ? Data("newmtl m\nKd 1 1 1\nmap_Kd c.png\n".utf8) : Data([0])
        }
    }

    /// Guard: an OBJ keeps its image's v flipped to down on import and its materials use the
    /// OpenGL green (`normalYSign` -1 as the reader gives), so a normal map laid on it still tilts
    /// toward the top of the picture. (The OBJ reader does not read bump maps from an MTL, so
    /// the map is set on the imported scene.)
    func testAnOBJNormalMapStillTiltsGreenTowardTheTopOfTheImage() throws {
        let obj = """
        mtllib plane.mtl
        v -1 -1 0
        v 1 -1 0
        v 1 1 0
        v -1 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 1
        usemtl m
        f 1/1/1 2/2/1 3/3/1
        f 1/1/1 3/3/1 4/4/1
        """
        var scene = try OBJReader.scene(from: Data(obj.utf8), sidecars: Folder())
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        let id = try XCTUnwrap(part.material)
        XCTAssertEqual(scene.materials[id].normalYSign, -1)
        XCTAssertFalse(part.uv0.isEmpty, "the texture coordinates are kept")
        XCTAssertEqual(part.uv0[part.positions.firstIndex(of: SIMD3(-1, -1, 0))!].y, 1, "v is flipped to down")
        scene.textures = [.pixels(width: 1, height: 1, rgba: [255, 255, 255, 255]), .pixels(width: 1, height: 1, rgba: texel + [255])]
        scene.materials[id].baseColor = SIMD4(0.8, 0.8, 0.8, 1)
        scene.materials[id].baseColorTexture = nil
        scene.materials[id].normalTexture = 1
        let mapped = try draw(scene)
        let up = try draw(baked(scene, normal: tilted(up: true)))
        let down = try draw(baked(scene, normal: tilted(up: false)))
        XCTAssertGreaterThan(worst(up, down, over: 8).many, 1000)
        let r = worst(mapped, up)
        print("P3D-NMGREEN obj: vs up worst \(r.worst) many \(r.many); vs down many \(worst(mapped, down).many)")
        XCTAssertEqual(r.many, 0, "\(r.many) pixels differ, worst \(r.worst) at \(r.x),\(r.y)")
    }
}
