import Foundation
import simd

struct StereoCalibration: Codable {
    struct Lens: Codable {
        let width: Int
        let height: Int
        let intrinsics: [Float] // fx, fy, cx, cy
        let distortion: [Float] // OpenCV order: k1, k2, p1, p2, k3
        let position: Float

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

    func verified(for pair: [String], factoryBaselineMM: Float) -> Bool {
        self.pair == pair && pair.count == 2 && pair[0] != pair[1]
            && factoryBaselineMM.isFinite && factoryBaselineMM > 0
            && baselineMM.isFinite && abs(baselineMM - factoryBaselineMM) <= factoryBaselineMM * 0.05
            && (0...1).contains(reprojectionRMSPx) && (0...1).contains(epipolarRMSPx)
            && [Float(50), 100, 200, 300].allSatisfy { target in
                references.contains {
                    abs($0.measuredCM - target) <= target * 0.1 && $0.stereoCM.isFinite
                        && abs($0.stereoCM - $0.measuredCM) <= max(4, $0.measuredCM * 0.1)
                }
            }
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
