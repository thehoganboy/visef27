import Foundation

@main
struct DenseStereoTests {
    static func check(_ passed: Bool, line: Int = #line) {
        if !passed {
            FileHandle.standardError.write(Data("Dense stereo fixture failed at line \(line)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let w = 112, h = 72, shift = 5, limit = 12
        var seed: UInt32 = 41
        let texture = (0..<(w * h)).map { _ -> Int in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Int((seed >> 24) & 255)
        }
        let left = texture.enumerated().map { index, value in
            (value * 2 + texture[max(index - 1, 0)]) / 3
        }
        func shifted(_ fraction: Float, vertical: Int = 0) -> [Int] {
            left.indices.map { i in
                let x = i % w, y = i / w + vertical
                guard y < h, x + shift + 1 < w else { return -1 }
                let j = y * w + x + shift
                return Int((Float(left[j]) * (1 - fraction) + Float(left[j + 1]) * fraction).rounded())
            }
        }
        let right = shifted(0)
        let started = Date()
        let dense = DenseStereo.match(left, right, width: w, height: h, maxShift: limit)
        let elapsed = Date().timeIntervalSince(started) * 1000
        let valid = dense.disparity.filter(\.isFinite)
        print("Integer-match count \(valid.count)")
        check(valid.count > w * h / 2)
        let sorted = valid.sorted()
        check(abs(sorted[valid.count / 2] - Float(shift)) < 0.15)
        let mae = valid.map { abs($0 - Float(shift)) }.reduce(0, +) / Float(valid.count)
        let fractional = DenseStereo.match(left, shifted(0.4), width: w, height: h, maxShift: limit)
            .disparity.filter(\.isFinite).sorted()
        check(fractional.count > 100)
        let estimate = fractional[fractional.count / 2]
        print("Fractional-match count \(fractional.count); median \(estimate)")
        check(abs(estimate - 5.4) < 0.45 && abs(estimate - estimate.rounded()) > 0.02)

        var occlusion = right
        for y in 20..<51 { for x in 37..<61 { occlusion[y * w + x] = -1 } }
        let masked = DenseStereo.match(left, occlusion, width: w, height: h, maxShift: limit)
        check(!masked.disparity[35 * w + 54].isFinite)
        let flat = [Int](repeating: 100, count: left.count)
        check(DenseStereo.match(flat, flat, width: w, height: h, maxShift: limit).disparity.allSatisfy { !$0.isFinite })
        let dark = left.map { $0 / 24 }
        check(DenseStereo.match(dark, dark, width: w, height: h, maxShift: limit).disparity.allSatisfy { !$0.isFinite })
        let repeatPattern = left.indices.map { ($0 % w % 4) * 45 + ($0 / w % 3) }
        check(DenseStereo.match(repeatPattern, repeatPattern, width: w, height: h, maxShift: limit)
            .disparity.allSatisfy { !$0.isFinite })
        let motion = DenseStereo.match(left, shifted(0, vertical: 7), width: w, height: h, maxShift: limit)
        check(motion.disparity.filter(\.isFinite).count < valid.count / 15)

        let near = DenseStereo.metric(focal: 230, baselineMM: 20, disparity: 5, sigma: 0.2, scaleFraction: 0.02)!
        check(abs(near.depth - 92) < 0.1 && (4...5).contains(near.sigma))
        check(DenseStereo.metric(focal: 230, baselineMM: 20, disparity: 1.5, sigma: 0.25, scaleFraction: 0.03) == nil)

        var sparse = 0
        for y in stride(from: 2, to: h - 2, by: 2) {
            for x in stride(from: 2, to: w - 2, by: 2) {
                if StereoCorrespondence.matchDisparity(left: left, right: right, width: w, height: h,
                    x: x, y: y, maxShift: limit) != nil { sparse += 1 }
            }
        }
        print(String(format: "SYNTHETIC dense coverage %d/%d, prior stride-2 matcher %d/%d; MAE %.3f px; fractional median %.3f px; dense %.1f ms",
            valid.count, w * h, sparse, w * h, mae, estimate, elapsed))
        print("PASS dense subpixel, low-light, texture, occlusion, vertical-motion and uncertainty checks")
    }
}
