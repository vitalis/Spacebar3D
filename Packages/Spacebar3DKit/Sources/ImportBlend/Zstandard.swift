import CZstd
import Foundation

/// Unpacks Zstandard data, which Blender 3.0 and later use for files saved compressed,
/// with the reference library's decoder (Sources/CZstd). A file may be several frames one
/// after another, with frames to skip between them; all are unpacked into one result.
enum Zstandard {
    enum Failure: Error, Equatable {
        case damaged
        case tooLarge
    }

    static func isCompressed(_ data: Data) -> Bool { data.count >= 4 && data.prefix(4).elementsEqual([0x28, 0xb5, 0x2f, 0xfd]) }

    /// `limit` is the most the result may be.
    static func decode(_ data: Data, limit: Int) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw Failure.damaged }
        defer { ZSTD_freeDStream(stream) }
        // The largest window a frame may ask for: 128 MB, the library's own default limit.
        ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 27)
        let step = max(ZSTD_DStreamOutSize(), 1 << 20)
        var chunk = [UInt8](repeating: 0, count: step)
        var out = Data()
        // What a single frame says it unpacks to, as a first guess at the room needed.
        let declared = data.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, $0.count) }
        if declared <= UInt64(limit) { out.reserveCapacity(Int(declared)) }
        return try data.withUnsafeBytes { raw -> Data in
            var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            var pending = 0
            while true {
                var produced = 0
                try chunk.withUnsafeMutableBytes { room in
                    var output = ZSTD_outBuffer(dst: room.baseAddress, size: room.count, pos: 0)
                    pending = ZSTD_decompressStream(stream, &output, &input)
                    guard ZSTD_isError(pending) == 0 else { throw Failure.damaged }
                    produced = output.pos
                }
                guard produced <= limit - out.count else { throw Failure.tooLarge }
                out.append(contentsOf: chunk[0..<produced])
                if input.pos >= input.size && produced < step {
                    // Nothing left to read and nothing held back: done, unless a frame was cut short.
                    guard pending == 0 else { throw Failure.damaged }
                    return out
                }
            }
        }
    }
}
