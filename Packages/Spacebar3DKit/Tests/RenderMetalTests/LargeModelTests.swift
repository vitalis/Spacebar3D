import Foundation
import ImportRouter
import ModelCore
import RenderMetal
import XCTest

/// Timings for big files. Skipped unless P3D_LARGE=1 (it writes a 100 MB file); run with
/// `P3D_LARGE=1 xcrun swift test --filter LargeModelTests`.
final class LargeModelTests: XCTestCase {
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func testTwoMillionTriangleSTL() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["P3D_LARGE"] == "1")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-large-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }
        try torusSTL(segments: 2000, sides: 500).write(to: url)
        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = CFAbsoluteTimeGetCurrent()
            let value = try body()
            print(String(format: "P3D-LARGE %@: %.3f s, footprint %.0f MB", label, CFAbsoluteTimeGetCurrent() - start, footprintMB()))
            return value
        }
        let scene = try time("import") { try ImportRouter.load(url, format: .stl) }
        XCTAssertEqual(scene.topology.faces, 2_000_000)
        let renderer = try MetalRenderer()
        let gpu = try time("upload (incl. smooth normals)") { try renderer.makeScene(scene) }
        renderer.show(gpu)
        print("P3D-LARGE vertices on the GPU \(gpu.vertexCount), gpu bytes \(gpu.gpuBytes / 1_048_576) MB")
        XCTAssertEqual(gpu.vertexCount, 1_000_000, "a face-by-face mesh is merged to its distinct positions")
        _ = try time("first frame 1600x1200") { try renderer.renderOffscreen(width: 1600, height: 1200) }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = try renderer.renderOffscreen(width: 1600, height: 1200) }
        print(String(format: "P3D-LARGE frame (offscreen, solid, incl. readback): %.1f ms", (CFAbsoluteTimeGetCurrent() - start) / 20 * 1000))
        time("wire build") { gpu.prepareWire() }
        print("P3D-LARGE wire lines \(gpu.wireLineCount), gpu bytes \(gpu.gpuBytes / 1_048_576) MB")
        renderer.look = RenderLook(view: .textured, wire: true)
        let wired = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 { _ = try renderer.renderOffscreen(width: 1600, height: 1200) }
        print(String(format: "P3D-LARGE frame (textured + wire): %.1f ms", (CFAbsoluteTimeGetCurrent() - wired) / 10 * 1000))
        time("outline build") { gpu.prepareOutline() }
        print("P3D-LARGE gpu bytes with outline \(gpu.gpuBytes / 1_048_576) MB")
        malloc_zone_pressure_relief(nil, 0)
        print(String(format: "P3D-LARGE after pressure relief: footprint %.0f MB", footprintMB()))
        for (label, look) in [("celShaded", RenderLook(view: .solid, style: .celShaded)), ("anime", RenderLook(view: .textured, style: .anime)), ("unlit", RenderLook(view: .textured, style: .unlit))] {
            renderer.look = look
            _ = try renderer.renderOffscreen(width: 1600, height: 1200)
            let began = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10 { _ = try renderer.renderOffscreen(width: 1600, height: 1200) }
            print(String(format: "P3D-LARGE frame (%@): %.1f ms, footprint %.0f MB", label, (CFAbsoluteTimeGetCurrent() - began) / 10 * 1000, footprintMB()))
        }
    }
}
