import Foundation

enum StereoNegotiation {
    static let pairOrder = [["wide", "ultrawide"], ["wide", "tele"], ["ultrawide", "tele"]]

    static func supportedPairs(in sets: [Set<String>]) -> [[String]] {
        pairOrder.filter { pair in sets.contains { $0.isSuperset(of: pair) } }
    }

    struct Rate: Hashable {
        let frames: Int32
        var fps: Double { Double(frames) / Double(interval) }
        var interval: Int64 = 1
        static let candidates: [Self] = [
            .init(frames: 30), .init(frames: 30_000, interval: 1001),
            .init(frames: 24), .init(frames: 24_000, interval: 1001),
            .init(frames: 15), .init(frames: 12), .init(frames: 10)
        ]
    }

    struct Format {
        let id: Int
        let multicam: Bool
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let binned: Bool
        let fov: Double
        let rates: [Rate]
        var pixels: Int { width * height }
        var signature: String { "\(width)x\(height)/\(pixelFormat)/\(binned)/\(fov)" }
    }

    struct Candidate: Equatable {
        let a: Int
        let b: Int
        let rate: Rate
    }

    static func candidates(_ a: [Format], _ b: [Format], preferred: [String]? = nil) -> [Candidate] {
        func usable(_ formats: [Format]) -> [Format] {
            formats.filter { $0.multicam && $0.width >= 2 && $0.height >= 2 && !$0.rates.isEmpty }
        }
        let left = usable(a), right = usable(b)
        var tiers: [[Candidate]] = []
        for rate in Rate.candidates {
            let lhs = left.filter { $0.rates.contains(rate) }
            let rhs = right.filter { $0.rates.contains(rate) }
            func score(_ format: Format) -> Double {
                Double(format.pixels) * (format.binned ? 0.55 : 1)
            }
            let pairs = lhs.flatMap { l in rhs.map { (l, $0) } }.sorted { x, y in
                func rank(_ lhs: Format, _ rhs: Format) -> Double {
                    let fovRatio = lhs.fov > 0 && rhs.fov > 0 ? min(lhs.fov, rhs.fov) / max(lhs.fov, rhs.fov) : 0.5
                    let aspect = abs(Double(lhs.width) / Double(lhs.height) - Double(rhs.width) / Double(rhs.height))
                    return (score(lhs) + score(rhs)) * (1 + aspect * 0.2 + (1 - fovRatio) * 0.4)
                }
                let xPreferred = [x.0.signature, x.1.signature] == preferred
                let yPreferred = [y.0.signature, y.1.signature] == preferred
                if xPreferred != yPreferred { return xPreferred }
                let a = rank(x.0, x.1), b = rank(y.0, y.1)
                return a == b ? (x.0.id, x.1.id) < (y.0.id, y.1.id) : a < b
            }
            // Keep geometry diversity, including asymmetric pairs, within the retry budget.
            var seen = Set<[String]>()
            var shortlist: [Candidate] = []
            for (a, b) in pairs where seen.insert([a.signature, b.signature]).inserted {
                shortlist.append(Candidate(a: a.id, b: b.id, rate: rate))
                if shortlist.count == 3 { break }
            }
            if !shortlist.isEmpty { tiers.append(shortlist) }
        }
        // Prefer materially different rates before re-testing another format at the same rate.
        return (0..<3).flatMap { index in tiers.compactMap { $0.count > index ? $0[index] : nil } }
    }

    struct Delivery {
        private(set) var accepted = 0
        private(set) var rejected = 0
        private(set) var consecutiveRejected = 0
        private var recent: [Bool] = []
        private var first: Double?
        private(set) var last: Double?
        private(set) var rejection = "no synchronized callback"

        var ready: Bool {
            guard let first, let last, last - first >= 0.20, recent.count >= 5 else { return false }
            return recent.filter { $0 }.count * 3 >= recent.count * 2
        }

        var fps: Double {
            guard let first, let last, last > first else { return 0 }
            return Double(accepted - 1) / (last - first)
        }

        mutating func sample(timestamp: Double?, rejection: String = "") {
            if let timestamp, timestamp.isFinite, last.map({ timestamp > $0 }) ?? true {
                if first == nil { first = timestamp }
                last = timestamp
                accepted += 1
                consecutiveRejected = 0
                recent.append(true)
            } else {
                rejected += 1
                consecutiveRejected += 1
                self.rejection = rejection.isEmpty ? "nonmonotonic timestamp" : rejection
                recent.append(false)
            }
            if recent.count > 12 { recent.removeFirst() }
        }
    }
}
