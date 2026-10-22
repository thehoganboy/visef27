// HorusEyes 2.0 — SpatialAudioEngine.swift
// ════════════════════════════════════════════════════════════════════════════════
// Non-Blocking 44.1kHz Stereo AVAudioSourceNode C-Callback DSP Spatial Synthesizer
// ════════════════════════════════════════════════════════════════════════════════

import Foundation
import AVFoundation
import Accelerate
import UIKit

// Thread-safe immutable audio parameters for realtime render thread
struct AudioRenderState {
    var pan: Float = 0.0
    var proximity: Float = 0.0
    var freq: Float = Config.freqMin
    var isActive: Bool = false
    var volumeFactor: Float = 1.0
    var cueMode: Int = 0 // 0: SHARP_PING, 1: ACOUSTIC_BLUR, 2: SYSTEM_FAULT_TONE, 3: MUTED
    var ttc: Float = Float.infinity
    var earconType: Int = 0 // 0: None, 1: PAUSE, 2: MUTE, 3: FLASH_ON, 4: FLASH_OFF
}

final class SpatialAudioEngine: ObservableObject {
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // Audio format
    private let sampleRate: Double = Double(Config.audioSampleRate)
    private let channelCount: AVAudioChannelCount = 2

    // State Pointer for zero-allocation C render block access
    private let statePtr: UnsafeMutablePointer<AudioRenderState>

