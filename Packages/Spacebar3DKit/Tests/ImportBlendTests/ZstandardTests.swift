import CryptoKit
import Foundation
@testable import ImportBlend
import XCTest

/// The Zstandard decoder is the reference library's; these check how it is driven: several
/// frames, frames to skip, the size limit, and data that is cut short or altered.
final class ZstandardTests: XCTestCase {
    /// 5,646 bytes of words, packed by the zstd tool at its level 19 with a checksum, and at level 1 without.
    private static let strong = Data(base64Encoded: "KLUv/WQOFT0kAHJJEhWQOcsB2Ic+IQDsL7a7iy4kHI0tETPt3a1WW9d3v3u9elV37VZ3a1e9kSOp2jiLxGFENM2CHEkAcCAGxWE+AoWwKEyiOZzC4ASCN6hizpJKewciGAgIiQSiqk8fImAMhAI6rIQMk9IkjQEimCisnvR+Y0f9FeC5c3VphI9eD8QNTY3rlYD1bHdLl1z9jsmcgsCV2Od1miHjUBO773QkfE2kkUBB1z6g7sae8VNLF26b9f6ZdLqG2/HnrQeHLLCVq0DN44NdgL9Dd97RhOHO/ZGKh8KVNu6Ip0rBlaTtdy574Bl+Uucz0SR8iFDNh7Obg4fRcpRiCUPf2vISQdrXXsHCNogVFYLKkB0gzSd/X+d2il+x6yh54fvqEd8omXYEq1xCykoZYjqitFvRGzDYV3qvLSmiKmDgPtE177VY2TfO6KLSgz2xd1ScCdX6bx+R/G3eOnZShjPVAf3r9rS33hRS7l01wAdSTE0KRISAOnpsed2thpJ8oa6CjjnUJV2ghoqpotrxyZyGFwgGk/UJV7k0OwKMiAij5333hmJklb3BC60oABLZ9Rb0jOHrEqqmHyHgAaCnxzOhKWeCeqC2WlW3U3BwhBJo0+8doQ7AZJT9l3N0jP29alBfo/vL95BOZrup4ah8GB+QfC8JxRkpvMnG/4DmH+iEc4DEhJgmjsdE0UxLe4yoC/ECj+x4+L9BsA/tZLTvYt+YUTdqvxqHIgK7EOh/IvFFvJqFtsebVsuWRv0v+twwZewkh66qMvwV47LYqSczdZ2k7JcrRaQ3DzK7RvYQWDZDPFVFwCkve3+sJHI3A5eeyKQu/Zi4/SU4nUrxR5oOmepyb5mE5hN1N8oIAvCHitliwwmXJVC/sYRckOrFkyy7aWUF7yzhCTJCCjuHmMSJ8ro28wjl4vt4loZKMm38b48b1A6mQVmqEvZuIBZYCBr1BStnJRKJhEF86jbQFw3e09ON/sPYX3twh3hjyOd233mPDkMNkW2rBQZe25oQv1gYzRw8IsJfh3WWwaCTm6+/i9FrwRkeF4NK7gnQBn7MKJFT/lIOa6xCPTCUKErFJ12GFALiB4EuLkSqsiAzY6a8OvkL1ba9LgTvU2iZCSAhgzC00kHcNRDEhachk4Iy2c0RjWVruFY/ltQBmjuJSSqCrTaZ0Na0gAwH07mSi+wn010mxi68dqFrMtkmKy3jqesXMul8lvYap0tkk/+zWw5P0miUU3i3DxyUIIANwkabf3l7VHVtAZ5UYkx7TO89/Y2rpHnMZt+BVk6KLFmvkZWb9orANSpQPoVyemTYN49pwutPVv8RmSd74xaenvsAiYxWo7azHrECWltK0jqkyOkibv2CFdFRjgEROBdgiKM8xA7yVEYqPiA55vPgVQZ4jZVJyKqN2FCyYwJz1HNHRLZwdOgBWbqkt1a15c4HrxGCjlH6RrxxdZmyKH2lCXrRKFV7/cEhNSdEBTVoItY1UJMTIDV1II8In32Z3joUBawn/VMJMFzlWCQDu7ixVB7N13PDZr39KixikNUrTiNiagW0Ezbu")!
    private static let fast = Data(base64Encoded: "KLUv/WAOFZ0tANZRLRWgpVAHH30miLx1CbOhKjNv0lW/eqIpACcAKACZ6WQYMxF8HXiA4AJdmUkE38pMZ/wp/ykXwYcGV2hw1Z4Mk4YSJMBPecOcDIMGV2hw9VO+MtMZT/kptzP2jD0jGaZocCWC74wnw5zRRPDZCmhwZT/lIvjQ4OqMKzORYUTwrcwkgo8MY6f8jGYnwxQNrn7K25WZTgIi+ETwtdae0c5o1jOanbGtWWtnbM9Y6xnNujKTWc1WZgqC1qgCL5mSQmVjzzIIIDgommi6tvYSQKDhRF95NE1j7Dja7s6hNSMcSeAdDt9w49Z53CJtbix932/QQRa7Cer0qMesBwpxifC7KXJEQEr3smVTihqWymn0JB3QMEvSN5YgR/PQf20DTQY4mx7PoYabfQWcFdm/2DwzCtoNCFQRbWC4JFlG5Vjc/pD5oDXosLED7XyryJt4aBjlRBYpbC4oWfG2aI4JXmrjeY7nzOzjyaRmVeW3TihCgtaMiCHeIGyGyCxTkzg2/h7gFgOii/CisAAf2yJBrAFYOsSKU67V71B4TDk8uA8xU0awzUqWAjckCHO1mBGnFYgY0IaKiAxfKyEOXG+YNXmIBxiYjRfO8ORqn1URLU6FKZQrogKVboxdVZiDYFHGLt/ie2Agh8PufS/ydMuZL+obQWhtkwWP2cMOYH6Jbgk1dgI4136RFtKd+eWQe+LrvfOLtMb8XgPNOyPg4/UAIJ4I5ugLWtdGFFYK5KJhtzrlOF+qXfEyCDXhclV4lF7f50k0Z62YJWNrBH86HqJcmaqN3LD2uoXDPVkqNhnCQTZ74yhAG9WUVwCQJoc36QZhm6rI+3rreznuOQLj4WmSOMxVYNkChcHqoKgbC4BvNOTGK3qEkuDEe9Ez0wks4TP9TBaE4AlX7+NWghvZS02uWJ75wAlH4la1K40S/AUYq2VyQpJUmsGg/g6iXHYAQfS0Ff7/+AfAfH3+TcgXpNcjZ8rH/RsnDiBJZnCRunx2pIzcLAMFIaji1qosAYDW1wLr7I3WNWW1mjwXJA2jVvGgUbCjBsMDapj6MsU+4W1UbHwk0mSqi2W95ewNZyqE5EtCMTRfZPOs+dTNSFIGs81Sqo/O+aBYIAGDMOBGPSt5yGKirMsisBsDe6GBKnueWaSL4SLjrZfthwBLQtuWZg7ZH18QNJKsi9ku4c8ewX67acA19run0QUBqaLM4TAEhYDM25yAfog+gg9RDUMj+tdbzmib7FXxhZXXimyECI3g5SDGyrvXOgVD6RS2ILhj3fHzkpFm/A829DWzmfHMjigsvZ2ohImpas+8clQwhEDQfOTnQ0uA1i0+2ppgUlQhVwaU+AllDf8x9/meM3dNIXe2xV86tDO/wxR7slgVPKC9NcxceDHI2fBCn0dz9HXAmy5RX8grLzBhaNOAlaCWREfyscohPJFhwEKEn8DEPWIY4DE1inmUv6srxqgOJyTavQQphrbpgfIzdkrP/pYdn129VvGrYpEZNG4Gecd3MweLYI64FA4Bn+WCr7kk27eqlDmsMFDOIUmQCDKHHsuu4mcWkmhwhpQU2C3r9Ysv+6oRfxFNs4N47i851N/ZPcudk6eqsIggT35v483CQe5KkDBtc3FYnev0vUhkqFIsSrI0XJ8LyqnRpTPw5sZJLhpmIaCcrUuSxgRJuKx1b0OxltnBW2jAdaqjJRIe+bRnxKzq5O0KuopxsY4jxahVsscYxSgr2bC6e63taU+oWiCotP0f4MLYJK/Xk/9TSIxkUG/+h5McXEG0bHgLBcioZrSK40o76vzP2cE3FZLVTJngE36ofxgAYNPPhvJqtCv7ggQJpvGv2wRG2OVTZ4IOwUcaOeY2l+ESspFzPdBsU1X9hDSQ4Pyy2zhxQZkZUYdYCRoK1CLvhSs3wVOFCtE9ty3Id4rY+KJqtYXIHx6+LpwA2mrVf68+twI=")!
    private static let digest = "de4d29415ca75c9cf6a9fbdb0860832af58ae8cd74b3a8fd0dc031be832861b4"

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A frame of blocks kept as they are, which needs no compressor to write.
    static func stored(_ data: Data) -> Data {
        var out = Data([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x50])
        var at = 0
        repeat {
            let size = min(data.count - at, 100_000), last = at + size == data.count
            let header = size << 3 | (last ? 1 : 0)
            out.append(contentsOf: [UInt8(header & 255), UInt8(header >> 8 & 255), UInt8(header >> 16 & 255)])
            out.append(data.subdata(in: at..<(at + size)))
            at += size
        } while at < data.count
        return out
    }

