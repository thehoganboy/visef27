// HorusEyes 2.0 — SpatialAudioEngine.swift
// ════════════════════════════════════════════════════════════════════════════════
// Crash-Proof Hardware-Adaptive Spatial Audio Synthesizer (Lazy Setup)
// ════════════════════════════════════════════════════════════════════════════════

import Foundation
import Combine
import AVFoundation
import Accelerate
import UIKit

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
    private var isGraphConfigured: Bool = false

    // Hardware adaptive rate
    private var sampleRate: Double = 48000.0
    private let channelCount: AVAudioChannelCount = 2

    // State Pointer for zero-allocation C render block access
    private let stateLock = NSLock()
    private let statePtr: UnsafeMutablePointer<AudioRenderState>

    // Haptics
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .medium)

    init() {
        self.statePtr = UnsafeMutablePointer<AudioRenderState>.allocate(capacity: 1)
        self.statePtr.initialize(to: AudioRenderState())
        hapticFeedback.prepare()
        // DO NOT call setupAudioGraph() here. It will be initialized safely in start().
    }

    deinit {
        stop()
        statePtr.deallocate()
    }

    // ── Safe Lazy Audio Graph Setup ───────────────────────────────────────────
    private func setupAudioGraphIfNeeded() {
        guard !isGraphConfigured else { return }

        // Determine effective hardware sample rate safely
        let hwFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        let effectiveRate = hwFormat.sampleRate > 8000 ? hwFormat.sampleRate : 48000.0
        self.sampleRate = effectiveRate

        guard let format = AVAudioFormat(standardFormatWithSampleRate: effectiveRate, channels: channelCount) else {
            print("[HorusEyes] Error: Cannot create AVAudioFormat for rate \(effectiveRate)")
            return
        }

        let state = self.statePtr
        let stateLock = self.stateLock

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
            guard !abl.isEmpty else { return noErr }

            let frames = Int(frameCount)
            let dt = 1.0 / Float(effectiveRate)
            // Never block the realtime thread. A contended block is silent.
            var currentState = AudioRenderState()
            if stateLock.try() {
                currentState = state.pointee
                state.pointee.earconType = 0
                stateLock.unlock()
            }

            let isDualBuffer = abl.count >= 2
            guard let buf0 = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let leftPtr = buf0
            let rightPtr = isDualBuffer ? (abl[1].mData?.assumingMemoryBound(to: Float.self) ?? buf0) : buf0

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

            // 2. System Fault Tone
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

                    let lim = tanh(sig * 0.891)
                    if isDualBuffer {
                        leftPtr[i] = lim
                        rightPtr[i] = lim
                    } else {
                        leftPtr[2 * i] = lim
                        leftPtr[2 * i + 1] = lim
                    }
                }
                return noErr
            }

            // 3. Silence / Muted Check
            if !currentState.isActive || currentState.cueMode == 3 {
                if activeEarconFreq == 0.0 {
                    if isDualBuffer {
                        for i in 0..<frames {
                            leftPtr[i] = 0.0
                            rightPtr[i] = 0.0
                        }
                    } else {
                        for i in 0..<(frames * 2) {
                            leftPtr[i] = 0.0
                        }
                    }
                    return noErr
                }
            }

            // 4. Spatial Geometry & Constant-Power ILD
            let pan = max(-1.0, min(1.0, currentState.pan))
            let prox = max(0.0, min(1.0, currentState.proximity))
            let targetFreq = max(100.0, min(2000.0, currentState.freq))
            let vol = max(0.0, min(1.0, currentState.volumeFactor))

            let beepInterval: Float
            if prox >= 0.70 || currentState.ttc <= Config.ttcCritical {
                let t = max(0.0, min(1.0, (prox - 0.70) / 0.30))
                beepInterval = max(Config.beepIntervalMin, 0.35 - (0.35 - Config.beepIntervalMin) * t)
            } else {
                let t = max(0.0, min(1.0, prox / 0.70))
                beepInterval = max(Config.beepIntervalMin, Config.beepIntervalMax - (Config.beepIntervalMax - 0.35) * t)
            }

            let maxAttenLinear = pow(10.0, -Config.ildMaxAttenuationDB / 20.0)
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

            let freqDelta = (targetFreq - currFreq) / Float(frames)
            let gainLDelta = (targetGainL - currGainL) / Float(frames)
            let gainRDelta = (targetGainR - currGainR) / Float(frames)

            for i in 0..<frames {
                currFreq += freqDelta
                currGainL += gainLDelta
                currGainR += gainRDelta

                let dPhase = 2.0 * .pi * currFreq * dt
                phase += dPhase
                if phase > (2.0 * .pi) { phase -= (2.0 * .pi) }

                var rawTone: Float = 0.0
                if currentState.cueMode == 0 || currentState.cueMode == 4 {
                    rawTone = 0.38 * sin(phase) + 0.12 * sin(2.0 * phase)
                } else {
                    let dFmPhase = 2.0 * .pi * Config.blurFmRateHz * dt
                    fmPhase += dFmPhase
                    if fmPhase > (2.0 * .pi) { fmPhase -= (2.0 * .pi) }
                    let mod = Config.blurFmDeviationHz * sin(fmPhase)
                    let instPhase = phase + (2.0 * .pi * mod * dt)
                    rawTone = 0.30 * sin(instPhase) + Config.blurSubharmonicGain * sin(0.5 * instPhase)
                }

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

                historyBuf.removeFirst()
                historyBuf.append(shaped)

                let idxL = max(0, min(maxItd - 1, (maxItd - 1) - delayL))
                let idxR = max(0, min(maxItd - 1, (maxItd - 1) - delayR))

                var outL = historyBuf[idxL] * currGainL
                var outR = historyBuf[idxR] * currGainR

                if pan < -0.15 {
                    let alpha = 0.50 * abs(pan)
                    lpStateR = (1.0 - alpha) * outR + alpha * lpStateR
                    outR = lpStateR
                } else if pan > 0.15 {
                    let alpha = 0.50 * pan
                    lpStateL = (1.0 - alpha) * outL + alpha * lpStateL
                    outL = lpStateL
                }

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

                    }
                }

                let sampleL = tanh(outL * 0.891)
                let sampleR = tanh(outR * 0.891)

                if isDualBuffer {
                    leftPtr[i] = sampleL
                    rightPtr[i] = sampleR
                } else {
                    leftPtr[2 * i] = sampleL
                    leftPtr[2 * i + 1] = sampleR
                }
            }

            return noErr
        }

        self.sourceNode = node
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        isGraphConfigured = true
    }

    func start() {
        guard !audioEngine.isRunning else { return }
        setupAudioGraphIfNeeded()
        do {
            try audioEngine.start()
            print("[HorusEyes] Spatial Audio Engine started successfully at \(sampleRate) Hz.")
        } catch {
            print("[HorusEyes] Audio Engine startup notice: \(error.localizedDescription)")
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    func update(decision: BudgetDecision) {
        stateLock.lock(); defer { stateLock.unlock() }
        if !decision.isActive {
            statePtr.pointee.isActive = false
            statePtr.pointee.cueMode = 3
            return
        }

        let effectiveProx = pow(decision.proximity, Config.proximityPower)
        let freq = Config.freqMin + (Config.freqMax - Config.freqMin) * effectiveProx

        let cueModeInt: Int
        switch decision.cueMode {
        case "ACOUSTIC_BLUR": cueModeInt = 1
        case "SYSTEM_FAULT_TONE": cueModeInt = 2
        case "MUTED", "STANDBY_UNRESOLVED": cueModeInt = 3
        case "SHARP_PING": cueModeInt = 0
        case "CAUTION_REMINDER": cueModeInt = 4
        default: cueModeInt = 2
        }

        statePtr.pointee.pan = decision.pan
        statePtr.pointee.proximity = effectiveProx
        statePtr.pointee.freq = cueModeInt == 4 ? 300 : freq
        statePtr.pointee.isActive = true
        statePtr.pointee.volumeFactor = decision.volumeFactor
        statePtr.pointee.cueMode = cueModeInt
        statePtr.pointee.ttc = decision.ttc
    }

    func playEarcon(type: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        let earconId: Int
        switch type {
        case "PAUSE": earconId = 1
        case "MUTE": earconId = 2
        case "FLASH_ON": earconId = 3
        case "FLASH_OFF": earconId = 4
        default: earconId = 0
        }
        statePtr.pointee.earconType = earconId
        hapticFeedback.impactOccurred()
    }
}
