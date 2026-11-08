// HorusEyes 2.0 — AuditoryBudgetManager.swift
// ════════════════════════════════════════════════════════════════════════════════
// Strict Single-Stream Auditory Budgeting + CRITICAL Preemption + Uncertainty Hysteresis
// ════════════════════════════════════════════════════════════════════════════════

import Foundation

struct BudgetDecision {
    let isActive: Bool
    let pan: Float
    let proximity: Float
    let distCM: Float
    let ttc: Float
    let priorityScore: Float
    let volumeFactor: Float
    let safeDirection: String
    let cueMode: String          // "SHARP_PING", "ACOUSTIC_BLUR", "SYSTEM_FAULT_TONE", "MUTED"
    let threatLevel: String
    let suppressedCount: Int
}

final class AuditoryBudgetManager {
    // Single Stream Arbitration
    private var currentActiveId: Int? = nil
    private var activeHoldCounter: Int = 0
    private var pendingSwitchId: Int? = nil
    private var pendingSwitchCounter: Int = 0

    // Uncertainty Hysteresis Memory
    private var currentCueMode: String = "SHARP_PING"
    private var unresolvedReminderCount: Int = 0

    // Configuration Constants
    private let hysteresisBoost: Float = 1.15
    private let minHoldFrames: Int = 5
    private let switchConfirmFrames: Int = 3

    init() {}

    // Threat Score Calculation: 1/TTC + 1/Z^1.5 (NO penalty reduction on high uncertainty)
    static func computeThreatScore(
        ttc: Float,
        proximity: Float,
        distCM: Float,
        uncertainty: Float = 0.0
    ) -> Float {
        let kinetic: Float
        if ttc.isFinite && ttc > 0.0 {
            kinetic = 1.0 / max(ttc, Config.ttcEpsilon)
        } else {
            kinetic = 0.0
        }

        let safeDist = max(10.0, distCM)
        let staticRisk = pow(80.0 / safeDist, 1.5)
        let proxBias = 0.25 * proximity

        return kinetic + staticRisk + proxBias
    }

