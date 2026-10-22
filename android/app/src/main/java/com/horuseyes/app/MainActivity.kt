package com.horuseyes.app

import android.Manifest
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.os.Bundle
import android.util.Size
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import com.horuseyes.app.audio.SpatialAudioEngine
import com.horuseyes.app.budget.AuditoryBudgetManager
import com.horuseyes.app.budget.BudgetDecision
import com.horuseyes.app.databinding.ActivityMainBinding
import com.horuseyes.app.kinematics.KinematicsEngine
import com.horuseyes.app.kinematics.KinematicsResult
import com.horuseyes.app.vision.CameraAnalyzer
import com.horuseyes.app.vision.DepthEngine
import com.horuseyes.app.vision.DepthResult
import com.horuseyes.app.vision.TelemetryListener
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * MainActivity - Vòng lặp điều phối chính của ứng dụng HorusEyes 2.0 trên Android.
 * Quản lý vòng đời CameraX, AudioTrack, điều khiển Start/Stop, Căn chỉnh cự ly và cập nhật HUD.
 */
class MainActivity : AppCompatActivity(), TelemetryListener {

    private lateinit var binding: ActivityMainBinding
    private lateinit var cameraExecutor: ExecutorService

    private var depthEngine: DepthEngine? = null
    private val kinematicsEngine = KinematicsEngine()
    private val budgetManager = AuditoryBudgetManager()
    private val audioEngine = SpatialAudioEngine()
    private var analyzer: CameraAnalyzer? = null

    private var isRunning: Boolean = true
    private var isMuted: Boolean = false
    private var currentScale: Float = Config.DEFAULT_DIST_SCALE

