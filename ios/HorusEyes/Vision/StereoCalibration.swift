import Foundation
import simd

struct StereoCalibration: Codable {
    struct Lens: Codable {
        let width: Int
        let height: Int
        let intrinsics: [Float] // fx, fy, cx, cy
        let distortion: [Float] // OpenCV order: k1, k2, p1, p2, k3
        let position: Float
        var fittedIntrinsics: [Float]? = nil

        var projection: simd_float3x3? {
            guard let k = fittedIntrinsics, k.count == 4, k.allSatisfy({ $0.isFinite }),
                  k[0] > 0, k[1] > 0, (0..<Float(width)).contains(k[2]),
                  (0..<Float(height)).contains(k[3]) else { return nil }
            return simd_float3x3(columns: (SIMD3(k[0], 0, 0), SIMD3(0, k[1], 0), SIMD3(k[2], k[3], 1)))
        }

        func matches(width: Int, height: Int, intrinsics k: simd_float3x3, position: Float) -> Bool {
            let live = [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y]
            return self.width == width && self.height == height && intrinsics.count == 4
                && distortion.count == 5 && distortion.allSatisfy { $0.isFinite && abs($0) <= 4 }
                && zip(live, intrinsics).allSatisfy { abs($0 - $1) <= max(1, abs($0) * 0.005) }
                && abs(self.position - position) <= 0.015
        }

        func project(_ ray: SIMD3<Float>, k: simd_float3x3) -> SIMD2<Float>? {
            guard ray.z > 0, distortion.count == 5 else { return nil }
            let x = ray.x / ray.z, y = ray.y / ray.z
            let r2 = x * x + y * y
            let d = distortion
            let radial = 1 + r2 * (d[0] + r2 * (d[1] + r2 * d[4]))
            return SIMD2(k.columns.0.x * (x * radial + 2 * d[2] * x * y + d[3] * (r2 + 2 * x * x)) + k.columns.2.x,
                         k.columns.1.y * (y * radial + d[2] * (r2 + 2 * y * y) + 2 * d[3] * x * y) + k.columns.2.y)
        }
    }

    struct Reference: Codable {
        let measuredCM: Float
        let stereoCM: Float
    }

    let pair: [String]
    let left: Lens
    let right: Lens
    let baselineMM: Float
    let reprojectionRMSPx: Float
    let epipolarRMSPx: Float
    let references: [Reference]
    var captureSignature: [String]? = nil
    var fittedExtrinsicsColumnsMM: [[Float]]? = nil
    var factoryExtrinsicsColumnsMM: [[Float]]? = nil
    var overlapFraction: Float? = nil
    var trainingPairs: Int? = nil

    private func matrix(_ columns: [[Float]]?) -> simd_float4x3? {
        guard let c = columns, c.count == 4, c.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite } }) else { return nil }
        func v(_ index: Int) -> SIMD3<Float> { SIMD3(c[index][0], c[index][1], c[index][2]) }
        return simd_float4x3(columns: (v(0), v(1), v(2), v(3)))
    }

    var fittedExtrinsics: simd_float4x3? { matrix(fittedExtrinsicsColumnsMM) }
    var scaleUncertainty: Float {
        references.map { abs($0.stereoCM - $0.measuredCM) / max(1, $0.measuredCM) }.max() ?? 1
    }

    func validationIssues() -> [String] {
        var issues: [String] = []
        if captureSignature?.count != 2 { issues.append("Missing ordered capture signature") }
        for (label, lens) in [("A", left), ("B", right)] {
            if lens.width <= 0 || lens.height <= 0 || lens.projection == nil || lens.intrinsics.count != 4 ||
                !lens.intrinsics.allSatisfy({ $0.isFinite }) || lens.distortion.count != 5 ||
                !lens.distortion.allSatisfy({ $0.isFinite && abs($0) <= 4 }) || !(0...1).contains(lens.position) {
                issues.append("Camera \(label) has invalid calibration or focus metadata")
            }
        }
        if (trainingPairs ?? 0) < 15 { issues.append("At least 15 usable fitting pairs required") }
        if !(0.25...1).contains(overlapFraction ?? 0) { issues.append("Insufficient rectified overlap") }
        if !(0...1).contains(reprojectionRMSPx) { issues.append("Reprojection RMS exceeds 1 px") }
        if !(0...1).contains(epipolarRMSPx) { issues.append("Held-out epipolar RMS exceeds 1 px") }
        if !hasReferences { issues.append("Held-out 50, 100, 200 and 300 cm references fail or are missing") }
        if pair.count != 2 || Set(pair).count != 2 || pair.contains("") { issues.append("Invalid camera IDs") }
        if let factory = matrix(factoryExtrinsicsColumnsMM), let fit = fittedExtrinsics,
           let rect = Self.rectification(fit), abs(rect.baseline - baselineMM) < 0.05,
           compatible(factory: factory) {
            // Baseline and relative pose agree with the independently supplied factory geometry.
        } else {
            issues.append("Fitted pose or baseline disagrees with factory geometry")
        }
        return issues
    }

    func compatible(factory: simd_float4x3) -> Bool {
        guard let fit = fittedExtrinsics, let fitRect = Self.rectification(fit),
              let active = Self.rectification(factory), verified(for: pair, factoryBaselineMM: active.baseline) else { return false }
        return abs(fitRect.baseline - active.baseline) <= active.baseline * 0.05
            && simd_dot(fitRect.basis[0], active.basis[0]) > 0.995
            && (0..<3).allSatisfy { simd_dot(fitRect.rotation[$0], active.rotation[$0]) > 0.999 }
    }

    private var hasReferences: Bool {
        references.allSatisfy { $0.measuredCM.isFinite && $0.measuredCM > 0 && $0.stereoCM.isFinite && $0.stereoCM > 0 }
            && [Float(50), 100, 200, 300].allSatisfy { target in
                references.contains {
                    abs($0.measuredCM - target) <= target * 0.1
                        && abs($0.stereoCM - $0.measuredCM) <= max(4, $0.measuredCM * 0.1)
                }
            }
    }

    func matchesCapture(_ signature: [String]) -> Bool {
        signature.count == 2 && captureSignature == signature
    }

    func verified(for pair: [String], factoryBaselineMM: Float) -> Bool {
        self.pair == pair && pair.count == 2 && pair[0] != pair[1]
            && factoryBaselineMM.isFinite && factoryBaselineMM > 0
            && baselineMM.isFinite && abs(baselineMM - factoryBaselineMM) <= factoryBaselineMM * 0.05
            && (0...1).contains(reprojectionRMSPx) && (0...1).contains(epipolarRMSPx)
            && hasReferences
    }

    static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StereoCalibration.json")
    }

    static func rectification(_ e: simd_float4x3) -> (basis: simd_float3x3, rotation: simd_float3x3, baseline: Float)? {
        let r = simd_float3x3(columns: (e.columns.0, e.columns.1, e.columns.2))
        guard abs(simd_determinant(r) - 1) < 0.01,
              (0..<3).allSatisfy({ i in (0..<3).allSatisfy { j in
                  abs(simd_dot(r[i], r[j]) - (i == j ? 1 : 0)) < 0.01
              } }) else { return nil }
        let offset = -(r.transpose * e.columns.3)
        let baseline = simd_length(offset)
        guard baseline.isFinite, (1...150).contains(baseline) else { return nil }
        let across = offset / baseline
        guard abs(across.z) < 0.1 else { return nil }
        let down = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), across))
        let forward = simd_cross(across, down)
        return (simd_float3x3(columns: (across, down, forward)), r, baseline)
    }
}
