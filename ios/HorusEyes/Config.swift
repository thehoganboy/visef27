// HorusEyes 2.0 — Config.swift
// ════════════════════════════════════════════════════════════════════════════════
// 100% Mathematical & Safety Parity with Python config.py
// ════════════════════════════════════════════════════════════════════════════════

import Foundation

enum Config {
    // ── Camera & Video Stream ─────────────────────────────────────────────────
    static let camWidth:  Int = 640
    static let camHeight: Int = 480
    static let defaultFPS: Int = 30

    // ── Low-Light & Auto-Torch (0-Lux Defense) ───────────────────────────────
    static let luxDarkOnThreshold:     Float = 28.0
    static let luxBrightOffThreshold:  Float = 75.0
    static let flashHoldMinSeconds:    Float = 5.0
    static let flashAeSettleFrames:    Int   = 5
    static let luxEnhancementThreshold: Float = 45.0
    static let luxZeroBlindThreshold:  Float = 3.5 // Calibrated: complete darkness / pocket (<3.5 luma), not sunset
    static let luxDarkConfirmFrames:   Int   = 8

    // ── PCHIP Calibration Nodes (11 knots — Monotonic Spline) ─────────────────
    // (raw_disparity, distance_cm) — strictly decreasing distance
    static let calibrationNodes: [(raw: Float, cm: Float)] = [
        (135.0,  350.0),   // Deep room / infinity (>3.5m)
        (175.0,  300.0),   // 3.0m: Far wall, end of room
        (235.0,  250.0),   // 2.5m: Absolute safe threshold (Clear Corridor)
        (295.0,  200.0),   // 2.0m: Far doorway, ceiling
        (375.0,  150.0),   // 1.5m: Wall at 1.5m / Caution threshold
        (505.0,  100.0),   // 1.0m: Door leaf, stair step
        (560.0,   70.0),   // 70cm: Collision warning threshold
        (650.0,   50.0),   // 50cm: Flat wall 50cm, handrail
        (800.0,   30.0),   // 30cm: DANGER (hand at 28–30cm)
        (950.0,   20.0),   // 20cm: Emergency approach
        (1200.0,  13.0),   // 13cm: CRITICAL SATURATION (touching lens)
    ]

    // ── Distance Thresholds (cm) ─────────────────────────────────────────────
    static let distCriticalCM: Float = 40.0
    static let distDangerCM:   Float = 80.0
    static let distWarningCM:  Float = 140.0
    static let distAlertCM:    Float = 200.0
    static let distSafeCM:     Float = 250.0

    // ── Geometric Floor/Ceiling Masking ──────────────────────────────────────
    static let topMaskRatio:    Float = 0.15
    static let bottomMaskRatio: Float = 0.15

    // ── Overhead & Drop-Off Hazard Detection ─────────────────────────────────
    static let overheadDepthDeltaCM:    Float = 40.0
    static let dropOffGradientThresh:   Float = 0.25

    // ── Base Activation Threshold ────────────────────────────────────────────
    static let baseActivationRaw:  Float = 375.0
    static let baseActivationPeak: Float = 520.0

    // ── Lens Saturation / Close Blocker ──────────────────────────────────────
    static let saturationCenterRatio: Float = 0.25
    static let saturationRawThreshold: Float = 800.0
    static let saturationGlobalRatio:  Float = 0.60

    // ── Spatial Obstacle Extraction ──────────────────────────────────────────
    static let minObstacleAreaRatio:   Float = 0.015
    static let proximityPower:         Float = 1.2

    // ── Time-To-Collision (TTC) & Kinematics ─────────────────────────────────
    static let ttcCritical:      Float = 1.0
    static let ttcWarning:       Float = 2.5
    static let ttcSafe:          Float = 4.0
    static let ttcEpsilon:       Float = 0.10
    static let vzDeadbandCmS:    Float = 20.0
    static let vzMinApproachCmS: Float = 20.0

    // ── Motion Activation ────────────────────────────────────────────────────
    static let motionDispThresholdCM: Float = 12.0
    static let motionHistoryLen:      Int   = 8
    static let velocitySmoothing:     Float = 0.40
    static let minNetDisplacementCM:  Float = 8.0
    static let motionConfirmFrames:   Int   = 1

    // ── Ego-Motion Compensation ──────────────────────────────────────────────
    static let userWalkSpeedCmS: Float = 120.0

    // ── Sector Safety Score ──────────────────────────────────────────────────
    static let safetyWClearance:       Float = 0.50
    static let safetyWTtc:             Float = 0.35
    static let safetyWVz:              Float = 0.15
    static let sectorHysteresisMargin: Float = 0.10
    static let sectorDeadlockThresh:   Float = 0.08

    // ── Auditory Budget Coordinator ──────────────────────────────────────────
    static let maxActiveStreams:    Int   = 1
    static let hysteresisDecay:    Float = 0.50
    static let uncertaintyBlurOn:  Float = 0.48
    static let uncertaintyBlurOff: Float = 0.38

    // ── 3D Binaural Spatial Audio Synthesis ──────────────────────────────────
    static let audioSampleRate:         Float = 44100.0
    static let audioChannels:           Int   = 2
    static let audioBlockSize:          Int   = 1024
    static let maxItdSamples:           Int   = 28
    static let ildMaxAttenuationDB:     Float = 18.0
    static let ildExponent:             Float = 1.8

    static let freqMin:            Float = 350.0
    static let freqMax:            Float = 950.0
    static let beepIntervalMax:    Float = 1.80
    static let beepIntervalMin:    Float = 0.08
    static let beepDuration:       Float = 0.05

    // ── System Fault Tone ────────────────────────────────────────────────────
    static let faultToneFreqHi:    Float = 440.0
    static let faultToneFreqLo:    Float = 330.0
    static let faultToneDuration:  Float = 0.15
    static let faultToneGap:       Float = 0.05

    // ── Auditory Earcons ─────────────────────────────────────────────────────
    static let earconPauseFreq:    Float = 600.0
    static let earconMuteFreq:     Float = 500.0
    static let earconFlashOnFreq:  Float = 800.0
    static let earconFlashOffFreq: Float = 400.0
    static let earconDuration:     Float = 0.08

    // ── Acoustic Blur DSP (Dual-Tone FM Warble) ──────────────────────────────
    static let blurFmDeviationHz:      Float = 35.0
    static let blurFmRateHz:           Float = 18.0
    static let blurSubharmonicGain:    Float = 0.15

    // ── Peak Limiter ─────────────────────────────────────────────────────────
    static let peakLimiterThresholdDBFS: Float = -1.0

    // ── Sector Partitions ────────────────────────────────────────────────────
    static let sectorLeftSplit:  Float = 0.33
    static let sectorRightSplit: Float = 0.66
}
