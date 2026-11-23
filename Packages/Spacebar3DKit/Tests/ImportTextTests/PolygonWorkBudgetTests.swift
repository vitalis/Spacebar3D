import Foundation
import ImportOBJ
import ModelCore
import simd
import XCTest

final class PolygonWorkBudgetTests: XCTestCase {
    /// A thick ribbon wound into a spiral: simple (no self-crossing), of `corners` corners.
    /// Nearly every corner on its inner side turns inwards, and the ears are found only
    /// at the far end of the ring, so each cut-off ear costs a scan of most of the ring and
    /// of the inward corners: close to cubic work in the corner count.
    private func spiral(corners: Int, z: Float) -> [SIMD3<Float>] {
        let half = corners / 2
        var inner: [SIMD3<Float>] = [], outer: [SIMD3<Float>] = []
        for i in 0..<half {
            let a = Float(i) * 0.05, r = 1 + a * 0.3
            inner.append(SIMD3(cos(a) * r, sin(a) * r, z))
            outer.append(SIMD3(cos(a) * (r + 0.15), sin(a) * (r + 0.15), z))
        }
        return outer + inner.reversed()
    }

    /// An OBJ of `faces` separate spiral faces of 1,000 corners each (about 1.3 MB for 40).
    private func objFile(faces: Int, corners: Int) -> Data {
        var text = ""
        for f in 0..<faces {
            for p in spiral(corners: corners, z: Float(f)) { text += "v \(p.x) \(p.y) \(p.z)\n" }
            text += "f " + (1...corners).map { String($0 + f * corners) }.joined(separator: " ") + "\n"
        }
        return Data(text.utf8)
    }

    /// The user opens (or Quick Looks) a modest OBJ whose faces are big concave outlines,
    /// and the preview hangs for minutes. The ear search has a work cap, but it is per face
    /// (64,000,000 steps, raised from 4,000,000 in d1cc175), so each such face may spend
    /// all of it: measured on the code at 0df3825, one spiral face of 1,000 corners takes
    /// 5,073,484 steps (1.26 s in a Debug build, about 250 ns per step), one of 4,000 corners
    /// reaches the whole 64,000,000 (14.1 s) and is dropped. A few MB of faces of 2,000+
    /// corners can therefore cost tens of minutes. Quick Look gives a preview seconds.
    /// Source: the review finding on PolygonTriangulation's `limit`, and measurement.
    ///
    /// Forty faces of 1,000 corners are 200,000,000 steps (about 68 s in Debug; sixty measured 100 s). Whatever the
    /// fix, a file-wide cap of 64,000,000 steps (about 14 s in Debug) or a cheaper algorithm
    /// must bring the whole import under 25 s. The bound is wall-clock because the step
    /// count is private; it is generous (the cap alone is about half of it, and a Release
    /// build is several times faster) so that only the missing file-wide limit fails it.
    func testAFileOfManyLargeConcaveFacesStaysWithinOneWholeFileBudget() throws {
        let data = objFile(faces: 40, corners: 1000)
        let start = Date()
        let scene = try OBJReader.scene(from: data)
        let seconds = Date().timeIntervalSince(start)
        let triangles = scene.meshes.flatMap(\.parts).reduce(0) { $0 + $1.triangleIndices.count / 3 }
        // The budget may spend itself on the first faces and leave later ones out; it must
        // not make the first face fail too.
        XCTAssertGreaterThanOrEqual(triangles, 998, "the first face is still triangulated")
        XCTAssertLessThan(seconds, 12, "40 faces of 1,000 corners took \(seconds) s (\(data.count) bytes of OBJ)")
    }

    /// The same hostile file, counted in steps and not seconds: one default `Budget` shared by
    /// forty spiral faces of 1,000 corners (5.07M steps each alone, 203M together) may spend at
    /// most 16,000,000 steps in all, so a hostile file opens in a few seconds in Debug and in Quick
    /// Look. Today the default is 64,000,000, spent whole (about 14 s in Debug). Each face's free
    /// allowance is not charged, and a face the budget cannot finish is fanned, never dropped.
    func testOneSharedBudgetSpendsAtMostSixteenMillionStepsOnFortyLargeFaces() throws {
        let budget = PolygonTriangulation.Budget()
        let start = budget.remaining
        var fanned = 0
        for f in 0..<40 {
            let points = spiral(corners: 1000, z: Float(f))
            let triangles = try XCTUnwrap(PolygonTriangulation.indices(count: points.count, budget: budget) { points[$0] })
            XCTAssertEqual(triangles.count, 998 * 3, "face \(f) is still given its triangles")
            if f == 0 { XCTAssertGreaterThan(budget.remaining, 0, "the first face does not use up the file's budget") }
            if budget.remaining == 0 { fanned += 1 }
        }
        let spent = start - budget.remaining
        XCTAssertLessThanOrEqual(start, 16_000_000, "the file budget starts at \(start) steps")
        XCTAssertLessThanOrEqual(spent, 16_000_000, "forty faces were charged \(spent) steps of \(start); \(fanned) of them came after it was empty")
    }

    // MARK: Small concave faces after the budget is spent

