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
        var lens = StereoCalibration.Lens(width: 480, height: 360, intrinsics: [300, 300, 240, 180],
                                          distortion: [0.1, 0, 0, 0, 0], position: 0.5)
        precondition(lens.matches(width: 480, height: 360, intrinsics: k, position: 0.5))
        precondition(!lens.matches(width: 480, height: 360, intrinsics: k, position: 0.6))
        precondition((lens.project(SIMD3(0.5, 0, 1), k: k)?.x ?? 0) > 390)
        lens.fittedIntrinsics = [300, 300, 240, 180]
        var profile = StereoCalibration(pair: ["wide", "ultra"], left: lens, right: lens, baselineMM: 20,
            reprojectionRMSPx: 0.3, epipolarRMSPx: 0.5,
            references: [Float(50), 100, 200, 300].map { .init(measuredCM: $0, stereoCM: $0) })
        precondition(profile.verified(for: ["wide", "ultra"], factoryBaselineMM: 20))
        precondition(!profile.verified(for: ["wide", "tele"], factoryBaselineMM: 20))
        precondition(!profile.verified(for: ["wide", "ultra"], factoryBaselineMM: 50))
        precondition(!profile.matchesCapture(["A", "B"]))
        profile.captureSignature = ["A", "B"]
        precondition(profile.matchesCapture(["A", "B"]))
        precondition(!profile.matchesCapture(["A", "changed geometry"]))
        precondition(!profile.matchesCapture(["B", "A"]))
        let columns: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [-20, 0, 0]]
        precondition(!profile.validationIssues().isEmpty)
        profile.factoryExtrinsicsColumnsMM = columns
        profile.fittedExtrinsicsColumnsMM = columns
        profile.overlapFraction = 0.75
        profile.trainingPairs = 18
        precondition(profile.validationIssues().isEmpty)
        precondition(profile.compatible(factory: transform))
        profile.fittedExtrinsicsColumnsMM?[3][0] = -50
        precondition(!profile.validationIssues().isEmpty)
        let errors = [Float(50), 100, 200, 300].map { truth -> Float in
            let disparity = 300 * 2 / truth
            return StereoCorrespondence.depthCM(focalPixels: 300, baselineMM: 20, subpixelDisparity: disparity) - truth
        }
        let mae = errors.map(abs).reduce(0, +) / Float(errors.count)
        let rmse = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Float(errors.count))
        precondition(mae < 0.001 && rmse < 0.001)
        print("PASS 18 stereo geometry checks. Synthetic projection fixture MAE \(mae) cm, RMSE \(rmse) cm.")
    }
}
