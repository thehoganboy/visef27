package com.horuseyes.app.vision

import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.horuseyes.app.budget.AuditoryBudgetManager
import com.horuseyes.app.budget.BudgetDecision
import com.horuseyes.app.kinematics.KinematicsEngine
import com.horuseyes.app.kinematics.KinematicsResult

interface TelemetryListener {
    fun onResult(depth: DepthResult, risk: KinematicsResult, decision: BudgetDecision,
                 sourceNanos: Long, generation: Long)
    fun onFault(generation: Long)
}

class CameraAnalyzer(private val depth: DepthEngine, private val listener: TelemetryListener) : ImageAnalysis.Analyzer {
    @Volatile var isRunning = false
    @Volatile var generation = 0L
    @Volatile var lastFrameNanos = 0L
    @Volatile var yawRate = 0f
    private var workerGeneration = -1L
    private var kin = KinematicsEngine()
    private var budget = AuditoryBudgetManager()
    private val epoch = SystemClock.elapsedRealtimeNanos()

    fun setActive(active: Boolean) {
        isRunning = false
        generation++
        isRunning = active
    }

    override fun analyze(image: ImageProxy) {
        val now = SystemClock.elapsedRealtimeNanos()
        lastFrameNanos = now
        val token = generation
        val bitmaps = mutableSetOf<Bitmap>()
        try {
            if (!isRunning) return
            if (workerGeneration != token) {
                kin = KinematicsEngine(); budget = AuditoryBudgetManager()
                workerGeneration = token
            }
            val raw = image.toBitmap().also { bitmaps.add(it) }
            val crop = image.cropRect
            val cropped = Bitmap.createBitmap(raw, crop.left, crop.top, crop.width(), crop.height()).also { bitmaps.add(it) }
            val matrix = Matrix().apply { postRotate(image.imageInfo.rotationDegrees.toFloat()) }
            val upright = Bitmap.createBitmap(cropped, 0, 0, cropped.width, cropped.height, matrix, true).also { bitmaps.add(it) }
            val input = Bitmap.createScaledBitmap(upright, depth.inW, depth.inH, true).also { bitmaps.add(it) }
            val result = depth.inferDepth(input).copy(sourceAspect = upright.width.toFloat() / upright.height)
            // Relative monotonic epoch avoids Float precision loss after long device uptime.
            val risk = kin.compute(result, (now - epoch) / 1_000_000_000f, yawRate)
            val decision = budget.coordinate(result, risk)
            if (isRunning && token == generation) listener.onResult(result, risk, decision, now, token)
        } catch (e: Exception) {
            android.util.Log.e("HorusEyes", "Perception unavailable", e)
            if (isRunning && token == generation) listener.onFault(token)
        } finally {
            bitmaps.forEach { it.recycle() }
            image.close()
        }
    }
}
