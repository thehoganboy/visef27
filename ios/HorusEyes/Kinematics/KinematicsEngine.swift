// HorusEyes 2.0 — KinematicsEngine.swift
// ════════════════════════════════════════════════════════════════════════════════
// Real-Time Kinematics & Time-To-Collision (TTC) Engine with Ego-Motion Compensation
// ════════════════════════════════════════════════════════════════════════════════

import Foundation

struct SectorThreat {
    let name: String            // "LEFT", "CENTER", "RIGHT"
    let distCM: Float
    let velocityZ: Float        // cm/s (positive = approaching)
    let ttc: Float              // seconds, Float.infinity if safe
    let threatLevel: String     // "CRITICAL", "WARNING", "SAFE"
}

struct KinematicsResult {
    let primaryTTC: Float
    let primaryVelocityZ: Float
    let threats: [String: SectorThreat]
    let safeDirection: String   // "STOP", "NONE"
    let isEvading: Bool
    let threatLevel: String     // "CRITICAL", "WARNING", "SAFE"
    let guidanceState: String
}

final class KinematicsEngine {
    // Sliding History for Primary Obstacle (N = 8)
    private var historyT: [Double] = []
    private var historyD: [Float] = []
    private var historyPan: [Float] = []
    private let historyCapacity = Config.motionHistoryLen

    // Track State
    private var lastFrameId: UInt64 = 0
    private var smoothedVz: Float = 0.0
    private var lastSafeDirection: String = "RIGHT"
    private var cachedResult: KinematicsResult?

    init() {}

