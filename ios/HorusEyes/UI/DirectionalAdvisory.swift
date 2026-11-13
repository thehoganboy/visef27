import Foundation

struct DirectionalAdvisory {
    var state: String = "UNKNOWN"
    var angleDeg: Double? = nil
    var confidence: Double? = nil
    var observedAngularRange: ClosedRange<Double>? = nil
    var sourceTimestamp: Double = 0
    var reasonCode: String = "UNSPECIFIED"

    init(
        state: String = "UNKNOWN",
        angleDeg: Double? = nil,
        confidence: Double? = nil,
        observedAngularRange: ClosedRange<Double>? = nil,
        sourceTimestamp: Double = 0,
        reasonCode: String = "UNSPECIFIED"
    ) {
        self.state = state
        self.angleDeg = angleDeg
        self.confidence = confidence
        self.observedAngularRange = observedAngularRange
        self.sourceTimestamp = sourceTimestamp
        self.reasonCode = reasonCode
    }

    func drawableAngle(now: Double) -> Double? {
        guard state == "AVAILABLE", let angle = angleDeg, angle.isFinite,
              let confidence = confidence, confidence > 0, confidence <= 1,
              let range = observedAngularRange, range.lowerBound >= -90, range.upperBound <= 90,
              range.contains(angle), (0.0...0.75).contains(now - sourceTimestamp) else { return nil }
        return angle
    }
}

