// HorusEyes 2.0 — ContentView.swift
// ════════════════════════════════════════════════════════════════════════════════
// Landscape Live Camera AR HUD & Spatial Obstacle Tracking (Eyes-Free & Assistant Mode)
// Apple HIG, WCAG AAA High-Contrast, Real-time Neural Depth Feedback
// ════════════════════════════════════════════════════════════════════════════════

import SwiftUI
import AVFoundation

struct ContentView: View {
    // ── Pipeline Controllers ───────────────────────────────────────────────────
    @StateObject private var cameraManager = CameraTorchManager()
    @StateObject private var depthEngine = DepthEngine()
    @StateObject private var imuManager = IMUManager()
    @StateObject private var audioEngine = SpatialAudioEngine()

    private let kinematicsEngine = KinematicsEngine()
    private let budgetManager = AuditoryBudgetManager()

    // ── Observable Pipeline Telemetry (Internal States) ───────────────────────
    @State private var isSystemPaused: Bool = false
    @State private var safeDirection: String = "RIGHT"
    @State private var threatLevel: String = "SAFE"
    @State private var guidanceState: String = "ESCAPE_RIGHT"
    @State private var currentDistCM: Float = 250.0
    @State private var currentVz: Float = 0.0
    @State private var currentTTC: Float = Float.infinity
    @State private var currentUncertainty: Float = 0.15
    @State private var currentCueMode: String = "MUTED"
    @State private var sectorDists: [String: Float] = ["LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0]

    // ── Tactile Feedback ──────────────────────────────────────────────────────
    private let impactFeedbackHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let impactFeedbackMedium = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ════════════════════════════════════════════════════════════
                // LAYER 0: Hardware-Accelerated Camera Preview Background
                // ════════════════════════════════════════════════════════════
                CameraPreviewView(session: cameraManager.session)
                    .ignoresSafeArea()

                // ════════════════════════════════════════════════════════════
                // LAYER 1: AR Bounding Boxes & Tracking Telemetry Overlay
                // ════════════════════════════════════════════════════════════
                TrackingOverlayView(
                    result: depthEngine.lastResult,
                    threatLevel: threatLevel,
                    safeDirection: safeDirection,
                    isPaused: isSystemPaused
                )

                // ════════════════════════════════════════════════════════════
                // LAYER 2: Landscape Peripheral Touch Controls & Status Bar
                // ════════════════════════════════════════════════════════════
                VStack {
                    // Top Bar: Glassmorphic Brand & Status Capsule
                    HStack {
                        // Brand Identifier
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 28, height: 28)
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.black)
                            }
                            Text("HORUSEYES 2.0")
                                .font(.system(size: 14, weight: .black, design: .rounded))
                                .tracking(1.2)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.70))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))

                        Spacer()

                        // Operational Status Capsule
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isSystemPaused ? Color.orange : (cameraManager.isZeroLuxBlind ? Color.red : Color.green))
                                .frame(width: 8, height: 8)
                                .shadow(color: isSystemPaused ? Color.orange : Color.green, radius: 4)

                            Text(isSystemPaused ? "TẠM DỪNG" : (cameraManager.isZeroLuxBlind ? "THIẾU SÁNG" : "ĐANG QUÉT"))
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundColor(isSystemPaused ? .orange : (cameraManager.isZeroLuxBlind ? .red : .green))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.70))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                    Spacer()

                    // Bottom Thumb Controls (Positioned at Screen Flanks)
                    HStack(alignment: .bottom) {
                        // Left Thumb: Smart 0-Lux Flashlight Toggle
                        Button(action: toggleTorchState) {
                            HStack(spacing: 10) {
                                Image(systemName: cameraManager.isTorchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(cameraManager.isTorchActive ? .yellow : .white)
                                Text(cameraManager.isTorchActive ? "ĐÈN: BẬT" : "ĐÈN AUTO")
                                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.80))
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(cameraManager.isTorchActive ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1.5))
                            .shadow(color: cameraManager.isTorchActive ? Color.yellow.opacity(0.3) : Color.clear, radius: 6)
                        }
                        .accessibilityLabel("Bật tắt đèn pin thông minh")

                        Spacer()

                        // Right Thumb: Giant Pause / Resume Toggle
                        Button(action: togglePauseState) {
                            HStack(spacing: 10) {
                                Image(systemName: isSystemPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundColor(isSystemPaused ? .green : .orange)
                                Text(isSystemPaused ? "TIẾP TỤC" : "TẠM DỪNG")
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.80))
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSystemPaused ? Color.green : Color.orange.opacity(0.8), lineWidth: 1.5))
                            .shadow(color: isSystemPaused ? Color.green.opacity(0.3) : Color.orange.opacity(0.25), radius: 8)
                        }
                        .accessibilityLabel(isSystemPaused ? "Tiếp tục quét" : "Tạm dừng quét")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            }
            .contentShape(Rectangle())
            // Eyes-free double-tap anywhere on screen toggles pause/resume
            .onTapGesture(count: 2) {
                togglePauseState()
            }
        }
        .onAppear {
            startPipeline()
        }
        .onDisappear {
            stopPipeline()
        }
    }

    // ── Pipeline Lifecycle ────────────────────────────────────────────────────
    private func startPipeline() {
        // 1. Start Sensors & Audio lazily on Main Thread
        audioEngine.start()
        cameraManager.start()
        imuManager.startMotionTracking()

        // 2. Link Camera Stream to Perception & Kinematics Loop
        cameraManager.onFrameProcessed = { pixelBuffer, frameId, aeSettle, luma in
            guard !self.isSystemPaused else { return }

            // Step 1: Spatial Depth Estimation + Multi-Obstacle Detection
            let obsResult = self.depthEngine.processFrame(
                pixelBuffer: pixelBuffer,
                frameId: frameId,
                aeSettleFramesRemaining: aeSettle,
                meanLuma: luma,
                isZeroLuxBlind: self.cameraManager.isZeroLuxBlind
            )

            // Step 2: Kinematics Centroid Tracking & TTC Computation
            let now = CACurrentMediaTime()
            let kinResult = self.kinematicsEngine.compute(
                obstacleResult: obsResult,
                frameId: frameId,
                timestamp: now,
                aeSettleRemaining: aeSettle,
                userWalkSpeedCmS: self.imuManager.estimatedWalkSpeedCmS,
                imuYawRateRadS: self.imuManager.yawRateRadS
            )

            // Step 3: Auditory Budget Coordination & Priority Arbitration
            let decision = self.budgetManager.coordinate(
                obstacleResult: obsResult,
                kinematicsResult: kinResult
            )

            // Step 4: Spatial Audio & Acoustic Actuation
            self.audioEngine.update(decision: decision)

            // Step 5: Update Telemetry State on Main Thread
            DispatchQueue.main.async {
                self.safeDirection = kinResult.safeDirection
                self.threatLevel = kinResult.threatLevel
                self.guidanceState = kinResult.guidanceState
                self.currentDistCM = decision.distCM
                self.currentVz = kinResult.primaryVelocityZ
                self.currentTTC = decision.ttc
                self.currentUncertainty = obsResult.uncertaintyScore
                self.currentCueMode = decision.cueMode
                self.sectorDists = obsResult.sectorDists
            }
        }

        // Link Torch Event to Earcon
        cameraManager.onTorchToggled = { isOn in
            self.audioEngine.playEarcon(type: isOn ? "FLASH_ON" : "FLASH_OFF")
        }
    }

    private func stopPipeline() {
        cameraManager.stop()
        audioEngine.stop()
        imuManager.stopMotionTracking()
    }

    // ── UI User Actions ───────────────────────────────────────────────────────
    private func togglePauseState() {
        isSystemPaused.toggle()
        if isSystemPaused {
            notificationFeedback.notificationOccurred(.warning)
            audioEngine.playEarcon(type: "PAUSE")
            audioEngine.update(decision: BudgetDecision(
                isActive: false, pan: 0, proximity: 0, distCM: 250, ttc: .infinity,
                priorityScore: 0, volumeFactor: 0, safeDirection: "STOP", cueMode: "MUTED",
                threatLevel: "SAFE", suppressedCount: 0
            ))
        } else {
            notificationFeedback.notificationOccurred(.success)
            audioEngine.playEarcon(type: "MUTE")
        }
    }

    private func toggleTorchState() {
        impactFeedbackMedium.impactOccurred()
        cameraManager.toggleManualTorch()
    }
}