    func compute(
        obstacleResult: ObstacleDetectionResult,
        frameId: UInt64,
        timestamp: Double,
        aeSettleRemaining: Int,
        userWalkSpeedCmS: Float = Config.userWalkSpeedCmS,
        imuYawRateRadS: Float = 0.0
    ) -> KinematicsResult {
        // Guard against duplicate frames or flash AE settling window
        if frameId <= lastFrameId || aeSettleRemaining > 0 {
            if let cached = cachedResult {
                return cached
            }
        }
        lastFrameId = frameId

        let distZ = obstacleResult.distCM
        let pan = obstacleResult.pan

        // Update sliding window
        historyT.append(timestamp)
        historyD.append(distZ)
        historyPan.append(pan)

        if historyT.count > historyCapacity {
            historyT.removeFirst()
            historyD.removeFirst()
            historyPan.removeFirst()
        }

        // Linear regression with shifted time-origin: t_tilde_i = t_i - t_0
        var rawVz: Float = 0.0
        let n = historyT.count
        if n >= 3 {
            let t0 = historyT[0]
            var sumT: Double = 0.0
            var sumD: Double = 0.0
            for i in 0..<n {
                sumT += (historyT[i] - t0)
                sumD += Double(historyD[i])
            }
            let meanT = sumT / Double(n)
            let meanD = sumD / Double(n)

            var num: Double = 0.0
            var den: Double = 0.0
            for i in 0..<n {
                let dt = (historyT[i] - t0) - meanT
                let dd = Double(historyD[i]) - meanD
                num += dt * dd
                den += dt * dt
            }

            if den > 1e-9 {
                let slope = Float(num / den)
                // Negative slope in distance means closing approach (positive vz)
                rawVz = -slope
            }
        }

        // Deadband filter (Config.vzDeadbandCmS = 20.0 cm/s)
        if rawVz < Config.vzDeadbandCmS {
            rawVz = 0.0
        }

        // Exponential smoothing
        let alpha = Config.velocitySmoothing
        smoothedVz = alpha * rawVz + (1.0 - alpha) * smoothedVz

        // Ego-motion compensation: stationary obstacles in path approach at user's walk speed
        let effectiveVz = max(smoothedVz, userWalkSpeedCmS)

        // Calculate primary TTC
        let primaryTTC: Float
        if distZ <= Config.distCriticalCM {
            primaryTTC = 0.5
        } else if effectiveVz > Config.vzMinApproachCmS {
            primaryTTC = max(0.1, distZ / effectiveVz)
        } else {
            primaryTTC = Float.infinity
        }

        // Threat level determination
        let threatLevel: String
        if distZ <= Config.distCriticalCM || primaryTTC <= Config.ttcCritical {
            threatLevel = "CRITICAL"
        } else if distZ <= Config.distDangerCM || primaryTTC <= Config.ttcWarning {
            threatLevel = "DANGER"
        } else if distZ <= Config.distWarningCM {
            threatLevel = "WARNING"
        } else {
            threatLevel = "SAFE"
        }

        // 3-Sector Threat Analysis
        let distL = obstacleResult.sectorDists["LEFT"] ?? 250.0
        let distC = obstacleResult.sectorDists["CENTER"] ?? 250.0
        let distR = obstacleResult.sectorDists["RIGHT"] ?? 250.0

        let vzL = (pan < -0.20) ? smoothedVz : 0.0
        let vzC = (abs(pan) <= 0.20) ? effectiveVz : 0.0
        let vzR = (pan > 0.20) ? smoothedVz : 0.0

        let ttcL = (distL <= Config.distCriticalCM) ? 0.5 : (vzL > 20.0 ? distL / vzL : Float.infinity)
        let ttcC = (distC <= Config.distCriticalCM) ? 0.5 : (vzC > 20.0 ? distC / vzC : Float.infinity)
        let ttcR = (distR <= Config.distCriticalCM) ? 0.5 : (vzR > 20.0 ? distR / vzR : Float.infinity)

        let threatL = SectorThreat(
            name: "LEFT", distCM: distL, velocityZ: vzL, ttc: ttcL,
            threatLevel: sectorThreatLevel(dist: distL, ttc: ttcL)
        )
        let threatC = SectorThreat(
            name: "CENTER", distCM: distC, velocityZ: vzC, ttc: ttcC,
            threatLevel: sectorThreatLevel(dist: distC, ttc: ttcC)
        )
        let threatR = SectorThreat(
            name: "RIGHT", distCM: distR, velocityZ: vzR, ttc: ttcR,
            threatLevel: sectorThreatLevel(dist: distR, ttc: ttcR)
        )

        let threats: [String: SectorThreat] = [
            "LEFT": threatL,
            "CENTER": threatC,
            "RIGHT": threatR
        ]

        // Sector Safety Scores (w1=0.50, w2=0.35, w3=0.15)
        let scoreL = computeSectorSafetyScore(medianDist: distL, ttc: ttcL, maxVz: vzL)
        let scoreR = computeSectorSafetyScore(medianDist: distR, ttc: ttcR, maxVz: vzR)

        // Safe Direction Selection with Hysteresis
        let safeDir: String
        let guidanceState: String

        if distC <= Config.distCriticalCM && distL <= Config.distCriticalCM && distR <= Config.distCriticalCM {
            safeDir = "STOP"
            guidanceState = "HAZARD_BLOCKED (STOP)"
        } else if obstacles.count > 0 || distC < Config.distWarningCM {
            safeDir = "NONE"
            guidanceState = "HAZARD_DETECTED"
        } else {
            safeDir = "NONE"
            guidanceState = "PATH_UNVERIFIED"
        }
        lastSafeDirection = safeDir

        // Evasion Intent Verification:
        // 1. Pan shifting outward to periphery
        // 2. IMU yaw rate confirms intentional turn
        // 3. Distance Z is not decreasing rapidly
        var isEvading = false
        if historyPan.count >= 4 {
            let firstPan = historyPan.first!
            let currentPan = historyPan.last!
            let panMovingOutward = abs(currentPan) > abs(firstPan) + 0.15
            let turningConfirmed = abs(imuYawRateRadS) > 0.35
            let distStable = rawVz < 30.0
            isEvading = panMovingOutward && turningConfirmed && distStable
        }

        let result = KinematicsResult(
            primaryTTC: primaryTTC,
            primaryVelocityZ: smoothedVz,
            threats: threats,
            safeDirection: safeDir,
            isEvading: isEvading,
            threatLevel: threatLevel,
            guidanceState: guidanceState
        )

        cachedResult = result
        return result
    }

    private func sectorThreatLevel(dist: Float, ttc: Float) -> String {
        if dist <= Config.distCriticalCM || ttc <= Config.ttcCritical {
            return "CRITICAL"
        } else if dist <= Config.distDangerCM || ttc <= Config.ttcWarning {
            return "WARNING"
        } else {
            return "SAFE"
        }
    }

    private func computeSectorSafetyScore(medianDist: Float, ttc: Float, maxVz: Float) -> Float {
        let w1 = Config.safetyWClearance
        let w2 = Config.safetyWTtc
        let w3 = Config.safetyWVz

        let cDist = min(1.0, max(0.0, medianDist / 250.0))
        let sClearance = cDist

        let sTtcThreat: Float
        if ttc.isFinite && ttc > 0.0 {
            sTtcThreat = min(1.0, max(0.0, (1.0 / max(ttc, 0.2)) / 5.0))
        } else {
            sTtcThreat = 0.0
        }

        let sVzPenalty = min(1.0, max(0.0, max(0.0, maxVz) / 100.0))
        let rawScore = w1 * sClearance - w2 * sTtcThreat - w3 * sVzPenalty
        return min(1.0, max(0.0, rawScore))
    }
}
