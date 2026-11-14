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
    static func nativeMetricDepthTests() {
        let geometry = DepthGeometry(width: 480, height: 640, fx: 420, cx: 240)
        func observe(_ depth: Float) -> ObstacleDetectionResult {
            let frame = DepthFrame(source: .lidar, timestamp: 10, geometry: geometry,
                width: 48, height: 64, centimeters: Array(repeating: depth, count: 48 * 64),
                confidence: Array(repeating: 2, count: 48 * 64), detail: "Fixture")
            return frame.spatialObservation()
        }
        let clear = observe(200)
        precondition(clear.sectorDists["CENTER"] == 200)
        precondition(estimateDirectionalAdvisory(observation: clear, threat: "SAFE", now: 10.1).state == "AVAILABLE")
        precondition(estimateDirectionalAdvisory(observation: observe(20), threat: "CRITICAL", now: 10.1).state == "STOP")
        precondition(estimateDirectionalAdvisory(observation: clear, threat: "SAFE", now: 11).state == "UNAVAILABLE")
        precondition(!observe(.nan).isValid)
        let unavailable = DepthFrame(source: .stereo, timestamp: 10, geometry: geometry,
            width: 48, height: 64, centimeters: Array(repeating: 200, count: 48 * 64),
            confidence: [], detail: "Fixture", error: "Calibration unverified")
        precondition(!unavailable.spatialObservation().isValid)
        func scene(_ depth: (Int, Int) -> Float) -> ObstacleDetectionResult {
            let values = (0..<(48 * 64)).map { depth($0 % 48, $0 / 48) }
            return DepthFrame(source: .lidar, timestamp: 10, geometry: geometry, width: 48, height: 64,
                centimeters: values, confidence: Array(repeating: 2, count: values.count), detail: "Fixture")
                .spatialObservation()
        }
        let scattered = scene { x, y in [18, 23, 25, 30].contains(x) && y == 25 ? 20 : 200 }
        precondition(scattered.allObstacles.isEmpty && scattered.sectorDists["CENTER"] == 200)
        let floor = scene { _, y in y >= 42 ? 32 : 200 }
        precondition(floor.allObstacles.isEmpty && estimateDirectionalAdvisory(observation: floor, threat: "SAFE", now: 10.1).state == "AVAILABLE")
        let lateral = scene { x, y in (x < 6 || x >= 42) && (14..<42).contains(y) ? 70 : 200 }
        precondition(lateral.allObstacles.count == 2)
        let forward = estimateDirectionalAdvisory(observation: lateral, threat: "WARNING", now: 10.1)
        precondition(forward.state == "AVAILABLE" && abs(forward.angleDeg ?? 100) <= 2)
        print("PASS 10 native metric spatial checks")
    }

    static func main() {
        nativeMetricDepthTests()
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
        testSourceTimestampLifecycleAndFreshness()
        testTensorSpatialIntegration()
        testRawTensorToSpatialBins()
        testLowLightRobustnessAndLocalDisparity()
        testLowLightReleaseCandidateCorrectiveAudit()
        testFinalDeviceReadinessAudioSync()
        testObstacleAvoidanceHotfixScenarios()
        testCenterCorridorFirstHotfixScenarios()
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

    static func testSourceTimestampLifecycleAndFreshness() {
        let now = 100.0
        func makeObs(ts: Double) -> ObstacleDetectionResult {
            return ObstacleDetectionResult(
                x: 96, y: 128, bbox: (x: 48, y: 64, w: 96, h: 128),
                pan: 0.0, proximity: 0.2, distCM: 200.0,
                modeText: "SAFE", uncertaintyScore: 0.05, isWall: false,
                sectorDists: ["LEFT": 200.0, "CENTER": 200.0, "RIGHT": 200.0],
                allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
                camWidth: 192, camHeight: 256, isValid: true,
                spatialBins: [], timestamp: ts
            )
        }

        // Case 1: Fresh observation (age = 0.10s) -> AVAILABLE
        let adv1 = estimateDirectionalAdvisory(observation: makeObs(ts: now - 0.10), threat: "SAFE", now: now)
        precondition(adv1.state == "AVAILABLE", "Case 1 failed: fresh observation must be AVAILABLE")
        precondition(adv1.sourceTimestamp == now - 0.10, "Case 1 failed: source timestamp must be preserved")

        // Case 2: Borderline fresh (age = 0.74s) -> AVAILABLE
        let adv2 = estimateDirectionalAdvisory(observation: makeObs(ts: now - 0.74), threat: "SAFE", now: now)
        precondition(adv2.state == "AVAILABLE", "Case 2 failed: 0.74s old observation must be AVAILABLE")

        // Case 3: Exact boundary (age = 0.75s) -> AVAILABLE
        let adv3 = estimateDirectionalAdvisory(observation: makeObs(ts: now - 0.75), threat: "SAFE", now: now)
        precondition(adv3.state == "AVAILABLE", "Case 3 failed: 0.75s old observation must be AVAILABLE")

        // Case 4: Stale observation (age = 0.76s) -> UNAVAILABLE
        let adv4 = estimateDirectionalAdvisory(observation: makeObs(ts: now - 0.76), threat: "SAFE", now: now)
        precondition(adv4.state == "UNAVAILABLE", "Case 4 failed: 0.76s old observation must be UNAVAILABLE")

        // Case 5: Extremely stale (age = 5.0s) -> UNAVAILABLE
        let adv5 = estimateDirectionalAdvisory(observation: makeObs(ts: now - 5.0), threat: "SAFE", now: now)
        precondition(adv5.state == "UNAVAILABLE", "Case 5 failed: 5.0s old observation must be UNAVAILABLE")

        // Case 6: Negative age / future observation anomaly (age = -0.10s) -> UNAVAILABLE
        let adv6 = estimateDirectionalAdvisory(observation: makeObs(ts: now + 0.10), threat: "SAFE", now: now)
        precondition(adv6.state == "UNAVAILABLE", "Case 6 failed: future observation anomaly must be UNAVAILABLE")

        // Case 7: Zero timestamp fallback (ts = 0.0) -> UNAVAILABLE
        let adv7 = estimateDirectionalAdvisory(observation: makeObs(ts: 0.0), threat: "SAFE", now: now)
        precondition(adv7.state == "UNAVAILABLE", "Case 7 failed: zero timestamp must be UNAVAILABLE")

        // Case 8: NaN / Infinite timestamp -> UNAVAILABLE
        let adv8 = estimateDirectionalAdvisory(observation: makeObs(ts: Double.nan), threat: "SAFE", now: now)
        precondition(adv8.state == "UNAVAILABLE", "Case 8 failed: NaN timestamp must be UNAVAILABLE")

        // Case 9: drawableAngle within 750ms -> returns angle
        let advFresh = DirectionalAdvisory(state: "AVAILABLE", angleDeg: 12.0, confidence: 0.55, observedAngularRange: -32.5...32.5, sourceTimestamp: 10.0)
        precondition(advFresh.drawableAngle(now: 10.20) == 12.0, "Case 9 failed: drawableAngle must return angle within freshness window")
        precondition(advFresh.drawableAngle(now: 10.75) == 12.0, "Case 9 failed: drawableAngle must return angle at 0.75s boundary")

        // Case 10: drawableAngle expired at > 750ms -> returns nil
        precondition(advFresh.drawableAngle(now: 10.76) == nil, "Case 10 failed: drawableAngle must return nil after 0.75s")
        precondition(advFresh.drawableAngle(now: 15.0) == nil, "Case 10 failed: drawableAngle must return nil for stale timestamp")

        print("PASS Swift Source Timestamp Lifecycle & Freshness (10/10)")
    }


    // Exercise the real native disparity -> bin extractor, not hand-built SpatialBin objects.
    // These are deterministic synthetic tensors, NOT physical camera validation.
    static func testRawTensorToSpatialBins() {
        let engine = DepthEngine() // CoreML model is optional for this pure extraction test.
        let gridW = 48
        let gridH = 64
        let base: Float = 250.0
        func blank(_ value: Float = 250.0) -> [Float] {
            return [Float](repeating: value, count: gridW * gridH)
        }
        func getBins(_ raw: [Float], obstacles: [SingleObstacle] = []) -> [SpatialBin] {
            return engine.computeSpatialBins(
                rawDisparity: raw, w: 192, h: 256,
                detectedObstacles: obstacles, numBins: 24, hfovDeg: 65.0
            )
        }
        func makeObs(_ bins: [SpatialBin], center: Float = 200.0, valid: Bool = true,
                     objects: [SingleObstacle] = [], overhead: Bool = false) -> ObstacleDetectionResult {
            return ObstacleDetectionResult(
                x: 96, y: 128, bbox: (48, 64, 96, 128),
                pan: 0.0, proximity: 0.0, distCM: center,
                modeText: "TENSOR_TEST", uncertaintyScore: 0.1, isWall: false,
                sectorDists: ["LEFT": 200.0, "CENTER": center, "RIGHT": 200.0],
                allObstacles: objects, isZeroLuxBlind: false,
                isOverheadHazard: overhead, isDropOffHazard: false,
                camWidth: 192, camHeight: 256, isValid: valid,
                spatialBins: bins, timestamp: 10.0
            )
        }

        // Case 1: uniform valid raw disparity supports a forward advisory.
        let clear = getBins(blank(base))
        precondition(clear.count == 24 && clear.allSatisfy { $0.isValid && $0.validRatio > 0.99 },
                     "Raw tensor case 1: 24 valid spatial bins expected")
        let clearAdv = estimateDirectionalAdvisory(
            observation: makeObs(clear), threat: "SAFE", now: 10.0
        )
        precondition(clearAdv.state == "AVAILABLE" && abs(clearAdv.angleDeg ?? 999) <= 2.0,
                     "Raw tensor case 1: forward should remain available")

        // Case 2: near lateral bands must not block a valid center corridor.
        var sidewalls = blank(base)
        for y in 0..<gridH {
            for x in 0..<8 { sidewalls[y * gridW + x] = 750 }
            for x in 40..<gridW { sidewalls[y * gridW + x] = 750 }
        }
        let sideBins = getBins(sidewalls)
        precondition(sideBins[0].isValid && sideBins[12].isValid &&
                     sideBins[0].distCM < sideBins[12].distCM &&
                     sideBins[23].distCM < sideBins[12].distCM,
                     "Raw tensor case 2: sidewalls must have nearer depth than center")
        let sideAdv = estimateDirectionalAdvisory(
            observation: makeObs(sideBins), threat: "SAFE", now: 10.0
        )
        precondition(sideAdv.state == "AVAILABLE" && abs(sideAdv.angleDeg ?? 999) <= 3.0,
                     "Raw tensor case 2: supported forward corridor should not be blocked")

        // Case 3: invalid raw center columns must remain invalid and cannot invent clearance.
        var missingCenter = blank(base)
        for y in 0..<gridH {
            for x in 22..<26 { missingCenter[y * gridW + x] = .nan }
        }
        let missingBins = getBins(missingCenter)
        precondition(!missingBins[11].isValid && !missingBins[12].isValid,
                     "Raw tensor case 3: invalid center pixels must not be filled")
        let unknownAdv = estimateDirectionalAdvisory(
            observation: makeObs(missingBins), threat: "SAFE", now: 10.0
        )
        precondition(unknownAdv.state == "UNAVAILABLE" && unknownAdv.angleDeg == nil,
                     "Raw tensor case 3: unsupported center must not create an arrow")

        // Case 4: upper-band disparity must be extracted separately from the body band.
        var overhead = blank(base)
        for y in 0..<12 {
            for x in 0..<gridW { overhead[y * gridW + x] = 750 }
        }
        let overheadBins = getBins(overhead)
        precondition(overheadBins[12].overheadDistCM.isFinite &&
                     overheadBins[12].bodyDistCM.isFinite &&
                     overheadBins[12].overheadDistCM < overheadBins[12].bodyDistCM,
                     "Raw tensor case 4: overhead band must be independently measured")
        let overAdv = estimateDirectionalAdvisory(
            observation: makeObs(overheadBins, overhead: true), threat: "CRITICAL", now: 10.0
        )
        precondition(overAdv.state == "STOP",
                     "Raw tensor case 4: critical overhead hazard must preempt guidance")

        // Case 5: actual projected obstacle bbox populates occupancy in the appropriate bins.
        let obj = SingleObstacle(id: 42, x: 96, y: 100, bbox: (80, 48, 32, 120),
                                 pan: 0.0, proximity: 0.6, distCM: 50,
                                 modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let occupied = getBins(blank(base), obstacles: [obj])
        precondition(occupied[11].hasObstacle && occupied[12].hasObstacle &&
                     !occupied[0].hasObstacle && !occupied[23].hasObstacle,
                     "Raw tensor case 5: obstacle occupancy should match projected bbox")

        print("PASS Swift Raw Disparity -> Spatial Bins -> Advisory (5 cases)")
    }

    static func testTensorSpatialIntegration() {
        func makeBin(id: Int, dist: Float, isValid: Bool = true, bodyDist: Float = .nan, groundDist: Float = .nan, overheadDist: Float = .nan, hasObs: Bool = false) -> SpatialBin {
            let halfFov: Float = 32.5
            let binW: Float = 65.0 / 24.0
            let aMin = -halfFov + Float(id) * binW
            let aMax = aMin + binW
            let aCenter = (aMin + aMax) / 2.0
            let bDist = bodyDist.isNaN ? dist : bodyDist
            return SpatialBin(
                binId: id, angleMin: aMin, angleMax: aMax, angleCenter: aCenter,
                validRatio: isValid ? 1.0 : 0.0, rawDepthStatistic: 200.0,
                distCM: isValid ? dist : .nan, isValid: isValid, hasObstacle: hasObs,
                bodyDistCM: bDist, groundDistCM: groundDist, overheadDistCM: overheadDist
            )
        }

        // 1. Open central corridor
        let bins1 = (0..<24).map { makeBin(id: $0, dist: 220.0) }
        let obs1 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.0, distCM: 220.0,
            modeText: "SAFE", uncertaintyScore: 0.05, isWall: false,
            sectorDists: ["LEFT": 220.0, "CENTER": 220.0, "RIGHT": 220.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins1, timestamp: 10.0
        )
        let adv1 = estimateDirectionalAdvisory(observation: obs1, threat: "SAFE", now: 10.0)
        precondition(adv1.state == "AVAILABLE" && abs(adv1.angleDeg ?? 999.0) <= 2.0, "Tensor 1 failed")

        // 2. Near sidewalls (left & right 28cm, center 200cm)
        let bins2 = (0..<24).map { id -> SpatialBin in
            let d: Float = (id < 4 || id >= 20) ? 28.0 : 200.0
            return makeBin(id: id, dist: d)
        }
        let obs2 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.2, distCM: 200.0,
            modeText: "DOORWAY", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 28.0, "CENTER": 200.0, "RIGHT": 28.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins2, timestamp: 10.0
        )
        let adv2 = estimateDirectionalAdvisory(observation: obs2, threat: "SAFE", now: 10.0)
        precondition(adv2.state == "AVAILABLE" && abs(adv2.angleDeg ?? 999.0) <= 3.0, "Tensor 2 failed")

        // 3. Narrow opening below clearance requirement
        let bins3 = (0..<24).map { id -> SpatialBin in
            let d: Float = (id >= 10 && id <= 13) ? 200.0 : 28.0
            return makeBin(id: id, dist: d)
        }
        let obsItemL = SingleObstacle(id: 1, x: 40, y: 108, bbox: (0, 51, 80, 115), pan: -0.5, proximity: 0.9, distCM: 28.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let obsItemR = SingleObstacle(id: 2, x: 152, y: 108, bbox: (112, 51, 80, 115), pan: 0.5, proximity: 0.9, distCM: 28.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let obs3 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.9, distCM: 28.0,
            modeText: "WALL", uncertaintyScore: 0.1, isWall: true,
            sectorDists: ["LEFT": 28.0, "CENTER": 28.0, "RIGHT": 28.0],
            allObstacles: [obsItemL, obsItemR], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins3, timestamp: 10.0
        )
        let adv3 = estimateDirectionalAdvisory(observation: obs3, threat: "CRITICAL", now: 10.0)
        precondition(adv3.state == "STOP", "Tensor 3 failed")

        // 4. Central near obstruction (55cm) with supported side route
        let bins4 = (0..<24).map { id -> SpatialBin in
            let d: Float = (id >= 9 && id <= 14) ? 55.0 : 200.0
            return makeBin(id: id, dist: d)
        }
        let obsItem4 = SingleObstacle(id: 1, x: 96, y: 108, bbox: (72, 51, 48, 115), pan: 0.0, proximity: 0.7, distCM: 55.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs4 = ObstacleDetectionResult(
            x: 96, y: 108, bbox: (72, 51, 48, 115), pan: 0.0, proximity: 0.7, distCM: 55.0,
            modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 200.0, "CENTER": 55.0, "RIGHT": 200.0],
            allObstacles: [obsItem4], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins4, timestamp: 10.0
        )
        let adv4 = estimateDirectionalAdvisory(observation: obs4, threat: "WARNING", now: 10.0)
        precondition(adv4.state == "AVAILABLE" && abs(adv4.angleDeg ?? 0.0) >= 5.0, "Tensor 4 failed")

        // 5. Invalid outer bins: edge distortion/NaNs, center clear
        let bins5 = (0..<24).map { id -> SpatialBin in
            let valid = !(id < 3 || id >= 21)
            return makeBin(id: id, dist: valid ? 180.0 : .nan, isValid: valid)
        }
        let obs5 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.2, distCM: 180.0,
            modeText: "SAFE", uncertaintyScore: 0.2, isWall: false,
            sectorDists: ["LEFT": .nan, "CENTER": 180.0, "RIGHT": .nan],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins5, timestamp: 10.0
        )
        let adv5 = estimateDirectionalAdvisory(observation: obs5, threat: "SAFE", now: 10.0)
        precondition(adv5.state == "AVAILABLE" && abs(adv5.angleDeg ?? 999.0) <= 2.0, "Tensor 5 failed")

        // 6. Invalid central bins: central region invalid -> UNAVAILABLE
        let bins6 = (0..<24).map { id -> SpatialBin in
            let valid = !(id == 11 || id == 12)
            return makeBin(id: id, dist: valid ? 200.0 : .nan, isValid: valid)
        }
        let obs6 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.0, distCM: .nan,
            modeText: "UNKNOWN", uncertaintyScore: 0.9, isWall: false,
            sectorDists: ["LEFT": 200.0, "CENTER": .nan, "RIGHT": 200.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins6, timestamp: 10.0
        )
        let adv6 = estimateDirectionalAdvisory(observation: obs6, threat: "SAFE", now: 10.0)
        precondition(adv6.state == "UNAVAILABLE", "Tensor 6 failed")

        // 7. Upper hazard multi-band under CRITICAL threat -> STOP
        let bins7 = (0..<24).map { makeBin(id: $0, dist: 180.0, overheadDist: 40.0) }
        let obsItem7 = SingleObstacle(id: 1, x: 96, y: 20, bbox: (30, 0, 132, 40), pan: 0.0, proximity: 0.8, distCM: 40.0, modeText: "OVERHEAD", uncertaintyScore: 0.1, isWall: false)
        let obs7 = ObstacleDetectionResult(
            x: 96, y: 20, bbox: (30, 0, 132, 40), pan: 0.0, proximity: 0.8, distCM: 40.0,
            modeText: "OVERHEAD", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 40.0, "CENTER": 40.0, "RIGHT": 40.0],
            allObstacles: [obsItem7], isZeroLuxBlind: false, isOverheadHazard: true, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins7, timestamp: 10.0
        )
        let adv7 = estimateDirectionalAdvisory(observation: obs7, threat: "CRITICAL", now: 10.0)
        precondition(adv7.state == "STOP", "Tensor 7 failed")

        // 8. Low ground obstacle: ground band caught hazard
        let bins8 = (0..<24).map { id -> SpatialBin in
            let gDist: Float = (id >= 9 && id <= 14) ? 30.0 : .nan
            return makeBin(id: id, dist: 180.0, groundDist: gDist)
        }
        precondition(bins8.contains(where: { !$0.groundDistCM.isNaN && $0.groundDistCM < 50.0 }), "Tensor 8 failed")

        // 9. Partly visible lateral object at frame edge
        let bins9 = (0..<24).map { id -> SpatialBin in
            let d: Float = (id >= 20) ? 55.0 : 180.0
            return makeBin(id: id, dist: d)
        }
        let obsItem9 = SingleObstacle(id: 1, x: 176, y: 108, bbox: (160, 51, 32, 115), pan: 0.8, proximity: 0.6, distCM: 55.0, modeText: "OBSTACLE", uncertaintyScore: 0.15, isWall: false)
        let obs9 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.3, distCM: 180.0,
            modeText: "SAFE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 200.0, "CENTER": 180.0, "RIGHT": 55.0],
            allObstacles: [obsItem9], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins9, timestamp: 10.0
        )
        let adv9 = estimateDirectionalAdvisory(observation: obs9, threat: "WARNING", now: 10.0)
        precondition(adv9.state == "AVAILABLE" && abs(adv9.angleDeg ?? 999.0) <= 15.0, "Tensor 9 failed")

        // 10. Entirely invalid tensor: all bins invalid -> UNKNOWN
        let bins10 = (0..<24).map { makeBin(id: $0, dist: .nan, isValid: false) }
        let obs10 = ObstacleDetectionResult(
            x: 0, y: 0, bbox: (0, 0, 0, 0), pan: 0.0, proximity: 0.0, distCM: .nan,
            modeText: "FAULT", uncertaintyScore: 1.0, isWall: false,
            sectorDists: [:], allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 0, camHeight: 0, isValid: false, spatialBins: bins10, timestamp: 10.0
        )
        let adv10 = estimateDirectionalAdvisory(observation: obs10, threat: "SENSOR_FAULT", now: 10.0)
        precondition(adv10.state == "UNKNOWN", "Tensor 10 failed")

        print("PASS Swift Tensor Spatial Integration (10/10)")
    }

    static func testLowLightRobustnessAndLocalDisparity() {
        let engine = DepthEngine()
        let halfFov: Float = 32.5
        let binW: Float = 65.0 / 24.0

        func makeBin(id: Int, dist: Float, isValid: Bool = true) -> SpatialBin {
            let aMin = -halfFov + Float(id) * binW
            let aMax = aMin + binW
            let aCenter = (aMin + aMax) / 2.0
            return SpatialBin(
                binId: id, angleMin: aMin, angleMax: aMax, angleCenter: aCenter,
                validRatio: isValid ? 1.0 : 0.0, rawDepthStatistic: 200.0,
                distCM: isValid ? dist : .nan, isValid: isValid, hasObstacle: false,
                bodyDistCM: isValid ? dist : .nan, groundDistCM: .nan, overheadDistCM: .nan
            )
        }

        // Test 1: Isolated single invalid disparity sample on outer edge must not suppress guidance
        var tensor1 = [Float](repeating: 200.0, count: 48 * 64)
        tensor1[0] = Float.nan // Single NaN at top-left corner
        let bins1 = engine.computeSpatialBins(rawDisparity: tensor1, w: 192, h: 256, detectedObstacles: [])
        let obs1 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.1, distCM: 200.0,
            modeText: "SAFE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 200.0, "CENTER": 200.0, "RIGHT": 200.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins1, timestamp: 10.0
        )
        let adv1 = estimateDirectionalAdvisory(observation: obs1, threat: "SAFE", now: 10.0)
        precondition(adv1.state == "AVAILABLE" && abs(adv1.angleDeg ?? 99.0) <= 2.0, "Test 1 failed: Isolated NaN on edge must not suppress guidance")
        precondition(adv1.reasonCode == "AVAILABLE_FORWARD", "Test 1 reason code expected AVAILABLE_FORWARD, got \(adv1.reasonCode)")

        // Test 2: Corridor with valid local evidence but center distance below 150 cm (e.g. 110 cm)
        let bins2 = (0..<24).map { makeBin(id: $0, dist: 110.0) }
        let obs2 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.3, distCM: 110.0,
            modeText: "SAFE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 110.0, "CENTER": 110.0, "RIGHT": 110.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins2, timestamp: 10.0
        )
        let adv2 = estimateDirectionalAdvisory(observation: obs2, threat: "SAFE", now: 10.0)
        precondition(adv2.state == "AVAILABLE" && abs(adv2.angleDeg ?? 99.0) <= 2.0, "Test 2 failed: 110cm open corridor must be AVAILABLE")
        precondition(adv2.reasonCode == "AVAILABLE_FORWARD", "Test 2 reason code expected AVAILABLE_FORWARD, got \(adv2.reasonCode)")

        // Test 3: Genuine close central obstruction (< 40cm) forces STOP
        let bins3 = (0..<24).map { makeBin(id: $0, dist: 30.0) }
        let obs3 = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 1.0, distCM: 30.0,
            modeText: "WALL", uncertaintyScore: 0.1, isWall: true,
            sectorDists: ["LEFT": 30.0, "CENTER": 30.0, "RIGHT": 30.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins3, timestamp: 10.0
        )
        let adv3 = estimateDirectionalAdvisory(observation: obs3, threat: "CRITICAL", now: 10.0)
        precondition(adv3.state == "STOP", "Test 3 failed: 30cm obstruction must force STOP")

        // Test 4: Stale timestamp (> 750ms) forces UNAVAILABLE
        let adv4 = estimateDirectionalAdvisory(observation: obs2, threat: "SAFE", now: 11.0) // 1.0s age
        precondition(adv4.state == "UNAVAILABLE", "Test 4 failed: Stale observation must be UNAVAILABLE")
        precondition(adv4.reasonCode == "SOURCE_FRAME_STALE", "Test 4 reason code expected SOURCE_FRAME_STALE, got \(adv4.reasonCode)")

        print("PASS Swift Low-Light Guidance Stability & Local Disparity (4 tests)")
    }

    static func testLowLightReleaseCandidateCorrectiveAudit() {
        let engine = DepthEngine()
        let kin = KinematicsEngine()
        let halfFov: Float = 32.5
        let binW: Float = 65.0 / 24.0

        func makeBin(id: Int, dist: Float, isValid: Bool = true) -> SpatialBin {
            let aMin = -halfFov + Float(id) * binW
            let aMax = aMin + binW
            let aCenter = (aMin + aMax) / 2.0
            return SpatialBin(
                binId: id, angleMin: aMin, angleMax: aMax, angleCenter: aCenter,
                validRatio: isValid ? 1.0 : 0.0, rawDepthStatistic: 200.0,
                distCM: dist, isValid: isValid, hasObstacle: false,
                bodyDistCM: dist, groundDistCM: .nan, overheadDistCM: .nan
            )
        }

        // 1. P0-A / P0-B: Directional STOP under non-CRITICAL threat (e.g. WARNING)
        let bins30cm = (0..<24).map { makeBin(id: $0, dist: 30.0) }
        let obs30cm = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (0, 0, 192, 256), pan: 0.0, proximity: 1.0, distCM: 30.0,
            modeText: "WALL", uncertaintyScore: 0.1, isWall: true,
            sectorDists: ["LEFT": 30.0, "CENTER": 30.0, "RIGHT": 30.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: bins30cm, timestamp: 10.0
        )
        let advStop = estimateDirectionalAdvisory(observation: obs30cm, threat: "WARNING", now: 10.0)
        precondition(advStop.state == "STOP", "P0-A failed: Directional STOP must trigger even under WARNING threat")
        precondition(advStop.reasonCode == "CRITICAL_OBSTACLE" || advStop.reasonCode == "CORRIDOR_OBSTRUCTED", "P0-A reason code expected STOP code, got \(advStop.reasonCode)")

        // 2. P0-B: Nonfinite clearance rejection (valid angular bin coverage but all-NaN distances)
        let binsNan = (0..<24).map { makeBin(id: $0, dist: .nan, isValid: true) }
        let obsNan = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.2, distCM: .nan,
            modeText: "SAFE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": .nan, "CENTER": .nan, "RIGHT": .nan],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: binsNan, timestamp: 10.0
        )
        let advNan = estimateDirectionalAdvisory(observation: obsNan, threat: "SAFE", now: 10.0)
        precondition(advNan.state == "UNAVAILABLE", "P0-B failed: NaN distances must yield UNAVAILABLE")
        precondition(advNan.reasonCode == "LOCAL_DEPTH_MISSING", "P0-B reason code expected LOCAL_DEPTH_MISSING, got \(advNan.reasonCode)")

        // 3. P0-C: Decoupled local observability from primary TTC distance in KinematicsEngine
        let obsValidLocalWithNanPrimary = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.2, distCM: .nan,
            modeText: "SAFE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 120.0, "CENTER": 120.0, "RIGHT": 120.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: (0..<24).map { makeBin(id: $0, dist: 120.0) }, timestamp: 20.0
        )
        let kinResult = kin.compute(obstacleResult: obsValidLocalWithNanPrimary, frameId: 100, timestamp: 20.0, aeSettleRemaining: 0)
        precondition(kinResult.threatLevel != "SENSOR_FAULT", "P0-C failed: Valid local observation with NaN primary distCM must not trigger SENSOR_FAULT (got \(kinResult.threatLevel))")
        precondition(kinResult.primaryTTC.isInfinite, "P0-C failed: Primary TTC must be infinite when primary dist is NaN")

        // 4. P1-D: All-NaN ground disparity handling in DepthEngine
        var tensorWithNanGround = [Float](repeating: 200.0, count: 48 * 64)
        // Set lower 25% (ground region) to NaN
        let botCut = Int(Double(64) * 0.78)
        for y in botCut..<64 {
            for x in 0..<48 {
                tensorWithNanGround[y * 48 + x] = .nan
            }
        }
        let depthResult = engine.evaluateSpatialEngineV8(
            rawDisparity: tensorWithNanGround,
            w: 192,
            h: 256,
            meanLuma: 50.0,
            sourceTimestamp: 10.0
        )
        precondition(!depthResult.isDropOffHazard, "P1-D failed: All-NaN ground disparity must not trigger false isDropOffHazard")

        print("PASS Swift Low-Light Release Candidate Corrective Audit (P0-A, P0-B, P0-C, P1-D)")
    }

    static func testFinalDeviceReadinessAudioSync() {
        let budget = AuditoryBudgetManager()

        func makeBin(id: Int, dist: Float, isValid: Bool = true) -> SpatialBin {
            let binW: Float = 65.0 / 24.0
            let aMin = -32.5 + Float(id) * binW
            let aMax = aMin + binW
            let aCenter = (aMin + aMax) / 2.0
            return SpatialBin(
                binId: id, angleMin: aMin, angleMax: aMax, angleCenter: aCenter,
                validRatio: isValid ? 1.0 : 0.0, rawDepthStatistic: 200.0,
                distCM: dist, isValid: isValid, hasObstacle: false,
                bodyDistCM: dist, groundDistCM: .nan, overheadDistCM: .nan
            )
        }

        // 1. Critical STOP advisory under CRITICAL threat produces high-priority warning
        let obsCrit = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (0, 0, 192, 256), pan: 0.0, proximity: 0.9, distCM: 28.0,
            modeText: "WALL", uncertaintyScore: 0.1, isWall: true,
            sectorDists: ["LEFT": 28.0, "CENTER": 28.0, "RIGHT": 28.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: (0..<24).map { makeBin(id: $0, dist: 28.0) }, timestamp: 10.0
        )
        let kCrit = KinematicsResult(
            primaryTTC: 0.6, primaryVelocityZ: 50.0, threats: [:], safeDirection: "STOP",
            isEvading: false, threatLevel: "CRITICAL", guidanceState: "HAZARD_BLOCKED",
            hazardState: "OBSERVED_HAZARD", lostUnresolvedTimestamp: 0.0, timestamp: 10.0
        )
        let advCrit = estimateDirectionalAdvisory(observation: obsCrit, threat: "CRITICAL", now: 10.0)
        precondition(advCrit.state == "STOP", "Must be STOP advisory")
        let decCrit = budget.coordinate(obstacleResult: obsCrit, kinematicsResult: kCrit, advisory: advCrit)
        precondition(decCrit.isActive, "Audio must be active on critical STOP")
        precondition(decCrit.safeDirection == "STOP", "Audio safe direction must be STOP")
        precondition(decCrit.cueMode == "SHARP_PING", "Cue mode must be SHARP_PING")
        precondition(decCrit.threatLevel == "CRITICAL", "Threat level must be CRITICAL")
        precondition(decCrit.priorityScore >= 90.0, "Priority score must be >= 90")
        precondition(decCrit.proximity == 1.0, "Proximity must be 1.0")
        precondition(decCrit.distCM == 28.0, "Measured distance must be preserved")
        precondition(decCrit.ttc == 0.6, "Measured TTC must be preserved")

        // 1B. P0-01: CRITICAL STOP with unknown distance and TTC must NOT fabricate 30cm or 0.8s
        let obsCritUnknown = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (0, 0, 192, 256), pan: 0.0, proximity: 1.0, distCM: .nan,
            modeText: "OBSTACLE", uncertaintyScore: 0.2, isWall: false,
            sectorDists: ["LEFT": .nan, "CENTER": .nan, "RIGHT": .nan],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: [], timestamp: 10.0
        )
        let kCritUnknown = KinematicsResult(
            primaryTTC: .infinity, primaryVelocityZ: 0.0, threats: [:], safeDirection: "STOP",
            isEvading: false, threatLevel: "CRITICAL", guidanceState: "HAZARD_BLOCKED",
            hazardState: "OBSERVED_HAZARD", lostUnresolvedTimestamp: 0.0, timestamp: 10.0
        )
        let advCritFallback = advisoryForRisk(threat: "CRITICAL", timestamp: 10.0)
        let decUnknown = budget.coordinate(obstacleResult: obsCritUnknown, kinematicsResult: kCritUnknown, advisory: advCritFallback)
        precondition(decUnknown.isActive, "Audio must be active on critical STOP")
        precondition(decUnknown.safeDirection == "STOP", "Audio safe direction must be STOP")
        precondition(decUnknown.cueMode == "SHARP_PING", "Cue mode must be SHARP_PING")
        precondition(decUnknown.threatLevel == "CRITICAL", "Threat level must be CRITICAL")
        precondition(decUnknown.proximity == 1.0, "Proximity must be 1.0")
        precondition(decUnknown.distCM.isNaN, "Must NOT fabricate 30cm distance")
        precondition(decUnknown.ttc.isInfinite, "Must NOT fabricate 0.8s TTC")

        // 2. Non-critical STOP advisory (corridor obstructed) under WARNING threat
        let obsWarn = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (0, 0, 192, 256), pan: 0.0, proximity: 0.5, distCM: 28.0,
            modeText: "WALL", uncertaintyScore: 0.1, isWall: true,
            sectorDists: ["LEFT": 28.0, "CENTER": 28.0, "RIGHT": 28.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: (0..<24).map { makeBin(id: $0, dist: 28.0) }, timestamp: 10.0
        )
        let kWarn = KinematicsResult(
            primaryTTC: .infinity, primaryVelocityZ: 0.0, threats: [:], safeDirection: "NONE",
            isEvading: false, threatLevel: "WARNING", guidanceState: "HAZARD_BLOCKED",
            hazardState: "OBSERVED_HAZARD", lostUnresolvedTimestamp: 0.0, timestamp: 10.0
        )
        let advWarnStop = estimateDirectionalAdvisory(observation: obsWarn, threat: "WARNING", now: 10.0)
        precondition(advWarnStop.state == "STOP", "Must be STOP advisory")
        let decWarn = budget.coordinate(obstacleResult: obsWarn, kinematicsResult: kWarn, advisory: advWarnStop)
        precondition(decWarn.isActive, "Audio must be active on non-critical STOP")
        precondition(decWarn.safeDirection == "STOP", "Audio safe direction must be STOP")
        precondition(decWarn.cueMode == "SHARP_PING", "Cue mode must be SHARP_PING")
        precondition(decWarn.threatLevel == "WARNING", "Threat level must be WARNING")
        precondition(decWarn.ttc.isInfinite, "TTC must remain infinite (no fabricated imminent collision)")
        precondition(decWarn.proximity == 0.70, "Proximity must be 0.70")
        precondition(decWarn.priorityScore == 50.0, "Priority score must be 50.0")

        // 3. UNAVAILABLE advisory under SAFE kinematics: muting and no forward sound
        let obsSafe = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (48, 64, 96, 128), pan: 0.0, proximity: 0.2, distCM: .nan,
            modeText: "SAFE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": .nan, "CENTER": .nan, "RIGHT": .nan],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: (0..<24).map { makeBin(id: $0, dist: .nan, isValid: true) }, timestamp: 10.0
        )
        let kSafe = KinematicsResult(
            primaryTTC: .infinity, primaryVelocityZ: 0.0, threats: [:], safeDirection: "NONE",
            isEvading: false, threatLevel: "SAFE", guidanceState: "PATH_CLEAR",
            hazardState: "OBSERVED_LOW_RISK", lostUnresolvedTimestamp: 0.0, timestamp: 10.0
        )
        let advUnavail = estimateDirectionalAdvisory(observation: obsSafe, threat: "SAFE", now: 10.0)
        precondition(advUnavail.state == "UNAVAILABLE", "Must be UNAVAILABLE advisory")
        let decSafe = budget.coordinate(obstacleResult: obsSafe, kinematicsResult: kSafe, advisory: advUnavail)
        precondition(!decSafe.isActive, "Audio must be inactive under UNAVAILABLE with SAFE kinematics")
        precondition(decSafe.cueMode == "MUTED", "Cue mode must be MUTED")
        precondition(decSafe.safeDirection == "NONE", "Safe direction must be NONE")

        // 4. Distinction between STOP, SENSOR_FAULT, and PAUSED
        let obsFault = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (0, 0, 0, 0), pan: 0.0, proximity: 0.0, distCM: .nan,
            modeText: "SENSOR_FAULT", uncertaintyScore: 1.0, isWall: false,
            sectorDists: [:], allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: false, spatialBins: [], timestamp: 10.0
        )
        let kFault = KinematicsResult(
            primaryTTC: .infinity, primaryVelocityZ: 0.0, threats: [:], safeDirection: "STOP",
            isEvading: false, threatLevel: "SENSOR_FAULT", guidanceState: "PERCEPTION_UNAVAILABLE",
            hazardState: "OBSERVED_LOW_RISK", lostUnresolvedTimestamp: 0.0, timestamp: 10.0
        )
        let advFault = estimateDirectionalAdvisory(observation: obsFault, threat: "SENSOR_FAULT", now: 10.0)
        let decFault = budget.coordinate(obstacleResult: obsFault, kinematicsResult: kFault, advisory: advFault)
        precondition(decFault.isActive, "Audio must be active on SENSOR_FAULT")
        precondition(decFault.cueMode == "SYSTEM_FAULT_TONE", "Cue mode must be SYSTEM_FAULT_TONE")
        precondition(decFault.threatLevel == "SENSOR_FAULT", "Threat level must be SENSOR_FAULT")

        let obsPaused = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (0, 0, 0, 0), pan: 0.0, proximity: 0.0, distCM: .nan,
            modeText: "PAUSED", uncertaintyScore: 0.0, isWall: false,
            sectorDists: [:], allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: [], timestamp: 10.0
        )
        let kPaused = KinematicsResult(
            primaryTTC: .infinity, primaryVelocityZ: 0.0, threats: [:], safeDirection: "NONE",
            isEvading: false, threatLevel: "PAUSED", guidanceState: "PAUSED",
            hazardState: "OBSERVED_LOW_RISK", lostUnresolvedTimestamp: 0.0, timestamp: 10.0
        )
        let advPaused = estimateDirectionalAdvisory(observation: nil, threat: "PAUSED", now: 10.0)
        let decPaused = budget.coordinate(obstacleResult: obsPaused, kinematicsResult: kPaused, advisory: advPaused)
        precondition(!decPaused.isActive, "Audio must be inactive on PAUSED")
        precondition(decPaused.cueMode == "MUTED", "Cue mode must be MUTED")
        precondition(decPaused.threatLevel == "PAUSED", "Threat level must be PAUSED")

        // 5. Stale observation freshness check (> 750ms)
        let binsClear = (0..<24).map { makeBin(id: $0, dist: 200.0) }
        let obsClear = ObstacleDetectionResult(
            x: 96, y: 128, bbox: (0, 0, 192, 256), pan: 0.0, proximity: 0.2, distCM: 200.0,
            modeText: "SAFE", uncertaintyScore: 0.1, isWall: false,
            sectorDists: ["LEFT": 200.0, "CENTER": 200.0, "RIGHT": 200.0],
            allObstacles: [], isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
            camWidth: 192, camHeight: 256, isValid: true, spatialBins: binsClear, timestamp: 10.0
        )
        let advFresh = estimateDirectionalAdvisory(observation: obsClear, threat: "SAFE", now: 10.20)
        precondition(advFresh.state == "AVAILABLE", "Must be AVAILABLE when fresh")
        precondition(advFresh.drawableAngle(now: 10.20) != nil, "Must have drawable angle at age 200ms")
        precondition(advFresh.drawableAngle(now: 10.80) == nil, "Must withdraw arrow at age 800ms (> 750ms)")
        let advStale = estimateDirectionalAdvisory(observation: obsClear, threat: "SAFE", now: 10.80)
        precondition(advStale.state == "UNAVAILABLE", "Must be UNAVAILABLE when stale")
        precondition(advStale.reasonCode == "SOURCE_FRAME_STALE", "Reason code must be SOURCE_FRAME_STALE")

        print("PASS Swift Final Device Readiness Audio Sync Tests")
    }

    static func testObstacleAvoidanceHotfixScenarios() {
        let halfFov: Float = 32.5
        let binW: Float = 65.0 / 24.0
        func makeBins(dists: [Float?]) -> [SpatialBin] {
            return (0..<24).map { i in
                let aMin = -halfFov + Float(i) * binW
                let aMax = aMin + binW
                let aCenter = (aMin + aMax) / 2.0
                let d = dists[i]
                let isV = d != nil && d!.isFinite && d! > 0
                return SpatialBin(
                    binId: i, angleMin: aMin, angleMax: aMax, angleCenter: aCenter,
                    validRatio: isV ? 1.0 : 0.0, rawDepthStatistic: 200.0,
                    distCM: isV ? d! : .nan, isValid: isV, hasObstacle: false,
                    bodyDistCM: isV ? d! : .nan, groundDistCM: .nan, overheadDistCM: .nan
                )
            }
        }
        func makeObs(
            threat: String = "SAFE",
            secDists: [String: Float],
            obstacles: [SingleObstacle],
            bins: [SpatialBin],
            camW: Int = 640,
            camH: Int = 480
        ) -> ObstacleDetectionResult {
            let centerD = secDists["CENTER"] ?? .nan
            return ObstacleDetectionResult(
                x: camW / 2, y: camH / 2,
                bbox: (x: camW / 4, y: camH / 4, w: camW / 2, h: camH / 2),
                pan: 0.0, proximity: 0.3, distCM: centerD,
                modeText: "TEST", uncertaintyScore: 0.1, isWall: false,
                sectorDists: secDists, allObstacles: obstacles,
                isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
                camWidth: camW, camHeight: camH, isValid: true,
                spatialBins: bins, timestamp: 10.0
            )
        }

        // 1. Small obstacle far left -> AVAILABLE forward if forward corridor supported
        let obs1Item = SingleObstacle(id: 1, x: 25, y: 200, bbox: (10, 100, 30, 200), pan: -0.85, proximity: 0.4, distCM: 70.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs1 = makeObs(secDists: ["LEFT": 70.0, "CENTER": 200.0, "RIGHT": 200.0], obstacles: [obs1Item], bins: makeBins(dists: [Float?](repeating: 200.0, count: 24)))
        let adv1 = estimateDirectionalAdvisory(observation: obs1, threat: "SAFE", now: 10.0)
        precondition(adv1.state == "AVAILABLE", "Scenario 1 failed state")
        precondition(abs(adv1.angleDeg ?? 99.0) <= 2.0, "Scenario 1 failed angle: expected forward, got \(String(describing: adv1.angleDeg))")
        precondition(adv1.reasonCode == "AVAILABLE_FORWARD", "Scenario 1 failed reason code")

        // 2. Small obstacle far right -> AVAILABLE forward
        let obs2Item = SingleObstacle(id: 2, x: 615, y: 200, bbox: (600, 100, 30, 200), pan: 0.85, proximity: 0.4, distCM: 70.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs2 = makeObs(secDists: ["LEFT": 200.0, "CENTER": 200.0, "RIGHT": 70.0], obstacles: [obs2Item], bins: makeBins(dists: [Float?](repeating: 200.0, count: 24)))
        let adv2 = estimateDirectionalAdvisory(observation: obs2, threat: "SAFE", now: 10.0)
        precondition(adv2.state == "AVAILABLE", "Scenario 2 failed state")
        precondition(abs(adv2.angleDeg ?? 99.0) <= 2.0, "Scenario 2 failed angle: expected forward, got \(String(describing: adv2.angleDeg))")
        precondition(adv2.reasonCode == "AVAILABLE_FORWARD", "Scenario 2 failed reason code")

        // 3. Left obstacle encroaching into forward corridor -> AVAILABLE with supported right correction
        let obs3Item = SingleObstacle(id: 3, x: 245, y: 200, bbox: (200, 100, 90, 200), pan: -0.25, proximity: 0.6, distCM: 55.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists3: [Float?] = [Float?](repeating: 55.0, count: 10) + [Float?](repeating: 200.0, count: 14)
        let obs3 = makeObs(threat: "WARNING", secDists: ["LEFT": 55.0, "CENTER": 100.0, "RIGHT": 200.0], obstacles: [obs3Item], bins: makeBins(dists: dists3))
        let adv3 = estimateDirectionalAdvisory(observation: obs3, threat: "WARNING", now: 10.0)
        precondition(adv3.state == "AVAILABLE", "Scenario 3 failed state")
        precondition((adv3.angleDeg ?? 0.0) > 0.0, "Scenario 3 failed angle: expected right correction, got \(String(describing: adv3.angleDeg))")
        precondition(adv3.reasonCode == "AVAILABLE_CORRECTION", "Scenario 3 failed reason code")

        // 4. Right obstacle encroaching -> AVAILABLE with supported left correction
        let obs4Item = SingleObstacle(id: 4, x: 395, y: 200, bbox: (350, 100, 90, 200), pan: 0.25, proximity: 0.6, distCM: 55.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists4: [Float?] = [Float?](repeating: 200.0, count: 14) + [Float?](repeating: 55.0, count: 10)
        let obs4 = makeObs(threat: "WARNING", secDists: ["LEFT": 200.0, "CENTER": 100.0, "RIGHT": 55.0], obstacles: [obs4Item], bins: makeBins(dists: dists4))
        let adv4 = estimateDirectionalAdvisory(observation: obs4, threat: "WARNING", now: 10.0)
        precondition(adv4.state == "AVAILABLE", "Scenario 4 failed state")
        precondition((adv4.angleDeg ?? 0.0) < 0.0, "Scenario 4 failed angle: expected left correction, got \(String(describing: adv4.angleDeg))")
        precondition(adv4.reasonCode == "AVAILABLE_CORRECTION", "Scenario 4 failed reason code")

        // 5. Central obstacle with sufficient side passage -> AVAILABLE alternative
        let obs5Item = SingleObstacle(id: 5, x: 320, y: 200, bbox: (270, 100, 100, 200), pan: 0.0, proximity: 0.7, distCM: 50.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists5: [Float?] = [Float?](repeating: 50.0, count: 14) + [Float?](repeating: 200.0, count: 10)
        let obs5 = makeObs(threat: "WARNING", secDists: ["LEFT": 50.0, "CENTER": 50.0, "RIGHT": 200.0], obstacles: [obs5Item], bins: makeBins(dists: dists5))
        let adv5 = estimateDirectionalAdvisory(observation: obs5, threat: "WARNING", now: 10.0)
        precondition(adv5.state == "AVAILABLE", "Scenario 5 failed state")
        precondition((adv5.angleDeg ?? 0.0) >= 10.0, "Scenario 5 failed angle: expected alternative >= 10 deg, got \(String(describing: adv5.angleDeg))")
        precondition(adv5.reasonCode == "AVAILABLE_ALTERNATIVE", "Scenario 5 failed reason code")

        // 6. Both sides and center obstructed -> STOP
        let obs6Item = SingleObstacle(id: 6, x: 320, y: 200, bbox: (100, 100, 440, 200), pan: 0.0, proximity: 0.9, distCM: 35.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let obs6 = makeObs(threat: "CRITICAL", secDists: ["LEFT": 35.0, "CENTER": 35.0, "RIGHT": 35.0], obstacles: [obs6Item], bins: makeBins(dists: [Float?](repeating: 35.0, count: 24)))
        let adv6 = estimateDirectionalAdvisory(observation: obs6, threat: "CRITICAL", now: 10.0)
        precondition(adv6.state == "STOP", "Scenario 6 failed state")
        precondition(adv6.reasonCode == "CORRIDOR_OBSTRUCTED", "Scenario 6 failed reason code")

        // 7. Narrow gap below body-clearance requirement -> STOP
        let obs7ItemL = SingleObstacle(id: 71, x: 200, y: 200, bbox: (100, 100, 200, 200), pan: -0.3, proximity: 0.8, distCM: 40.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let obs7ItemR = SingleObstacle(id: 72, x: 440, y: 200, bbox: (340, 100, 200, 200), pan: 0.3, proximity: 0.8, distCM: 40.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let dists7: [Float?] = [Float?](repeating: 40.0, count: 11) + [180.0, 180.0] + [Float?](repeating: 40.0, count: 11)
        let obs7 = makeObs(threat: "WARNING", secDists: ["LEFT": 40.0, "CENTER": 40.0, "RIGHT": 40.0], obstacles: [obs7ItemL, obs7ItemR], bins: makeBins(dists: dists7))
        let adv7 = estimateDirectionalAdvisory(observation: obs7, threat: "WARNING", now: 10.0)
        precondition(adv7.state == "STOP", "Scenario 7 failed state: narrow gap must STOP")
        precondition(adv7.reasonCode == "CORRIDOR_OBSTRUCTED", "Scenario 7 failed reason code")

        // 8. Unknown side passage -> UNAVAILABLE, not invented AVAILABLE
        let obs8Item = SingleObstacle(id: 8, x: 320, y: 200, bbox: (270, 100, 100, 200), pan: 0.0, proximity: 0.7, distCM: 50.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists8 = [Float?](repeating: nil, count: 24)
        let obs8 = makeObs(threat: "WARNING", secDists: ["LEFT": .nan, "CENTER": 50.0, "RIGHT": .nan], obstacles: [obs8Item], bins: makeBins(dists: dists8))
        let adv8 = estimateDirectionalAdvisory(observation: obs8, threat: "WARNING", now: 10.0)
        precondition(adv8.state == "UNAVAILABLE", "Scenario 8 failed state: unknown passage must be UNAVAILABLE")

        // 9. Imminent unavoidable collision -> STOP immediately
        let obs9Item = SingleObstacle(id: 9, x: 320, y: 200, bbox: (260, 80, 120, 350), pan: 0.0, proximity: 1.0, distCM: 20.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs9 = makeObs(threat: "CRITICAL", secDists: ["LEFT": 20.0, "CENTER": 20.0, "RIGHT": 20.0], obstacles: [obs9Item], bins: makeBins(dists: [Float?](repeating: 20.0, count: 24)))
        let adv9 = estimateDirectionalAdvisory(observation: obs9, threat: "CRITICAL", now: 10.0)
        precondition(adv9.state == "STOP", "Scenario 9 failed state: imminent collision must force STOP")
        precondition(adv9.reasonCode == "CRITICAL_OBSTACLE", "Scenario 9 failed reason code")

        // 10. Existing valid heading becomes obstructed -> no smoothed arrow through the obstacle
        let obs10Item = SingleObstacle(id: 10, x: 320, y: 200, bbox: (270, 100, 100, 200), pan: 0.0, proximity: 0.8, distCM: 45.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists10: [Float?] = [Float?](repeating: 45.0, count: 12) + [Float?](repeating: 200.0, count: 12)
        let obs10 = makeObs(threat: "WARNING", secDists: ["LEFT": 45.0, "CENTER": 45.0, "RIGHT": 200.0], obstacles: [obs10Item], bins: makeBins(dists: dists10))
        let adv10 = estimateDirectionalAdvisory(observation: obs10, threat: "WARNING", now: 10.0, prevAngle: 0.0)
        precondition(adv10.state == "AVAILABLE", "Scenario 10 failed state")
        guard let a10 = adv10.angleDeg else { fatalError("Scenario 10 missing angle") }
        precondition(a10 >= 12.0, "Scenario 10 failed: angle must not interpolate through center obstacle (expected >= 12.0, got \(a10))")

        print("PASS Swift Final Obstacle Avoidance Policy Scenarios (10/10)")
    }

    static func testCenterCorridorFirstHotfixScenarios() {
        let halfFov: Float = 32.5
        let binW: Float = 65.0 / 24.0
        func makeBins(dists: [Float?]) -> [SpatialBin] {
            return (0..<24).map { i in
                let aMin = -halfFov + Float(i) * binW
                let aMax = aMin + binW
                let aCenter = (aMin + aMax) / 2.0
                let d = dists[i]
                let isV = d != nil && d!.isFinite && d! > 0
                return SpatialBin(
                    binId: i, angleMin: aMin, angleMax: aMax, angleCenter: aCenter,
                    validRatio: isV ? 1.0 : 0.0, rawDepthStatistic: 200.0,
                    distCM: isV ? d! : .nan, isValid: isV, hasObstacle: false,
                    bodyDistCM: isV ? d! : .nan, groundDistCM: .nan, overheadDistCM: .nan
                )
            }
        }
        func makeObs(
            threat: String = "SAFE",
            secDists: [String: Float],
            obstacles: [SingleObstacle],
            bins: [SpatialBin],
            camW: Int = 640,
            camH: Int = 480
        ) -> ObstacleDetectionResult {
            let centerD = secDists["CENTER"] ?? .nan
            return ObstacleDetectionResult(
                x: camW / 2, y: camH / 2,
                bbox: (x: camW / 4, y: camH / 4, w: camW / 2, h: camH / 2),
                pan: 0.0, proximity: 0.3, distCM: centerD,
                modeText: "TEST", uncertaintyScore: 0.1, isWall: false,
                sectorDists: secDists, allObstacles: obstacles,
                isZeroLuxBlind: false, isOverheadHazard: false, isDropOffHazard: false,
                camWidth: camW, camHeight: camH, isValid: true,
                spatialBins: bins, timestamp: 10.0
            )
        }

        let budget = AuditoryBudgetManager()

        // 1. Only far-left obstacle, clear center -> AVAILABLE_FORWARD
        let obs1Item = SingleObstacle(id: 1, x: 25, y: 200, bbox: (10, 100, 30, 200), pan: -0.85, proximity: 0.4, distCM: 70.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs1 = makeObs(secDists: ["LEFT": 70.0, "CENTER": 200.0, "RIGHT": 200.0], obstacles: [obs1Item], bins: makeBins(dists: [Float?](repeating: 200.0, count: 24)))
        let adv1 = estimateDirectionalAdvisory(observation: obs1, threat: "SAFE", now: 10.0)
        precondition(adv1.state == "AVAILABLE", "CTO 1: state must be AVAILABLE")
        precondition(abs(adv1.angleDeg ?? 99.0) <= 2.0, "CTO 1: angle must be 0° forward")
        precondition(adv1.reasonCode == "AVAILABLE_FORWARD", "CTO 1: reason must be AVAILABLE_FORWARD")

        // 2. Only far-right obstacle, clear center -> AVAILABLE_FORWARD
        let obs2Item = SingleObstacle(id: 2, x: 615, y: 200, bbox: (600, 100, 30, 200), pan: 0.85, proximity: 0.4, distCM: 70.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs2 = makeObs(secDists: ["LEFT": 200.0, "CENTER": 200.0, "RIGHT": 70.0], obstacles: [obs2Item], bins: makeBins(dists: [Float?](repeating: 200.0, count: 24)))
        let adv2 = estimateDirectionalAdvisory(observation: obs2, threat: "SAFE", now: 10.0)
        precondition(adv2.state == "AVAILABLE", "CTO 2: state must be AVAILABLE")
        precondition(abs(adv2.angleDeg ?? 99.0) <= 2.0, "CTO 2: angle must be 0° forward")
        precondition(adv2.reasonCode == "AVAILABLE_FORWARD", "CTO 2: reason must be AVAILABLE_FORWARD")

        // 3. Obstacles on both sides, sufficient central gap -> AVAILABLE_FORWARD
        let obs3ItemL = SingleObstacle(id: 31, x: 45, y: 200, bbox: (20, 100, 50, 200), pan: -0.80, proximity: 0.4, distCM: 80.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs3ItemR = SingleObstacle(id: 32, x: 595, y: 200, bbox: (570, 100, 50, 200), pan: 0.80, proximity: 0.4, distCM: 80.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists3 = [Float?](repeating: 80.0, count: 4) + [Float?](repeating: 200.0, count: 16) + [Float?](repeating: 80.0, count: 4)
        let obs3 = makeObs(secDists: ["LEFT": 80.0, "CENTER": 200.0, "RIGHT": 80.0], obstacles: [obs3ItemL, obs3ItemR], bins: makeBins(dists: dists3))
        let adv3 = estimateDirectionalAdvisory(observation: obs3, threat: "SAFE", now: 10.0)
        precondition(adv3.state == "AVAILABLE", "CTO 3: state must be AVAILABLE")
        precondition(abs(adv3.angleDeg ?? 99.0) <= 2.0, "CTO 3: angle must be 0° forward")
        precondition(adv3.reasonCode == "AVAILABLE_FORWARD", "CTO 3: reason must be AVAILABLE_FORWARD")

        // 4. Left side significantly encroaches -> AVAILABLE right correction
        let obs4Item = SingleObstacle(id: 4, x: 245, y: 200, bbox: (200, 100, 90, 200), pan: -0.25, proximity: 0.6, distCM: 55.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists4 = [Float?](repeating: 55.0, count: 10) + [Float?](repeating: 200.0, count: 14)
        let obs4 = makeObs(threat: "WARNING", secDists: ["LEFT": 55.0, "CENTER": 100.0, "RIGHT": 200.0], obstacles: [obs4Item], bins: makeBins(dists: dists4))
        let adv4 = estimateDirectionalAdvisory(observation: obs4, threat: "WARNING", now: 10.0)
        precondition(adv4.state == "AVAILABLE", "CTO 4: state must be AVAILABLE")
        precondition((adv4.angleDeg ?? 0.0) > 0.0, "CTO 4: expected right correction")
        precondition(adv4.reasonCode == "AVAILABLE_CORRECTION", "CTO 4: reason must be AVAILABLE_CORRECTION")

        // 5. Right side significantly encroaches -> AVAILABLE left correction
        let obs5Item = SingleObstacle(id: 5, x: 395, y: 200, bbox: (350, 100, 90, 200), pan: 0.25, proximity: 0.6, distCM: 55.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists5 = [Float?](repeating: 200.0, count: 14) + [Float?](repeating: 55.0, count: 10)
        let obs5 = makeObs(threat: "WARNING", secDists: ["LEFT": 200.0, "CENTER": 100.0, "RIGHT": 55.0], obstacles: [obs5Item], bins: makeBins(dists: dists5))
        let adv5 = estimateDirectionalAdvisory(observation: obs5, threat: "WARNING", now: 10.0)
        precondition(adv5.state == "AVAILABLE", "CTO 5: state must be AVAILABLE")
        precondition((adv5.angleDeg ?? 0.0) < 0.0, "CTO 5: expected left correction")
        precondition(adv5.reasonCode == "AVAILABLE_CORRECTION", "CTO 5: reason must be AVAILABLE_CORRECTION")

        // 6. Large obstacle left of center, clear right corridor -> AVAILABLE right alternative
        let obs6Item = SingleObstacle(id: 6, x: 320, y: 200, bbox: (270, 100, 100, 200), pan: 0.0, proximity: 0.7, distCM: 50.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists6 = [Float?](repeating: 50.0, count: 14) + [Float?](repeating: 200.0, count: 10)
        let obs6 = makeObs(threat: "WARNING", secDists: ["LEFT": 50.0, "CENTER": 50.0, "RIGHT": 200.0], obstacles: [obs6Item], bins: makeBins(dists: dists6))
        let adv6 = estimateDirectionalAdvisory(observation: obs6, threat: "WARNING", now: 10.0)
        precondition(adv6.state == "AVAILABLE", "CTO 6: state must be AVAILABLE")
        precondition((adv6.angleDeg ?? 0.0) >= 10.0, "CTO 6: expected right alternative")
        precondition(adv6.reasonCode == "AVAILABLE_ALTERNATIVE", "CTO 6: reason must be AVAILABLE_ALTERNATIVE")

        // 7. Large obstacle right of center, clear left corridor -> AVAILABLE left alternative
        let obs7Item = SingleObstacle(id: 7, x: 320, y: 200, bbox: (270, 100, 100, 200), pan: 0.0, proximity: 0.7, distCM: 50.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists7 = [Float?](repeating: 200.0, count: 10) + [Float?](repeating: 50.0, count: 14)
        let obs7 = makeObs(threat: "WARNING", secDists: ["LEFT": 200.0, "CENTER": 50.0, "RIGHT": 50.0], obstacles: [obs7Item], bins: makeBins(dists: dists7))
        let adv7 = estimateDirectionalAdvisory(observation: obs7, threat: "WARNING", now: 10.0)
        precondition(adv7.state == "AVAILABLE", "CTO 7: state must be AVAILABLE")
        precondition((adv7.angleDeg ?? 0.0) <= -10.0, "CTO 7: expected left alternative")
        precondition(adv7.reasonCode == "AVAILABLE_ALTERNATIVE", "CTO 7: reason must be AVAILABLE_ALTERNATIVE")

        // 8. CRITICAL side obstacle, unaffected center -> AVAILABLE with appropriate hazard warning
        let obs8Item = SingleObstacle(id: 8, x: 30, y: 200, bbox: (10, 100, 40, 200), pan: -0.85, proximity: 0.95, distCM: 35.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists8 = [Float?](repeating: 35.0, count: 4) + [Float?](repeating: 180.0, count: 20)
        let obs8 = makeObs(threat: "CRITICAL", secDists: ["LEFT": 35.0, "CENTER": 180.0, "RIGHT": 180.0], obstacles: [obs8Item], bins: makeBins(dists: dists8))
        let adv8 = estimateDirectionalAdvisory(observation: obs8, threat: "CRITICAL", now: 10.0)
        precondition(adv8.state == "AVAILABLE", "CTO 8: state must be AVAILABLE despite critical side hazard")
        precondition(abs(adv8.angleDeg ?? 99.0) <= 2.0, "CTO 8: forward walking path remains unobstructed")
        precondition(adv8.reasonCode == "AVAILABLE_FORWARD", "CTO 8: reason must be AVAILABLE_FORWARD")
        // Verify audio budget hazard warning preservation:
        let kin8 = KinematicsResult(
            primaryTTC: .infinity, primaryVelocityZ: 0, threats: [:],
            safeDirection: "FORWARD", isEvading: false, threatLevel: "CRITICAL",
            guidanceState: "HAZARD_IMMEDIATE", hazardState: "ACTIVE_HAZARD",
            lostUnresolvedTimestamp: 0.0, timestamp: 10.0
        )
        let decision8 = budget.coordinate(obstacleResult: obs8, kinematicsResult: kin8, advisory: adv8)
        precondition(decision8.isActive == true, "CTO 8: Audio warning must remain active")
        precondition(decision8.threatLevel == "CRITICAL", "CTO 8: Audio must warn of critical threat")
        precondition(decision8.cueMode == "SHARP_PING", "CTO 8: Audio cue must be SHARP_PING")
        precondition(decision8.pan < -0.3, "CTO 8: Audio pan must indicate left side hazard")

        // 9. Entire usable corridor blocked -> STOP
        let obs9Item = SingleObstacle(id: 9, x: 320, y: 200, bbox: (100, 100, 440, 200), pan: 0.0, proximity: 0.9, distCM: 35.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let obs9 = makeObs(threat: "CRITICAL", secDists: ["LEFT": 35.0, "CENTER": 35.0, "RIGHT": 35.0], obstacles: [obs9Item], bins: makeBins(dists: [Float?](repeating: 35.0, count: 24)))
        let adv9 = estimateDirectionalAdvisory(observation: obs9, threat: "CRITICAL", now: 10.0)
        precondition(adv9.state == "STOP", "CTO 9: state must be STOP")
        precondition(adv9.reasonCode == "CORRIDOR_OBSTRUCTED", "CTO 9: reason must be CORRIDOR_OBSTRUCTED")

        // 10. Imminent unavoidable collision -> STOP
        let obs10Item = SingleObstacle(id: 10, x: 320, y: 200, bbox: (260, 80, 120, 350), pan: 0.0, proximity: 1.0, distCM: 20.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let obs10 = makeObs(threat: "CRITICAL", secDists: ["LEFT": 20.0, "CENTER": 20.0, "RIGHT": 20.0], obstacles: [obs10Item], bins: makeBins(dists: [Float?](repeating: 20.0, count: 24)))
        let adv10 = estimateDirectionalAdvisory(observation: obs10, threat: "CRITICAL", now: 10.0)
        precondition(adv10.state == "STOP", "CTO 10: state must be STOP")
        precondition(adv10.reasonCode == "CRITICAL_OBSTACLE", "CTO 10: reason must be CRITICAL_OBSTACLE")

        // 11. Unknown central and side clearance -> UNAVAILABLE
        let obs11Item = SingleObstacle(id: 11, x: 320, y: 200, bbox: (270, 100, 100, 200), pan: 0.0, proximity: 0.7, distCM: 50.0, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        let dists11 = [Float?](repeating: nil, count: 24)
        let obs11 = makeObs(threat: "WARNING", secDists: ["LEFT": .nan, "CENTER": 50.0, "RIGHT": .nan], obstacles: [obs11Item], bins: makeBins(dists: dists11))
        let adv11 = estimateDirectionalAdvisory(observation: obs11, threat: "WARNING", now: 10.0)
        precondition(adv11.state == "UNAVAILABLE", "CTO 11: state must be UNAVAILABLE")

        // 12. Narrow gap below body-width requirement -> STOP
        let obs12ItemL = SingleObstacle(id: 121, x: 200, y: 200, bbox: (100, 100, 200, 200), pan: -0.3, proximity: 0.8, distCM: 40.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let obs12ItemR = SingleObstacle(id: 122, x: 440, y: 200, bbox: (340, 100, 200, 200), pan: 0.3, proximity: 0.8, distCM: 40.0, modeText: "WALL", uncertaintyScore: 0.1, isWall: true)
        let dists12 = [Float?](repeating: 40.0, count: 11) + [180.0, 180.0] + [Float?](repeating: 40.0, count: 11)
        let obs12 = makeObs(threat: "WARNING", secDists: ["LEFT": 40.0, "CENTER": 40.0, "RIGHT": 40.0], obstacles: [obs12ItemL, obs12ItemR], bins: makeBins(dists: dists12))
        let adv12 = estimateDirectionalAdvisory(observation: obs12, threat: "WARNING", now: 10.0)
        precondition(adv12.state == "STOP", "CTO 12: narrow gap below clearance requirement must be STOP")
        precondition(adv12.reasonCode == "CORRIDOR_OBSTRUCTED", "CTO 12: reason must be CORRIDOR_OBSTRUCTED")

        print("PASS Swift Center-Corridor First Hotfix Scenarios (12/12)")
    }
}
