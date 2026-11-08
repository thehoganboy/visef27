package com.horuseyes.app.kinematics

import android.graphics.Rect
import com.horuseyes.app.Config
import com.horuseyes.app.vision.DepthResult
import com.horuseyes.app.vision.Obstacle
import java.util.ArrayDeque
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

data class SectorThreat(
    val name: String,
    val distCm: Float,
    val velocityZ: Float,
    val ttc: Float,
    val threatLevel: String
)

data class TrackDetail(
    val vzRaw: Float,
    val vzSmooth: Float,
    val deltaD: Float,
    val deltaT: Float,
    val ttc: Float,
    val distCm: Float,
    val bbox: Rect,
    val motionStatus: String = "STATIC"
)

data class KinematicsResult(
    val primaryTtc: Float,
    val primaryVelocityZ: Float,
    val threats: Map<String, SectorThreat>,
    val safeDirection: String, // "LEFT", "RIGHT", "STOP"
    val isEvading: Boolean,
    val threatLevel: String,
    val obstacleTtcs: Map<Int, Float>,
    val obstacleVzs: Map<Int, Float>,
    val trackDetails: Map<Int, TrackDetail>,
    val sectorScores: Map<String, Float> = mapOf("LEFT" to 0.5f, "RIGHT" to 0.5f),
    val guidanceState: String = "ESCAPE_RIGHT"
)

/**
 * Tính Điểm An Toàn Tổng Hợp (Sector Safety Score) chuẩn hóa trên miền [0.0, 1.0].
 * Score = w1 * S_clearance - w2 * S_ttc_threat - w3 * S_velocity_penalty
 */
fun computeSectorSafetyScore(
    medianDistanceSector: Float,
    freePixelRatio: Float = 1.0f,
    ttc: Float = Float.POSITIVE_INFINITY,
    maxVzInSector: Float = 0.0f,
    w1: Float = Config.SAFETY_W_CLEARANCE,
    w2: Float = Config.SAFETY_W_TTC,
    w3: Float = Config.SAFETY_W_VZ
): Float {
    val cDist = (medianDistanceSector / 250.0f).coerceIn(0.0f, 1.0f)
    val sClearance = cDist * freePixelRatio.coerceIn(0.0f, 1.0f)
    val sTtcThreat = if (ttc.isFinite() && ttc > 0.0f) {
        (1.0f / max(ttc, 0.2f)).coerceIn(0.0f, 5.0f) / 5.0f
    } else {
        0.0f
    }
    val posVz = max(0.0f, maxVzInSector)
    val sVelocityPenalty = (posVz / 100.0f).coerceIn(0.0f, 1.0f)
    val rawScore = w1 * sClearance - w2 * sTtcThreat - w3 * sVelocityPenalty
    return rawScore.coerceIn(0.0f, 1.0f)
}

internal class TrackedObstacle(
    val trackId: Int,
    var cx: Float,
    var cy: Float,
    var bbox: Rect,
    var pan: Float,
    var distCm: Float
) {
    val historyT = ArrayDeque<Float>()
    val historyD = ArrayDeque<Float>()
    var missingCount: Int = 0
    var smoothedVz: Float = 0f
    var rawVz: Float = 0f
    var deltaD: Float = 0f
    var deltaT: Float = 0f
    var approachConfirmCount: Int = 0

    // Bounding box và centroid được làm mượt per-track (chống giật reticle)
    var smX: Float = cx
    var smY: Float = cy
    var smLeft: Float = bbox.left.toFloat()
    var smTop: Float = bbox.top.toFloat()
    var smRight: Float = bbox.right.toFloat()
    var smBottom: Float = bbox.bottom.toFloat()
    var smDist: Float = distCm
    var smPan: Float = pan
}

/**
 * Centroid + IoU Tracker thích ứng kết hợp hồi quy tuyến tính trượt và bộ lọc EMA.
 * Hoàn toàn tương đương với LightweightCentroidTracker trong motion_ttc.py.
 */
