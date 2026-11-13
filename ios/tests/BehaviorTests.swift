import Foundation

@main struct BehaviorTests {
    static func obs(_ distance: Float = 30, objects: Bool = true, valid: Bool = true) -> ObstacleDetectionResult {
        let o = SingleObstacle(id: 1, x: 96, y: 128, bbox: (76,98,40,60), pan: 0,
            proximity: 1, distCM: distance, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        return ObstacleDetectionResult(x: 96,y: 128,bbox: o.bbox,pan: 0,proximity: 1,distCM: distance,
            modeText: "OBSTACLE",uncertaintyScore: 0.1,isWall: false,
            sectorDists: ["LEFT":250,"CENTER":distance,"RIGHT":250],allObstacles: objects ? [o] : [],
            isZeroLuxBlind: false,isOverheadHazard: false,isDropOffHazard: false,camWidth: 192,camHeight: 256,isValid: valid)
    }
    static func main() {
        let kin = KinematicsEngine(), budget = AuditoryBudgetManager()
        for i in 1...12 {
            let result = kin.compute(obstacleResult: obs(),frameId: UInt64(i),timestamp: 10+Double(i)*0.1,aeSettleRemaining: 0)
            precondition(result.threatLevel == "CRITICAL" && result.primaryTTC.isInfinite, "Static proximity must not invent TTC")
            precondition(budget.coordinate(obstacleResult: obs(),kinematicsResult: result).isActive)
        }
        for i in 13...32 {
            let result = kin.compute(obstacleResult: obs(250,objects:false),frameId: UInt64(i),timestamp:10+Double(i)*0.1,aeSettleRemaining:0,imuYawRateRadS:0.6)
            precondition(result.threatLevel != "SAFE", "Rotation must not clear hazard")
            precondition(result.primaryTTC.isInfinite)
        }
        let fault = kin.compute(obstacleResult:obs(.nan,valid:false),frameId:33,timestamp:14,aeSettleRemaining:0)
        precondition(fault.threatLevel == "SENSOR_FAULT")
        precondition(budget.coordinate(obstacleResult:obs(.nan,valid:false),kinematicsResult:fault).cueMode == "SYSTEM_FAULT_TONE")
        print("PASS Swift: static TTC, active critical audio, rotation/loss, invalid model precedence")

        testGoldenDirectionalScenarios()
    }

    static func loadGoldenScenarios() -> [[String: Any]]? {
        let cwd = FileManager.default.currentDirectoryPath
        var candidates: [String] = [
            "tests/golden_directional_scenarios.json",
            "\(cwd)/tests/golden_directional_scenarios.json",
            "../tests/golden_directional_scenarios.json",
            "../../tests/golden_directional_scenarios.json"
        ]
        if let ghWs = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"] {
            candidates.insert("\(ghWs)/tests/golden_directional_scenarios.json", at: 0)
        }
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: url)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let scenarios = json?["scenarios"] as? [[String: Any]] {
                    print("[BehaviorTests] Successfully loaded \(scenarios.count) scenarios from: \(path)")
                    return scenarios
                }
            } catch {
                // Continue trying candidate paths
            }
        }
        print("[BehaviorTests] FATAL: Could not load golden scenarios. Tried paths: \(candidates) (CWD: \(cwd))")
        return nil
    }

    static func testGoldenDirectionalScenarios() {
        guard let scenarios = loadGoldenScenarios() else {
            fatalError("Failed to load golden_directional_scenarios.json")
        }
        precondition(scenarios.count == 16, "Must contain 16 golden scenarios")

        for s in scenarios {
            guard let id = s["id"] as? Int,
                  let name = s["name"] as? String,
                  let threat = s["threat"] as? String,
                  let camW = s["cam_width"] as? Int,
                  let camH = s["cam_height"] as? Int,
                  let hfovDeg = s["hfov_deg"] as? Double,
                  let now = s["now"] as? Double,
                  let obsTs = s["obs_timestamp"] as? Double,
                  let isValid = s["is_valid"] as? Bool,
                  let expected = s["expected"] as? [String: Any],
                  let expectedState = expected["state"] as? String else {
                fatalError("Corrupted scenario structure")
            }

            let prevAngle = s["prev_angle"] as? Double

            // Spatial bins
            var bins: [SpatialBin] = []
            if let binsJson = s["spatial_bins"] as? [[String: Any]] {
                for b in binsJson {
                    let binId = b["bin_id"] as? Int ?? 0
                    let aMin = Float(b["angle_min"] as? Double ?? 0.0)
                    let aMax = Float(b["angle_max"] as? Double ?? 0.0)
                    let aCenter = Float(b["angle_center"] as? Double ?? 0.0)
                    let vRatio = Float(b["valid_ratio"] as? Double ?? 0.0)
                    let rStat = Float(b["raw_depth_statistic"] as? Double ?? 0.0)
                    let dist = Float(b["dist_cm"] as? Double ?? Double.nan)
                    let bValid = b["is_valid"] as? Bool ?? false
                    let hasObs = b["has_obstacle"] as? Bool ?? false
                    bins.append(SpatialBin(
                        binId: binId,
                        angleMin: aMin,
                        angleMax: aMax,
                        angleCenter: aCenter,
                        validRatio: vRatio,
                        rawDepthStatistic: rStat,
                        distCM: dist,
                        isValid: bValid,
                        hasObstacle: hasObs,
                        bodyDistCM: dist,
                        groundDistCM: .nan,
                        overheadDistCM: .nan
                    ))
                }
            }

            // Obstacles
            var obstacles: [SingleObstacle] = []
            if let obsJson = s["all_obstacles"] as? [[String: Any]] {
                for o in obsJson {
                    let oId = o["id"] as? Int ?? 0
                    let ox = o["x"] as? Int ?? 0
                    let oy = o["y"] as? Int ?? 0
                    let bboxArr = o["bbox"] as? [Int] ?? [0,0,0,0]
                    let bbox = (x: bboxArr[0], y: bboxArr[1], w: bboxArr[2], h: bboxArr[3])
                    let pan = Float(o["pan"] as? Double ?? 0.0)
                    let prox = Float(o["proximity"] as? Double ?? 0.0)
                    let dist = Float(o["dist_cm"] as? Double ?? 0.0)
                    let modeText = o["mode_text"] as? String ?? ""
                    let uncert = Float(o["uncertainty_score"] as? Double ?? 0.0)
                    let isWall = o["is_wall"] as? Bool ?? false
                    obstacles.append(SingleObstacle(
                        id: oId, x: ox, y: oy, bbox: bbox, pan: pan,
                        proximity: prox, distCM: dist, modeText: modeText,
                        uncertaintyScore: uncert, isWall: isWall
                    ))
                }
            }

            // Sector dists
            var secDists: [String: Float] = [:]
            if let secJson = s["sector_dists"] as? [String: Any] {
                for (k, v) in secJson {
                    if let dVal = v as? Double {
                        secDists[k] = Float(dVal)
                    }
                }
            }

            let centerDist = secDists["CENTER"] ?? 200.0
            let obs = ObstacleDetectionResult(
                x: camW / 2, y: camH / 2,
                bbox: (x: camW / 4, y: camH / 4, w: camW / 2, h: camH / 2),
                pan: 0.0, proximity: 0.5, distCM: centerDist,
                modeText: "TEST", uncertaintyScore: 0.1, isWall: false,
                sectorDists: secDists, allObstacles: obstacles,
                isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
                camWidth: camW, camHeight: camH, isValid: isValid,
                spatialBins: bins, timestamp: obsTs
            )

            let adv = estimateDirectionalAdvisory(
                observation: obs, threat: threat, now: now,
                hfovDeg: hfovDeg, prevAngle: prevAngle
            )

            precondition(adv.state == expectedState, "Scenario \(id) (\(name)) state mismatch: expected \(expectedState), got \(adv.state)")

            if expectedState == "AVAILABLE" {
                guard let angle = adv.angleDeg else {
                    fatalError("Scenario \(id) (\(name)) expected angle for AVAILABLE")
                }
                let sign = expected["direction_sign"] as? String ?? ""
                if sign == "FORWARD" {
                    precondition(abs(angle) <= 2.0, "Scenario \(id) (\(name)) expected FORWARD, got \(angle)")
                } else if sign == "LEFT" {
                    precondition(angle < 0.0, "Scenario \(id) (\(name)) expected LEFT, got \(angle)")
                } else if sign == "RIGHT" {
                    precondition(angle > 0.0, "Scenario \(id) (\(name)) expected RIGHT, got \(angle)")
                }
                if let range = expected["angle_range"] as? [Double] {
                    precondition(angle >= range[0] && angle <= range[1], "Scenario \(id) (\(name)) angle \(angle) outside range \(range)")
                }
            } else {
                precondition(adv.angleDeg == nil, "Scenario \(id) (\(name)) non-AVAILABLE state must have nil angle")
            }
        }
        print("PASS Swift Golden Directional Scenarios (16/16)")
    }
}
