import simd

/// Where a model lies, in the numbers of its file.
///
/// A Float has 24 bits. Four million units out, two of them next to each other are half
/// a unit apart, and whatever is worked out there (where a corner is on the screen, how
/// far it is from the eye) lands on those steps. Where a file puts its model is not
/// shown, so a model far off is brought to its own middle, where the numbers are fine.
public struct Whereabouts: Sendable {
    public private(set) var low = SIMD3<Double>(repeating: .infinity)
    public private(set) var high = SIMD3<Double>(repeating: -.infinity)

    public init() {}

    /// A coordinate that is infinite or no number is no place, and is left out.
    @inline(__always) public mutating func include(_ point: SIMD3<Double>) {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
        low = simd_min(low, point); high = simd_max(high, point)
    }

    /// The model's middle, when it lies more than a hundred times the model's own size
    /// from the origin: nearer than that, a Float still tells the model's points apart to
    /// a hundred-thousandth of its size.
    public var farMiddle: SIMD3<Double>? {
        guard low.x <= high.x else { return nil }
        let middle = low / 2 + high / 2
        return simd_reduce_max(simd_abs(middle)) > 100 * simd_reduce_max(high - low) ? middle : nil
    }
}
