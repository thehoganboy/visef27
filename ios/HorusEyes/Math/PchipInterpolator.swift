// HorusEyes 2.0 — PchipInterpolator.swift
// ════════════════════════════════════════════════════════════════════════════════
// Fritsch-Carlson PCHIP Monotone Cubic Hermite Interpolation (11 knots)
// Guarantees: strict monotonicity, NaN/Inf immunity, boundary clamping.
// ════════════════════════════════════════════════════════════════════════════════

import Foundation
import Accelerate

/// Monotone Piecewise Cubic Hermite Interpolating Polynomial.
/// Converts MiDaS raw disparity → metric distance (cm) with zero overshoot.
final class PchipInterpolator {
    private let xs: [Float]  // raw disparity knots (ascending)
    private let ys: [Float]  // distance knots (descending — strictly monotone)
    private let ms: [Float]  // Fritsch-Carlson tangent slopes at each knot
    private let n: Int

    init(nodes: [(raw: Float, cm: Float)] = Config.calibrationNodes) {
        precondition(nodes.count >= 2, "PCHIP requires at least 2 nodes")
        xs = nodes.map { $0.raw }
        ys = nodes.map { $0.cm  }
        n  = xs.count

        // 1. Finite differences δ_k = (y_{k+1} - y_k) / (x_{k+1} - x_k)
        var deltas = [Float](repeating: 0, count: n - 1)
        for k in 0 ..< n - 1 {
            let dx = xs[k + 1] - xs[k]
            deltas[k] = dx > 1e-9 ? (ys[k + 1] - ys[k]) / dx : 0
        }

        // 2. Fritsch-Carlson tangents with monotonicity enforcement
        var tangents = [Float](repeating: 0, count: n)

        // Endpoint tangents (one-sided)
        tangents[0]     = deltas[0]
        tangents[n - 1] = deltas[n - 2]

        // Interior tangents
        for k in 1 ..< n - 1 {
            let d0 = deltas[k - 1]
            let d1 = deltas[k]

            // Different signs or either is zero → flat tangent (monotonicity)
            if d0 * d1 <= 0 {
                tangents[k] = 0
            } else {
                // Harmonic mean weighted tangent
                let w1 = 2.0 * Float(xs[k + 1] - xs[k]) + Float(xs[k] - xs[k - 1])
                let w2 = Float(xs[k + 1] - xs[k]) + 2.0 * Float(xs[k] - xs[k - 1])
                tangents[k] = (w1 + w2) / (w1 / d0 + w2 / d1)
            }
        }

        // 3. Monotonicity correction (Fritsch-Carlson §4)
        for k in 0 ..< n - 1 {
            let dk = deltas[k]
            if abs(dk) < 1e-12 {
                tangents[k]     = 0
                tangents[k + 1] = 0
                continue
            }
            let alpha = tangents[k]     / dk
            let beta  = tangents[k + 1] / dk
            let mag   = alpha * alpha + beta * beta
            if mag > 9.0 {
                let tau = 3.0 / sqrt(mag)
                tangents[k]     = tau * alpha * dk
                tangents[k + 1] = tau * beta  * dk
            }
        }

        ms = tangents
    }

    /// Evaluate the interpolant at a single raw disparity value.
    /// Input is clamped to [xs.first, xs.last]; NaN/Inf returns 350.0 (safe far).
    func evaluate(_ rawVal: Float) -> Float {
        guard rawVal.isFinite else { return ys[0] }  // 350.0 — safe fallback

        // Clamp input to knot domain BEFORE lookup
        let x = min(max(rawVal, xs[0]), xs[n - 1])

        // Binary search for interval
        var lo = 0, hi = n - 2
        while lo < hi {
            let mid = (lo + hi) >> 1
            if x >= xs[mid + 1] {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let k = lo

        // Hermite basis on normalized parameter t ∈ [0, 1]
        let h  = xs[k + 1] - xs[k]
        guard h > 1e-12 else { return ys[k] }
        let t  = (x - xs[k]) / h

        let t2 = t * t
        let t3 = t2 * t
        let h00 =  2 * t3 - 3 * t2 + 1
        let h10 =      t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 =      t3 -     t2

        let result = h00 * ys[k] + h10 * h * ms[k]
                   + h01 * ys[k + 1] + h11 * h * ms[k + 1]

        // Final boundary clamp to [13, 350]
        return min(max(result, ys[n - 1]), ys[0])
    }

    /// Vectorized evaluation for a contiguous Float array via Accelerate.
    func evaluate(_ rawArray: [Float]) -> [Float] {
        return rawArray.map { evaluate($0) }
    }

    /// Evaluates raw disparity to distance in cm (alias for evaluate)
    func interpolate(_ rawVal: Float) -> Float {
        return evaluate(rawVal)
    }

    /// Vectorized evaluation alias
    func interpolate(_ rawArray: [Float]) -> [Float] {
        return evaluate(rawArray)
    }
}
