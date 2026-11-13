package com.horuseyes.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.horuseyes.app.audio.SpatialAudioEngine
import com.horuseyes.app.budget.BudgetDecision
import com.horuseyes.app.budget.faultDecision
import com.horuseyes.app.databinding.ActivityMainBinding
import com.horuseyes.app.kinematics.KinematicsResult
import com.horuseyes.app.vision.*
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity(), TelemetryListener, SensorEventListener {
    private lateinit var binding: ActivityMainBinding
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private var depth: DepthEngine? = null
    private var analyzer: CameraAnalyzer? = null
    private var provider: ProcessCameraProvider? = null
    private var audio: SpatialAudioEngine? = null
    private var running = false
    private var closed = false
    private var lastResult = 0L
    private var started = 0L
    private lateinit var sensors: SensorManager
    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        if (it) bindCamera() else showFault()
    }
    private val watchdog = object : Runnable {
        override fun run() {
            if (closed) return
            if (running) {
                val now = SystemClock.elapsedRealtimeNanos()
                if (now - started > 1_000_000_000L &&
                    (analyzer == null || now - (analyzer?.lastFrameNanos ?: 0) > 1_000_000_000L ||
                     now - lastResult > 1_000_000_000L)) showFault()
            }
            handler.postDelayed(this, 250)
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        sensors = getSystemService(SENSOR_SERVICE) as SensorManager
        binding.btnStartStop.setOnClickListener {
            binding.btnStartStop.performHapticFeedback(android.view.HapticFeedbackConstants.CONFIRM)
            setRunning(!running)
        }
        handler.post(watchdog)
        executor.execute {
            try { depth = DepthEngine(this) } catch (e: Exception) {
                android.util.Log.e("HorusEyes", "Model unavailable", e)
            }
            runOnUiThread {
                if (!closed) {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) bindCamera()
                    else permission.launch(Manifest.permission.CAMERA)
                }
            }
        }
    }
    private fun setRunning(value: Boolean) {
        running = value
        started = SystemClock.elapsedRealtimeNanos(); lastResult = started
        analyzer?.setActive(value)
        binding.btnStartStop.text = if (value) "DỪNG" else "CHẠY"
        binding.btnStartStop.contentDescription = if (value) "Dừng nhận thức tránh va chạm" else "Bắt đầu nhận thức tránh va chạm"
        binding.overlayView.setState(if (value) "INITIALIZING" else "PAUSED")
        if (value) {
            try {
                if (audio == null) audio = SpatialAudioEngine().also { it.start() }
                audio?.setMuted(false)
            } catch (e: Exception) {
                android.util.Log.e("HorusEyes", "Audio unavailable", e)
                binding.overlayView.setState("SENSOR_FAULT")
            }
        } else audio?.setMuted(true)
    }
    private fun bindCamera() {
        binding.previewView.post {
            val future = ProcessCameraProvider.getInstance(this)
            future.addListener({
                if (closed) return@addListener
                try {
                    val camera = future.get(); provider = camera
                    binding.previewView.scaleType = PreviewView.ScaleType.FIT_CENTER
                    val preview = Preview.Builder().setTargetRotation(android.view.Surface.ROTATION_0).build()
                    preview.setSurfaceProvider(binding.previewView.surfaceProvider)
                    val analysis = ImageAnalysis.Builder()
                        .setTargetRotation(android.view.Surface.ROTATION_0)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888).build()
                    depth?.let {
                        analyzer = CameraAnalyzer(it, this).also { a ->
                            a.setActive(running); analysis.setAnalyzer(executor, a)
                        }
                    }
                    val group = UseCaseGroup.Builder().addUseCase(preview).addUseCase(analysis)
                    binding.previewView.viewPort?.let { group.setViewPort(it) }
                    camera.unbindAll()
                    camera.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, group.build())
                } catch (e: Exception) {
                    android.util.Log.e("HorusEyes", "Camera unavailable", e); showFault()
                }
            }, ContextCompat.getMainExecutor(this))
        }
    }
    private fun showFault() {
        binding.overlayView.setState("SENSOR_FAULT")
        if (running) audio?.updateState(faultDecision())
    }
    override fun onResult(depth: DepthResult, risk: KinematicsResult, decision: BudgetDecision, sourceNanos: Long, generation: Long) {
        runOnUiThread {
            if (!running || generation != analyzer?.generation || closed) return@runOnUiThread
            val now = SystemClock.elapsedRealtimeNanos()
            val ageSec = (now - sourceNanos) / 1_000_000_000.0f
            if (sourceNanos <= 0L || ageSec < -0.05f || ageSec > 0.75f) return@runOnUiThread
            if (sourceNanos < lastResult) return@runOnUiThread
            lastResult = sourceNanos
            binding.overlayView.update(depth, risk.threatLevel, now)
            audio?.updateState(decision)
        }
    }
    override fun onFault(generation: Long) { runOnUiThread {
        if (running && generation == analyzer?.generation) showFault()
    } }
    override fun onResume() {
        super.onResume()
        sensors.registerListener(this, sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE), SensorManager.SENSOR_DELAY_UI)
    }
    override fun onPause() {
        setRunning(false)
        sensors.unregisterListener(this)
        super.onPause()
    }
    override fun onSensorChanged(event: SensorEvent) { analyzer?.yawRate = event.values[1] }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    override fun onDestroy() {
        closed = true; handler.removeCallbacks(watchdog)
        analyzer?.setActive(false); provider?.unbindAll(); audio?.stop()
        // Model closure is queued behind any in-flight inference.
        executor.execute { depth?.close() }; executor.shutdown()
        super.onDestroy()
    }
}
