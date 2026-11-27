import Foundation

/// Rectified luma matching on a disparity-major cost volume. Sliding sums
/// aggregate local Census costs without recomputing the window per hypothesis.
enum DenseStereo {
    struct Result {
        let disparity: [Float]
        let sigma: [Float]
        let overlap: Int
    }

    static func match(_ left: [Int], _ right: [Int], width w: Int, height h: Int, maxShift: Int) -> Result {
        let n = w * h
        let limit = min(maxShift, w / 3)
        let invalid = UInt16.max
        var disparity = [Float](repeating: .nan, count: n)
        var sigma = disparity
        guard w >= 12, h >= 12, left.count == n, right.count == n, limit >= 3 else {
            return Result(disparity: disparity, sigma: sigma, overlap: 0)
        }
        func descriptors(_ luma: [Int]) -> (pattern: [UInt32], texture: [UInt8]) {
            var pattern = [UInt32](repeating: 0, count: n)
            var texture = [UInt8](repeating: 0, count: n)
            for y in 2..<(h - 2) {
                for x in 2..<(w - 2) {
                    let i = y * w + x, center = luma[i]
                    guard center >= 0 else { continue }
                    var mask: UInt32 = 0
                    var lo = center, hi = center
                    var valid = true
                    for dy in -2...2 {
                        for dx in -2...2 where dx != 0 || dy != 0 {
                            let v = luma[i + dy * w + dx]
                            mask = (mask << 1) | (v < center ? 1 : 0)
                            lo = min(lo, v)
                            hi = max(hi, v)
                            valid = valid && v >= 0
                        }
                    }
                    if valid {
                        pattern[i] = mask
                        texture[i] = UInt8(min(255, max(1, hi - lo)))
                    }
                }
            }
            return (pattern, texture)
        }
        let a = descriptors(left), b = descriptors(right)
        var costs = [UInt16](repeating: invalid, count: (limit + 1) * n)
        let penalty = 1024 // Any invalid descriptor in a 5×5 box invalidates the hypothesis.
        var horizontal = [Int](repeating: 0, count: n)
        var overlap = 0
        costs.withUnsafeMutableBufferPointer { volume in
            for shift in 0...limit {
                let start = shift * n
                for y in 0..<h {
                    let row = y * w
                    var total = 0
                    var ring = (0, 0, 0, 0, 0)
                    for x in 0..<w {
                        let i = row + x, j = i - shift
                        var value = penalty
                        if x >= shift && a.texture[i] > 0 && b.texture[j] > 0 {
                            value = (a.pattern[i] ^ b.pattern[j]).nonzeroBitCount
                                + min(6, abs(left[i] - right[j]) / 12)
                        }
                        total += value - ring.0
                        ring = (ring.1, ring.2, ring.3, ring.4, value)
                        if x >= 4 { horizontal[i - 2] = total }
                    }
                }
                for x in 4..<(w - 4) {
                    var total = 0
                    for y in 0..<h {
                        let i = y * w + x
                        total += horizontal[i]
                        if y >= 5 { total -= horizontal[i - 5 * w] }
                        if y >= 4 && total < penalty {
                            volume[start + i - 2 * w] = UInt16(total)
                            if shift == 0 { overlap += 1 }
                        }
                    }
                }
            }

            func winner(at i: Int, x: Int, reverse: Bool) -> (Float, Float)? {
                let texture = reverse ? b.texture[i] : a.texture[i]
                guard texture >= 16 else { return nil }
                let bound = min(limit, reverse ? w - 1 - x : x)
                guard bound >= 3 else { return nil }
                func cost(_ d: Int) -> Int { Int(volume[d * n + i + (reverse ? d : 0)]) }
                var best = Int(invalid), index = 0
                for d in 0...bound {
                    let c = cost(d)
                    if c < best { best = c; index = d }
                }
                guard index > 0, index < bound, best < 360 else { return nil }
                var alternate = Int(invalid)
                for d in 0...bound where abs(d - index) > 1 { alternate = min(alternate, cost(d)) }
                guard alternate < Int(invalid), alternate - best >= max(20, best / 5) else { return nil }
                let lc = cost(index - 1), rc = cost(index + 1), curvature = lc + rc - 2 * best
                guard lc < Int(invalid), rc < Int(invalid), curvature >= 12 else { return nil }
                let offset = Float(lc - rc) / Float(2 * curvature)
                let uncertainty = max(0.15, min(0.8, sqrt(Float(max(8, best / 8)) / Float(curvature))))
                return (Float(index) + offset, uncertainty)
            }

            var reverse = [Float](repeating: .nan, count: n)
            for y in 4..<(h - 4) {
                for x in 4..<(w - 4) {
                    let i = y * w + x
                    reverse[i] = winner(at: i, x: x, reverse: true)?.0 ?? .nan
                }
            }
            for y in 4..<(h - 4) {
                for x in 4..<(w - 4) {
                    let i = y * w + x
                    guard let (d, uncertainty) = winner(at: i, x: x, reverse: false) else { continue }
                    let j = x - Int(d.rounded())
                    guard j >= 0, j < w else { continue }
                    let delta = abs(d - reverse[y * w + j])
                    guard delta <= 0.75 else { continue }
                    disparity[i] = d
                    sigma[i] = max(uncertainty, delta / 2)
                }
            }
        }
        // Reject isolated hypotheses or sharp mixed-depth windows. Missing
        // pixels stay missing, including at the edge of the overlap region.
        let direct = disparity
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x, d = direct[i]
                guard d.isFinite else { continue }
                let neighbors = [i - 1, i + 1, i - w, i + w].filter {
                    let tolerance: Float = abs(left[$0] - left[i]) >= 48 ? 0.40 : max(0.65, d * 0.10)
                    return abs(direct[$0] - d) < tolerance
                }
                if neighbors.count < 2 { disparity[i] = .nan; sigma[i] = .nan }
            }
        }
        return Result(disparity: disparity, sigma: sigma, overlap: overlap)
    }

    static func metric(focal: Float, baselineMM: Float, disparity: Float, sigma: Float,
                       scaleFraction: Float) -> (depth: Float, sigma: Float)? {
        guard let estimate = estimate(focal: focal, baselineMM: baselineMM, disparity: disparity,
                                      sigma: sigma, scaleFraction: scaleFraction),
              supportsClearance(depth: estimate.depth, sigma: estimate.sigma) else { return nil }
        return estimate
    }

    static func supportsClearance(depth: Float, sigma: Float) -> Bool {
        sigma.isFinite && sigma > 0 && sigma <= min(30, depth * 0.18)
    }

    static func estimate(focal: Float, baselineMM: Float, disparity: Float, sigma: Float,
                         scaleFraction: Float, motionPx: Float = 0) -> (depth: Float, sigma: Float)? {
        guard disparity.isFinite, disparity > 0, sigma.isFinite, sigma > 0,
              scaleFraction.isFinite, scaleFraction >= 0, motionPx.isFinite else { return nil }
        let z = StereoCorrespondence.depthCM(focalPixels: focal, baselineMM: baselineMM, subpixelDisparity: disparity)
        let uncertainty = z * hypot(hypot(sigma, motionPx) / disparity, scaleFraction)
        guard z.isFinite, (15...650).contains(z), uncertainty.isFinite else { return nil }
        return (z, uncertainty)
    }
}