    func coordinate(
        obstacleResult: ObstacleDetectionResult,
        kinematicsResult: KinematicsResult
    ) -> BudgetDecision {
        let distCM = obstacleResult.distCM
        let ttc = kinematicsResult.primaryTTC
        let threatLevel = kinematicsResult.threatLevel
        let safeDir = kinematicsResult.safeDirection
        _ = obstacleResult.uncertaintyScore
        let isEvading = kinematicsResult.isEvading

        // ── 0. Sensor Fault / 0-Lux Blind Override ────────────────────────────
        if obstacleResult.isZeroLuxBlind || obstacleResult.modeText.contains("SENSOR_BLIND") {
            return BudgetDecision(
                isActive: true,
                pan: 0.0,
                proximity: 1.0,
                distCM: 0.0,
                ttc: 0.0,
                priorityScore: 99.0,
                volumeFactor: 1.0,
                safeDirection: "STOP",
                cueMode: "SYSTEM_FAULT_TONE",
                threatLevel: "CRITICAL",
                suppressedCount: 0
            )
        }

        // ── 0B. Directive 01B-A++ Task P1-F02: Monotonic Time-Based Bounded Reminder Policy (FPS-Independent) ──
        if kinematicsResult.hazardState == "LOST_UNRESOLVED" || threatLevel == "UNRESOLVED_HAZARD" {
            let lostTs = kinematicsResult.lostUnresolvedTimestamp
            let nowTs = kinematicsResult.timestamp
            let elapsedUnresolved = (lostTs > 0.0 && nowTs >= lostTs) ? (nowTs - lostTs) : 0.0

            if elapsedUnresolved <= 1.5 {
                return BudgetDecision(
                    isActive: true,
                    pan: 0.0,
                    proximity: 0.40,
                    distCM: distCM,
                    ttc: Float.infinity,
                    priorityScore: 15.0,
                    volumeFactor: 0.35,
                    safeDirection: "NONE",
                    cueMode: "CAUTION_REMINDER",
                    threatLevel: "UNRESOLVED_HAZARD",
                    suppressedCount: 0
                )
            } else {
                return BudgetDecision(
                    isActive: false,
                    pan: 0.0,
                    proximity: 0.0,
                    distCM: distCM,
                    ttc: Float.infinity,
                    priorityScore: 0.0,
                    volumeFactor: 0.0,
                    safeDirection: "NONE",
                    cueMode: "STANDBY_UNRESOLVED",
                    threatLevel: "UNRESOLVED_HAZARD",
                    suppressedCount: 0
                )
            }
        }

        // ── 1. Total Auditory Suppression Rule ────────────────────────────────
        // Complete silence if in safe region to prevent cognitive fatigue
        let isSuppressed = (threatLevel == "SAFE" || distCM >= Config.distSafeCM ||
                            obstacleResult.modeText.hasPrefix("SAFE") ||
                            (distCM >= Config.distAlertCM && ttc > Config.ttcWarning))

        if isSuppressed {
            currentActiveId = nil
            activeHoldCounter = 0
            pendingSwitchId = nil
            pendingSwitchCounter = 0
            currentCueMode = "MUTED"

            return BudgetDecision(
                isActive: false,
                pan: 0.0,
                proximity: 0.0,
                distCM: distCM,
                ttc: Float.infinity,
                priorityScore: 0.0,
                volumeFactor: 0.0,
                safeDirection: safeDir,
                cueMode: "MUTED",
                threatLevel: "SAFE",
                suppressedCount: max(1, obstacleResult.allObstacles.count)
            )
        }

        // ── 2. Single-Stream Allocation with CRITICAL Preemption ──────────────
        let allObstacles = obstacleResult.allObstacles.isEmpty ? [
            SingleObstacle(
                id: 1, x: obstacleResult.x, y: obstacleResult.y,
                bbox: obstacleResult.bbox, pan: obstacleResult.pan,
                proximity: obstacleResult.proximity, distCM: obstacleResult.distCM,
                modeText: obstacleResult.modeText,
                uncertaintyScore: obstacleResult.uncertaintyScore,
                isWall: obstacleResult.isWall
            )
        ] : obstacleResult.allObstacles

        var scored = [(score: Float, rawScore: Float, obs: SingleObstacle, ttc: Float)]()
        for obs in allObstacles {
            let obsTtc = ttc
            let rawScore = AuditoryBudgetManager.computeThreatScore(
                ttc: obsTtc, proximity: obs.proximity, distCM: obs.distCM, uncertainty: obs.uncertaintyScore
            )
            let isCurrentActive = (currentActiveId != nil && currentActiveId == obs.id)
            let effectiveScore = isCurrentActive ? (rawScore * hysteresisBoost) : rawScore
            scored.append((effectiveScore, rawScore, obs, obsTtc))
        }

        scored.sort { $0.score > $1.score }
        let top = scored.first!

        // CRITICAL Preemption: If obstacle is critical (TTC <= 1.0s or Z <= 40cm), preempt immediately
        let isTopCritical = (top.ttc <= Config.ttcCritical || top.obs.distCM <= Config.distCriticalCM)
        let winnerObs: SingleObstacle
        let winnerTtc: Float
        let winnerScore: Float

        if isTopCritical && (currentActiveId != top.obs.id) {
            currentActiveId = top.obs.id
            activeHoldCounter = 1
            pendingSwitchId = nil
            pendingSwitchCounter = 0
            winnerObs = top.obs
            winnerTtc = top.ttc
            winnerScore = top.rawScore
        } else if currentActiveId == nil || currentActiveId == top.obs.id {
            currentActiveId = top.obs.id
            activeHoldCounter += 1
            pendingSwitchId = nil
            pendingSwitchCounter = 0
            winnerObs = top.obs
            winnerTtc = top.ttc
            winnerScore = top.rawScore
        } else {
            // New obstacle vying for audio stream
            if pendingSwitchId == top.obs.id {
                pendingSwitchCounter += 1
            } else {
                pendingSwitchId = top.obs.id
                pendingSwitchCounter = 1
            }

            if pendingSwitchCounter >= switchConfirmFrames || (activeHoldCounter >= minHoldFrames && pendingSwitchCounter >= 2) {
                currentActiveId = top.obs.id
                activeHoldCounter = 1
                pendingSwitchId = nil
                pendingSwitchCounter = 0
                winnerObs = top.obs
                winnerTtc = top.ttc
                winnerScore = top.rawScore
            } else {
                // Keep existing obstacle
                activeHoldCounter += 1
                winnerObs = top.obs
                winnerTtc = top.ttc
                winnerScore = top.rawScore
            }
        }

        // ── 3. Direct Spatial Hazard Localization (FIX-M01 & TASK 01A-2) ──────
        let outputPan: Float
        if safeDir == "STOP" {
            outputPan = 0.0
        } else {
            outputPan = max(Float(-1.0), min(Float(1.0), winnerObs.pan))
        }

        // ── 4. Full Warning Volume Preservation (Directive 01B Task A2) ──────
        // Do not attenuate warning volume solely based on camera rotation
        let volumeFactor: Float = 1.0

        // ── 5. Uncertainty Hysteresis [0.38, 0.48] ───────────────────────────
        let cueMode: String
        if winnerObs.uncertaintyScore >= Config.uncertaintyBlurOn {
            cueMode = "ACOUSTIC_BLUR"
        } else if winnerObs.uncertaintyScore <= Config.uncertaintyBlurOff {
            cueMode = "SHARP_PING"
        } else {
            cueMode = currentCueMode
        }
        currentCueMode = cueMode

        let suppressedCount = max(0, allObstacles.count - 1)

        return BudgetDecision(
            isActive: true,
            pan: outputPan,
            proximity: winnerObs.proximity,
            distCM: winnerObs.distCM,
            ttc: winnerTtc,
            priorityScore: winnerScore,
            volumeFactor: volumeFactor,
            safeDirection: safeDir,
            cueMode: cueMode,
            threatLevel: threatLevel,
            suppressedCount: suppressedCount
        )
    }
}