internal class LightweightCentroidTracker(
    private val maxMissing: Int = 4,
    private val matchDistThresh: Float = 160.0f
) {
    private var nextId = 1
    val tracks = mutableMapOf<Int, TrackedObstacle>()

    private fun computeIoU(b1: Rect, b2: Rect): Float {
        val xA = max(b1.left, b2.left)
        val yA = max(b1.top, b2.top)
        val xB = min(b1.right, b2.right)
        val yB = min(b1.bottom, b2.bottom)

        val interW = max(0, xB - xA)
        val interH = max(0, yB - yA)
        val interArea = interW * interH

        val area1 = max(1, b1.width() * b1.height())
        val area2 = max(1, b2.width() * b2.height())
        return interArea.toFloat() / (area1 + area2 - interArea)
    }

    fun update(obstacles: List<Obstacle>, timestamp: Float): Map<Int, Float> {
        val vzMap = mutableMapOf<Int, Float>()

        if (obstacles.isEmpty()) {
            val iter = tracks.iterator()
            while (iter.hasNext()) {
                val entry = iter.next()
                entry.value.missingCount++
                if (entry.value.missingCount > maxMissing) {
                    iter.remove()
                }
            }
            return vzMap
        }

        if (tracks.isEmpty()) {
            for (obs in obstacles) {
                val trk = TrackedObstacle(
                    trackId = nextId,
                    cx = obs.x.toFloat(),
                    cy = obs.y.toFloat(),
                    bbox = obs.bbox,
                    pan = obs.pan,
                    distCm = obs.distCm
                )
                trk.historyT.addLast(timestamp)
                trk.historyD.addLast(obs.distCm)
                tracks[nextId] = trk
                obs.id = nextId
                vzMap[obs.id] = 0f
                nextId++
            }
            return vzMap
        }

        val trackIds = tracks.keys.toList()
        val numTracks = trackIds.size
        val numObs = obstacles.size
        val costMatrix = FloatArray(numTracks * numObs)

        for (i in 0 until numTracks) {
            val trk = tracks[trackIds[i]]!!
            val diag = hypot(trk.bbox.width().toFloat(), trk.bbox.height().toFloat())
            val adaptiveRadius = max(80.0f, max(0.45f * diag, matchDistThresh))

            for (j in 0 until numObs) {
                val obs = obstacles[j]
                val distCentroid = hypot(trk.cx - obs.x.toFloat(), trk.cy - obs.y.toFloat())
                val iou = computeIoU(trk.bbox, obs.bbox)
                var cost = (distCentroid / max(adaptiveRadius, 1.0f)) * 0.70f + (1.0f - iou) * 0.30f
                if (distCentroid > adaptiveRadius && iou < 0.05f) {
                    cost += 10.0f
                }
                costMatrix[i * numObs + j] = cost
            }
        }

        val matchedTracks = mutableSetOf<Int>()
        val matchedObs = mutableSetOf<Int>()

        // Sắp xếp các cặp theo chi phí tăng dần (Greedy Bipartite Matching)
        val pairList = ArrayList<Pair<Int, Float>>()
        for (idx in costMatrix.indices) {
            pairList.add(Pair(idx, costMatrix[idx]))
        }
        pairList.sortBy { it.second }

        for (p in pairList) {
            val idx = p.first
            val cost = p.second
            val i = idx / numObs
            val j = idx % numObs

            if (matchedTracks.contains(i) || matchedObs.contains(j)) continue
            if (cost > 1.2f) continue

            val tid = trackIds[i]
            val trk = tracks[tid]!!
            val obs = obstacles[j]

            trk.cx = obs.x.toFloat()
            trk.cy = obs.y.toFloat()
            trk.bbox = obs.bbox
            trk.pan = obs.pan
            trk.distCm = obs.distCm
            trk.missingCount = 0

            // Làm mượt hình học per-track
            val a = 0.35f
            trk.smX = (1f - a) * trk.smX + a * obs.x.toFloat()
            trk.smY = (1f - a) * trk.smY + a * obs.y.toFloat()
            trk.smLeft = (1f - a) * trk.smLeft + a * obs.bbox.left.toFloat()
            trk.smTop = (1f - a) * trk.smTop + a * obs.bbox.top.toFloat()
            trk.smRight = (1f - a) * trk.smRight + a * obs.bbox.right.toFloat()
            trk.smBottom = (1f - a) * trk.smBottom + a * obs.bbox.bottom.toFloat()
            trk.smDist = (1f - a) * trk.smDist + a * obs.distCm
            trk.smPan = (1f - a) * trk.smPan + a * obs.pan

            obs.id = tid
            // Cập nhật vị trí mượt vào Obstacle
            obs.distCm = trk.smDist
            obs.bbox.set(trk.smLeft.toInt(), trk.smTop.toInt(), trk.smRight.toInt(), trk.smBottom.toInt())

            trk.historyT.addLast(timestamp)
            trk.historyD.addLast(obs.distCm)
            while (trk.historyT.size > Config.MOTION_HISTORY_LEN) trk.historyT.removeFirst()
            while (trk.historyD.size > Config.MOTION_HISTORY_LEN) trk.historyD.removeFirst()

            val vz = calculateVz(trk)
            vzMap[obs.id] = vz

            matchedTracks.add(i)
            matchedObs.add(j)
        }

        // Tạo track mới cho các vật thể chưa được gán
        for (j in 0 until numObs) {
            if (!matchedObs.contains(j)) {
                val obs = obstacles[j]
                val trk = TrackedObstacle(
                    trackId = nextId,
                    cx = obs.x.toFloat(),
                    cy = obs.y.toFloat(),
                    bbox = obs.bbox,
                    pan = obs.pan,
                    distCm = obs.distCm
                )
                trk.historyT.addLast(timestamp)
                trk.historyD.addLast(obs.distCm)
                tracks[nextId] = trk
                obs.id = nextId
                vzMap[obs.id] = 0f
                nextId++
            }
        }

        // Xóa các track quá hạn
        val iter = tracks.iterator()
        while (iter.hasNext()) {
            val entry = iter.next()
            val tid = entry.key
            val trackIdx = trackIds.indexOf(tid)
            if (trackIdx != -1 && !matchedTracks.contains(trackIdx)) {
                entry.value.missingCount++
                if (entry.value.missingCount > maxMissing) {
                    iter.remove()
                }
            }
        }

        return vzMap
    }

    private fun calculateVz(trk: TrackedObstacle): Float {
        val n = trk.historyT.size
        if (n < 2) {
            trk.rawVz = 0f
            trk.smoothedVz = 0f
            trk.deltaD = 0f
            trk.deltaT = 0f
            return 0f
        }

        val tList = trk.historyT.toList()
        val dList = trk.historyD.toList()

        val dt = (tList.last() - tList[n - 2]).coerceIn(0.010f, 1.200f)
        val dd = dList.last() - dList[n - 2]
        trk.deltaD = dd
        trk.deltaT = dt

        // ── Kiểm tra mốc dao động (Oscillation & Net Displacement) ──
        val dMin = dList.minOrNull() ?: dList.last()
        val dMax = dList.maxOrNull() ?: dList.last()
        val oscillation = dMax - dMin
        val netDisp = dList.first() - dList.last() // > 0: đang tiến lại gần

        if (oscillation < Config.MOTION_DISP_THRESHOLD_CM || abs(netDisp) < Config.MIN_NET_DISPLACEMENT_CM) {
            trk.rawVz = 0f
            trk.smoothedVz = 0f
            trk.approachConfirmCount = 0
            return 0f
        }

        val tSpan = (tList.last() - tList.first()).coerceIn(0.050f, 3.500f)
        val vzCalculated = (netDisp / tSpan).coerceIn(-250f, 350f)
        trk.rawVz = vzCalculated

        val alpha = Config.VELOCITY_SMOOTHING
        var vzSmooth = if (trk.smoothedVz == 0f) {
            vzCalculated
        } else {
            alpha * vzCalculated + (1f - alpha) * trk.smoothedVz
        }

        if (abs(vzSmooth) < Config.VZ_DEADBAND_CM_S) {
            vzSmooth = 0f
        }

        trk.smoothedVz = vzSmooth
        return vzSmooth
    }
}

