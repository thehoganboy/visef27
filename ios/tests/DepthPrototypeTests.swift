import Foundation

@main
struct DepthPrototypeTests {
    static func main() {
        precondition(DepthFrame.centimeters(meters: 1.5, confidence: 2) == 150)
        precondition(DepthFrame.centimeters(meters: 0.5, confidence: 1) == 50)
        precondition(DepthFrame.centimeters(meters: 1, confidence: 0).isNaN)
        precondition(DepthFrame.centimeters(meters: 1, confidence: 255).isNaN)
        for value: Float in [.nan, .infinity, -.infinity, 0, -1, .greatestFiniteMagnitude] {
            precondition(DepthFrame.centimeters(meters: value, confidence: 2).isNaN)
        }

        let width = 64
        let height = 24
        let shift = 5
        let left = (0..<(width * height)).map { index in
            ((index * index * 13) ^ (index * 71)) & 255
        }
        var right = [Int](repeating: -1, count: left.count)
        for y in 0..<height {
            for x in 0..<(width - shift) { right[y * width + x] = left[y * width + x + shift] }
        }
        let disparity = StereoCorrespondence.disparity(left: left, right: right, width: width,
            height: height, x: 30, y: 12, maxShift: 12)
        precondition(disparity == shift)
        precondition(StereoCorrespondence.depthCM(focalPixels: 200, baselineMM: 50, disparity: disparity!) == 200)
        precondition(StereoCorrespondence.depthCM(focalPixels: .nan, baselineMM: 50, disparity: shift).isNaN)
        let uniform = [Int](repeating: 100, count: left.count)
        precondition(StereoCorrespondence.disparity(left: uniform, right: uniform, width: width,
            height: height, x: 30, y: 12, maxShift: 12) == nil)
        precondition(StereoCorrespondence.disparity(left: left, right: right, width: width,
            height: height, x: 0, y: 12, maxShift: 12) == nil)
        precondition(StereoCorrespondence.synchronized(20, 20.007))
        precondition(!StereoCorrespondence.synchronized(20, 20.009))
        precondition(!StereoCorrespondence.synchronized(.nan, 20))

        var epoch = DepthSourceEpoch()
        let original = epoch.value
        precondition(epoch.accepts(original, timestamp: 1, now: 1.1, after: 0))
        for _ in 0..<20 { epoch.invalidate() }
        precondition(!epoch.accepts(original, timestamp: 1, now: 1.1, after: 0))
        let restarted = epoch.value
        precondition(!epoch.accepts(restarted, timestamp: 1, now: 1.8, after: 0))
        precondition(!epoch.accepts(restarted, timestamp: 1, now: 1.1, after: 1))
        precondition(!epoch.accepts(restarted, timestamp: 2, now: 1.1, after: 0))
        precondition(epoch.accepts(restarted, timestamp: 2, now: 2.1, after: 1))
        precondition(DepthMode.midas.unavailableReason(hasHardware: false) == nil)
        precondition(DepthMode.lidar.unavailableReason(hasHardware: false) != nil)
        precondition(DepthMode.stereo.unavailableReason(hasHardware: false) != nil)
        precondition(DepthMode.stereo.unavailableReason(hasHardware: true) == nil)
        print("PASS 28 portable assertions: LiDAR filtering (10), stereo geometry and sync (8), freshness and switching (6), capability (4)")
    }
}
