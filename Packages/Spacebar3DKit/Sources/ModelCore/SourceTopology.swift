/// Face statistics as the file's author made them: a quad counts once, although every
/// renderer draws it as two triangles.
public struct SourceTopology: Equatable, Sendable {
    /// Polygons as authored (a quad counts once).
    public var faces = 0
    /// Positions as authored (before they are split per face corner).
    public var vertices = 0
    public var triangles = 0
    public var quads = 0
    /// Polygons with five or more corners.
    public var ngons = 0
    /// Corner count of every polygon, in file order, one list per geometry in the file.
    /// Lets the wireframe outline the file's polygons instead of the triangles they become.
    public var polygons: [[Int]] = []

    public init(faces: Int = 0, vertices: Int = 0, triangles: Int = 0, quads: Int = 0, ngons: Int = 0, polygons: [[Int]] = []) {
        self.faces = faces; self.vertices = vertices; self.triangles = triangles; self.quads = quads; self.ngons = ngons; self.polygons = polygons
    }

    /// Counts one more polygon with the given number of corners, in the current geometry.
    public mutating func addFace(corners: Int) {
        guard corners >= 3 else { return }
        if polygons.isEmpty { polygons.append([]) }
        polygons[polygons.count - 1].append(corners)
        faces += 1
        if corners == 3 { triangles += 1 } else if corners == 4 { quads += 1 } else { ngons += 1 }
    }

    /// The one-word description shown in the statistics: "Triangle", "Quad", "N-gon",
    /// "Mixed", or a dash when there are no faces.
    public var label: String { topologyLabel(triangles: triangles, quads: quads, ngons: ngons) }
}

public func topologyLabel(triangles: Int, quads: Int, ngons: Int) -> String {
    let kinds = [triangles > 0, quads > 0, ngons > 0].filter { $0 }.count
    if kinds == 0 { return "–" }
    if kinds > 1 { return L10n.text("Mixed") }
    return quads > 0 ? L10n.text("Quad") : ngons > 0 ? L10n.text("N-gon") : L10n.text("Triangle")
}