    // Haptics
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .medium)

    init() {
        self.statePtr = UnsafeMutablePointer<AudioRenderState>.allocate(capacity: 1)
        self.statePtr.initialize(to: AudioRenderState())
        hapticFeedback.prepare()
        setupAudioGraph()
    }

    deinit {
        stop()
        statePtr.deallocate()
    }

    // ── Setup Audio Graph ─────────────────────────────────────────────────────
    private func setupAudioGraph() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount) else {
            print("[HorusEyes] Error creating AVAudioFormat.")
            return
        }

        let state = self.statePtr

        // DSP persistent registers inside C-closure
        var phase: Float = 0.0
        var fmPhase: Float = 0.0
        var beepTimer: Float = 0.0
        var beepOn: Bool = false

        var currFreq: Float = Config.freqMin
        var currGainL: Float = 0.0
        var currGainR: Float = 0.0

        var lpStateL: Float = 0.0
        var lpStateR: Float = 0.0

        var faultTimer: Float = 0.0
        var earconTimer: Float = 0.0
        var activeEarconFreq: Float = 0.0

        let maxItd = Config.maxItdSamples
        var historyBuf = [Float](repeating: 0.0, count: maxItd)

        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            let currentState = state.pointee
            let frames = Int(frameCount)
            let dt = 1.0 / Float(Config.audioSampleRate)

            // 1. Earcon Check
            if currentState.earconType != 0 && activeEarconFreq == 0.0 {
                switch currentState.earconType {
                case 1: activeEarconFreq = Config.earconPauseFreq
                case 2: activeEarconFreq = Config.earconMuteFreq
                case 3: activeEarconFreq = Config.earconFlashOnFreq
                case 4: activeEarconFreq = Config.earconFlashOffFreq
                default: activeEarconFreq = 600.0
                }
                earconTimer = 0.0
            }

            // 2. System Fault Tone (Dual Pulse 440Hz -> 330Hz)
            if currentState.cueMode == 2 {
                for i in 0..<frames {
                    faultTimer += dt
                    let cycle = 2.0 * Config.faultToneDuration + Config.faultToneGap
                    let pos = fmod(faultTimer, cycle)
                    var sig: Float = 0.0

                    if pos < Config.faultToneDuration {
                        let env = min(1.0, pos / 0.003) * min(1.0, (Config.faultToneDuration - pos) / 0.005)
                        sig = 0.35 * env * sin(2.0 * .pi * Config.faultToneFreqHi * pos)
                    } else if pos > (Config.faultToneDuration + Config.faultToneGap) {
                        let pos2 = pos - Config.faultToneDuration - Config.faultToneGap
                        let env = min(1.0, pos2 / 0.003) * min(1.0, (Config.faultToneDuration - pos2) / 0.005)
                        sig = 0.35 * env * sin(2.0 * .pi * Config.faultToneFreqLo * pos2)
                    }

                    // Soft-knee limiter: tanh(x * 0.891)
                    let lim = tanh(sig * 0.891)
                    leftPtr[i] = lim
                    rightPtr[i] = lim
                }
                return noErr
            }

            // 3. Silence / Muted Check
            if !currentState.isActive || currentState.cueMode == 3 {
                if activeEarconFreq == 0.0 {
                    for i in 0..<frames {
                        leftPtr[i] = 0.0
                        rightPtr[i] = 0.0
                    }
                    return noErr
                }
            }

            // 4. Spatial Geometry & Constant-Power ILD
            let pan = max(-1.0, min(1.0, currentState.pan))
            let prox = max(0.0, min(1.0, currentState.proximity))
            let targetFreq = max(100.0, min(2000.0, currentState.freq))
            let vol = max(0.0, min(1.0, currentState.volumeFactor))

            // Beep interval calculation
            let beepInterval: Float
            if prox >= 0.70 || currentState.ttc <= Config.ttcCritical {
                let t = max(0.0, min(1.0, (prox - 0.70) / 0.30))
                beepInterval = max(Config.beepIntervalMin, 0.35 - (0.35 - Config.beepIntervalMin) * t)
            } else {
                let t = max(0.0, min(1.0, prox / 0.70))
                beepInterval = max(Config.beepIntervalMin, Config.beepIntervalMax - (Config.beepIntervalMax - 0.35) * t)
            }

            // Constant-Power Panning & 18dB ILD Head-Shadow
            let maxAttenLinear = pow(10.0, -Config.ildMaxAttenuationDB / 20.0) // ~0.126
            let targetGainL: Float
            let targetGainR: Float
            let delayL: Int
            let delayR: Int

            if pan < 0.0 {
                let shadow = max(maxAttenLinear, 1.0 - abs(pan) * (1.0 - maxAttenLinear))
                targetGainL = 1.0 * vol
                targetGainR = shadow * vol
                delayL = 0
                delayR = Int(round(abs(pan) * Float(maxItd)))
            } else if pan > 0.0 {
                let shadow = max(maxAttenLinear, 1.0 - abs(pan) * (1.0 - maxAttenLinear))
                targetGainL = shadow * vol
                targetGainR = 1.0 * vol
                delayL = Int(round(pan * Float(maxItd)))
                delayR = 0
            } else {
                targetGainL = 1.0 * vol
                targetGainR = 1.0 * vol
                delayL = 0
                delayR = 0
            }

            // 5. Per-Sample DSP Loop
            let freqDelta = (targetFreq - currFreq) / Float(frames)
            let gainLDelta = (targetGainL - currGainL) / Float(frames)
            let gainRDelta = (targetGainR - currGainR) / Float(frames)

            for i in 0..<frames {
                currFreq += freqDelta
                currGainL += gainLDelta
                currGainR += gainRDelta

                // Phase accumulators
                let dPhase = 2.0 * .pi * currFreq * dt
                phase += dPhase
                if phase > (2.0 * .pi) { phase -= (2.0 * .pi) }

                // Mode-specific timbre
                var rawTone: Float = 0.0
                if currentState.cueMode == 0 {
                    // SHARP_PING: Fundamental + 2nd harmonic
                    rawTone = 0.38 * sin(phase) + 0.12 * sin(2.0 * phase)
                } else {
                    // ACOUSTIC_BLUR: Dual-Tone FM Warble + Subharmonic
                    let dFmPhase = 2.0 * .pi * Config.blurFmRateHz * dt
                    fmPhase += dFmPhase
                    if fmPhase > (2.0 * .pi) { fmPhase -= (2.0 * .pi) }
                    let mod = Config.blurFmDeviationHz * sin(fmPhase)
                    let instPhase = phase + (2.0 * .pi * mod * dt)
                    rawTone = 0.30 * sin(instPhase) + Config.blurSubharmonicGain * sin(0.5 * instPhase)
                }

                // Envelope Attack 3ms / Release 10ms
                beepTimer += dt
                var envelope: Float = 0.0
                if beepOn {
                    if beepTimer >= Config.beepDuration {
                        beepOn = false
                        beepTimer = 0.0
                    } else if beepTimer < 0.003 {
                        envelope = beepTimer / 0.003
                    } else if beepTimer > (Config.beepDuration - 0.010) {
                        envelope = (Config.beepDuration - beepTimer) / 0.010
                    } else {
                        envelope = 1.0
                    }
                } else {
                    let silenceDur = max(0.01, beepInterval - Config.beepDuration)
                    if beepTimer >= silenceDur {
                        beepOn = true
                        beepTimer = 0.0
                    }
                }

                let shaped = rawTone * envelope

                // Woodworth Fractional Delay (ITD)
                historyBuf.removeFirst()
                historyBuf.append(shaped)

                let idxL = max(0, min(maxItd - 1, (maxItd - 1) - delayL))
                let idxR = max(0, min(maxItd - 1, (maxItd - 1) - delayR))

                var outL = historyBuf[idxL] * currGainL
                var outR = historyBuf[idxR] * currGainR

                // Head shadow single-pole low pass on far ear
                if pan < -0.15 {
                    let alpha = 0.50 * abs(pan)
                    lpStateR = (1.0 - alpha) * outR + alpha * lpStateR
                    outR = lpStateR
                } else if pan > 0.15 {
                    let alpha = 0.50 * pan
                    lpStateL = (1.0 - alpha) * outL + alpha * lpStateL
                    outL = lpStateL
                }

                // Earcon overlay
                if activeEarconFreq > 0.0 {
                    earconTimer += dt
                    if earconTimer < Config.earconDuration {
                        let tEnv = earconTimer / Config.earconDuration
                        let eEnv = min(1.0, tEnv * 10.0) * max(0.0, 1.0 - tEnv)
                        let eTone = 0.25 * eEnv * sin(2.0 * .pi * activeEarconFreq * earconTimer)
                        outL += eTone
                        outR += eTone
                    } else {
                        activeEarconFreq = 0.0
                        state.pointee.earconType = 0
                    }
                }

                // Soft-Knee Peak Limiter at -1.0 dBFS (tanh)
                leftPtr[i] = tanh(outL * 0.891)
                rightPtr[i] = tanh(outR * 0.891)
            }

            return noErr
        }

        self.sourceNode = node
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
    }

    func start() {
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
                print("[HorusEyes] 3D Binaural Spatial Audio Engine started successfully.")
            }
        } catch {
            print("[HorusEyes] Error starting AVAudioEngine: \(error)")
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    // ── Atomic State Updates from Main Thread ────────────────────────────────
    func update(decision: BudgetDecision) {
        if !decision.isActive {
            statePtr.pointee.isActive = false
            statePtr.pointee.cueMode = 3 // MUTED
            return
        }

        let effectiveProx = pow(decision.proximity, Config.proximityPower)
        let freq = Config.freqMin + (Config.freqMax - Config.freqMin) * effectiveProx

        let cueModeInt: Int
        switch decision.cueMode {
        case "ACOUSTIC_BLUR": cueModeInt = 1
        case "SYSTEM_FAULT_TONE": cueModeInt = 2
        case "MUTED": cueModeInt = 3
        default: cueModeInt = 0 // SHARP_PING
        }

        statePtr.pointee.pan = decision.pan
        statePtr.pointee.proximity = effectiveProx
        statePtr.pointee.freq = freq
        statePtr.pointee.isActive = true
        statePtr.pointee.volumeFactor = decision.volumeFactor
        statePtr.pointee.cueMode = cueModeInt
        statePtr.pointee.ttc = decision.ttc
    }

    func playEarcon(type: String) {
        let typeCode: Int
        switch type {
        case "PAUSE": typeCode = 1
        case "MUTE": typeCode = 2
        case "FLASH_ON": typeCode = 3
        case "FLASH_OFF": typeCode = 4
        default: typeCode = 1
        }
        statePtr.pointee.earconType = typeCode
        hapticFeedback.impactOccurred()
    }

    func setSystemFaultMode(enabled: Bool) {
        statePtr.pointee.cueMode = enabled ? 2 : 0
        statePtr.pointee.isActive = enabled
    }
}
