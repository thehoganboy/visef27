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
    val sourceNanos: Long = 0
) {
    fun drawableAngle(now: Long): Float? {
        val a = angleDeg ?: return null
        val range = observedRange ?: return null
        if (state != "AVAILABLE" || !a.isFinite() || now - sourceNanos !in 0..1_000_000_000L ||
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
    if (threat == "PAUSED" || threat == "INITIALIZING" || threat == "SENSOR_FAULT" || depth == null || !depth.isValid) {
        return DirectionalAdvisory("UNKNOWN", sourceNanos = nowNanos)
    }

    val halfFov = hfovDeg / 2f
    val obsRange = Pair(-halfFov, halfFov)
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
        return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = nowNanos)
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

    if (profiles.isEmpty() && validC && zCenter < 150f) {
        val angCenter = depth.pan * halfFov
        val weight = if (zCenter < 80f) 15f else 5f
        profiles.add(ObsProfile(angCenter, 12f, weight, zCenter, true))
    }

    // Clear frame with no detected obstacles: only permitted if ALL 3 sectors are valid & clear
    if (profiles.isEmpty()) {
        if (validC && validL && validR && zCenter >= 150f && zLeft >= 150f && zRight >= 150f) {
            val angOut = if (prevAngle != null && prevAngle.isFinite()) 0.3f * 0f + 0.7f * prevAngle else 0f
            return DirectionalAdvisory("AVAILABLE", angOut, 0.55f, obsRange, nowNanos)
        } else if (!validC && !validL && !validR) {
            return DirectionalAdvisory("UNAVAILABLE", observedRange = obsRange, sourceNanos = nowNanos)
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
        val (secValid, zSec) = when {
            cand < -10f -> Pair(validL, zLeft)
            cand > 10f -> Pair(validR, zRight)
            else -> Pair(validC, zCenter)
        }
        if (!secValid) continue

        var isBlocked = false
        if (zSec < 40f) isBlocked = true

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

        if (zSec < 80f) risk += ((80f - zSec) / 10f) * 4f
        else if (zSec < 150f) risk += ((150f - zSec) / 70f) * 1.5f

        risk += 0.05f * abs(cand)

        if (prevAngle != null && prevAngle.isFinite() && abs(cand - prevAngle) <= 3.5f) {
            risk -= 1.0f
        }

        eligibleCandidates.add(Candidate(cand, zSec, risk))
    }

    // Step 5C: Evaluate outcomes when no candidate is eligible
    if (eligibleCandidates.isEmpty()) {
        return if (obstructedCount > 0 && (obstructedCount >= allCandidateAngles.size / 2 || (validC && zCenter < 50f))) {
            DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = nowNanos)
        } else {
            DirectionalAdvisory("UNAVAILABLE", observedRange = obsRange, sourceNanos = nowNanos)
        }
    }

    // ── Step 6: Hierarchical Movement Policy (Directive Section 3) ──

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
        return DirectionalAdvisory("AVAILABLE", angleOut, 0.55f, obsRange, nowNanos)
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
            return DirectionalAdvisory("AVAILABLE", scAngle, conf, obsRange, nowNanos)
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

    if (minCost > 30f || (threat == "CRITICAL" && validC && zCenter < 40f)) {
        return DirectionalAdvisory("STOP", observedRange = obsRange, sourceNanos = nowNanos)
    }

    val conf = max(0.30f, min(0.55f, 1f - (minCost / 35f)))
    var selected = bestCand
    if (prevAngle != null && prevAngle.isFinite()) {
        selected = 0.45f * selected + 0.55f * prevAngle
    }
    selected = max(-halfFov, min(halfFov, selected))

    return DirectionalAdvisory("AVAILABLE", selected, conf, obsRange, nowNanos)
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

    fun update(result: DepthResult, state: String, sourceNanos: Long) {
        depth = result; threat = state; timestamp = sourceNanos
        advisory = estimateDirectionalAdvisory(result, state, sourceNanos, prevAngle = prevAngle)
        prevAngle = if (advisory.state == "AVAILABLE") advisory.angleDeg else null
        contentDescription = if (state == "CRITICAL") "Stop. Obstacle detected" else "Direction advisory"
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val now = SystemClock.elapsedRealtimeNanos()
        // Preview is live. Suppress brackets older than 250 ms rather than show
        // geometrically correct but temporally misleading stale detections.
        depth?.takeIf { now - timestamp <= 250_000_000L }?.let { d ->
            val sh = 1f; val sw = d.sourceAspect
            val scale = min(width / sw, height / sh)
            val ox = (width - sw * scale) / 2; val oy = (height - scale) / 2
            paint.color = when (threat) {
                "CRITICAL" -> Color.rgb(239, 68, 74)
                "WARNING" -> Color.rgb(245, 180, 60)
                else -> Color.LTGRAY
            }
            paint.strokeWidth = 3 * resources.displayMetrics.density
            for (o in d.allObstacles) {
                val l = ox + o.bbox.left.toFloat() / d.width * sw * scale
                val r = ox + o.bbox.right.toFloat() / d.width * sw * scale
                val t = oy + o.bbox.top.toFloat() / d.height * scale
                val b = oy + o.bbox.bottom.toFloat() / d.height * scale
                val leg = min(20 * resources.displayMetrics.density, min(r - l, b - t) / 3)
                for ((x, y, dx, dy) in listOf(listOf(l, t, 1f, 1f), listOf(r, t, -1f, 1f), listOf(l, b, 1f, -1f), listOf(r, b, -1f, -1f))) {
                    canvas.drawLine(x, y, x + dx * leg, y, paint)
                    canvas.drawLine(x, y, x, y + dy * leg, paint)
                }
            }
        }
        val cx = width / 2f; val cy = height * 0.87f
        val angle = advisory.drawableAngle(now)
        if (angle != null && threat != "PAUSED") {
            canvas.save(); canvas.translate(cx, cy); canvas.scale(1f, 0.7f); canvas.rotate(angle)
            val path = Path().apply {
                moveTo(-13f, 25f); lineTo(13f, 25f); lineTo(13f, -15f); lineTo(28f, -15f)
                lineTo(0f, -53f); lineTo(-28f, -15f); lineTo(-13f, -15f); close()
            }
            paint.color = Color.DKGRAY; canvas.save(); canvas.translate(4f, 7f); canvas.drawPath(path, paint); canvas.restore()
            paint.color = Color.LTGRAY; canvas.drawPath(path, paint); canvas.restore()
        } else {
            val text = when (threat) {
                "PAUSED" -> "PAUSED"
                "CRITICAL" -> "STOP"
                else -> "UNAVAILABLE"
            }
            paint.textSize = 22 * resources.displayMetrics.scaledDensity; paint.textAlign = Paint.Align.CENTER
            paint.color = Color.argb(220, 18, 20, 24)
            canvas.drawRoundRect(cx - 150 * resources.displayMetrics.density, cy - 40, cx + 150 * resources.displayMetrics.density, cy + 25, 16f, 16f, paint)
            paint.color = if (threat == "CRITICAL") Color.rgb(239, 68, 74) else Color.LTGRAY
            canvas.drawText(text, cx, cy + 5, paint)
        }
        if (depth != null) postInvalidateDelayed(250)
    }
}
