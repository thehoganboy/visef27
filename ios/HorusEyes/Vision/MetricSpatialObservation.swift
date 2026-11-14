import Foundation

extension DepthFrame {
    func spatialObservation() -> ObstacleDetectionResult {
        let camera = geometry
        var bins: [SpatialBin] = []
        var obstacles: [SingleObstacle] = []
        var sectors: [String: Float] = [:]
        var overhead = false
        var dropOff = false
        if error == nil, camera.isValid, width >= 24, height >= 20,
           centimeters.count == width * height {
            func samples(_ x: Range<Int>, _ y: Range<Int>) -> [Float] {
                y.flatMap { row in x.map { centimeters[row * width + $0] } }
                    .filter { $0.isFinite && $0 > 0 }.sorted()
            }
            func quantile(_ sorted: [Float], _ fraction: Double) -> Float {
                guard !sorted.isEmpty else { return .nan }
                return sorted[Int(Double(sorted.count - 1) * fraction)]
            }
            let upper = 0..<(height / 5)
            let body = (height / 5)..<(height * 65 / 100)
            let ground = (height * 65 / 100)..<(height * 85 / 100)
            let bottom = ground.upperBound..<height
            let above = (ground.upperBound - max(1, height / 20))..<ground.upperBound
            for i in 0..<24 {
                let cols = (i * width / 24)..<((i + 1) * width / 24)
                let x0 = i * camera.width / 24
                let x1 = (i + 1) * camera.width / 24
                let angle0 = atan2(Float(x0) - camera.cx, camera.fx) * 180 / .pi
                let angle1 = atan2(Float(x1) - camera.cx, camera.fx) * 180 / .pi
                let bodyValues = samples(cols, body)
                let overheadValues = samples(cols, upper)
                let groundValues = samples(cols, ground)
                let bodyCoverage = Float(bodyValues.count) / Float(cols.count * body.count)
                let coverageOK = bodyCoverage >= 0.75 &&
                    overheadValues.count * 4 >= 3 * cols.count * upper.count &&
                    groundValues.count * 4 >= 3 * cols.count * ground.count
                let dBody = quantile(bodyValues, 0.05)
                let dTop = quantile(overheadValues, 0.05)
                let dGround = quantile(groundValues, 0.05)
                let measured = [dBody, dTop, dGround].filter { $0.isFinite }.min() ?? .nan
                let nearby = bodyValues.prefix { $0 <= Config.distWarningCM }
                let obstacle = nearby.count >= 4
                if obstacle {
                    let cm = quantile(Array(nearby), 0.1)
                    let box = (x: x0, y: camera.height / 5, w: x1 - x0, h: camera.height * 45 / 100)
                    obstacles.append(SingleObstacle(id: i, x: (x0 + x1) / 2, y: box.y + box.h / 2,
                        bbox: box, pan: max(-1, min(1, ((Float(x0 + x1) / 2) - camera.cx) / (Float(camera.width) / 2))),
                        proximity: max(0, min(1, 1 - cm / Config.distWarningCM)), distCM: cm,
                        modeText: "MEASURED OBSTACLE", uncertaintyScore: 1 - bodyCoverage, isWall: false))
                }
                if angle0 <= 5 && angle1 >= -5 {
                    let topNear = quantile(overheadValues, 0.15)
                    let topFar = quantile(overheadValues, 0.70)
                    overhead = overhead || (overheadValues.count * 2 >= cols.count * upper.count &&
                        topNear < Config.distWarningCM && topFar - topNear > Config.overheadDepthDeltaCM)
                    let lowerValues = samples(cols, bottom)
                    let aboveValues = samples(cols, above)
                    let lowerDepth = quantile(lowerValues, 0.5)
                    let aboveDepth = quantile(aboveValues, 0.5)
                    dropOff = dropOff || (lowerValues.count * 2 >= cols.count * bottom.count &&
                        aboveValues.count * 2 >= cols.count * above.count && lowerDepth > aboveDepth / 0.6)
                }
                bins.append(SpatialBin(binId: i, angleMin: angle0, angleMax: angle1,
                    angleCenter: (angle0 + angle1) / 2, validRatio: bodyCoverage,
                    rawDepthStatistic: measured, distCM: measured, isValid: coverageOK,
                    hasObstacle: obstacle, bodyDistCM: dBody, groundDistCM: dGround, overheadDistCM: dTop))
            }
            for (index, name) in ["LEFT", "CENTER", "RIGHT"].enumerated() {
                let local = bins[(index * 8)..<((index + 1) * 8)]
                sectors[name] = local.filter { $0.isValid }.map { $0.distCM }.min()
            }
        }
        obstacles.sort { $0.distCM < $1.distCM }
        let first = obstacles.first
        var result = ObstacleDetectionResult(x: first?.x ?? 0, y: first?.y ?? 0,
            bbox: first?.bbox ?? (0, 0, 0, 0), pan: first?.pan ?? 0, proximity: first?.proximity ?? 0,
            distCM: first?.distCM ?? sectors["CENTER"] ?? .nan,
            modeText: error ?? detail, uncertaintyScore: first?.uncertaintyScore ?? 1,
            isWall: false, sectorDists: sectors, allObstacles: obstacles, isZeroLuxBlind: false,
            isOverheadHazard: overhead, isDropOffHazard: dropOff, camWidth: camera.width, camHeight: camera.height,
            isValid: !obstacles.isEmpty || overhead || dropOff || bins.contains { $0.isValid },
            spatialBins: bins, timestamp: timestamp)
        result.geometry = camera.isValid ? camera : nil
        return result
    }
}