    func testWhatTheZstdToolPackedIsUnpacked() throws {
        XCTAssertTrue(Zstandard.isCompressed(Self.strong))
        XCTAssertFalse(Zstandard.isCompressed(Data("BLENDER-v402".utf8)))
        for packed in [Self.strong, Self.fast] {
            let plain = try Zstandard.decode(packed, limit: 1 << 20)
            XCTAssertEqual(plain.count, 5646)
            XCTAssertEqual(digest(plain), Self.digest)
        }
    }

    func testFramesOneAfterAnotherAndFramesToSkip() throws {
        // As Blender writes a large file: frames, then a table of them in a frame a reader skips.
        let table = Data([0x5e, 0x2a, 0x4d, 0x18, 5, 0, 0, 0]) + Data("table".utf8)
        let plain = try Zstandard.decode(Self.fast, limit: 1 << 20)
        XCTAssertEqual(try Zstandard.decode(Self.strong + table + Self.fast + table, limit: 1 << 20), plain + plain)
        XCTAssertEqual(try Zstandard.decode(Self.stored(plain) + Self.strong, limit: 1 << 20), plain + plain)
        // More than a megabyte, so it comes out over several rounds.
        let large = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 >> 3) })
        XCTAssertEqual(try Zstandard.decode(Self.stored(large), limit: 4_000_000), large)
    }

    func testTheResultStopsAtTheLimit() throws {
        XCTAssertThrowsError(try Zstandard.decode(Self.strong, limit: 5645)) { XCTAssertEqual($0 as? Zstandard.Failure, .tooLarge) }
        XCTAssertNoThrow(try Zstandard.decode(Self.strong, limit: 5646))
        // Zeros pack a thousand to one; what they unpack to is still held to the limit.
        let large = Data(count: 3_000_000)
        XCTAssertThrowsError(try Zstandard.decode(Self.stored(large), limit: 2_000_000)) { XCTAssertEqual($0 as? Zstandard.Failure, .tooLarge) }
    }

    func testCutShortOrAlteredDataFailsInsteadOfGivingSomethingElse() throws {
        let plain = try Zstandard.decode(Self.strong, limit: 1 << 20)
        for length in 0..<Self.strong.count {
            XCTAssertThrowsError(try Zstandard.decode(Self.strong.prefix(length), limit: 1 << 20), "cut at \(length)")
        }
        // The checksum at its end catches a change the decoder itself cannot see.
        for packed in [Self.strong, Self.fast] {
            for index in 0..<packed.count {
                var changed = packed
                changed[index] ^= 0x41
                if packed == Self.strong {
                    if let got = try? Zstandard.decode(changed, limit: 1 << 20) { XCTAssertEqual(got, plain, "byte \(index)") }
                } else {
                    _ = try? Zstandard.decode(changed, limit: 1 << 20)
                }
            }
        }
        XCTAssertThrowsError(try Zstandard.decode(Data([0x28, 0xb5, 0x2f, 0xfd]) + Data(count: 64), limit: 1 << 20))
    }
}
