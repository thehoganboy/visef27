package com.horuseyes.app.ui

import android.content.Context
import android.graphics.*
import android.os.SystemClock
import android.util.AttributeSet
import android.view.View
import com.horuseyes.app.vision.DepthResult
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// Optional angle is camera-relative: negative left, positive right.
// Directional advice represents a lower-estimated-collision-risk heading within the observed FOV.
data class DirectionalAdvisory(
    val state: String = "UNKNOWN",
    val angleDeg: Float? = null,
    val confidence: Float? = null,
    val observedRange: Pair<Float, Float>? = null,
    val sourceNanos: Long = 0,
    val reasonCode: String = "UNSPECIFIED"
) {
    fun drawableAngle(now: Long): Float? {
        val a = angleDeg ?: return null
        val range = observedRange ?: return null
        if (state != "AVAILABLE" || !a.isFinite() || (now - sourceNanos) !in 0L..750_000_000L ||
            confidence == null || confidence <= 0 || confidence > 1 ||
            range.first < -90 || range.second > 90 || a < range.first || a > range.second) return null
        return a
    }
}

fun estimateDirectionalAdvisory(
    depth: DepthResult?,
    threat: String,
    nowNanos: Long,
    hfovDeg: Float = 65f,
    prevAngle: Float? = null
): DirectionalAdvisory {
    if (threat == "PAUSED") {
        return DirectionalAdvisory("UNKNOWN", sourceNanos = nowNanos, reasonCode = "PAUSED")
    }
    if (threat == "INITIALIZING") {
        return DirectionalAdvisory("UNKNOWN", sourceNanos = nowNanos, reasonCode = "INITIALIZING")
    }
    if (threat == "SENSOR_FAULT") {
        return DirectionalAdvisory("UNKNOWN", sourceNanos = nowNanos, reasonCode = "SENSOR_FAULT")
    }
    if (depth == null || !depth.isValid) {
        return DirectionalAdvisory("UNKNOWN", sourceNanos = nowNanos, reasonCode = "MODEL_OUTPUT_INVALID")
    }

    val halfFov = hfovDeg / 2f
    val obsRange = Pair(-halfFov, halfFov)

    // Spatial observation freshness check (reject missing, invalid, or stale observations > 750ms)
    if (depth.timestampNanos <= 0L) {
        return DirectionalAdvisory("UNAVAILABLE", observedRange = obsRange, sourceNanos = nowNanos, reasonCode = "SOURCE_FRAME_MISSING")
    }
    val ageSeconds = (nowNanos - depth.timestampNanos) / 1_000_000_000.0
    if (ageSeconds < -0.05 || ageSeconds > 0.75) {
        return DirectionalAdvisory("UNAVAILABLE", observedRange = obsRange, sourceNanos = depth.timestampNanos, reasonCode = "SOURCE_FRAME_STALE")
    }
    val advNanos = depth.timestampNanos

    val camW = if (depth.width > 0) depth.width.toFloat() else 192f
    val cx = camW / 2f
    val fx = cx / kotlin.math.tan(Math.toRadians(halfFov.toDouble())).toFloat()

    // Explicit validity-aware sector extraction (no fabricated 250cm defaults)
    val zLeftRaw = depth.sectorDists["LEFT"]
    val validL = zLeftRaw != null && zLeftRaw.isFinite() && zLeftRaw > 0f
    val zLeft = if (validL) zLeftRaw!! else Float.NaN

    var zCenterRaw = depth.sectorDists["CENTER"] ?: depth.distCm
    val validC = zCenterRaw.isFinite() && zCenterRaw > 0f
    val zCenter = if (validC) zCenterRaw else Float.NaN

    val zRightRaw = depth.sectorDists["RIGHT"]
    val validR = zRightRaw != null && zRightRaw.isFinite() && zRightRaw > 0f
    val zRight = if (validR) zRightRaw!! else Float.NaN

    // Completely obstructed check if all sectors are valid and close
    if (validC && zCenter < 50f && validL && zLeft < 60f && validR && zRight < 60f) {
        if (depth.spatialBins.isNotEmpty()) {
            val cBins = depth.spatialBins.filter { abs(it.angleCenter) <= 6.0f && it.isValid }
            val cDists = cBins.map { it.estimatedDistanceCm }
            val finiteCDists = cDists.filter { it.isFinite() && it > 0f }
            if (finiteCDists.size == cBins.size && finiteCDists.isNotEmpty() && finiteCDists.all { it >= 75f }) {
                // Central corridor is genuinely open with valid distance readings (doorway clearance)
            } else {
                return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "CORRIDOR_OBSTRUCTED")
            }
        } else {
            return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "CORRIDOR_OBSTRUCTED")
        }
    }

    // Overhead or drop-off hazard under CRITICAL threat forces immediate STOP
    val isOverhead = depth.overheadHazard || depth.modeText == "OVERHEAD" || depth.allObstacles.any { it.modeText == "OVERHEAD" }
    val isDropOff = depth.dropOffHazard || depth.modeText == "DROP_OFF" || depth.allObstacles.any { it.modeText == "DROP_OFF" }
    if (threat == "CRITICAL" && isOverhead) {
        return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "OVERHEAD_HAZARD")
    }
    if (threat == "CRITICAL" && isDropOff) {
        return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "DROP_OFF_HAZARD")
    }

    data class ObsProfile(val angCenter: Float, val radius: Float, val weight: Float, val zObs: Float, val isValidDist: Boolean)
    val profiles = mutableListOf<ObsProfile>()

    for (o in depth.allObstacles) {
        val l = if (o.bbox.right > o.bbox.left) o.bbox.left.toFloat() else (o.x - 20f)
        val r = if (o.bbox.right > o.bbox.left) o.bbox.right.toFloat() else (o.x + 20f)
        val isDistValid = o.distCm.isFinite() && o.distCm > 0f
        val angLeft = Math.toDegrees(kotlin.math.atan2((l - cx).toDouble(), fx.toDouble())).toFloat()
        val angRight = Math.toDegrees(kotlin.math.atan2((r - cx).toDouble(), fx.toDouble())).toFloat()
        val angCenter = (angLeft + angRight) / 2f
        val angHalfW = max(2f, (angRight - angLeft) / 2f)
        val totalRadius: Float
        val weight: Float
        val zVal: Float
        if (isDistValid) {
            zVal = max(10f, o.distCm)
            val marginDeg = min(22f, max(4f, Math.toDegrees(kotlin.math.atan2(20.0, zVal.toDouble())).toFloat()))
            totalRadius = angHalfW + marginDeg
            weight = when {
                zVal < 50f -> 20f
                zVal < 80f -> 10f
                zVal < 150f -> 4f
                else -> 1f
            }
        } else {
            // Unknown-distance obstacle: retain image-space angular occupancy without fabricating 100cm
            zVal = Float.NaN
            val marginDeg = 8f
            totalRadius = angHalfW + marginDeg
            weight = 12f
        }
        profiles.add(ObsProfile(angCenter, totalRadius, weight, zVal, isDistValid))
    }

    val bins = depth.spatialBins

    // Clear observation with no detected obstacles (P0-02 & P0-B)
    if (profiles.isEmpty()) {
        var centerSupported = false
        var centerCoverageOk = false
        var candDist = if (validC && zCenter.isFinite() && zCenter > 0f) zCenter else Float.NaN
        if (bins.isNotEmpty()) {
            val cBins = bins.filter { abs(it.angleCenter) <= 5.0f }
            val validCList = cBins.filter { it.isValid }
            if (validCList.size >= max(1, (cBins.size * 0.75f).toInt())) {
                centerCoverageOk = true
                val dists = validCList.map { it.estimatedDistanceCm }.filter { it.isFinite() && it > 0f }
                if (dists.isNotEmpty()) {
                    candDist = dists.minOrNull() ?: Float.NaN
                    centerSupported = true
                }
            }
        } else if (validC) {
            centerCoverageOk = true
            if (zCenter.isFinite() && zCenter > 0f) {
                centerSupported = true
            }
        }

        if (centerSupported && candDist.isFinite() && candDist > 0f && candDist >= 75.0f) {
            var angleOut = 0.0f
            if (prevAngle != null && prevAngle.isFinite()) {
                angleOut = 0.3f * angleOut + 0.7f * prevAngle
            }
            return DirectionalAdvisory(
                state = "AVAILABLE",
                angleDeg = kotlin.math.round(angleOut * 10f) / 10f,
                confidence = 0.55f,
                observedRange = obsRange,
                sourceNanos = advNanos,
                reasonCode = "AVAILABLE_FORWARD"
            )
        } else if (centerSupported && candDist.isFinite() && candDist < 40.0f) {
            return DirectionalAdvisory(
                state = "STOP",
                observedRange = obsRange,
                sourceNanos = advNanos,
                reasonCode = "CRITICAL_OBSTACLE"
            )
        } else {
            val reason = if (!centerCoverageOk) {
                "CENTER_COVERAGE_INSUFFICIENT"
            } else if (!centerSupported || !candDist.isFinite() || candDist <= 0f) {
                "LOCAL_DEPTH_MISSING"
            } else {
                "NO_SUPPORTED_CANDIDATE"
            }
            return DirectionalAdvisory(
                state = "UNAVAILABLE",
                observedRange = obsRange,
                sourceNanos = advNanos,
                reasonCode = reason
            )
        }
    }

    // Step 5A: Generate all candidate headings across observed FOV
    val allCandidateAngles = mutableListOf<Float>()
    var aStep = -halfFov + 2.5f
    while (aStep <= halfFov - 2.5f + 1e-4f) {
        allCandidateAngles.add(aStep)
        aStep += 2.5f
    }

    // Step 5B: Determine eligibility for each candidate heading (P0-01 Hard Rejection)
    data class Candidate(val ang: Float, val zSec: Float, val risk: Float)
    val eligibleCandidates = mutableListOf<Candidate>()
    var obstructedCount = 0

    for (cand in allCandidateAngles) {
        var candSupported = false
        var candDist = Float.NaN

        if (bins.isNotEmpty()) {
            val cMin = cand - 5.0f
            val cMax = cand + 5.0f
            val kMin = cand - 2.5f
            val kMax = cand + 2.5f
            val wCorr = cMax - cMin  // 10.0 deg
            val wCore = kMax - kMin  // 5.0 deg

            var validCorrCov = 0.0f
            var validCoreCov = 0.0f
            val validDists = mutableListOf<Float>()

            for (b in bins) {
                if (b.angleMax <= b.angleMin) continue
                val ovCorr = max(0.0f, min(b.angleMax, cMax) - max(b.angleMin, cMin))
                val ovCore = max(0.0f, min(b.angleMax, kMax) - max(b.angleMin, kMin))

                if (b.isValid) {
                    validCorrCov += ovCorr
                    validCoreCov += ovCore
                    if (ovCorr > 0.0f && b.estimatedDistanceCm.isFinite() && b.estimatedDistanceCm > 0f) {
                        validDists.add(b.estimatedDistanceCm)
                    }
                }
            }

            val corrRatio = validCorrCov / wCorr
            val coreRatio = validCoreCov / wCore

            // Candidate corridor requires >= 75% valid coverage and central core >= 90%
            if (corrRatio >= 0.75f && coreRatio >= 0.90f && validDists.isNotEmpty()) {
                candSupported = true
                candDist = validDists.minOrNull() ?: Float.NaN
            }
        } else {
            // 3-sector fallback for legacy mocks or tests without spatialBins
            val (secValid, zSec) = when {
                cand < -10f -> Pair(validL, zLeft)
                cand > 10f -> Pair(validR, zRight)
                else -> Pair(validC, zCenter)
            }
            if (secValid) {
                candSupported = true
                candDist = zSec
            }
        }

        if (!candSupported) continue

        var isBlocked = false
        if (candDist < 40f) isBlocked = true

        if (!isBlocked) {
            for (p in profiles) {
                val dAng = abs(cand - p.angCenter)
                if (!p.isValidDist) {
                    if (dAng < p.radius) { isBlocked = true; break }
                } else {
                    if (p.zObs < 50f && dAng < p.radius) { isBlocked = true; break }
                    if (p.zObs < 35f && dAng < (p.radius + 2f)) { isBlocked = true; break }
                }
            }
        }

        if (isBlocked) {
            obstructedCount++
            continue
        }

        var risk = 0f
        for (p in profiles) {
            val dAng = abs(cand - p.angCenter)
            if (dAng < p.radius) {
                val penetration = 1f - (dAng / p.radius)
                risk += p.weight * (penetration * penetration) * 15f
            } else {
                val dEdge = dAng - p.radius
                if (dEdge < 15f) {
                    risk += p.weight * kotlin.math.exp(-((dEdge * dEdge) / 40f)).toFloat() * 2f
                }
            }
        }

        if (candDist < 80f) risk += ((80f - candDist) / 10f) * 4f
        else if (candDist < 150f) risk += ((150f - candDist) / 70f) * 1.5f

        risk += 0.05f * abs(cand)

        if (prevAngle != null && prevAngle.isFinite() && abs(cand - prevAngle) <= 3.5f) {
            risk -= 1.0f
        }

        eligibleCandidates.add(Candidate(cand, candDist, risk))
    }

    // Step 5C: Evaluate outcomes when no candidate is eligible
    if (eligibleCandidates.isEmpty()) {
        return if (obstructedCount > 0 && (obstructedCount >= allCandidateAngles.size / 2 || (validC && zCenter < 50f))) {
            DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "CORRIDOR_OBSTRUCTED")
        } else {
            val cBins = bins.filter { abs(it.angleCenter) <= 5.0f }
            val centerValidCount = cBins.filter { it.isValid }.size
            val centerMissing = bins.isNotEmpty() && (centerValidCount < max(1, (cBins.size * 0.70f).toInt()))
            val code = if (centerMissing) "CENTER_COVERAGE_INSUFFICIENT" else "NO_SUPPORTED_CANDIDATE"
            DirectionalAdvisory("UNAVAILABLE", observedRange = obsRange, sourceNanos = advNanos, reasonCode = code)
        }
    }

    // ── Step 6: Hierarchical Movement Policy (P0-02 Corridor Evidence) ──

    // Priority 1: HOLD FORWARD
    var fwdEligible = false
    var fwdDist = Float.NaN
    var fwdRisk = Float.MAX_VALUE
    for (c in eligibleCandidates) {
        if (abs(c.ang - 0f) < 1.5f) {
            fwdEligible = true
            fwdDist = c.zSec
            fwdRisk = c.risk
            break
        }
    }

    val fwdEncroached = profiles.any { p -> abs(p.angCenter) < p.radius }

    if (fwdEligible && !fwdEncroached && fwdDist >= 75f && fwdRisk <= 4f) {
        var angleOut = 0f
        if (prevAngle != null && prevAngle.isFinite()) {
            angleOut = 0.35f * 0f + 0.65f * prevAngle
            if (abs(angleOut) < 1.0f) angleOut = 0f
        }
        return DirectionalAdvisory("AVAILABLE", angleOut, 0.55f, obsRange, sourceNanos = advNanos, reasonCode = "AVAILABLE_FORWARD")
    }

    // Priority 2: SMALL CORRECTION
    val smallCandidates = eligibleCandidates.filter { abs(it.ang) <= 12.5f }
    if (smallCandidates.isNotEmpty()) {
        val bestSc = smallCandidates.minByOrNull { it.risk + 0.08f * abs(it.ang) }!!
        if (bestSc.risk < 20f && (!fwdEligible || fwdEncroached || bestSc.risk < fwdRisk - 0.5f)) {
            var scAngle = bestSc.ang
            if (prevAngle != null && prevAngle.isFinite()) {
                scAngle = 0.45f * scAngle + 0.55f * prevAngle
            }
            scAngle = max(-halfFov, min(halfFov, scAngle))
            val conf = max(0.35f, min(0.55f, 1f - (bestSc.risk / 35f)))
            return DirectionalAdvisory("AVAILABLE", scAngle, conf, obsRange, sourceNanos = advNanos, reasonCode = "AVAILABLE_CORRECTION")
        }
    }

    // Priority 3: ALTERNATIVE HEADING
    var bestCand = 0f
    var minCost = Float.MAX_VALUE
    for (c in eligibleCandidates) {
        var cost = c.risk + 0.08f * abs(c.ang)
        if (prevAngle != null && prevAngle.isFinite()) {
            cost += 0.05f * abs(c.ang - prevAngle)
        }
        if (cost < minCost) {
            minCost = cost
            bestCand = c.ang
        }
    }

    if (minCost > 30f) {
        return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "NO_SAFE_PATH")
    }

    if (threat == "CRITICAL" && validC) {
        // Immediate frontal collision (< 25cm) forces emergency STOP
        if (zCenter < 25f) {
            return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "CRITICAL_OBSTACLE")
        }
        // Constrained center hazard (< 40cm): allow alternative heading only if genuinely safe and has clearance
        if (zCenter < 40f && (minCost > 15f || !eligibleCandidates.any { abs(it.ang - bestCand) < 1.5f && it.zSec >= 60f })) {
            return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = advNanos, reasonCode = "CRITICAL_OBSTACLE")
        }
    }

    val conf = max(0.30f, min(0.55f, 1f - (minCost / 35f)))
    var selected = bestCand
    if (prevAngle != null && prevAngle.isFinite()) {
        selected = 0.45f * selected + 0.55f * prevAngle
    }
    selected = max(-halfFov, min(halfFov, selected))

    return DirectionalAdvisory("AVAILABLE", selected, conf, obsRange, sourceNanos = advNanos, reasonCode = "AVAILABLE_ALTERNATIVE")
}

