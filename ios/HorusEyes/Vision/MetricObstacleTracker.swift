import Foundation

/// Registration and display filtering for measured components. Risk still consumes the current raw samples.
struct MetricObstacleTracker {
    struct Track {
        let id: Int
        let box: CGRect
        let distanceCM: Float
        let confidence: Float
        let isWall: Bool
        let isCritical: Bool
    }

    struct Update {
        let observations: [SingleObstacle]
        let display: [Track]
    }

    private struct State {
        let track: Track
        let lastBox: CGRect
        let lastDistanceCM: Float
        let timestamp: Double
        let hits: Int
    }

    private var tracks: [State] = []
    private var nextID = 1
    private var lastTimestamp = -Double.infinity

    mutating func update(_ input: [SingleObstacle], timestamp: Double, imageSize: CGSize,
                         yawRate: Float) -> Update {
        guard timestamp.isFinite, timestamp > lastTimestamp, imageSize.width > 0, imageSize.height > 0 else {
            return Update(observations: input, display: [])
        }
        lastTimestamp = timestamp
        tracks.removeAll { timestamp - $0.timestamp > 0.45 }
        let diagonal = hypot(imageSize.width, imageSize.height)
        let detections = input.filter { $0.distCM.isFinite && $0.distCM > 0 && $0.bbox.w > 0 && $0.bbox.h > 0 }
        let boxes = detections.map { CGRect(x: $0.bbox.x, y: $0.bbox.y, width: $0.bbox.w, height: $0.bbox.h) }

        var candidates: [(detection: Int, track: Int, cost: CGFloat)] = []
        for i in detections.indices {
            let box = boxes[i]
            for j in tracks.indices {
                let prior = tracks[j]
                let dt = timestamp - prior.timestamp
                let overlap = Self.overlap(box, prior.lastBox)
                let travel = hypot(box.midX - prior.lastBox.midX, box.midY - prior.lastBox.midY) / diagonal
                let delta = abs(detections[i].distCM - prior.lastDistanceCM)
                let maxDepthChange = max(12, prior.lastDistanceCM * 0.18) + Float(dt) * 140
                let maxTravel = min(0.14, 0.055 + dt * (0.11 + Double(min(abs(yawRate), 1)) * 0.05))
                guard delta <= maxDepthChange, travel <= maxTravel || overlap >= 0.16 else { continue }
                let cost = (1 - overlap) * 0.55 + travel * 2
                    + CGFloat(delta / maxDepthChange) * 0.25
                candidates.append((i, j, cost))
            }
        }
        candidates.sort {
            if $0.cost != $1.cost { return $0.cost < $1.cost }
            if $0.detection != $1.detection { return $0.detection < $1.detection }
            return tracks[$0.track].track.id < tracks[$1.track].track.id
        }

        var used = Set<Int>()
        var associations: [Int: Int] = [:]
        for item in candidates where associations[item.detection] == nil && !used.contains(item.track) {
            associations[item.detection] = item.track
            used.insert(item.track)
        }
        var active: [State] = []
        var observations: [SingleObstacle] = []
        for (i, raw) in detections.enumerated() {
            let prior = associations[i].map { tracks[$0] }
            var measurement = raw
            let id = prior?.track.id ?? nextID
            if prior == nil { nextID += 1 }
            measurement.id = id
            observations.append(measurement)

            let critical = raw.distCM <= Config.distCriticalCM
            let box = boxes[i]
            var displayBox = box
            var displayDistance = raw.distCM
            var hits = 1
            if let prior {
                hits = min(prior.hits + 1, 5)
                let elapsed = timestamp - prior.timestamp
                let sizeRatio = Self.area(box) / Self.area(prior.lastBox)
                if !critical, elapsed <= 0.24, (0.60...1.65).contains(sizeRatio), abs(yawRate) <= 0.35 {
                    let weight = CGFloat(1 - exp(-elapsed / 0.11))
                    let old = prior.track.box
                    displayBox = CGRect(x: old.minX + (box.minX - old.minX) * weight,
                                        y: old.minY + (box.minY - old.minY) * weight,
                                        width: old.width + (box.width - old.width) * weight,
                                        height: old.height + (box.height - old.height) * weight)
                    displayDistance = prior.track.distanceCM + (raw.distCM - prior.track.distanceCM) * Float(weight)
                }
            }
            let confidence = min(1, (0.45 + 0.11 * Float(hits)) * (1 - raw.uncertaintyScore * 0.5))
            let track = Track(id: id, box: displayBox, distanceCM: displayDistance,
                              confidence: confidence, isWall: raw.isWall, isCritical: critical)
            active.append(State(track: track, lastBox: box, lastDistanceCM: raw.distCM,
                                timestamp: timestamp, hits: hits))
        }
        // Unmatched tracks may be reacquired after an occlusion. Only matched tracks are drawn.
        let hidden = tracks.enumerated().filter { !used.contains($0.offset) }.map(\.element)
            .sorted { $0.timestamp > $1.timestamp }
        tracks = Array((active + hidden).prefix(48))
        var visible: [Track] = []
        for item in active.sorted(by: { $0.lastDistanceCM < $1.lastDistanceCM }) {
            let track = item.track
            if visible.contains(where: {
                Self.overlap($0.box, track.box) >= 0.65 &&
                    abs($0.distanceCM - track.distanceCM) < max(8, track.distanceCM * 0.10)
            }) { continue }
            visible.append(track)
        }
        return Update(observations: observations, display: visible)
    }

    private static func area(_ box: CGRect) -> CGFloat { box.width * box.height }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let shared = area(intersection)
        return shared / (area(lhs) + area(rhs) - shared)
    }
}
