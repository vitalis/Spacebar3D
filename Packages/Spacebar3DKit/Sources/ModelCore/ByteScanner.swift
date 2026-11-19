import Foundation

/// Walks the bytes of a text file token by token without copying it. For the text formats
/// (PLY, OBJ), whose files run to hundreds of megabytes.
public struct ByteScanner {
    public let bytes: UnsafeBufferPointer<UInt8>
    public var at: Int

    public init(_ bytes: UnsafeBufferPointer<UInt8>, at: Int = 0) { self.bytes = bytes; self.at = at }

    public var isAtEnd: Bool { at >= bytes.count }

    @inline(__always) static func isBlank(_ b: UInt8) -> Bool { isSpace(b) && b != 0x0a }
    @inline(__always) static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || (0x09...0x0d).contains(b) }

    /// The next token on the current line, or nil at the end of the line (which is not passed).
    public mutating func tokenOnLine() -> Range<Int>? {
        while at < bytes.count, Self.isBlank(bytes[at]) { at += 1 }
        guard at < bytes.count, bytes[at] != 0x0a else { return nil }
        let start = at
        while at < bytes.count, !Self.isSpace(bytes[at]) { at += 1 }
        return start..<at
    }

    /// The next token, wherever it is; nil at the end of the data.
    public mutating func token() -> Range<Int>? {
        while at < bytes.count, Self.isSpace(bytes[at]) { at += 1 }
        guard at < bytes.count else { return nil }
        let start = at
        while at < bytes.count, !Self.isSpace(bytes[at]) { at += 1 }
        return start..<at
    }

    /// Moves past the end of the current line.
    public mutating func skipLine() {
        while at < bytes.count, bytes[at] != 0x0a { at += 1 }
        if at < bytes.count { at += 1 }
    }

    /// The rest of the current line as text, without the line ending; moves past it.
    public mutating func restOfLine() -> String {
        while at < bytes.count, Self.isBlank(bytes[at]) { at += 1 }
        let start = at
        while at < bytes.count, bytes[at] != 0x0a { at += 1 }
        var end = at
        while end > start, Self.isBlank(bytes[end - 1]) { end -= 1 }
        if at < bytes.count { at += 1 }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    }

    public func equals(_ token: Range<Int>, _ word: StaticString) -> Bool {
        guard token.count == word.utf8CodeUnitCount else { return false }
        return memcmp(bytes.baseAddress! + token.lowerBound, word.utf8Start, token.count) == 0
    }

    public func string(_ token: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[token]), as: UTF8.self)
    }

    /// A token as a number; nil when it is not one.
    public func number(_ token: Range<Int>) -> Double? {
        guard !token.isEmpty, token.count < 64 else { return nil }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            memcpy(buffer.baseAddress!, bytes.baseAddress! + token.lowerBound, token.count)
            buffer[token.count] = 0
            var stop: UnsafeMutablePointer<CChar>?
            let value = strtod(buffer.baseAddress!, &stop)
            return stop == buffer.baseAddress! ? nil : value
        }
    }

    /// A token as a whole number (optionally signed), reading digits up to `end` or the
    /// first other character; nil when it does not start with one.
    public func integer(from start: Int, to end: Int) -> (value: Int, next: Int)? {
        var i = start, negative = false
        if i < end, bytes[i] == 0x2d || bytes[i] == 0x2b { negative = bytes[i] == 0x2d; i += 1 }
        let first = i
        var value = 0
        while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int(bytes[i] - 0x30))
            if o1 || o2 { return nil }
            value = a; i += 1
        }
        return i > first ? (negative ? -value : value, i) : nil
    }
}
