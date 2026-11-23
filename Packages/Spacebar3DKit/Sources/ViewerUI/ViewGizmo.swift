import CoreGraphics
import RenderMetal
import simd

/// The camera axes the gizmo is drawn from.
struct GizmoBasis: Equatable {
    var right = SIMD3<Float>(1, 0, 0)
    var up = SIMD3<Float>(0, 1, 0)
    var back = SIMD3<Float>(0, 0, 1)
}

struct GizmoHandle: Equatable {
    var preset: ViewPreset
    var axis: Character
    var positive: Bool
    /// Position in -1...1 from the gizmo's centre, y pointing down.
    var point: CGPoint
    /// Larger is nearer the viewer.
    var depth: Float
}

/// The pure part of the axis gizmo: where the six handles are and which one a click hits.
enum ViewGizmo {
    /// The six handles, farthest first (the order to draw them in).
    static func handles(_ basis: GizmoBasis) -> [GizmoHandle] {
        ViewPreset.allCases.map { preset in
            let d = preset.direction
            let axis: Character = d.x != 0 ? "X" : d.y != 0 ? "Y" : "Z"
            let positive = (d.x + d.y + d.z) > 0
            return GizmoHandle(
                preset: preset, axis: axis, positive: positive,
                point: CGPoint(x: CGFloat(simd_dot(d, basis.right)), y: CGFloat(-simd_dot(d, basis.up))),
                depth: simd_dot(d, basis.back))
        }.sorted { $0.depth < $1.depth }
    }

    /// The view to look along for a click at `point` (same unit space as the handles), or
    /// nil when no handle is within `radius`. The nearest handle wins where they overlap.
    static func hit(_ point: CGPoint, handles: [GizmoHandle], radius: CGFloat) -> ViewPreset? {
        handles.reversed().first { hypot($0.point.x - point.x, $0.point.y - point.y) <= radius }?.preset
    }
}
