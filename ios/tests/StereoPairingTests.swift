import Foundation

@main
struct StereoPairingTests {
    private final class Buffer {}

    static func main() throws {
        var matcher = StereoPairing<String>()
        func ingest(_ time: Double, _ camera: StereoCamera) -> (StereoPairing<String>.Sample, StereoPairing<String>.Sample)? {
            matcher.ingest(.init(timestamp: time, payload: camera == .a ? "A" : "B"), camera: camera)
        }

        precondition(ingest(1, .a) == nil)
        precondition(matcher.buffered == 1)
        let aFirst = ingest(1.003, .b)!
        precondition(aFirst.0.payload == "A" && aFirst.1.payload == "B")
        precondition(ingest(1.036, .b) == nil)
        let bFirst = ingest(1.032, .a)!
        precondition(bFirst.0.timestamp == 1.032 && bFirst.1.timestamp == 1.036)
        precondition(ingest(1.036, .b) == nil)
        precondition(ingest(1.030, .a) == nil)
        precondition(matcher.rejected == 2)
        precondition(ingest(1.066, .a) == nil)
        precondition(ingest(1.081, .b) == nil)
        precondition(matcher.histogram[3] == 1)
        precondition(abs((matcher.skew.p95 ?? 0) - 4) < 0.01)
        precondition(abs((matcher.skew.jitter ?? 0) - 1) < 0.01)
        for n in 0..<100 { precondition(ingest(2 + Double(n) / 30, .b) == nil) }
        precondition(matcher.buffered <= StereoPairing<String>.capacity)
        precondition(matcher.obsolete > 90)

        var owned = StereoPairing<Buffer>()
        weak var released: Buffer?
        do {
            let buffer = Buffer()
            released = buffer
            precondition(owned.ingest(.init(timestamp: 1, payload: buffer), camera: .a) == nil)
        }
        precondition(released != nil)
        for time in [1.033, 1.066, 1.099] {
            precondition(owned.ingest(.init(timestamp: time, payload: Buffer()), camera: .a) == nil)
        }
        precondition(released == nil)
        weak var releasedOnRollback: Buffer?
        do {
            let buffer = Buffer()
            releasedOnRollback = buffer
            precondition(owned.ingest(.init(timestamp: 2, payload: buffer), camera: .a) == nil)
        }
        owned = StereoPairing()
        precondition(owned.buffered == 0 && releasedOnRollback == nil)

        var a = StereoStreamStats()
        var b = StereoStreamStats()
        a.missing += 2
        b.drop(reason: "lateData")
        b.drop(reason: "discontinuity")
        a.invalidate("missingClock")
        b.sample(raw: 10, host: 20, arrived: 20.001, width: 640, height: 480, pixelFormat: 875704422)
        b.sample(raw: 10.05, host: 20.05, arrived: 20.06, width: 640, height: 480, pixelFormat: 875704422)
        precondition(a.missing == 2 && b.missing == 0 && a.dropped.isEmpty)
        precondition(b.dropped == ["lateData": 1, "discontinuity": 1] && abs(b.fps - 20) < 0.01)
        let payload = try JSONEncoder().encode([a, b])
        let json = try JSONSerialization.jsonObject(with: payload) as! [[String: Any]]
        precondition(json[0]["invalidReasons"] as? [String: Int] == ["missingClock": 1])
        precondition(json[1]["width"] as? Int == 640)

        precondition(StereoDeliveryStrategy.automatic.phases(probeLateDrops: true) == [.synchronizer, .lateDropProbe, .independent])
        precondition(StereoDeliveryStrategy.automatic.phases(probeLateDrops: false) == [.synchronizer, .independent])
        precondition(StereoDeliveryStrategy.synchronizer.phases(probeLateDrops: false) == [.synchronizer])
        precondition(StereoDeliveryStrategy.independent.phases(probeLateDrops: true) == [.independent])
        var epoch = DepthSourceEpoch()
        let prior = epoch.value
        epoch.invalidate()
        precondition(!epoch.accepts(prior, timestamp: 45, now: 45.05, after: 0))
        print("PASS stereo pairing, skew, telemetry, buffer ownership, strategy and stale generation")
    }
}
