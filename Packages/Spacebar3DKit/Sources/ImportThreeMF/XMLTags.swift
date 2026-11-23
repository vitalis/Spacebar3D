import Foundation

/// Walks the tags of an XML document byte by byte, with their attributes. 3MF model files
/// are written by programs, one element per vertex and per triangle, millions of them;
/// this reads only what those need: tag names and quoted attribute values. Text between
/// tags, comments, processing instructions and CDATA are passed over.
struct XMLTags {
    let bytes: UnsafeBufferPointer<UInt8>
    private var at = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    struct Tag {
        /// The name without any "prefix:".
        var name: Range<Int>
        var closing: Bool        // </name>
        var selfClosing: Bool    // <name ... />
        /// Where the attributes start and the tag ends.
        var attributes: Range<Int>
    }

    mutating func next() -> Tag? {
        let end = bytes.count
        while at < end {
            guard bytes[at] == 0x3c else { at += 1; continue }
            at += 1
            guard at < end else { return nil }
            if bytes[at] == 0x21 {      // <!-- ... -->, <![CDATA[ ... ]]>, <!DOCTYPE ...>
                if at + 2 < end, bytes[at + 1] == 0x2d, bytes[at + 2] == 0x2d {
                    at += 3
                    while at + 2 < end, !(bytes[at] == 0x2d && bytes[at + 1] == 0x2d && bytes[at + 2] == 0x3e) { at += 1 }
                    at = min(end, at + 3)
                } else if at + 7 < end, bytes[at + 1] == 0x5b {
                    while at + 2 < end, !(bytes[at] == 0x5d && bytes[at + 1] == 0x5d && bytes[at + 2] == 0x3e) { at += 1 }
                    at = min(end, at + 3)
                } else {
                    while at < end, bytes[at] != 0x3e { at += 1 }
                }
                continue
            }
            if bytes[at] == 0x3f {      // <? ... ?>
                while at + 1 < end, !(bytes[at] == 0x3f && bytes[at + 1] == 0x3e) { at += 1 }
                at = min(end, at + 2)
                continue
            }
            var closing = false
            if bytes[at] == 0x2f { closing = true; at += 1 }
            var nameStart = at
            while at < end, !Self.isSpace(bytes[at]), bytes[at] != 0x3e, bytes[at] != 0x2f {
                if bytes[at] == 0x3a { nameStart = at + 1 }
                at += 1
            }
            let name = nameStart..<at
            let attributesStart = at
            // To the end of the tag, minding quoted values (which may hold '>').
            var quote: UInt8 = 0
            while at < end {
                let b = bytes[at]
                if quote != 0 { if b == quote { quote = 0 } } else if b == 0x22 || b == 0x27 { quote = b } else if b == 0x3e { break }
                at += 1
            }
            guard at < end else { return nil }
            let selfClosing = at > attributesStart && bytes[at - 1] == 0x2f
            let attributes = attributesStart..<(selfClosing ? at - 1 : at)
            at += 1
            guard !name.isEmpty else { continue }
            return Tag(name: name, closing: closing, selfClosing: selfClosing, attributes: attributes)
        }
        return nil
    }

    @inline(__always) static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || (0x09...0x0d).contains(b) }

    func name(_ tag: Tag, is word: StaticString) -> Bool {
        tag.name.count == word.utf8CodeUnitCount && memcmp(bytes.baseAddress! + tag.name.lowerBound, word.utf8Start, tag.name.count) == 0
    }

    /// The value of the attribute with this name (any "prefix:" on it ignored), as a range of bytes.
    func attribute(_ tag: Tag, _ wanted: StaticString) -> Range<Int>? {
        var from = tag.attributes.lowerBound
        return attribute(tag, wanted, from: &from)
    }

    /// The same, for tags read by the million: the search starts at `from`, which is
    /// left behind the attribute found, so that attributes asked for in the order they
    /// are written are each found at once. One that is not there after `from` is looked
    /// for from the start.
    func attribute(_ tag: Tag, _ wanted: StaticString, from: inout Int) -> Range<Int>? {
        let start = from
        if let found = scan(tag, wanted, from: &from) { return found }
        guard start > tag.attributes.lowerBound else { return nil }
        from = tag.attributes.lowerBound
        if let found = scan(tag, wanted, from: &from) { return found }
        from = start
        return nil
    }

    private func scan(_ tag: Tag, _ wanted: StaticString, from: inout Int) -> Range<Int>? {
        var i = from
        let end = tag.attributes.upperBound
        while i < end {
            while i < end, Self.isSpace(bytes[i]) { i += 1 }
            var nameStart = i
            while i < end, bytes[i] != 0x3d, !Self.isSpace(bytes[i]) {
                if bytes[i] == 0x3a { nameStart = i + 1 }
                i += 1
            }
            let nameEnd = i
            while i < end, bytes[i] != 0x3d { i += 1 }
            i += 1
            while i < end, Self.isSpace(bytes[i]) { i += 1 }
            guard i < end, bytes[i] == 0x22 || bytes[i] == 0x27 else { return nil }
            let quote = bytes[i]
            i += 1
            let valueStart = i
            while i < end, bytes[i] != quote { i += 1 }
            guard i < end else { return nil }
            if nameEnd - nameStart == wanted.utf8CodeUnitCount, memcmp(bytes.baseAddress! + nameStart, wanted.utf8Start, nameEnd - nameStart) == 0 {
                from = i + 1
                return valueStart..<i
            }
            i += 1
        }
        return nil
    }

    func string(_ range: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self) }

    private static let powersOfTen: [Double] = (0...22).map { pow(10, Double($0)) }

    func number(_ range: Range<Int>) -> Double? {
        guard !range.isEmpty, range.count < 64 else { return nil }
        // Plain decimals, as nearly every file writes them: up to 15 digits divide
        // exactly rounded. Anything else goes the slow way.
        plain: do {
            var i = range.lowerBound
            let end = range.upperBound
            var negative = false
            if bytes[i] == 0x2d { negative = true; i += 1 } else if bytes[i] == 0x2b { i += 1 }
            var mantissa: UInt64 = 0
            var digits = 0, decimals = 0
            var point = false
            while i < end {
                let b = bytes[i]
                if b >= 0x30, b <= 0x39 {
                    guard digits < 15 else { break plain }
                    mantissa = mantissa * 10 + UInt64(b - 0x30)
                    digits += 1
                    if point { decimals += 1 }
                } else if b == 0x2e, !point {
                    point = true
                } else {
                    break plain
                }
                i += 1
            }
            guard digits > 0, digits <= 15 else { break plain }
            let value = Double(mantissa) / Self.powersOfTen[decimals]
            return negative ? -value : value
        }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            memcpy(buffer.baseAddress!, bytes.baseAddress! + range.lowerBound, range.count)
            buffer[range.count] = 0
            var stop: UnsafeMutablePointer<CChar>?
            let value = strtod(buffer.baseAddress!, &stop)
            return stop == buffer.baseAddress! ? nil : value
        }
    }

    /// A whole number that is not negative, or nil.
    func index(_ range: Range<Int>) -> Int? {
        guard !range.isEmpty, range.count <= 10 else { return nil }
        var value = 0
        for i in range {
            guard bytes[i] >= 0x30, bytes[i] <= 0x39 else { return nil }
            value = value * 10 + Int(bytes[i] - 0x30)
        }
        return value
    }
}
