import Foundation
import ModelCore
import simd

/// Reads the material library of an OBJ model (`.mtl`).
///
/// Kept for each material: its colour (`Kd`), how see-through it is (`d`, or `Tr` counted
/// the other way), the colour image (`map_Kd`, options before the name passed over), and
/// the roughness and metalness some exporters add (`Pr`, `Pm`). Highlights, glow, bump
/// maps and the other images are not read.
public enum MTLReader {
    public struct Entry: Equatable, Sendable {
        public var colour: SIMD3<Float>?
        public var opacity: Float = 1
        /// The colour image, by the name the library uses for it.
        public var colourImage: String?
        public var roughness: Float?
        public var metallic: Float?

        func material(named name: String) -> ModelScene.Material {
            var material = OBJReader.neutral
            material.name = name
            if let colour { material.baseColor = SIMD4(colour, 1) }
            material.opacity = opacity
            if let roughness { material.roughness = roughness }
            if let metallic { material.metallic = metallic }
            material.authoredPBR = roughness != nil || metallic != nil
            return material
        }
    }

    public struct Library: Equatable, Sendable {
        public var materials: [String: Entry] = [:]

        public init() {}

        /// Adds another library; a name already there keeps its first meaning.
        public mutating func merge(_ other: Library) {
            materials.merge(other.materials) { first, _ in first }
        }
    }

    /// Libraries larger than this are not read.
    static let maxBytes = 16 * 1024 * 1024

    public static func library(from data: Data) -> Library {
        guard data.count <= maxBytes else { return Library() }
        return data.withUnsafeBytes { raw in library(from: raw.bindMemory(to: UInt8.self)) }
    }

    private static func library(from bytes: UnsafeBufferPointer<UInt8>) -> Library {
        var scanner = ByteScanner(bytes)
        var library = Library()
        var name: String?
        var entry = Entry()
        func unit(_ value: Double) -> Float { Float(min(1, max(0, value.isFinite ? value : 0))) }
        func close() {
            if let name, library.materials[name] == nil { library.materials[name] = entry }
        }
        while !scanner.isAtEnd {
            guard let word = scanner.tokenOnLine() else { scanner.skipLine(); continue }
            if scanner.equals(word, "newmtl") {
                close()
                name = scanner.restOfLine()
                entry = Entry()
                continue
            }
            if scanner.equals(word, "Kd") {
                var values: [Double] = []
                while let token = scanner.tokenOnLine(), let value = scanner.number(token) { values.append(value) }
                // One value is a grey; "spectral" and "xyz" colours are not read.
                if values.count >= 3 { entry.colour = SIMD3(unit(values[0]), unit(values[1]), unit(values[2])) }
                else if values.count == 1 { entry.colour = SIMD3(repeating: unit(values[0])) }
            } else if scanner.equals(word, "d") {
                // "d -halo 0.5" exists too.
                while let token = scanner.tokenOnLine() { if let value = scanner.number(token) { entry.opacity = unit(value); break } }
            } else if scanner.equals(word, "Tr") {
                if let token = scanner.tokenOnLine(), let value = scanner.number(token) { entry.opacity = 1 - unit(value) }
            } else if scanner.equals(word, "Pr") {
                if let token = scanner.tokenOnLine(), let value = scanner.number(token) { entry.roughness = unit(value) }
            } else if scanner.equals(word, "Pm") {
                if let token = scanner.tokenOnLine(), let value = scanner.number(token) { entry.metallic = unit(value) }
            } else if scanner.equals(word, "map_Kd") {
                entry.colourImage = imageName(scanner.restOfLine())
                continue
            }
            scanner.skipLine()
        }
        close()
        return library
    }

    /// How many values follow each option that can stand before an image's name.
    private static let optionValues: [String: Int] = [
        "-blendu": 1, "-blendv": 1, "-cc": 1, "-clamp": 1, "-bm": 1, "-boost": 1, "-imfchan": 1, "-texres": 1, "-type": 1, "-mm": 2,
        "-o": 3, "-s": 3, "-t": 3,
    ]

    /// The image's name from the rest of a map line: the options first, then the name,
    /// which may hold spaces.
    static func imageName(_ line: String) -> String? {
        var words = line.split(separator: " ", omittingEmptySubsequences: true)[...]
        while let first = words.first, let count = optionValues[String(first)] {
            words = words.dropFirst()
            if count == 3 {
                // One to three numbers.
                var taken = 0
                while taken < 3, let next = words.first, Double(next) != nil, words.count > 1 { words = words.dropFirst(); taken += 1 }
            } else {
                words = words.dropFirst(min(count, max(0, words.count - 1)))
            }
        }
        let name = words.joined(separator: " ")
        return name.isEmpty ? nil : name
    }
}
