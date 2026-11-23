/// Where a position is looked for first in a table of positions: any whole number, of
/// which a table takes the low bits.
///
/// The corners of a voxel model, a height field or a part drawn on a grid are whole steps
/// apart, and as Floats they differ in a few high bits only. A table that fills evenly
/// with scattered points must fill as evenly with these: three coordinates multiplied
/// apart and laid over one another kept the pattern, and the corners of a 64 x 64 x 64
/// lattice took 4,600 looks each to place. Two multiplications 64 bits wide, of which the
/// upper half is kept, leave none of it.
public enum PositionHash {
    @inlinable @inline(__always) public static func home(_ x: Float, _ y: Float, _ z: Float) -> Int {
        // + 0 turns -0 into +0 so both hash alike.
        var h = (UInt64((x + 0).bitPattern) << 32 | UInt64((y + 0).bitPattern)) &* 0x9E37_79B9_7F4A_7C15
        h = (h ^ (h >> 29) ^ UInt64((z + 0).bitPattern)) &* 0xBF58_476D_1CE4_E5B9
        return Int(truncatingIfNeeded: h >> 32)
    }
}
