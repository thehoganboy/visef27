import Foundation

enum StereoCamera: Int, CaseIterable {
    case a, b
    var other: Self { self == .a ? .b : .a }
}

enum StereoDeliveryStrategy: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case synchronizer = "Synchronizer"
    case independent = "Independent"
    var id: Self { self }

    func phases(probeLateDrops: Bool) -> [StereoDeliveryPhase] {
        switch self {
        case .automatic: return probeLateDrops ? [.synchronizer, .lateDropProbe, .independent] : [.synchronizer, .independent]
        case .synchronizer: return probeLateDrops ? [.synchronizer, .lateDropProbe] : [.synchronizer]
        case .independent: return [.independent]
        }
    }
}

enum StereoDeliveryPhase: String {
    case synchronizer, lateDropProbe, independent
}

struct StereoStreamStats: Encodable {
    var samples = 0
    var imageCallbacks = 0
    var lastCallbackPTS: Double?
    var lastConvertedHost: Double?
    var missing = 0
    var invalid = 0
    var invalidReasons: [String: Int] = [:]
    var dropped: [String: Int] = [:]
    var firstHost: Double?
    var lastHost: Double?
    var lastRaw: Double?
    var lastLatencyMS: Double?
    var width: Int?
    var height: Int?
    var pixelFormat: UInt32?
    var attached = false
    var enabled = false
    var active = false
    var ports = ""

    var fps: Double {
        guard let firstHost, let lastHost, lastHost > firstHost else { return 0 }
        return Double(samples - 1) / (lastHost - firstHost)
    }

    mutating func sample(raw: Double, host: Double, arrived: Double, width: Int, height: Int, pixelFormat: UInt32) {
        samples += 1
        if firstHost == nil { firstHost = host }
        lastRaw = raw
        lastHost = host
        lastLatencyMS = (arrived - host) * 1000
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    mutating func invalidate(_ reason: String) {
        invalid += 1
        invalidReasons[reason, default: 0] += 1
    }

    mutating func drop(reason: String) { dropped[reason, default: 0] += 1 }

    enum CodingKeys: String, CodingKey {
        case samples, missing, invalid, dropped, firstHost, lastHost, lastRaw, lastLatencyMS, invalidReasons
        case width, height, pixelFormat, attached, enabled, active, ports, fps
        case imageCallbacks, lastCallbackPTS, lastConvertedHost
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(samples, forKey: .samples)
        try c.encode(imageCallbacks, forKey: .imageCallbacks)
        try c.encodeIfPresent(lastCallbackPTS, forKey: .lastCallbackPTS)
        try c.encodeIfPresent(lastConvertedHost, forKey: .lastConvertedHost)
        try c.encode(missing, forKey: .missing)
        try c.encode(invalid, forKey: .invalid)
        try c.encode(invalidReasons, forKey: .invalidReasons)
        try c.encode(dropped, forKey: .dropped)
        try c.encodeIfPresent(firstHost, forKey: .firstHost)
        try c.encodeIfPresent(lastHost, forKey: .lastHost)
        try c.encodeIfPresent(lastRaw, forKey: .lastRaw)
        try c.encodeIfPresent(lastLatencyMS, forKey: .lastLatencyMS)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(pixelFormat, forKey: .pixelFormat)
        try c.encode(attached, forKey: .attached)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(active, forKey: .active)
        try c.encode(ports, forKey: .ports)
        try c.encode(fps, forKey: .fps)
    }
}

struct StereoPairing<Payload> {
    static var tolerance: Double { 0.008 }
    static var capacity: Int { 2 }

    struct Sample {
        let timestamp: Double
        let payload: Payload
    }

    private var frames: [[Sample]] = [[], []]
    private var latest: [Double] = [-.infinity, -.infinity]
    private var lastPaired: [Double] = [-.infinity, -.infinity]
    private(set) var rejected = 0
    private(set) var obsolete = 0
    private(set) var histogram = [Int](repeating: 0, count: 5)
    private var acceptedOffsets: [Double] = []
    private var observedSkew: [Double] = []
    var buffered: Int { frames[0].count + frames[1].count }

    // A pair is emitted once. Each stream advances monotonically, including after
    // a late sample, and the prior attempt's queues are discarded on teardown.
    mutating func ingest(_ sample: Sample, camera: StereoCamera) -> (Sample, Sample)? {
        let i = camera.rawValue, j = camera.other.rawValue
        let timestamp = sample.timestamp
        guard timestamp.isFinite, timestamp > latest[i] else { rejected += 1; return nil }
        latest[i] = timestamp
        guard timestamp > lastPaired[i] else { obsolete += 1; return nil }

        if let nearest = frames[j].indices.min(by: {
            abs(frames[j][$0].timestamp - timestamp) < abs(frames[j][$1].timestamp - timestamp)
        }) {
            let skew = abs(frames[j][nearest].timestamp - timestamp)
            let bucket = skew <= 0.002 ? 0 : skew <= 0.004 ? 1 : skew <= Self.tolerance ? 2 : skew <= 0.016 ? 3 : 4
            histogram[bucket] += 1
            observedSkew.append(skew * 1000)
            if observedSkew.count > 128 { observedSkew.removeFirst() }
            if skew <= Self.tolerance {
                let other = frames[j][nearest]
                let ordered = camera == .a ? (sample, other) : (other, sample)
                obsolete += nearest + frames[i].count
                frames[i].removeAll(keepingCapacity: true)
                frames[j].removeFirst(nearest + 1)
                lastPaired = [ordered.0.timestamp, ordered.1.timestamp]
                acceptedOffsets.append((ordered.1.timestamp - ordered.0.timestamp) * 1000)
                if acceptedOffsets.count > 128 { acceptedOffsets.removeFirst() }
                return ordered
            }
        }
        frames[i].append(sample)
        for side in [i, j] {
            let boundary = max(latest[1 - side] - Self.tolerance, timestamp - 0.12)
            while let first = frames[side].first, first.timestamp < boundary || frames[side].count > Self.capacity {
                frames[side].removeFirst()
                obsolete += 1
            }
        }
        return nil
    }

    var candidateSkew: (median: Double?, p95: Double?) {
        guard !observedSkew.isEmpty else { return (nil, nil) }
        let ranked = observedSkew.sorted()
        return (ranked[ranked.count / 2], ranked[Int(ceil(Double(ranked.count) * 0.95)) - 1])
    }

    var skew: (median: Double?, p95: Double?, offset: Double?, jitter: Double?) {
        guard !acceptedOffsets.isEmpty else { return (nil, nil, nil, nil) }
        let magnitude = acceptedOffsets.map(abs).sorted()
        let signed = acceptedOffsets.sorted()
        let median = signed[signed.count / 2]
        let jitter = signed.map { abs($0 - median) }.sorted()
        let index = Int(ceil(Double(signed.count) * 0.95)) - 1
        return (magnitude[magnitude.count / 2], magnitude[index], median, jitter[index])
    }
}
