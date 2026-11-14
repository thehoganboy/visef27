import Foundation

enum DepthMode: String, CaseIterable, Identifiable {
    case midas = "MiDaS"
    case lidar = "LiDAR"
    case stereo = "Stereo β"

    var id: Self { self }
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
        guard focalPixels.isFinite, focalPixels > 0, baselineMM.isFinite,
              baselineMM > 0, disparity > 0 else { return .nan }
        let cm = focalPixels * (baselineMM / 10) / Float(disparity)
        return cm.isFinite ? cm : .nan
    }

    static func disparity(left: [Int], right: [Int], width: Int, height: Int,
                          x: Int, y: Int, maxShift: Int) -> Int? {
        let radius = 2
        guard width > 2 * radius, height > 2 * radius, left.count == width * height,
              right.count == left.count, x >= radius, x < width - radius,
              y >= radius, y < height - radius, maxShift > 0 else { return nil }

        func match(_ reference: [Int], _ target: [Int], at center: Int, direction: Int) -> Int? {
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
            return shift
        }

        guard let shift = match(left, right, at: x, direction: -1),
              let reverse = match(right, left, at: x - shift, direction: 1),
              shift == reverse else { return nil }
        return shift
    }
}