func estimateDirectionalAdvisory(
    observation: ObstacleDetectionResult?,
    threat: String,
    now: Double,
    hfovDeg: Double = 65.0,
    prevAngle: Double? = nil
) -> DirectionalAdvisory {
    if threat == "PAUSED" {
        return DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: now, reasonCode: "PAUSED")
    }
    if threat == "INITIALIZING" {
        return DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: now, reasonCode: "INITIALIZING")
    }
    if threat == "SENSOR_FAULT" {
        return DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: now, reasonCode: "SENSOR_FAULT")
    }
    if observation == nil || !(observation?.isValid ?? false) {
        return DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: now, reasonCode: "MODEL_OUTPUT_INVALID")
    }
    guard let obs = observation, !obs.isZeroLuxBlind else {
        return DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: now, reasonCode: "SENSOR_BLIND")
    }

    let halfFov = hfovDeg / 2.0
    let obsRange = (-halfFov)...halfFov

    // Spatial observation freshness check (reject missing, invalid, or stale observations > 750ms)
    guard obs.timestamp > 0 && !obs.timestamp.isNaN && !obs.timestamp.isInfinite else {
        return DirectionalAdvisory(state: "UNAVAILABLE", observedAngularRange: obsRange, sourceTimestamp: now, reasonCode: "SOURCE_FRAME_STALE")
    }
    let age = now - obs.timestamp
    if age < -0.05 || age > 0.75 {
        return DirectionalAdvisory(state: "UNAVAILABLE", observedAngularRange: obsRange, sourceTimestamp: obs.timestamp, reasonCode: "SOURCE_FRAME_STALE")
    }
    let advTs = obs.timestamp

    let camW = Double(obs.camWidth > 0 ? obs.camWidth : 192)
    let cx = camW / 2.0
    let fx = cx / tan(halfFov * .pi / 180.0)

    // Explicit validity-aware sector extraction (no fabricated 250cm defaults)
    let zLeftRaw = obs.sectorDists["LEFT"]
    let validL = zLeftRaw != nil && zLeftRaw!.isFinite && zLeftRaw! > 0
    let zLeft = validL ? Double(zLeftRaw!) : Double.nan

    var zCenterRaw = obs.sectorDists["CENTER"] ?? obs.distCM
    let validC = zCenterRaw.isFinite && zCenterRaw > 0
    let zCenter = validC ? Double(zCenterRaw) : Double.nan

    let zRightRaw = obs.sectorDists["RIGHT"]
    let validR = zRightRaw != nil && zRightRaw!.isFinite && zRightRaw! > 0
    let zRight = validR ? Double(zRightRaw!) : Double.nan

    // Completely obstructed check if all sectors are valid and close
    if validC && zCenter < 50.0 && validL && zLeft < 60.0 && validR && zRight < 60.0 {
        if !obs.spatialBins.isEmpty {
            let cBins = obs.spatialBins.filter { abs(Double($0.angleCenter)) <= 6.0 && $0.isValid }
            let cDists = cBins.map { Double($0.distCM) }
            let finiteCDists = cDists.filter { $0.isFinite && $0 > 0 }
            if finiteCDists.count == cBins.count && !finiteCDists.isEmpty && finiteCDists.allSatisfy({ $0 >= 75.0 }) {
                // Central corridor is genuinely open with valid distance readings (doorway clearance)
            } else {
                return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "CORRIDOR_OBSTRUCTED")
            }
        } else {
            return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "CORRIDOR_OBSTRUCTED")
        }
    }

    // Overhead or drop-off hazard under CRITICAL threat forces immediate STOP
    let isOverhead = obs.isOverheadHazard || obs.modeText == "OVERHEAD" || obs.allObstacles.contains(where: { $0.modeText == "OVERHEAD" })
    let isDropOff = obs.isDropOffHazard || obs.modeText == "DROP_OFF" || obs.allObstacles.contains(where: { $0.modeText == "DROP_OFF" })
    if threat == "CRITICAL" && isOverhead {
        return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "OVERHEAD_HAZARD")
    }
    if threat == "CRITICAL" && isDropOff {
        return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "DROP_OFF_HAZARD")
    }

    struct ObsProfile {
        let angCenter: Double
        let radius: Double
        let weight: Double
        let zObs: Double
        let isValidDist: Bool
    }
    var profiles: [ObsProfile] = []

    for o in obs.allObstacles {
        let l = Double(o.bbox.x)
        let r = Double(o.bbox.x + o.bbox.w)
        let isDistValid = o.distCM.isFinite && o.distCM > 0
        let angLeft = atan2(l - cx, fx) * 180.0 / .pi
        let angRight = atan2(r - cx, fx) * 180.0 / .pi
        let angCenter = (angLeft + angRight) / 2.0
        let angHalfW = max(2.0, (angRight - angLeft) / 2.0)
        let totalRadius: Double
        let weight: Double
        let zVal: Double
        if isDistValid {
            zVal = max(10.0, Double(o.distCM))
            let marginDeg = min(22.0, max(4.0, atan2(20.0, zVal) * 180.0 / .pi))
            totalRadius = angHalfW + marginDeg
            if zVal < 50.0 { weight = 20.0 }
            else if zVal < 80.0 { weight = 10.0 }
            else if zVal < 150.0 { weight = 4.0 }
            else { weight = 1.0 }
        } else {
            // Unknown-distance obstacle: retain image-space angular occupancy without fabricating 100cm
            zVal = Double.nan
            let marginDeg = 8.0
            totalRadius = angHalfW + marginDeg
            weight = 12.0
        }
        profiles.append(ObsProfile(angCenter: angCenter, radius: totalRadius, weight: weight, zObs: zVal, isValidDist: isDistValid))
    }

    let bins = obs.spatialBins

    // Clear observation with no detected obstacles (P0-02)
    if profiles.isEmpty {
        var centerSupported = false
        var candDist = validC ? zCenter : Double.nan
        if !bins.isEmpty {
            let cBins = bins.filter { abs($0.angleCenter) <= 5.0 }
            let validCList = cBins.filter { $0.isValid }
            if validCList.count >= max(1, Int(Double(cBins.count) * 0.75)) {
                centerSupported = true
                let dists = validCList.compactMap { Double($0.distCM) }.filter { $0.isFinite && $0 > 0 }
                if !dists.isEmpty { candDist = dists.min() ?? Double.nan }
            }
        } else if validC {
            centerSupported = true
        }

        if centerSupported && (!candDist.isFinite || candDist >= 75.0) {
            var angleOut = 0.0
            if let pa = prevAngle, pa.isFinite {
                angleOut = 0.3 * angleOut + 0.7 * pa
            }
            return DirectionalAdvisory(
                state: "AVAILABLE",
                angleDeg: (angleOut * 10.0).rounded() / 10.0,
                confidence: 0.55,
                observedAngularRange: obsRange,
                sourceTimestampSeconds: advTs,
                reasonCode: "AVAILABLE_FORWARD"
            )
        } else if centerSupported && candDist.isFinite && candDist < 40.0 {
            return DirectionalAdvisory(
                state: "STOP",
                angleDeg: nil,
                confidence: nil,
                observedAngularRange: obsRange,
                sourceTimestampSeconds: advTs,
                reasonCode: "CRITICAL_OBSTACLE"
            )
        } else {
            return DirectionalAdvisory(
                state: "UNAVAILABLE",
                angleDeg: nil,
                confidence: nil,
                observedAngularRange: obsRange,
                sourceTimestampSeconds: advTs,
                reasonCode: !centerSupported ? "CENTER_COVERAGE_INSUFFICIENT" : "NO_SUPPORTED_CANDIDATE"
            )
        }
    }

    // Step 5A: Generate all candidate headings across observed FOV
    var allCandidateAngles: [Double] = []
    var aStep = -halfFov + 2.5
    while aStep <= halfFov - 2.5 + 1e-4 {
        allCandidateAngles.append(aStep)
        aStep += 2.5
    }

    // Step 5B: Determine eligibility for each candidate heading (P0-01 / P0-02 Evidence Evaluation)
    struct Candidate {
        let ang: Double
        let zSec: Double
        let risk: Double
    }
    var eligibleCandidates: [Candidate] = []
    var obstructedCount = 0
    for cand in allCandidateAngles {
        var candSupported = false
        var candDist = Double.nan

        if !bins.isEmpty {
            let cMin = cand - 5.0
            let cMax = cand + 5.0
            let kMin = cand - 2.5
            let kMax = cand + 2.5
            let wCorr = cMax - cMin  // 10.0 deg
            let wCore = kMax - kMin  // 5.0 deg

            var validCorrCov: Double = 0.0
            var validCoreCov: Double = 0.0
            var validDists: [Double] = []

            for b in bins {
                let bMin = Double(b.angleMin)
                let bMax = Double(b.angleMax)
                if bMax <= bMin { continue }

                let ovCorr = max(0.0, min(bMax, cMax) - max(bMin, cMin))
                let ovCore = max(0.0, min(bMax, kMax) - max(bMin, kMin))

                if b.isValid {
                    validCorrCov += ovCorr
                    validCoreCov += ovCore
                    let d = Double(b.distCM)
                    if ovCorr > 0.0 && d.isFinite && d > 0 {
                        validDists.append(d)
                    }
                }
            }

            let corrRatio = validCorrCov / wCorr
            let coreRatio = validCoreCov / wCore

            // Candidate corridor requires >= 75% valid coverage and load-bearing central core >= 90%
            if corrRatio >= 0.75 && coreRatio >= 0.90 && !validDists.isEmpty {
                candSupported = true
                candDist = validDists.min() ?? Double.nan
            }
        } else {
            // 3-sector fallback for legacy mocks or tests without spatialBins
            let (secValid, zSec): (Bool, Double)
            if cand < -10.0 {
                secValid = validL; zSec = zLeft
            } else if cand > 10.0 {
                secValid = validR; zSec = zRight
            } else {
                secValid = validC; zSec = zCenter
            }
            if secValid {
                candSupported = true
                candDist = zSec
            }
        }

        if !candSupported { continue }

        var isBlocked = false
        if candDist < 40.0 { isBlocked = true }

        if !isBlocked {
            for p in profiles {
                let dAng = abs(cand - p.angCenter)
                if !p.isValidDist {
                    if dAng < p.radius { isBlocked = true; break }
                } else {
                    if p.zObs < 50.0 && dAng < p.radius { isBlocked = true; break }
                    if p.zObs < 35.0 && dAng < (p.radius + 2.0) { isBlocked = true; break }
                }
            }
        }

        if isBlocked {
            obstructedCount += 1
            continue
        }

        var risk = 0.0
        for p in profiles {
            let dAng = abs(cand - p.angCenter)
            if dAng < p.radius {
                let penetration = 1.0 - (dAng / p.radius)
                risk += p.weight * (penetration * penetration) * 15.0
            } else {
                let dEdge = dAng - p.radius
                if dEdge < 15.0 {
                    risk += p.weight * exp(-((dEdge * dEdge) / 40.0)) * 2.0
                }
            }
        }

        if candDist < 80.0 { risk += ((80.0 - candDist) / 10.0) * 4.0 }
        else if candDist < 150.0 { risk += ((150.0 - candDist) / 70.0) * 1.5 }

        risk += 0.05 * abs(cand)

        if let prev = prevAngle, prev.isFinite, abs(cand - prev) <= 3.5 {
            risk -= 1.0
        }

        eligibleCandidates.append(Candidate(ang: cand, zSec: candDist, risk: risk))
    }

    // Step 5C: Evaluate outcomes when no candidate is eligible
    if eligibleCandidates.isEmpty {
        if obstructedCount > 0 && (obstructedCount >= allCandidateAngles.count / 2 || (validC && zCenter < 50.0)) {
            return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "CORRIDOR_OBSTRUCTED")
        } else {
            // Check if center had invalid bins
            let cBins = bins.filter { abs(Double($0.angleCenter)) <= 5.0 }
            let centerValidCount = cBins.filter { $0.isValid }.count
            let centerMissing = !bins.isEmpty && (centerValidCount < max(1, Int(Double(cBins.count) * 0.70)))
            let code = centerMissing ? "CENTER_COVERAGE_INSUFFICIENT" : "NO_SUPPORTED_CANDIDATE"
            return DirectionalAdvisory(state: "UNAVAILABLE", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: code)
        }
    }

    // ── Step 6: Hierarchical Movement Policy (P0-02 Corridor Evidence) ──

    // Priority 1: HOLD FORWARD
    var fwdEligible = false
    var fwdDist = Double.nan
    var fwdRisk = Double.infinity
    for c in eligibleCandidates {
        if abs(c.ang - 0.0) < 1.5 {
            fwdEligible = true
            fwdDist = c.zSec
            fwdRisk = c.risk
            break
        }
    }

    let fwdEncroached = profiles.contains { abs($0.angCenter) < $0.radius }

    if fwdEligible && !fwdEncroached && fwdDist >= 75.0 && fwdRisk <= 4.0 {
        var angleOut = 0.0
        if let prev = prevAngle, prev.isFinite {
            angleOut = 0.35 * 0.0 + 0.65 * prev
            if abs(angleOut) < 1.0 { angleOut = 0.0 }
        }
        return DirectionalAdvisory(state: "AVAILABLE", angleDeg: angleOut, confidence: 0.55, observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "AVAILABLE_FORWARD")
    }

    // Priority 2: SMALL CORRECTION
    let smallCandidates = eligibleCandidates.filter { abs($0.ang) <= 12.5 }
    if !smallCandidates.isEmpty {
        let bestSc = smallCandidates.min { ($0.risk + 0.08 * abs($0.ang)) < ($1.risk + 0.08 * abs($1.ang)) }!
        if bestSc.risk < 20.0 && (!fwdEligible || fwdEncroached || bestSc.risk < fwdRisk - 0.5) {
            var scAngle = bestSc.ang
            if let prev = prevAngle, prev.isFinite {
                scAngle = 0.45 * scAngle + 0.55 * prev
            }
            scAngle = max(-halfFov, min(halfFov, scAngle))
            let conf = max(0.35, min(0.55, 1.0 - (bestSc.risk / 35.0)))
            return DirectionalAdvisory(state: "AVAILABLE", angleDeg: scAngle, confidence: conf, observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "AVAILABLE_CORRECTION")
        }
    }

    // Priority 3: ALTERNATIVE HEADING
    var bestCand = 0.0
    var minCost = Double.infinity
    for c in eligibleCandidates {
        var cost = c.risk + 0.08 * abs(c.ang)
        if let prev = prevAngle, prev.isFinite {
            cost += 0.05 * abs(c.ang - prev)
        }
        if cost < minCost {
            minCost = cost
            bestCand = c.ang
        }
    }

    if minCost > 30.0 {
        return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "NO_SAFE_PATH")
    }

    if threat == "CRITICAL" && validC {
        // Immediate frontal collision (< 25cm) forces emergency STOP
        if zCenter < 25.0 {
            return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "CRITICAL_OBSTACLE")
        }
        // Constrained center hazard (< 40cm): allow alternative heading only if genuinely safe and has clearance
        if zCenter < 40.0 && (minCost > 15.0 || !eligibleCandidates.contains(where: { abs($0.ang - bestCand) < 1.5 && $0.zSec >= 60.0 })) {
            return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "CRITICAL_OBSTACLE")
        }
    }

    let conf = max(0.30, min(0.55, 1.0 - (minCost / 35.0)))
    var selected = bestCand
    if let prev = prevAngle, prev.isFinite {
        selected = 0.45 * selected + 0.55 * prev
    }
    selected = max(-halfFov, min(halfFov, selected))

    return DirectionalAdvisory(state: "AVAILABLE", angleDeg: selected, confidence: conf, observedAngularRange: obsRange, sourceTimestamp: advTs, reasonCode: "AVAILABLE_ALTERNATIVE")
}