    /// Ordinary concave outlines, counter-clockwise in x-y.
    private var smallShapes: [(name: String, points: [SIMD2<Float>])] {
        let comb: [SIMD2<Float>] = (0..<5).flatMap { t -> [SIMD2<Float>] in let x = Float(t) * 2; return [SIMD2(x, 0), SIMD2(x, 3), SIMD2(x + 1, 3), SIMD2(x + 1, 1)] } + [SIMD2(10, 0), SIMD2(10, -1), SIMD2(0, -1)]
        let counterClockwise = Array(comb.reversed())
        return [("L", [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 2), SIMD2(2, 2), SIMD2(2, 4), SIMD2(0, 4)]),
                ("notched hexagon", [SIMD2(0, 0), SIMD2(4, 0), SIMD2(5, 2), SIMD2(4, 4), SIMD2(0, 4), SIMD2(1, 2)]),
                ("arrow", [SIMD2(0, 1), SIMD2(3, 1), SIMD2(3, 0), SIMD2(5, 2), SIMD2(3, 4), SIMD2(3, 3), SIMD2(0, 3)]),
                ("comb of 23 corners", counterClockwise)]
    }

    private func area(_ p: [SIMD2<Float>]) -> Float {
        (0..<p.count).reduce(0) { $0 + (p[$1].x * p[($1 + 1) % p.count].y - p[($1 + 1) % p.count].x * p[$1].y) } / 2
    }

    /// Each small face's cost in steps, read from a fresh `Budget` (its `remaining` falls by the
    /// steps spent). Measured on this tree: see the assertion message. A file of ordinary
    /// concave faces must be able to afford very many of them within 64,000,000 steps.
    func testOrdinaryConcaveFacesCostFewStepsEach() throws {
        for shape in smallShapes {
            let budget = PolygonTriangulation.Budget()
            let before = budget.remaining
            let triangles = try XCTUnwrap(PolygonTriangulation.indices(count: shape.points.count, budget: budget) { SIMD3(shape.points[$0], 0) })
            let steps = before - budget.remaining
            XCTAssertEqual(triangles.count, (shape.points.count - 2) * 3)
            XCTAssertLessThan(steps, 2_000, "\(shape.name) of \(shape.points.count) corners cost \(steps) steps; 64M would cover \(64_000_000 / max(steps, 1)) of them")
        }
    }

    /// Hostile spirals first spend the file's whole allowance; later small ordinary concave
    /// faces (an L, a notched hexagon, an arrow, a comb) must still be cut along their
    /// outlines. A face fanned from its first corner draws triangles outside its outline,
    /// which the user sees as spikes and filled-in notches. Source: the Budget's
    /// `if let budget, budget.remaining == 0 { return fan() }` in PolygonTriangulation.
    /// A fan has the right signed area for any simple polygon, so each triangle is checked
    /// to turn the polygon's way and the absolute areas must sum to the polygon's area.
    /// The whole file must also stay in 25 s (the spirals alone use the 64M allowance,
    /// about 14 s in Debug).
    func testSmallConcaveFacesAfterTheBudgetIsSpentAreStillCutAlongTheirOutline() throws {
        let spirals = 14, copies = 50
        var text = ""
        for f in 0..<spirals {
            for p in spiral(corners: 1000, z: Float(f)) { text += "v \(p.x) \(p.y) \(p.z)\n" }
            text += "f " + (1...1000).map { String($0 + f * 1000) }.joined(separator: " ") + "\n"
        }
        var next = spirals * 1000 + 1
        for k in 0..<copies {
            for shape in smallShapes {
                for p in shape.points { text += "v \(p.x + Float(k) * 20) \(p.y + 5 + Float(smallShapes.firstIndex { $0.name == shape.name }!) * 20) 100\n" }
                text += "f " + (next..<(next + shape.points.count)).map(String.init).joined(separator: " ") + "\n"
                next += shape.points.count
            }
        }
        let start = Date()
        let scene = try OBJReader.scene(from: Data(text.utf8))
        let seconds = Date().timeIntervalSince(start)

        var wrong: [String: Int] = [:], areaSum: [String: Float] = [:], count: [String: Int] = [:]
        for part in scene.meshes.flatMap(\.parts) {
            let t = part.triangleIndices
            for i in stride(from: 0, to: t.count, by: 3) {
                let a = part.positions[Int(t[i])], b = part.positions[Int(t[i + 1])], c = part.positions[Int(t[i + 2])]
                guard a.z == 100 else { continue }
                let key = "\(Int((a.x / 20).rounded(.down))),\(Int((a.y / 20).rounded(.down)))"
                let signed = ((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
                if signed < -1e-4 { wrong[key, default: 0] += 1 }
                areaSum[key, default: 0] += abs(signed)
                count[key, default: 0] += 1
            }
        }
        var bad: [String] = []
        for k in 0..<copies {
            for (row, shape) in smallShapes.enumerated() {
                let key = "\(k),\(row)"
                let want = area(shape.points)
                if (areaSum[key] ?? 0) < want - 1e-3 || (areaSum[key] ?? 0) > want + 1e-3 || wrong[key, default: 0] > 0 { bad.append("\(shape.name) #\(k): area \(areaSum[key] ?? 0) of \(want), \(wrong[key, default: 0]) turned over") }
            }
        }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) of \(copies * smallShapes.count) small faces are not cut along their outline, e.g. \(bad.prefix(3))")
        XCTAssertLessThan(seconds, 25, "the file took \(seconds) s")
    }
}
