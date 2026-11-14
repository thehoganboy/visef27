import Foundation
import simd

@main
struct StereoCalibrationTests {
    static func main() {
        let transform = simd_float4x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0),
                                                SIMD3(0, 0, 1), SIMD3(-20, 0, 0)))
        let rect = StereoCalibration.rectification(transform)!
        precondition(rect.baseline == 20)
        precondition(rect.basis * SIMD3<Float>(1, 0, 0) == SIMD3<Float>(1, 0, 0))
        let invalid = simd_float4x3(columns: (SIMD3(2, 0, 0), SIMD3(0, 1, 0),
                                              SIMD3(0, 0, 1), SIMD3(-20, 0, 0)))
        precondition(StereoCalibration.rectification(invalid) == nil)
        let k = simd_float3x3(columns: (SIMD3(300, 0, 0), SIMD3(0, 300, 0), SIMD3(240, 180, 1)))
        let lens = StereoCalibration.Lens(width: 480, height: 360, intrinsics: [300, 300, 240, 180],
                                          distortion: [0.1, 0, 0, 0, 0], position: 0.5)
        precondition(lens.matches(width: 480, height: 360, intrinsics: k, position: 0.5))
        precondition(!lens.matches(width: 480, height: 360, intrinsics: k, position: 0.6))
        precondition((lens.project(SIMD3(0.5, 0, 1), k: k)?.x ?? 0) > 390)
        let profile = StereoCalibration(pair: ["wide", "ultra"], left: lens, right: lens, baselineMM: 20,
            reprojectionRMSPx: 0.3, epipolarRMSPx: 0.5,
            references: [Float(50), 100, 200, 300].map { .init(measuredCM: $0, stereoCM: $0) })
        precondition(profile.verified(for: ["wide", "ultra"], factoryBaselineMM: 20))
        precondition(!profile.verified(for: ["wide", "tele"], factoryBaselineMM: 20))
        precondition(!profile.verified(for: ["wide", "ultra"], factoryBaselineMM: 50))
        print("PASS 9 stereo calibration and rectification assertions (synthetic)")
    }
}
