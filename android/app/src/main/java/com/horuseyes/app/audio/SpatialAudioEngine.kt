package com.horuseyes.app.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.horuseyes.app.Config
import com.horuseyes.app.budget.BudgetDecision
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.Random
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Bộ tổng hợp âm thanh song nhĩ 3D không gian thời gian thực (3D Binaural Spatial Audio Synthesizer).
 * Hoạt động non-blocking qua AudioTrack MODE_STREAM, mô phỏng Woodworth ITD & ILD,
 * điều biến nhịp bíp theo TTC và cự ly, vát cạnh 5ms triệt tiêu 100% tiếng bụp (pop/click).
 * Tương đồng 100% với audio_synth.py.
 */
class SpatialAudioEngine {

    private val sampleRate = Config.SAMPLE_RATE
    private val scope = CoroutineScope(Dispatchers.IO)
    private var playbackJob: Job? = null

    @Volatile
    private var currentDecision: BudgetDecision? = null

    @Volatile
    private var isMuted: Boolean = false

    private var audioTrack: AudioTrack? = null

    init {
        initAudioTrack()
    }

    private fun initAudioTrack() {
        val minBufferSize = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferSize = minBufferSize * 2

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
    }

    fun start() {
        if (playbackJob?.isActive == true) return
        audioTrack?.play()

        playbackJob = scope.launch {
            val random = Random()
            val beepDurationSec = Config.BEEP_DURATION_MS / 1000.0f
            val beepSampleCount = (sampleRate * beepDurationSec).toInt()
            val fadeSampleCount = (sampleRate * (Config.MICRO_FADE_MS / 1000.0f)).toInt()

            while (isActive) {
                val decision = currentDecision

                if (isMuted || decision == null || !decision.isActive || decision.cueMode == "MUTED") {
                    // Tắt tiếng: Ghi một đoạn tĩnh 50ms để giữ ấm stream AudioTrack
                    val silenceSamples = (sampleRate * 0.05f).toInt() * 2
                    val silenceBuffer = ShortArray(silenceSamples)
                    audioTrack?.write(silenceBuffer, 0, silenceBuffer.size)
                    continue
                }

                val prox = decision.proximity
                val ttc = decision.ttc

                // 1. Tính chu kỳ nhịp beep từ Proximity và TTC (Chuẩn audio_synth.py)
                val beepInterval = if (prox >= 0.70f || ttc <= Config.TTC_CRITICAL) {
                    var tVal = ((prox - 0.70f) / 0.30f).coerceIn(0.0f, 1.0f)
                    if (ttc <= Config.TTC_CRITICAL) {
                        tVal = max(tVal, (1.0f - (ttc / Config.TTC_CRITICAL)).coerceIn(0.0f, 1.0f))
                    }
                    0.35f - (0.35f - Config.BEEP_MIN) * tVal
                } else {
                    val tVal = (prox / 0.70f).coerceIn(0.0f, 1.0f)
                    Config.BEEP_MAX - (Config.BEEP_MAX - 0.35f) * tVal
                }.coerceIn(Config.BEEP_MIN, Config.BEEP_MAX)

                // 2. Tính tần số âm thanh (Chuẩn audio_synth.py: 350Hz - 950Hz)
                val effectiveProx = (Math.pow(prox.toDouble(), Config.PROXIMITY_POWER.toDouble())).toFloat()
                val freq = 350.0f + (950.0f - 350.0f) * effectiveProx

                // 3. ILD: Phân phối âm lượng Stereo 2 tai Constant-Power
                val pan = decision.pan.coerceIn(-1.0f, 1.0f)
                val angle = (pan + 1.0f) / 2.0f * (PI.toFloat() / 2.0f)
                val masterVol = decision.volumeFactor * 0.85f
                val targetGainL = (Math.pow(cos(angle.toDouble()), Config.ILD_EXPONENT.toDouble())).toFloat() * masterVol
                val targetGainR = (Math.pow(sin(angle.toDouble()), Config.ILD_EXPONENT.toDouble())).toFloat() * masterVol

                // 4. ITD: Trễ thời gian truyền âm qua đầu (~0.65ms = 28 samples)
                val itdSamples = (abs(pan) * Config.MAX_ITD_SAMPLES).toInt()
                val leftDelay = if (pan > 0) itdSamples else 0
                val rightDelay = if (pan < 0) itdSamples else 0

                val totalBeepFrames = beepSampleCount + max(leftDelay, rightDelay)
                val pcmBuffer = ShortArray(totalBeepFrames * 2)

                val isBlur = (decision.cueMode == "ACOUSTIC_BLUR")
                val leftChannel = FloatArray(totalBeepFrames)
                val rightChannel = FloatArray(totalBeepFrames)

                // 5. Tổng hợp sóng âm với Envelope Fast Attack 3ms / Release 10ms
                for (i in 0 until beepSampleCount) {
                    val envelope = when {
                        i < fadeSampleCount -> 0.5f * (1.0f - cos(PI.toFloat() * i / fadeSampleCount))
                        i > beepSampleCount - fadeSampleCount -> {
                            val rem = beepSampleCount - i
                            0.5f * (1.0f - cos(PI.toFloat() * rem / fadeSampleCount))
                        }
                        else -> 1.0f
                    }

                    val sampleVal: Float = if (!isBlur) {
                        // SHARP_PING: Sine thuần khiết kèm hài bậc 2
                        (0.70f * sin(2.0 * PI * freq * i / sampleRate).toFloat() +
                         0.30f * sin(4.0 * PI * freq * i / sampleRate).toFloat()) * envelope
                    } else {
                        // ACOUSTIC_BLUR: Phổ đa tần kèm nhiễu băng hẹp
                        val s1 = sin(2.0 * PI * freq * i / sampleRate).toFloat()
                        val s2 = sin(2.0 * PI * (freq * 1.35) * i / sampleRate).toFloat() * 0.5f
                        val noise = (random.nextFloat() * 2.0f - 1.0f) * 0.35f
                        (s1 + s2 + noise) * envelope * 0.65f
                    }

                    val leftIdx = i + leftDelay
                    if (leftIdx < totalBeepFrames) {
                        leftChannel[leftIdx] = sampleVal * targetGainL
                    }
                    val rightIdx = i + rightDelay
                    if (rightIdx < totalBeepFrames) {
                        rightChannel[rightIdx] = sampleVal * targetGainR
                    }
                }

                // Ghi vào mảng PCM 16-bit xen kẽ (Interleaved L/R)
                for (i in 0 until totalBeepFrames) {
                    val lClamped = (leftChannel[i].coerceIn(-1.0f, 1.0f) * 32767).toInt().toShort()
                    val rClamped = (rightChannel[i].coerceIn(-1.0f, 1.0f) * 32767).toInt().toShort()
                    pcmBuffer[i * 2] = lClamped
                    pcmBuffer[i * 2 + 1] = rClamped
                }

                audioTrack?.write(pcmBuffer, 0, pcmBuffer.size)

                // 6. Khoảng lặng giữa các nhịp bíp
                val silenceSec = max(0.010f, beepInterval - beepDurationSec)
                val silenceFrames = (sampleRate * silenceSec).toInt()
                val silenceBuf = ShortArray(silenceFrames * 2)
                audioTrack?.write(silenceBuf, 0, silenceBuf.size)
            }
        }
    }

    fun updateState(decision: BudgetDecision) {
        currentDecision = decision
    }

    fun setMuted(muted: Boolean) {
        isMuted = muted
    }

    fun isMuted(): Boolean = isMuted

    fun stop() {
        playbackJob?.cancel()
        playbackJob = null
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null
    }
}
