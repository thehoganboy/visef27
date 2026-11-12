package com.horuseyes.app.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.horuseyes.app.budget.BudgetDecision
import com.horuseyes.app.budget.faultDecision
import kotlin.math.*

/** Fixed 20ms blocks prevent old long silence writes delaying critical warnings. */
class SpatialAudioEngine {
    @Volatile private var decision: BudgetDecision? = null
    @Volatile private var muted = true
    @Volatile private var running = false
    private var worker: Thread? = null
    private var track: AudioTrack? = null
    fun start() {
        if (running) return
        val rate = 44100
        val minSize = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        require(minSize > 0)
        val output = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(max(minSize, 3528)).setTransferMode(AudioTrack.MODE_STREAM).build()
        track = output; output.play(); running = true
        worker = Thread {
            val buffer = ShortArray(882 * 2)
            var phase = 0.0; var timer = 0.0; var priorCue = ""
            while (running) {
                val d = decision
                val cue = d?.cueMode ?: "MUTED"
                if (cue != priorCue) { timer = 0.0; priorCue = cue }
                for (i in 0 until 882) {
                    var sample = 0.0
                    var pan = 0.0
                    if (!muted && d != null && d.isActive && cue !in setOf("MUTED", "STANDBY_UNRESOLVED")) {
                        val fault = cue == "SYSTEM_FAULT_TONE"
                        val reminder = cue == "CAUTION_REMINDER"
                        val prox = d.proximity.coerceIn(0f,1f)
                        val interval = if (fault || reminder) 1.5 else (.9 - .75*prox).coerceIn(.15,.9)
                        val pos = timer % interval
                        val freq = if(fault) { if(pos < .12) 440.0 else 330.0 } else if(reminder) 300.0 else 350.0 + 600*prox
                        val local = if (fault && pos >= .20) pos-.20 else pos
                        val audible = if(fault) pos < .12 || pos in .20.. .32 else pos < .10
                        phase = (phase + 2*PI*freq/rate) % (2*PI)
                        if (audible) {
                            val duration = if(fault) .12 else .10
                            val envelope = min(1.0,local/.005).coerceAtLeast(0.0) * min(1.0,(duration-local)/.01).coerceAtLeast(0.0)
                            sample = sin(phase) * envelope * d.volumeFactor.coerceIn(0f,1f) * .6
                            if(cue == "ACOUSTIC_BLUR") sample = .65*sample + .15*sin(phase*1.35)*envelope
                        }
                        pan = if(fault || reminder) 0.0 else d.pan.toDouble().coerceIn(-1.0,1.0)
                    }
                    val angle = (pan+1)*PI/4
                    buffer[2*i] = (sample*cos(angle)*32767).toInt().coerceIn(-32767,32767).toShort()
                    buffer[2*i+1] = (sample*sin(angle)*32767).toInt().coerceIn(-32767,32767).toShort()
                    timer += 1.0/rate
                }
                if (output.write(buffer,0,buffer.size) < 0) break
            }
        }.apply { name = "HorusAudio"; start() }
    }
    fun updateState(value: BudgetDecision) {
        decision = if(value.cueMode !in setOf("SHARP_PING","ACOUSTIC_BLUR","SYSTEM_FAULT_TONE","CAUTION_REMINDER","STANDBY_UNRESOLVED","MUTED") ||
            !value.pan.isFinite() || !value.proximity.isFinite() || !value.volumeFactor.isFinite()) faultDecision() else value
    }
    fun setMuted(value: Boolean) { muted = value; if(value) decision = null }
    fun stop() {
        muted = true; running = false
        track?.pause(); track?.flush(); worker?.join(500)
        track?.release(); track = null; worker = null
    }
}
