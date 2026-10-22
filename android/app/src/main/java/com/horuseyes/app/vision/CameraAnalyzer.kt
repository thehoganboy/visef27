package com.horuseyes.app.vision

import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.horuseyes.app.Config
import com.horuseyes.app.audio.SpatialAudioEngine
import com.horuseyes.app.budget.AuditoryBudgetManager
import com.horuseyes.app.budget.BudgetDecision
import com.horuseyes.app.kinematics.KinematicsEngine
import com.horuseyes.app.kinematics.KinematicsResult

interface TelemetryListener {
    fun onTelemetryUpdate(
        depthResult: DepthResult,
        kinematicsResult: KinematicsResult,
        decision: BudgetDecision,
        fps: Float,
        latencyMs: Float
    )
}

/**
 * CameraX ImageAnalysis Analyzer xử lý luồng khung hình thời gian thực.
 * Pipeline: CameraX -> YUV to Bitmap -> Rotate to Portrait -> Scale to 192x256 ->
 *           MiDaS ONNX -> Kinematics TTC & Tracker -> Auditory Budget -> Audio Synthesizer -> UI Overlay.
 */
class CameraAnalyzer(
    private val depthEngine: DepthEngine,
    private val kinematicsEngine: KinematicsEngine,
    private val budgetManager: AuditoryBudgetManager,
    private val audioEngine: SpatialAudioEngine,
    private val listener: TelemetryListener? = null
) : ImageAnalysis.Analyzer {

    @Volatile
    var isRunning: Boolean = true

    private var lastTimestampNanos: Long = 0L
    private var fpsEma: Float = 30.0f
    private val inW = Config.INPUT_WIDTH   // 192
    private val inH = Config.INPUT_HEIGHT  // 256

    override fun analyze(imageProxy: ImageProxy) {
        if (!isRunning) {
            imageProxy.close()
            return
        }
        val tStart = SystemClock.elapsedRealtimeNanos()

        try {
            // 1. Chuyển đổi ImageProxy sang Bitmap ARGB_8888 và căn chỉnh góc quay chuẩn portrait
            val rawBitmap = imageProxy.toBitmap()
            val rotationDegrees = imageProxy.imageInfo.rotationDegrees

            val alignedBitmap = if (rotationDegrees != 0) {
                val matrix = Matrix().apply { postRotate(rotationDegrees.toFloat()) }
                Bitmap.createBitmap(rawBitmap, 0, 0, rawBitmap.width, rawBitmap.height, matrix, true)
            } else {
                rawBitmap
            }

            // 2. Co dãn chính xác về tỷ lệ 3:4 chuẩn Portrait (192 x 256)
            val inputBitmap = if (alignedBitmap.width != inW || alignedBitmap.height != inH) {
                Bitmap.createScaledBitmap(alignedBitmap, inW, inH, true)
            } else {
                alignedBitmap
            }

            // 3. Đo mốc thời gian liên tục (giây)
            val nowNanos = System.nanoTime()
            val timestampSec = nowNanos / 1_000_000_000.0f

            // 4. Suy luận độ sâu & Phân đoạn không gian (Perception)
            val depthResult = depthEngine.inferDepth(inputBitmap)

            // 5. Theo dõi động học Centroid + TTC Prediction (Kinematics)
            val kinematicsResult = kinematicsEngine.compute(depthResult, timestampSec)

            // 6. Điều phối ngân sách thính giác nhận thức (Decision)
            val decision = budgetManager.coordinate(depthResult, kinematicsResult)

            // 7. Cập nhật trạng thái âm thanh 3D Binaural (Actuation)
            audioEngine.updateState(decision)

            // 8. Đo đạc FPS và Độ trễ đường ống biên (Profiling)
            val tEnd = SystemClock.elapsedRealtimeNanos()
            val latencyMs = (tEnd - tStart) / 1_000_000.0f

            if (lastTimestampNanos > 0L) {
                val dtSec = (nowNanos - lastTimestampNanos) / 1_000_000_000.0f
                if (dtSec > 0.001f) {
                    val instantFps = 1.0f / dtSec
                    fpsEma = 0.20f * instantFps + 0.80f * fpsEma
                }
            }
            lastTimestampNanos = nowNanos

            // 9. Bắn thông báo cập nhật Telemetry UI
            listener?.onTelemetryUpdate(
                depthResult,
                kinematicsResult,
                decision,
                fpsEma,
                latencyMs
            )

        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            // Luôn đóng ImageProxy để tránh nghẽn luồng CameraX
            imageProxy.close()
        }
    }
}