/**
 * Bộ xử lý động học chuyển động, Time-to-Collision (TTC) và dẫn hướng né thoát an toàn.
 * Tương đồng 100% với motion_ttc.py.
 */
class KinematicsEngine {

    private var prevTimestamp: Float = 0f
    private var prevDistCm: Float? = null
    private var prevPan: Float = 0f
    private var prevSectorDists: Map<String, Float>? = null

    private val tracker = LightweightCentroidTracker()
    private val sectorVz = mutableMapOf("LEFT" to 0f, "CENTER" to 0f, "RIGHT" to 0f)
    private var smoothedSafeDir = "CLEAR"

    private var consecutiveEvasionFrames = 0
    private var lastEvasionDir = "NONE"
    private var dirHysteresisFrames = 0

    fun compute(depthRes: DepthResult, timestamp: Float): KinematicsResult {
        val now = timestamp
        val dt = if (prevTimestamp > 0.0f && now > prevTimestamp) {
            (now - prevTimestamp).coerceIn(0.010f, 1.200f)
        } else {
            1.0f / 30.0f
        }

        val secDists = depthRes.sectorDists
        val allObs = depthRes.allObstacles

        // Cập nhật Centroid Tracker
        val obsVzs = tracker.update(allObs, now)

        val currDist = depthRes.distCm
        val currPan = depthRes.pan

        // Nếu không có vật cản nào (Phòng trống hoặc an toàn > 1.5m)
        if (allObs.isEmpty()) {
            prevDistCm = currDist
            prevPan = currPan
            prevSectorDists = secDists.toMap()
            prevTimestamp = now

            val threats = mapOf(
                "LEFT" to SectorThreat("LEFT", secDists["LEFT"] ?: 250f, 0f, Float.POSITIVE_INFINITY, "SAFE"),
                "CENTER" to SectorThreat("CENTER", secDists["CENTER"] ?: 250f, 0f, Float.POSITIVE_INFINITY, "SAFE"),
                "RIGHT" to SectorThreat("RIGHT", secDists["RIGHT"] ?: 250f, 0f, Float.POSITIVE_INFINITY, "SAFE")
            )
            return KinematicsResult(
                primaryTtc = Float.POSITIVE_INFINITY,
                primaryVelocityZ = 0f,
                threats = threats,
                safeDirection = "CLEAR",
                isEvading = false,
                threatLevel = "SAFE",
                obstacleTtcs = emptyMap(),
                obstacleVzs = emptyMap(),
                trackDetails = emptyMap(),
                sectorScores = mapOf("LEFT" to 0.5f, "RIGHT" to 0.5f),
                guidanceState = "CLEAR_FORWARD"
            )
        }

        // Tính TTC & Mức độ đe dọa cho từng vật thể (Chuẩn Python motion_ttc.py)
        val obsTtcs = mutableMapOf<Int, Float>()
        val obsThreats = mutableMapOf<Int, String>()

        for (o in allObs) {
            val ovz = obsVzs[o.id] ?: 0f
            var ottc = Float.POSITIVE_INFINITY

            val trk = tracker.tracks[o.id]
            val hasApproachTrend = if (trk != null && trk.historyD.size >= 2) {
                val dList = trk.historyD.toList()
                val osc = (dList.maxOrNull() ?: dList.last()) - (dList.minOrNull() ?: dList.last())
                val netDisp = dList.first() - dList.last()
                osc >= Config.MOTION_DISP_THRESHOLD_CM && netDisp >= Config.MIN_NET_DISPLACEMENT_CM && ovz >= Config.VZ_MIN_APPROACH_CM_S
            } else false

            val isTrulyApproaching = if (trk != null) {
                if (hasApproachTrend) trk.approachConfirmCount++ else trk.approachConfirmCount = 0
                trk.approachConfirmCount >= Config.MOTION_CONFIRM_FRAMES
            } else false

            if (isTrulyApproaching && o.distCm < Config.DIST_SAFE_CM) {
                ottc = (o.distCm / max(ovz, 1.0f)).coerceIn(0.05f, 10.0f)
            }
            obsTtcs[o.id] = ottc

            // Phân loại mức độ đe dọa vật thể tĩnh vs động (Bản chất chuẩn xác từ Python)
            val oLevel = when {
                (ottc <= Config.TTC_CRITICAL && ovz >= 25.0f) || (o.distCm <= Config.DIST_CRITICAL_CM) -> "CRITICAL"
                (ottc <= Config.TTC_WARNING && isTrulyApproaching) || (o.distCm <= Config.DIST_DANGER_CM) -> "WARNING"
                else -> "SAFE" // Vật tĩnh ngoài 30cm -> SAFE (Không kêu giả)
            }
            obsThreats[o.id] = oLevel
        }

        // Chọn vật thể ưu tiên cao nhất
        val sortedObs = allObs.sortedWith(compareBy(
            { when (obsThreats[it.id]) { "CRITICAL" -> 0; "WARNING" -> 1; else -> 2 } },
            { obsTtcs[it.id] ?: Float.POSITIVE_INFINITY },
            { it.distCm }
        ))

        val primaryObs = sortedObs.first()
        val primaryId = primaryObs.id
        var primaryVz = obsVzs[primaryId] ?: 0f
        var primaryTtc = obsTtcs[primaryId] ?: Float.POSITIVE_INFINITY
        if (primaryVz <= 0f) primaryTtc = Float.POSITIVE_INFINITY
        val obsThreatLevel = obsThreats[primaryId] ?: "SAFE"

        // Đánh giá 3 hành lang di chuyển
        val prevSec = prevSectorDists ?: secDists
        val threats = mutableMapOf<String, SectorThreat>()

        for (name in listOf("LEFT", "CENTER", "RIGHT")) {
            val sCurr = secDists[name] ?: 250f
            val sPrev = prevSec[name] ?: sCurr
            val sDiff = sCurr - sPrev
            val sRawVz = if (abs(sDiff) < 2.5f) 0f else - (sDiff / dt).coerceIn(-200f, 300f)

            val alpha = Config.VELOCITY_SMOOTHING
            var sVz = alpha * sRawVz + (1f - alpha) * (sectorVz[name] ?: 0f)
            if (abs(sVz) < Config.VZ_DEADBAND_CM_S) sVz = 0f
            sectorVz[name] = sVz

            var sTtc = Float.POSITIVE_INFINITY
            if (sVz >= Config.VZ_MIN_APPROACH_CM_S && sCurr < Config.DIST_SAFE_CM && (-sDiff >= Config.MIN_NET_DISPLACEMENT_CM)) {
                sTtc = (sCurr / max(sVz, 1f)).coerceIn(0.05f, 10f)
            }

            val sLevel = when {
                (sTtc <= Config.TTC_CRITICAL && sVz >= 20f) || (sCurr <= Config.DIST_CRITICAL_CM) -> "CRITICAL"
                (sTtc <= Config.TTC_WARNING && sVz >= Config.VZ_MIN_APPROACH_CM_S) || (sCurr <= Config.DIST_DANGER_CM) -> "WARNING"
                else -> "SAFE"
            }

            threats[name] = SectorThreat(name, sCurr, sVz, sTtc, sLevel)
        }

        // ── 4. Xác định Hướng né thoát an toàn (Risk-Aware Safe Path Guidance) ──
        val camW = Config.INPUT_WIDTH.toFloat()
        val camH = Config.INPUT_HEIGHT.toFloat()
        val secArea = max(1.0f, (camW * Config.SECTOR_LEFT_SPLIT) * camH)

        val leftObs = allObs.filter { it.pan < -0.18f || it.x < camW * Config.SECTOR_LEFT_SPLIT }
        val rightObs = allObs.filter { it.pan > 0.18f || it.x > camW * Config.SECTOR_RIGHT_SPLIT }

        // Vận tốc tiếp cận vz > 0 lớn nhất và TTC nhỏ nhất cho từng sector
        val leftVzs = leftObs.mapNotNull { obsVzs[it.id] }.filter { it > 0f }.toMutableList()
        threats["LEFT"]?.let { if (it.velocityZ > 0f) leftVzs.add(it.velocityZ) }
        val maxVzLeft = leftVzs.maxOrNull() ?: 0f

        val leftTtcs = leftObs.mapNotNull { obsTtcs[it.id] }.filter { it.isFinite() }.toMutableList()
        threats["LEFT"]?.let { if (it.ttc.isFinite()) leftTtcs.add(it.ttc) }
        val minTtcLeft = leftTtcs.minOrNull() ?: Float.POSITIVE_INFINITY

        val leftOccArea = leftObs.sumOf { (it.bbox.width() * it.bbox.height()).toDouble() }.toFloat()
        val freeRatioLeft = (1.0f - (leftOccArea / secArea)).coerceIn(0.0f, 1.0f)

        val rightVzs = rightObs.mapNotNull { obsVzs[it.id] }.filter { it > 0f }.toMutableList()
        threats["RIGHT"]?.let { if (it.velocityZ > 0f) rightVzs.add(it.velocityZ) }
        val maxVzRight = rightVzs.maxOrNull() ?: 0f

        val rightTtcs = rightObs.mapNotNull { obsTtcs[it.id] }.filter { it.isFinite() }.toMutableList()
        threats["RIGHT"]?.let { if (it.ttc.isFinite()) rightTtcs.add(it.ttc) }
        val minTtcRight = rightTtcs.minOrNull() ?: Float.POSITIVE_INFINITY

        val rightOccArea = rightObs.sumOf { (it.bbox.width() * it.bbox.height()).toDouble() }.toFloat()
        val freeRatioRight = (1.0f - (rightOccArea / secArea)).coerceIn(0.0f, 1.0f)

        val scoreLeft = computeSectorSafetyScore(
            medianDistanceSector = secDists["LEFT"] ?: 250f,
            freePixelRatio = freeRatioLeft,
            ttc = minTtcLeft,
            maxVzInSector = maxVzLeft
        )
        val scoreRight = computeSectorSafetyScore(
            medianDistanceSector = secDists["RIGHT"] ?: 250f,
            freePixelRatio = freeRatioRight,
            ttc = minTtcRight,
            maxVzInSector = maxVzRight
        )
        val sectorScores = mapOf("LEFT" to scoreLeft, "RIGHT" to scoreRight)

        val margin = Config.SECTOR_HYSTERESIS_MARGIN
        val deadlockThresh = Config.SECTOR_DEADLOCK_THRESH
        val centerDist = secDists["CENTER"] ?: 250f
        val centerBlocked = centerDist < Config.DIST_WARNING_CM || threats["CENTER"]?.threatLevel != "SAFE"

        val dangerDist = 35.0f
        val leftDist = secDists["LEFT"] ?: 250f
        val rightDist = secDists["RIGHT"] ?: 250f
        val leftBlocked = leftDist < dangerDist || scoreLeft < deadlockThresh || threats["LEFT"]?.threatLevel == "CRITICAL"
        val rightBlocked = rightDist < dangerDist || scoreRight < deadlockThresh || threats["RIGHT"]?.threatLevel == "CRITICAL"

        val (safeDir, guidanceState) = when {
            // CHỈ kích hoạt STOP khi cả 3 hướng (Giữa, Trái, Phải) đều bị chặn hoàn toàn!
            centerBlocked && leftBlocked && rightBlocked -> {
                dirHysteresisFrames = 0
                "STOP" to "HAZARD_BLOCKED (STOP)"
            }
            allObs.isNotEmpty() || centerBlocked || threats["LEFT"]?.threatLevel != "SAFE" || threats["RIGHT"]?.threatLevel != "SAFE" -> {
                "NONE" to "HAZARD_DETECTED"
            }
            else -> {
                "NONE" to "PATH_UNVERIFIED"
            }
        }

        // Threat level tổng quan (Kết hợp mối nguy và hành lang)
        val threatLevel = when {
            obsThreatLevel == "CRITICAL" || threats["CENTER"]?.threatLevel == "CRITICAL" || (guidanceState == "HAZARD_BLOCKED" && min(secDists["LEFT"] ?: 250f, min(secDists["CENTER"] ?: 250f, secDists["RIGHT"] ?: 250f)) <= Config.DIST_CRITICAL_CM) -> "CRITICAL"
            obsThreatLevel == "WARNING" || threats["CENTER"]?.threatLevel == "WARNING" || guidanceState == "HAZARD_BLOCKED" ||
            (threats["LEFT"]?.threatLevel == "WARNING" && safeDir == "RIGHT") ||
            (threats["RIGHT"]?.threatLevel == "WARNING" && safeDir == "LEFT") -> "WARNING"
            else -> "SAFE"
        }

        // Directive 01B-A+ Task A+1: Không triệt tiêu cảnh báo chỉ vì quay điện thoại (pan).
        // isEvading giữ nguyên false trong camera-only để bảo toàn 100% cảnh báo.
        val isEvading = false

        prevDistCm = currDist
        prevPan = currPan
        prevSectorDists = secDists.toMap()
        prevTimestamp = now

        val trackDetails = mutableMapOf<Int, TrackDetail>()
        for (o in allObs) {
            val trk = tracker.tracks[o.id]
            val ovz = trk?.smoothedVz ?: 0f
            val ottc = obsTtcs[o.id] ?: Float.POSITIVE_INFINITY
            val motionStatus = when {
                ovz >= Config.VZ_MIN_APPROACH_CM_S -> "APPROACHING"
                ovz <= -Config.VZ_MIN_APPROACH_CM_S -> "RECEDING"
                else -> "STATIC"
            }
            trackDetails[o.id] = TrackDetail(
                vzRaw = trk?.rawVz ?: 0f,
                vzSmooth = ovz,
                deltaD = trk?.deltaD ?: 0f,
                deltaT = trk?.deltaT ?: 0f,
                ttc = ottc,
                distCm = o.distCm,
                bbox = o.bbox,
                motionStatus = motionStatus
            )
        }

        return KinematicsResult(
            primaryTtc = primaryTtc,
            primaryVelocityZ = primaryVz,
            threats = threats,
            safeDirection = safeDir,
            isEvading = isEvading,
            threatLevel = threatLevel,
            obstacleTtcs = obsTtcs,
            obstacleVzs = obsVzs,
            trackDetails = trackDetails,
            sectorScores = sectorScores,
            guidanceState = guidanceState
        )
    }
}
