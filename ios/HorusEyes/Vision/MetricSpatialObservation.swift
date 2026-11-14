import Foundation

extension DepthFrame {
    func spatialObservation() -> ObstacleDetectionResult {
        let camera = geometry
        var bins: [SpatialBin] = []
        var obstacles: [SingleObstacle] = []
        var sectors: [String: Float] = [:]
        var overhead = false
        if error == nil, camera.isValid, width >= 24, height >= 20,
           centimeters.count == width * height {
            func sample(_ index: Int) -> Float {
                guard confidence.count == centimeters.count, confidence[index] >= 1 else { return .nan }
                let value = centimeters[index]
                return value.isFinite && value > 0 ? value : .nan
            }

            var supported = [Float](repeating: .nan, count: centimeters.count)
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let index = y * width + x
                    let value = sample(index)
                    guard value.isFinite else { continue }
                    let tolerance = max(6, value * 0.08)
                    var neighbors = 0
                    var strong = 0
                    for row in (y - 1)...(y + 1) {
                        for col in (x - 1)...(x + 1) where row != y || col != x {
                            let other = row * width + col
                            if abs(sample(other) - value) <= tolerance {
                                neighbors += 1
                                if confidence[other] == 2 { strong += 1 }
                            }
                        }
                    }
                    if neighbors >= (confidence[index] == 2 || strong >= 2 ? 3 : 4) { supported[index] = value }
                }
            }

            let body = (height / 5)..<(height * 65 / 100)
            let upper = 1..<body.lowerBound
            let ground = body.upperBound..<(height * 85 / 100)
            func samples(_ columns: Range<Int>, _ rows: Range<Int>) -> [Float] {
                rows.flatMap { row in columns.map { supported[row * width + $0] } }
                    .filter(\.isFinite).sorted()
            }
            func quantile(_ sorted: [Float], _ fraction: Double) -> Float {
                guard !sorted.isEmpty else { return .nan }
                return sorted[Int(Double(sorted.count - 1) * fraction)]
            }

            // Use connected, depth-continuous body samples to localize distinct objects.
            var visited = [Bool](repeating: false, count: supported.count)
            for y in body {
                for x in 0..<width {
                    let index = y * width + x
                    guard !visited[index], supported[index] <= Config.distWarningCM else { continue }
                    var component = [index]
                    visited[index] = true
                    var cursor = 0
                    var near: [Float] = []
                    var x0 = x, x1 = x, y0 = y, y1 = y
                    while cursor < component.count {
                        let current = component[cursor]
                        cursor += 1
                        let row = current / width, col = current % width
                        x0 = min(x0, col)
                        x1 = max(x1, col)
                        y0 = min(y0, row)
                        y1 = max(y1, row)
                        near.append(supported[current])
                        for (nx, ny) in [(col - 1, row), (col + 1, row), (col, row - 1), (col, row + 1)] {
                            guard (0..<width).contains(nx), body.contains(ny) else { continue }
                            let next = ny * width + nx
                            let value = supported[next]
                            guard !visited[next], value <= Config.distWarningCM,
                                  abs(value - supported[current]) <= max(8, value * 0.1) else { continue }
                            visited[next] = true
                            component.append(next)
                        }
                    }
                    guard component.count >= 6, y1 - y0 >= 2 else { continue }
                    let cm = quantile(near.sorted(), 0.1)
                    let left = x0 * camera.width / width, right = (x1 + 1) * camera.width / width
                    let top = y0 * camera.height / height, bottom = (y1 + 1) * camera.height / height
                    let center = (left + right) / 2
                    obstacles.append(SingleObstacle(id: index, x: center, y: (top + bottom) / 2,
                        bbox: (left, top, right - left, bottom - top),
                        pan: max(-1, min(1, (Float(center) - camera.cx) / (Float(camera.width) / 2))),
                        proximity: max(0, min(1, 1 - cm / Config.distWarningCM)), distCM: cm,
                        modeText: "MEASURED OBSTACLE", uncertaintyScore: 0.2, isWall: false))
                }
            }

            for i in 0..<24 {
                let cols = (i * width / 24)..<((i + 1) * width / 24)
                let x0 = i * camera.width / 24
                let x1 = (i + 1) * camera.width / 24
                let angle0 = atan2(Float(x0) - camera.cx, camera.fx) * 180 / .pi
                let angle1 = atan2(Float(x1) - camera.cx, camera.fx) * 180 / .pi
                let b = samples(cols, body)
                let u = samples(cols, upper)
                let g = samples(cols, ground)
                let coverage = Float(b.count) / Float(cols.count * body.count)
                let dBody = quantile(b, 0.05)
                let dTop = quantile(u, 0.15)
                let dGround = quantile(g, 0.1)
                let topFar = quantile(u, 0.70)
                let topSupported = u.count * 4 >= 3 * cols.count * upper.count
                let overheadHere = topSupported && dTop < Config.distWarningCM
                    && topFar - dTop > Config.overheadDepthDeltaCM
                if angle0 <= 2.5 && angle1 >= -2.5 { overhead = overhead || overheadHere }
                let blocked = obstacles.contains { $0.bbox.x < x1 && $0.bbox.x + $0.bbox.w > x0 }
                bins.append(SpatialBin(binId: i, angleMin: angle0, angleMax: angle1,
                    angleCenter: (angle0 + angle1) / 2, validRatio: coverage,
                    rawDepthStatistic: dBody, distCM: overheadHere ? min(dBody, dTop) : dBody,
                    isValid: coverage >= 0.75 && topSupported,
                    hasObstacle: blocked, bodyDistCM: dBody, groundDistCM: dGround, overheadDistCM: dTop))
            }
            for (index, name) in ["LEFT", "CENTER", "RIGHT"].enumerated() {
                let local = bins[(index * 8)..<((index + 1) * 8)]
                let relevant = name == "CENTER" ? local.filter { abs($0.angleCenter) <= 5 } : Array(local)
                sectors[name] = relevant.filter(\.isValid).map(\.distCM).min()
            }
        }
        obstacles.sort { $0.distCM < $1.distCM }
        let frontal = obstacles.first { abs($0.pan) <= 0.18 }
        let first = frontal ?? obstacles.first
        var result = ObstacleDetectionResult(x: first?.x ?? 0, y: first?.y ?? 0,
            bbox: first?.bbox ?? (0, 0, 0, 0), pan: first?.pan ?? 0, proximity: first?.proximity ?? 0,
            distCM: first?.distCM ?? sectors["CENTER"] ?? .nan,
            modeText: error ?? detail, uncertaintyScore: first?.uncertaintyScore ?? 1,
            isWall: false, sectorDists: sectors, allObstacles: obstacles, isZeroLuxBlind: false,
            isOverheadHazard: overhead, isDropOffHazard: false, camWidth: camera.width, camHeight: camera.height,
            isValid: !obstacles.isEmpty || overhead || bins.contains { $0.isValid },
            spatialBins: bins, timestamp: timestamp)
        result.geometry = camera.isValid ? camera : nil
        return result
    }
}
