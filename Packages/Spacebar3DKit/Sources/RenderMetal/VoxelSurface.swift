import Metal
import simd

/// Samples the surface in one world-space grid so neighboring materials use the same cube size.
extension GPUScene {
  func makeVoxelParts() -> [Part] {
    let side = max(framing.size.max(), 0.000001) / 40
    let origin = framing.center - framing.size / 2
    typealias Cell = SIMD3<Int32>
    var occupied = Set<Cell>()
    var output: [Part] = []

    for source in parts {
      let vertices = source.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
      let indices = source.indexBuffer?.contents().assumingMemoryBound(to: UInt32.self)
      let uvs = source.uvBuffer?.contents().assumingMemoryBound(to: SIMD2<Float>.self)
      let colors = source.colorBuffer?.contents().assumingMemoryBound(to: SIMD4<UInt8>.self)
      var samples: [(Cell, SIMD2<Float>, SIMD4<UInt8>)] = []
      func vertex(_ corner: Int) -> Int { indices.map { Int($0[corner]) } ?? corner }
      func position(_ i: Int) -> SIMD3<Float> {
        let w = source.model * SIMD4(vertices[i * 6], vertices[i * 6 + 1], vertices[i * 6 + 2], 1)
        return (SIMD3(w.x, w.y, w.z) - origin) / side
      }
      func sample(_ p: SIMD3<Float>, _ a: Int, _ b: Int, _ c: Int, _ weights: SIMD3<Float>) {
        guard abs(p.x) < 1_000_000, abs(p.y) < 1_000_000, abs(p.z) < 1_000_000,
          occupied.count < 160000
        else { return }
        let cell = Cell(floor(p))
        guard occupied.insert(cell).inserted else { return }
        let uv = uvs.map { $0[a] * weights.x + $0[b] * weights.y + $0[c] * weights.z } ?? .zero
        var color = SIMD4<UInt8>(repeating: 255)
        if let colors {
          let rgb =
            SIMD4<Float>(colors[a]) * weights.x + SIMD4<Float>(colors[b]) * weights.y + SIMD4<
              Float
            >(colors[c]) * weights.z
          color = SIMD4<UInt8>(
            simd_clamp(rgb.rounded(.toNearestOrAwayFromZero), .zero, SIMD4(repeating: 255)))
        }
        samples.append((cell, uv, color))
      }
      if source.isPoints {
        source.forEachDrawnVertex { i in sample(position(i), i, i, i, SIMD3(1, 0, 0)) }
      } else {
        for corner in stride(from: 0, to: source.drawnVertexCount - 2, by: 3) {
          let a = vertex(corner)
          let b = vertex(corner + 1)
          let c = vertex(corner + 2)
          let p = position(a)
          let q = position(b)
          let r = position(c)
          let span = max(simd_length(q - p), simd_length(r - p), simd_length(r - q))
          guard span.isFinite else { continue }
          let steps = Int(max(1, min(96, ceil(span * 1.5))))
          for row in 0...steps {
            for col in 0...(steps - row) {
              let u = Float(row) / Float(steps)
              let v = Float(col) / Float(steps)
              sample(p + (q - p) * u + (r - p) * v, a, b, c, SIMD3(1 - u - v, u, v))
            }
          }
        }
      }
      var mesh: [Float] = []
      var texcoords: [SIMD2<Float>] = []
      var tint: [SIMD4<UInt8>] = []
      var triangles: [UInt32] = []
      var edges: [UInt32] = []
      for (cell, uv, color) in samples {
        for axis in 0..<3 {
          for sign: Int32 in [-1, 1] {
            var normal = Cell.zero
            normal[axis] = sign
            guard !occupied.contains(cell &+ normal) else { continue }
            let base = UInt32(mesh.count / 6)
            for (u, v): (Float, Float) in [(0, 0), (1, 0), (1, 1), (0, 1)] {
              var corner = SIMD3<Float>(cell)
              if sign > 0 { corner[axis] += 1 }
              corner[(axis + 1) % 3] += sign > 0 ? u : v
              corner[(axis + 2) % 3] += sign > 0 ? v : u
              let world = origin + corner * side
              mesh += [
                world.x, world.y, world.z, Float(normal.x), Float(normal.y), Float(normal.z),
              ]
              if uvs != nil { texcoords.append(uv) }
              if colors != nil { tint.append(color) }
            }
            triangles += [base, base + 1, base + 2, base, base + 2, base + 3]
            edges += [base, base + 1, base + 1, base + 2, base + 2, base + 3, base + 3, base]
          }
        }
      }
      func buffer<T>(_ values: [T]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes {
          device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
      }
      guard let positions = buffer(mesh), let faces = buffer(triangles) else { continue }
      let part = Part(
        vertexBuffer: positions, vertexCount: mesh.count / 6, indexBuffer: faces,
        indexCount: triangles.count, model: matrix_identity_float4x4, material: source.material,
        faceSizes: nil)
      part.uvBuffer = buffer(texcoords)
      part.colorBuffer = buffer(tint)
      part.texture = source.texture
      part.worldCenter = source.worldCenter
      part.wireIndexBuffer = buffer(edges)
      part.wireIndexCount = edges.count
      output.append(part)
    }
    return output
  }
}
