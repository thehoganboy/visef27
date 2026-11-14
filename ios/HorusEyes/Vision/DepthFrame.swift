import Foundation

enum DepthMode: String, CaseIterable, Identifiable {
    case midas = "MiDaS"
    case lidar = "LiDAR"
    case stereo = "Stereo β"

    var id: Self { self }

    func distanceLabel(_ cm: Float) -> String {
        guard cm.isFinite, cm > 0 else { return "N/A" }
        let prefix = self == .lidar ? "" : "≈ "
        return prefix + String(format: "%.0f cm", cm)
    }

    func unavailableReason(hasHardware: Bool) -> String? {
        guard !hasHardware else { return nil }
        switch self {
        case .midas: return nil
        case .lidar: return "LiDAR scene depth requires a supported iPhone"
        case .stereo: return "Stereo requires a supported rear physical MultiCam pair"
        }
    }
}

struct DepthGeometry {
    let width: Int
    let height: Int
    let fx: Float
    let cx: Float

    var isValid: Bool { width > 0 && height > 0 && fx.isFinite && fx > 0 && cx.isFinite && cx > 0 && cx < Float(width) }
}

struct DepthFrame {
    let source: DepthMode
    let timestamp: Double
    let geometry: DepthGeometry
    let width: Int
    let height: Int
    let centimeters: [Float]
    let confidence: [UInt8]
    let detail: String
    var error: String? = nil
    var captureProcessingMS: Double = 0

    var strongCoverage: Double? {
        guard !confidence.isEmpty, confidence.count == centimeters.count else { return nil }
        return Double(confidence.filter { $0 == 2 }.count) / Double(confidence.count)
    }

    var validityMask: [Bool] { centimeters.map { $0.isFinite && $0 > 0 } }

    var coverage: Double {
        guard !centimeters.isEmpty else { return 0 }
        return Double(centimeters.lazy.filter { $0.isFinite && $0 > 0 }.count) / Double(centimeters.count)
    }

    static func centimeters(meters: Float, confidence: UInt8) -> Float {
        guard confidence == 1 || confidence == 2, meters.isFinite, meters > 0 else { return .nan }
        let cm = meters * 100
        return cm.isFinite ? cm : .nan
    }
}

struct DepthSourceEpoch {
    private(set) var value = 0

    mutating func invalidate() { value += 1 }

    func accepts(_ token: Int, timestamp: Double, now: Double, after: Double) -> Bool {
        value == token && timestamp.isFinite && timestamp > 0 && timestamp > after
            && (-0.05...0.75).contains(now - timestamp)
    }
}

enum StereoCorrespondence {
    static func synchronized(_ first: Double, _ second: Double) -> Bool {
        first.isFinite && second.isFinite && abs(first - second) <= 0.008
    }

    static func depthCM(focalPixels: Float, baselineMM: Float, disparity: Int) -> Float {
        depthCM(focalPixels: focalPixels, baselineMM: baselineMM, subpixelDisparity: Float(disparity))
    }

    static func depthCM(focalPixels: Float, baselineMM: Float, subpixelDisparity: Float) -> Float {
        guard focalPixels.isFinite, focalPixels > 0, baselineMM.isFinite,
              baselineMM > 0, subpixelDisparity.isFinite, subpixelDisparity > 0 else { return .nan }
        let cm = focalPixels * (baselineMM / 10) / subpixelDisparity
        return cm.isFinite ? cm : .nan
    }

    static func disparity(left: [Int], right: [Int], width: Int, height: Int,
                          x: Int, y: Int, maxShift: Int) -> Int? {
        matchDisparity(left: left, right: right, width: width, height: height,
            x: x, y: y, maxShift: maxShift).map { Int($0.rounded()) }
    }

    static func matchDisparity(left: [Int], right: [Int], width: Int, height: Int,
                               x: Int, y: Int, maxShift: Int) -> Float? {
        let radius = 2
        guard width > 2 * radius, height > 2 * radius, left.count == width * height,
              right.count == left.count, x >= radius, x < width - radius,
              y >= radius, y < height - radius, maxShift > 0 else { return nil }

        func match(_ reference: [Int], _ target: [Int], at center: Int, direction: Int) -> Float? {
            var best = Int.max
            var second = Int.max
            var shift = 0
            var low = 255
            var high = 0
            for row in (y - radius)...(y + radius) {
                for column in (center - radius)...(center + radius) {
                    let value = reference[row * width + column]
                    guard value >= 0 else { return nil }
                    low = min(low, value)
                    high = max(high, value)
                }
            }
            guard high - low >= 18 else { return nil }

            var costs = [Int](repeating: Int.max, count: maxShift + 1)
            for candidate in 0...maxShift {
                let destination = center + direction * candidate
                guard destination >= radius, destination < width - radius else { break }
                var score = 0
                var valid = true
                for row in (y - radius)...(y + radius) {
                    for offset in -radius...radius {
                        let other = target[row * width + destination + offset]
                        valid = valid && other >= 0
                        score += abs(reference[row * width + center + offset] - other)
                    }
                }
                guard valid else { continue }
                costs[candidate] = score
                if score < best {
                    second = best
                    best = score
                    shift = candidate
                } else {
                    second = min(second, score)
                }
            }
            guard shift > 0, best <= 25 * 25, second < Int.max,
                  second - best >= max(35, best / 4) else { return nil }
            guard shift < maxShift, costs[shift - 1] < Int.max, costs[shift + 1] < Int.max else {
                return Float(shift)
            }
            let leftCost = Float(costs[shift - 1]), rightCost = Float(costs[shift + 1])
            let curvature = leftCost + rightCost - 2 * Float(best)
            let offset = curvature > 0 ? (leftCost - rightCost) / (2 * curvature) : 0
            return Float(shift) + offset
        }

        guard let shift = match(left, right, at: x, direction: -1),
              let reverse = match(right, left, at: x - Int(shift.rounded()), direction: 1),
              abs(shift - reverse) <= 0.75 else { return nil }
        return shift
    }
}
