package com.horuseyes.app.budget

import com.horuseyes.app.Config
import com.horuseyes.app.kinematics.KinematicsResult
import com.horuseyes.app.vision.DepthResult
import com.horuseyes.app.vision.Obstacle
import kotlin.math.max

/**
 * Quyết định phân phối ngân sách âm học duy nhất cho người dùng khiếm thị.
 */
data class BudgetDecision(
    val isActive: Boolean,
    val pan: Float,
    val proximity: Float,
    val distCm: Float,
    val ttc: Float,
    val velocityZ: Float = 0f,
    val priorityScore: Float,
    val volumeFactor: Float,
    val safeDirection: String,
    val guidanceState: String = "ESCAPE_RIGHT",
    val cueMode: String,
    val suppressedCount: Int,
    val activeObstacleId: Int,
    val threatLevel: String = "SAFE",
    val suppressedObstacles: List<Obstacle> = emptyList()
)

/**
 * Bộ điều phối ngân sách thính giác nhận thức độ bất định (Auditory Budget Manager).
 * Áp dụng ràng buộc cứng: Tối đa 1 luồng âm thanh active để tránh quá tải nhận thức.
 * Tương đồng 100% với auditory_budget.py.
 */
class AuditoryBudgetManager {

    private var currentActiveId: Int? = null
    private var activeHoldCounter: Int = 0
    private var pendingSwitchId: Int? = null
    private var pendingSwitchCounter: Int = 0

    companion object {
        fun computeThreatScore(ttc: Float, proximity: Float, uncertainty: Float): Float {
            val kinetic = if (ttc < Float.POSITIVE_INFINITY) {
                (1.0f / max(ttc, Config.TTC_EPSILON)) * (1.0f - 0.3f * uncertainty)
            } else {
                0.0f
            }
            val proxBias = 0.20f * proximity
            return kinetic + proxBias
        }
    }

    fun coordinate(depthRes: DepthResult, kinRes: KinematicsResult): BudgetDecision {
        val distCm = depthRes.distCm
        val ttc = kinRes.primaryTtc
        val threatLevel = kinRes.threatLevel
        val safeDir = kinRes.safeDirection
        val allObs = depthRes.allObstacles
        val isEvading = kinRes.isEvading

        // ── 1. Quy tắc Triệt tiêu thính giác (Suppression Filter - Im lặng tuyệt đối) ──
        if (threatLevel == "SAFE" ||
            allObs.isEmpty() ||
            distCm >= Config.DIST_SAFE_CM ||
            (distCm >= Config.DIST_ALERT_CM && ttc > Config.TTC_WARNING)
        ) {
            currentActiveId = null
            activeHoldCounter = 0
            pendingSwitchId = null
            pendingSwitchCounter = 0

            return BudgetDecision(
                isActive = false,
                pan = 0f,
                proximity = 0f,
                distCm = distCm,
                ttc = Float.POSITIVE_INFINITY,
                velocityZ = 0f,
                priorityScore = 0f,
                volumeFactor = 0f,
                safeDirection = safeDir,
                guidanceState = kinRes.guidanceState,
                cueMode = "MUTED",
                suppressedCount = allObs.size,
                activeObstacleId = 0,
                threatLevel = "SAFE",
                suppressedObstacles = allObs
            )
        }

        // ── 2. Đánh giá điểm ưu tiên (Threat Score) cho từng ứng viên ──
        val scoredList = ArrayList<Triple<Float, Obstacle, Float>>() // <effectiveScore, obs, ottc>
        for (o in allObs) {
            val ottc = kinRes.obstacleTtcs[o.id] ?: Float.POSITIVE_INFINITY
            val rawScore = computeThreatScore(ottc, o.proximity, o.uncertaintyScore)
            val isCurrentActive = (currentActiveId != null && o.id == currentActiveId)
            val effectiveScore = if (isCurrentActive) rawScore * Config.HYSTERESIS_BOOST else rawScore
            scoredList.add(Triple(effectiveScore, o, ottc))
        }

        scoredList.sortByDescending { it.first }
        val topCandidate = scoredList[0]
        val topObs = topCandidate.second
        val topTtc = topCandidate.third

        // ── 3. Cơ chế Hysteresis Lock-in chuyển mạch chống chập chờn ──
        val winnerObs: Obstacle
        val winnerTtc: Float

        if (currentActiveId == null) {
            currentActiveId = topObs.id
            activeHoldCounter = 1
            pendingSwitchId = null
            pendingSwitchCounter = 0
            winnerObs = topObs
            winnerTtc = topTtc
        } else if (topObs.id == currentActiveId) {
            activeHoldCounter++
            pendingSwitchId = null
            pendingSwitchCounter = 0
            winnerObs = topObs
            winnerTtc = topTtc
        } else {
            if (pendingSwitchId == topObs.id) {
                pendingSwitchCounter++
            } else {
                pendingSwitchId = topObs.id
                pendingSwitchCounter = 1
            }

            val canSwitch = (pendingSwitchCounter >= Config.SWITCH_CONFIRM_FRAMES) ||
                    (activeHoldCounter >= Config.MIN_HOLD_FRAMES && pendingSwitchCounter >= 2)

            if (canSwitch) {
                currentActiveId = topObs.id
                activeHoldCounter = 1
                pendingSwitchId = null
                pendingSwitchCounter = 0
                winnerObs = topObs
                winnerTtc = topTtc
            } else {
                activeHoldCounter++
                val currObs = allObs.find { it.id == currentActiveId } ?: topObs
                winnerObs = currObs
                winnerTtc = kinRes.obstacleTtcs[winnerObs.id] ?: topTtc
            }
        }

        // ── 4. Điều phối Panning 3D (Định hướng né thoát an toàn) ──
        val pan = when {
            safeDir == "STOP" -> 0.0f
            threatLevel == "CRITICAL" || winnerTtc <= Config.TTC_CRITICAL -> {
                if (safeDir == "LEFT") -0.75f else +0.75f
            }
            threatLevel == "WARNING" && safeDir in listOf("LEFT", "RIGHT") -> {
                if (safeDir == "RIGHT") +0.65f else -0.65f
            }
            else -> winnerObs.pan
        }.coerceIn(-1.0f, 1.0f)

        // ── 5. Mã hóa âm học theo độ bất định AI ──
        val cueMode = if (winnerObs.uncertaintyScore >= Config.UNCERTAINTY_BLUR_THRESHOLD) {
            "ACOUSTIC_BLUR"
        } else {
            "SHARP_PING"
        }

        val volumeFactor = if (isEvading) Config.HYSTERESIS_DECAY else 1.0f
        val activeVz = kinRes.obstacleVzs[winnerObs.id] ?: kinRes.primaryVelocityZ
        val suppressedList = allObs.filter { it.id != winnerObs.id }

        return BudgetDecision(
            isActive = true,
            pan = pan,
            proximity = winnerObs.proximity,
            distCm = winnerObs.distCm,
            ttc = winnerTtc,
            velocityZ = activeVz,
            priorityScore = 1.0f,
            volumeFactor = volumeFactor,
            safeDirection = safeDir,
            guidanceState = kinRes.guidanceState,
            cueMode = cueMode,
            suppressedCount = suppressedList.size,
            activeObstacleId = winnerObs.id,
            threatLevel = threatLevel,
            suppressedObstacles = suppressedList
        )
    }
}