class OverlayView(context: Context, attrs: AttributeSet?) : View(context, attrs) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var depth: DepthResult? = null
    private var threat = "PAUSED"
    private var timestamp = 0L
    private var prevAngle: Float? = null
    var advisory = DirectionalAdvisory()

    fun setState(state: String) {
        threat = state; depth = null; advisory = DirectionalAdvisory(); prevAngle = null
        contentDescription = if (state == "PAUSED") "Perception paused" else "Direction unavailable"
        invalidate()
    }

    fun update(result: DepthResult, state: String, nowNanos: Long = SystemClock.elapsedRealtimeNanos()) {
        depth = result; threat = state; timestamp = result.timestampNanos
        advisory = estimateDirectionalAdvisory(result, state, nowNanos, prevAngle = prevAngle)
        prevAngle = if (advisory.state == "AVAILABLE") advisory.angleDeg else null
        val isStop = advisory.state == "STOP" || state == "CRITICAL"
        contentDescription = if (isStop) "Stop. Obstacle detected" else "Direction advisory"
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val now = SystemClock.elapsedRealtimeNanos()
        val density = resources.displayMetrics.density

        // Preview is live. Suppress brackets older than 250 ms rather than show
        // geometrically correct but temporally misleading stale detections.
        depth?.takeIf { now - timestamp <= 250_000_000L }?.let { d ->
            val sh = 1f; val sw = d.sourceAspect
            val scale = min(width / sw, height / sh)
            val ox = (width - sw * scale) / 2; val oy = (height - scale) / 2

            val isStop = advisory.state == "STOP" || threat == "CRITICAL"
            val primaryColor = when {
                isStop -> Color.rgb(255, 59, 48)       // Apple Red
                threat == "WARNING" -> Color.rgb(255, 149, 0) // Apple Orange
                else -> Color.rgb(242, 242, 247)             // Apple Crisp White
            }

            for (o in d.allObstacles) {
                val l = ox + o.bbox.left.toFloat() / d.width * sw * scale
                val r = ox + o.bbox.right.toFloat() / d.width * sw * scale
                val t = oy + o.bbox.top.toFloat() / d.height * scale
                val b = oy + o.bbox.bottom.toFloat() / d.height * scale
                val leg = min(26f * density, min(r - l, b - t) / 2.8f)

                // Pass 1: Outer dark outline for high contrast against bright scenes
                paint.color = Color.argb(220, 0, 0, 0)
                paint.strokeWidth = 7.0f * density
                paint.strokeCap = Paint.Cap.ROUND
                for ((x, y, dx, dy) in listOf(listOf(l, t, 1f, 1f), listOf(r, t, -1f, 1f), listOf(l, b, 1f, -1f), listOf(r, b, -1f, -1f))) {
                    canvas.drawLine(x, y, x + dx * leg, y, paint)
                    canvas.drawLine(x, y, x, y + dy * leg, paint)
                }

                // Pass 2: Vivid inner colored stroke
                paint.color = primaryColor
                paint.strokeWidth = 4.5f * density
                paint.strokeCap = Paint.Cap.ROUND
                for ((x, y, dx, dy) in listOf(listOf(l, t, 1f, 1f), listOf(r, t, -1f, 1f), listOf(l, b, 1f, -1f), listOf(r, b, -1f, -1f))) {
                    canvas.drawLine(x, y, x + dx * leg, y, paint)
                    canvas.drawLine(x, y, x, y + dy * leg, paint)
                }
            }
        }

        val cx = width / 2f
        val cy = height * 0.86f
        val angle = advisory.drawableAngle(now)

        if (angle != null && threat != "PAUSED") {
            // Perceptual visual rotation mapping (P0-01)
            val visualAngle = (angle * 1.4f).coerceIn(-45f, 45f)
            val lateralOffset = (visualAngle * 0.9f * density).coerceIn(-35f * density, 35f * density)

            canvas.save()
            canvas.translate(cx + lateralOffset, cy)
            canvas.scale(1.10f, 0.75f) // 3D road-projected perspective
            canvas.rotate(visualAngle)

            // Scaled 1.25x 3D arrow path with wider arrowhead
            val path = Path().apply {
                moveTo(-16f * density, 32f * density)
                lineTo(16f * density, 32f * density)
                lineTo(16f * density, -20f * density)
                lineTo(38f * density, -20f * density)
                lineTo(0f, -68f * density) // Prominent arrowhead tip
                lineTo(-38f * density, -20f * density)
                lineTo(-16f * density, -20f * density)
                close()
            }

            // Outer drop shadow
            paint.style = Paint.Style.FILL
            paint.color = Color.argb(160, 0, 0, 0)
            canvas.save()
            canvas.translate(0f, 6f * density)
            canvas.drawPath(path, paint)
            canvas.restore()

            // Outer dark stroke for maximum edge contrast
            paint.style = Paint.Style.STROKE
            paint.color = Color.argb(120, 0, 0, 0)
            paint.strokeWidth = 2.5f * density
            canvas.drawPath(path, paint)

            // Front surface: Crisp silver-white gradient
            paint.style = Paint.Style.FILL
            paint.shader = android.graphics.LinearGradient(
                0f, -68f * density, 0f, 32f * density,
                Color.WHITE, Color.rgb(209, 209, 214),
                android.graphics.Shader.TileMode.CLAMP
            )
            canvas.drawPath(path, paint)
            paint.shader = null

            canvas.restore()
        } else {
            val isStop = (advisory.state == "STOP" || threat == "CRITICAL") && threat != "PAUSED"
            val isPaused = threat == "PAUSED"
            val text = when {
                isPaused -> "PAUSED"
                isStop -> "STOP"
                else -> "UNAVAILABLE"
            }
            paint.style = Paint.Style.FILL
            paint.textSize = 22f * density
            paint.textAlign = Paint.Align.CENTER
            paint.isFakeBoldText = true

            // Pill badge background
            paint.color = Color.argb(215, 12, 14, 18)
            val badgeHalfW = 120f * density
            val badgeH = 26f * density
            canvas.drawRoundRect(cx - badgeHalfW, cy - badgeH, cx + badgeHalfW, cy + badgeH, 18f * density, 18f * density, paint)

            // Pill subtle border
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 1f * density
            paint.color = Color.argb(60, 255, 255, 255)
            canvas.drawRoundRect(cx - badgeHalfW, cy - badgeH, cx + badgeHalfW, cy + badgeH, 18f * density, 18f * density, paint)

            // Text
            paint.style = Paint.Style.FILL
            paint.color = if (isStop) Color.rgb(255, 59, 48) else Color.rgb(242, 242, 247)
            canvas.drawText(text, cx, cy + 8f * density, paint)
            paint.isFakeBoldText = false
        }

        if (depth != null) postInvalidateDelayed(250)
    }
}