    private val cameraPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            startCamera()
        } else {
            Toast.makeText(
                this,
                getString(R.string.camera_permission_required),
                Toast.LENGTH_LONG
            ).show()
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        cameraExecutor = Executors.newSingleThreadExecutor()

        try {
            // Khởi tạo AI Depth Engine từ assets
            depthEngine = DepthEngine(this, "midas_small.onnx")
            depthEngine?.scaleFactor = currentScale
        } catch (e: Exception) {
            e.printStackTrace()
            Toast.makeText(
                this,
                "Lỗi khởi tạo ONNX Model: ${e.message}. Vui lòng kiểm tra file assets/midas_small.onnx!",
                Toast.LENGTH_LONG
            ).show()
        }

        setupControlListeners()
        audioEngine.start()

        if (allPermissionsGranted()) {
            startCamera()
        } else {
            cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    private fun setupControlListeners() {
        // 1. Nút START / STOP
        binding.btnStartStop.setOnClickListener {
            toggleRunningState()
        }

        // 2. Nút BẬT / TẮT ÂM THANH
        binding.btnMute.setOnClickListener {
            toggleMuteState()
        }

        // 3. Căn chỉnh tiêu cự: Giảm (-)
        binding.btnScaleDown.setOnClickListener {
            adjustScale(-0.05f)
        }

        // 4. Căn chỉnh tiêu cự: Tăng (+)
        binding.btnScaleUp.setOnClickListener {
            adjustScale(0.05f)
        }

        // 5. Căn chỉnh tiêu cự: Đặt lại (1.00x)
        binding.btnScaleReset.setOnClickListener {
            resetScale()
        }
    }

    private fun toggleRunningState() {
        isRunning = !isRunning
        analyzer?.isRunning = isRunning
        binding.overlayView.isPaused = !isRunning

        if (isRunning) {
            binding.btnStartStop.text = "STOP"
            binding.btnStartStop.backgroundTintList = ColorStateList.valueOf(0xFFEF4444.toInt()) // Red
            binding.tvStatusBadge.text = "● RUNNING"
            binding.tvStatusBadge.setTextColor(0xFF00E676.toInt()) // Green
            binding.tvStatusBadge.setBackgroundColor(0x3300E676.toInt())
            audioEngine.setMuted(isMuted)
        } else {
            binding.btnStartStop.text = "START"
            binding.btnStartStop.backgroundTintList = ColorStateList.valueOf(0xFF10B981.toInt()) // Green
            binding.tvStatusBadge.text = "⏸ PAUSED"
            binding.tvStatusBadge.setTextColor(0xFFF59E0B.toInt()) // Amber
            binding.tvStatusBadge.setBackgroundColor(0x33F59E0B.toInt())
            audioEngine.setMuted(true)
        }
    }

    private fun toggleMuteState() {
        isMuted = !isMuted
        if (isRunning) {
            audioEngine.setMuted(isMuted)
        }
        if (isMuted) {
            binding.btnMute.text = "🔇 TẮT"
            binding.btnMute.setTextColor(0xFFEF4444.toInt())
        } else {
            binding.btnMute.text = "🔊 ÂM"
            binding.btnMute.setTextColor(0xFFE0E0E0.toInt())
        }
    }

    private fun adjustScale(delta: Float) {
        currentScale = (currentScale + delta).coerceIn(0.50f, 2.00f)
        depthEngine?.scaleFactor = currentScale
        binding.btnScaleReset.text = String.format(Locale.US, "%.2fx", currentScale)
    }

    private fun resetScale() {
        currentScale = Config.DEFAULT_DIST_SCALE
        depthEngine?.scaleFactor = currentScale
        binding.btnScaleReset.text = "1.00x"
    }

    private fun allPermissionsGranted(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)

        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            // 1. Luồng xem trước (Camera Preview)
            binding.previewView.scaleType = androidx.camera.view.PreviewView.ScaleType.FILL_CENTER
            val preview = Preview.Builder()
                .setTargetResolution(Size(Config.CAM_WIDTH, Config.CAM_HEIGHT))
                .build()
                .also {
                    it.setSurfaceProvider(binding.previewView.surfaceProvider)
                }

            // 2. Luồng phân tích khung hình biên (ImageAnalysis)
            val imageAnalyzer = ImageAnalysis.Builder()
                .setTargetResolution(Size(Config.CAM_WIDTH, Config.CAM_HEIGHT))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
                .also { analysis ->
                    depthEngine?.let { engine ->
                        val a = CameraAnalyzer(
                            depthEngine = engine,
                            kinematicsEngine = kinematicsEngine,
                            budgetManager = budgetManager,
                            audioEngine = audioEngine,
                            listener = this
                        )
                        a.isRunning = isRunning
                        analyzer = a
                        analysis.setAnalyzer(cameraExecutor, a)
                    }
                }

            // Camera sau mặc định
            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this,
                    cameraSelector,
                    preview,
                    imageAnalyzer
                )
            } catch (exc: Exception) {
                exc.printStackTrace()
                Toast.makeText(this, "Không thể liên kết Camera: ${exc.message}", Toast.LENGTH_SHORT).show()
            }

        }, ContextCompat.getMainExecutor(this))
    }

    override fun onTelemetryUpdate(
        depthResult: DepthResult,
        kinematicsResult: KinematicsResult,
        decision: BudgetDecision,
        fps: Float,
        latencyMs: Float
    ) {
        runOnUiThread {
            if (!isRunning) return@runOnUiThread

            binding.overlayView.updateTelemetry(
                depthResult,
                kinematicsResult,
                decision,
                fps,
                latencyMs
            )

            val statusStr = when (kinematicsResult.threatLevel) {
                "CRITICAL" -> "● NGUY HIỂM"
                "WARNING" -> "▲ CẢNH BÁO"
                else -> "✓ AN TOÀN"
            }

            binding.tvTelemetry.text = String.format(
                Locale.US,
                "FPS: %.0f | Trễ: %.0fms | Cự ly: %.0fcm | %s",
                fps,
                latencyMs,
                depthResult.distCm,
                statusStr
            )

            val leftDist = depthResult.sectorDists["LEFT"] ?: 0f
            val centerDist = depthResult.sectorDists["CENTER"] ?: 0f
            val rightDist = depthResult.sectorDists["RIGHT"] ?: 0f
            val lScore = kinematicsResult.sectorScores["LEFT"] ?: 0.5f
            val rScore = kinematicsResult.sectorScores["RIGHT"] ?: 0.5f

            binding.tvCorridor.text = String.format(
                Locale.US,
                "Trái: %.0fcm (%.2f) | Giữa: %.0fcm | Phải: %.0fcm (%.2f) | %s",
                leftDist,
                lScore,
                centerDist,
                rightDist,
                rScore,
                kinematicsResult.guidanceState
            )
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        audioEngine.stop()
        depthEngine?.close()
        cameraExecutor.shutdown()
    }
}
