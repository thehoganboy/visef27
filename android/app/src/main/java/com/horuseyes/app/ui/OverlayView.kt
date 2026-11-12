package com.horuseyes.app.ui

import android.content.Context
import android.graphics.*
import android.os.SystemClock
import android.util.AttributeSet
import android.view.View
import com.horuseyes.app.vision.DepthResult
import kotlin.math.min

// Optional angle is camera-relative: negative left, positive right. No current
// estimator establishes traversability, so live guidance remains unavailable.
data class DirectionalAdvisory(val state: String = "UNKNOWN", val angleDeg: Float? = null,
    val confidence: Float? = null, val observedRange: Pair<Float, Float>? = null,
    val sourceNanos: Long = 0) {
    fun drawableAngle(now: Long): Float? {
        val a = angleDeg ?: return null
        val range = observedRange ?: return null
        if (state != "AVAILABLE" || !a.isFinite() || now - sourceNanos !in 0..1_000_000_000L ||
            confidence == null || confidence <= 0 || confidence > 1 ||
            range.first < -90 || range.second > 90 || a < range.first || a > range.second) return null
        return a
    }
}

class OverlayView(context: Context, attrs: AttributeSet?) : View(context, attrs) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var depth: DepthResult? = null
    private var threat = "PAUSED"
    private var timestamp = 0L
    var advisory = DirectionalAdvisory()
    fun setState(state: String) {
        threat = state; depth = null; advisory = DirectionalAdvisory()
        contentDescription = if (state == "PAUSED") "Perception paused" else "Direction unavailable"
        invalidate()
    }
    fun update(result: DepthResult, state: String, sourceNanos: Long) {
        depth = result; threat = state; timestamp = sourceNanos
        advisory = DirectionalAdvisory(if (state == "CRITICAL") "STOP" else "UNAVAILABLE", sourceNanos = sourceNanos)
        contentDescription = if (state == "CRITICAL") "Stop. Obstacle detected" else "Direction unavailable"
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
            val ox = (width - sw * scale)/2; val oy = (height - scale)/2
            paint.color = when(threat) { "CRITICAL" -> Color.rgb(239,68,74); "WARNING" -> Color.rgb(245,180,60); else -> Color.LTGRAY }
            paint.strokeWidth = 3 * resources.displayMetrics.density
            for (o in d.allObstacles) {
                val l = ox + o.bbox.left.toFloat()/d.width*sw*scale
                val r = ox + o.bbox.right.toFloat()/d.width*sw*scale
                val t = oy + o.bbox.top.toFloat()/d.height*scale
                val b = oy + o.bbox.bottom.toFloat()/d.height*scale
                val leg = min(20 * resources.displayMetrics.density, min(r-l,b-t)/3)
                for ((x,y,dx,dy) in listOf(listOf(l,t,1f,1f), listOf(r,t,-1f,1f), listOf(l,b,1f,-1f), listOf(r,b,-1f,-1f))) {
                    canvas.drawLine(x,y,x+dx*leg,y,paint); canvas.drawLine(x,y,x,y+dy*leg,paint)
                }
            }
        }
        val cx = width/2f; val cy = height*.87f
        val angle = advisory.drawableAngle(now)
        if (angle != null && threat != "PAUSED") {
            canvas.save(); canvas.translate(cx,cy); canvas.scale(1f,.7f); canvas.rotate(angle)
            val path = Path().apply { moveTo(-13f,25f); lineTo(13f,25f); lineTo(13f,-15f); lineTo(28f,-15f); lineTo(0f,-53f); lineTo(-28f,-15f); lineTo(-13f,-15f); close() }
            paint.color = Color.DKGRAY; canvas.save(); canvas.translate(4f,7f); canvas.drawPath(path,paint); canvas.restore()
            paint.color = Color.LTGRAY; canvas.drawPath(path,paint); canvas.restore()
        } else {
            val text = when(threat) { "PAUSED" -> "PAUSED"; "CRITICAL" -> "STOP"; else -> "UNAVAILABLE" }
            paint.textSize = 22 * resources.displayMetrics.scaledDensity; paint.textAlign = Paint.Align.CENTER
            paint.color = Color.argb(220,18,20,24)
            canvas.drawRoundRect(cx-150*resources.displayMetrics.density,cy-40,cx+150*resources.displayMetrics.density,cy+25,16f,16f,paint)
            paint.color = if(threat == "CRITICAL") Color.rgb(239,68,74) else Color.LTGRAY
            canvas.drawText(text,cx,cy+5,paint)
        }
        if (depth != null) postInvalidateDelayed(250)
    }
}
