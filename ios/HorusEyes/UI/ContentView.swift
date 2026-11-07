// HorusEyes 2.0 — ContentView.swift
// ════════════════════════════════════════════════════════════════════════════════
// Modern Ultra-Minimalist Accessible iOS HUD (Zero Numbers, Pure Human-Centric UI)
// Apple Human Interface Guidelines & Blind Ergonomics (Eyes-Free Operation)
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
                // Pure OLED Deep Black Background
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ════════════════════════════════════════════════════════════
                    // TOP BAR: Brand Identity + Simple Status Capsule
                    // ════════════════════════════════════════════════════════════
                    HStack(alignment: .center) {
                        // Brand Logo
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.cyan.opacity(0.8), Color.blue],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 30, height: 30)
                                    .shadow(color: .cyan.opacity(0.4), radius: 6)

                                Image(systemName: "eye.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.black)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text("HORUSEYES")
                                    .font(.system(size: 16, weight: .black, design: .rounded))
                                    .tracking(1.4)
                                    .foregroundColor(.white)
                                Text("TRỢ THỊ THÔNG MINH")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(.cyan.opacity(0.85))
                            }
                        }

                        Spacer()

                        // Simple Human-Friendly Status Capsule
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isSystemPaused ? Color.orange : (cameraManager.isZeroLuxBlind ? Color.red : Color.green))
                                .frame(width: 8, height: 8)
                                .shadow(color: isSystemPaused ? Color.orange : Color.green, radius: 4)

                            Text(isSystemPaused ? "TẠM DỪNG" : (cameraManager.isZeroLuxBlind ? "THIẾU SÁNG" : "ĐANG BẢO VỆ"))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(isSystemPaused ? .orange : (cameraManager.isZeroLuxBlind ? .red : .green))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    // ════════════════════════════════════════════════════════════
                    // UPPER SECTION: Ultra-Minimalist Spatial Guidance (Zero Numbers)
                    // ════════════════════════════════════════════════════════════
                    VStack(spacing: 16) {
                        // 1. Spatial Clearance & Direction Orb (Pure Visual & Qualitative)
                        SpatialRadarView(
                            sectorDists: sectorDists,
                            nearestDistCM: currentDistCM,
                            threatLevel: threatLevel,
                            isPaused: isSystemPaused
                        )

                        // 2. Dynamic Escape Direction Banner
                        EscapeGuidanceBanner(
                            safeDirection: safeDirection,
                            threatLevel: threatLevel,
                            isPaused: isSystemPaused
                        )
                        .padding(.horizontal, 16)

                        Spacer(minLength: 0)
                    }
                    .frame(height: geo.size.height * 0.48)

                    // ════════════════════════════════════════════════════════════
                    // LOWER SECTION: Giant Ergonomic Tactile Control Pads
                    // ════════════════════════════════════════════════════════════
                    VStack(spacing: 14) {
                        // ── Pad 1: System State (Pause / Resume) ────────────────
                        Button(action: togglePauseState) {
                            HStack(spacing: 20) {
                                ZStack {
                                    Circle()
                                        .fill(isSystemPaused ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                        .frame(width: 60, height: 60)

                                    Image(systemName: isSystemPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 26, weight: .black))
                                        .foregroundColor(isSystemPaused ? .green : .orange)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isSystemPaused ? "TIẾP TỤC DẪN ĐƯỜNG" : "TẠM DỪNG HỆ THỐNG")
                                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                                        .foregroundColor(.white)
                                    Text(isSystemPaused ? "Chạm để bật lại quét và âm thanh" : "Chạm để tắt âm thanh và tạm dừng")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundColor(Color.white.opacity(0.65))
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(Color.white.opacity(0.3))
                            }
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: isSystemPaused
                                                ? [Color(white: 0.16), Color(white: 0.10)]
                                                : [Color(red: 0.18, green: 0.12, blue: 0.08), Color(white: 0.10)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                                            .stroke(
                                                isSystemPaused
                                                    ? Color.green.opacity(0.4)
                                                    : Color.orange.opacity(0.3),
                                                lineWidth: 1.5
                                            )
                                    )
                            )
                            .shadow(color: isSystemPaused ? Color.green.opacity(0.15) : Color.orange.opacity(0.1), radius: 12, y: 4)
                        }
                        .accessibilityLabel(isSystemPaused ? "Tiếp tục dẫn đường" : "Tạm dừng hệ thống")
                        .accessibilityHint("Nhấn hai lần để chuyển đổi trạng thái")

                        // ── Pad 2: Smart Flashlight & 0-Lux Defense ────────────
                        Button(action: toggleTorchState) {
                            HStack(spacing: 20) {
                                ZStack {
                                    Circle()
                                        .fill(cameraManager.isTorchActive ? Color.yellow.opacity(0.2) : Color.cyan.opacity(0.15))
                                        .frame(width: 60, height: 60)

                                    Image(systemName: cameraManager.isTorchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                                        .font(.system(size: 26, weight: .black))
                                        .foregroundColor(cameraManager.isTorchActive ? .yellow : .cyan)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cameraManager.isTorchActive ? "ĐÈN FLASH: ĐANG BẬT" : "ĐÈN THÔNG MINH (0-LUX)")
                                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                                        .foregroundColor(.white)
                                    Text(cameraManager.isTorchActive ? "Chạm để chuyển chế độ tự động" : "Tự động kích hoạt khi trời tối")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundColor(Color.white.opacity(0.65))
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(Color.white.opacity(0.3))
                            }
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: cameraManager.isTorchActive
                                                ? [Color(red: 0.22, green: 0.18, blue: 0.05), Color(white: 0.10)]
                                                : [Color(white: 0.14), Color(white: 0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                                            .stroke(
                                                cameraManager.isTorchActive
                                                    ? Color.yellow.opacity(0.5)
                                                    : Color.cyan.opacity(0.25),
                                                lineWidth: 1.5
                                            )
                                    )
                            )
                            .shadow(color: cameraManager.isTorchActive ? Color.yellow.opacity(0.2) : Color.cyan.opacity(0.08), radius: 12, y: 4)
                        }
                        .accessibilityLabel(cameraManager.isTorchActive ? "Đèn flash đang bật, nhấn để chuyển sang tự động" : "Đèn flash tự động, nhấn để bật thủ công")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 22)
                    .frame(height: geo.size.height * 0.52)
                }
            }
            // Double Tap Gesture anywhere on the screen for blind users to easily toggle pause/play
            .onTapGesture(count: 2) {
                togglePauseState()
            }
        }
        .onAppear(perform: startPipeline)
        .onDisappear(perform: stopPipeline)
    }

    // ── Pipeline Lifecycle & Real-Time Sync ────────────────────────────────────
    private func startPipeline() {
        impactFeedbackHeavy.prepare()
        impactFeedbackMedium.prepare()
        notificationFeedback.prepare()
        audioEngine.start()
        cameraManager.start()
        imuManager.startMotionTracking()

        // Link Camera to Vision & Audio DSP
        cameraManager.onFrameProcessed = { pixelBuffer, frameId, aeSettle, luma in
            guard !self.isSystemPaused else { return }

            let isBlind = self.cameraManager.isZeroLuxBlind

            // 1. CoreML Spatial Depth Processing
            let obsResult = self.depthEngine.processFrame(
                pixelBuffer: pixelBuffer,
                frameId: frameId,
                aeSettleFramesRemaining: aeSettle,
                meanLuma: luma,
                isZeroLuxBlind: isBlind
            )

            // 2. Kinematics, TTC & Sector Guidance
            let now = CACurrentMediaTime()
            let kinResult = self.kinematicsEngine.compute(
                obstacleResult: obsResult,
                frameId: frameId,
                timestamp: now,
                aeSettleRemaining: aeSettle,
                userWalkSpeedCmS: self.imuManager.estimatedWalkSpeedCmS,
                imuYawRateRadS: self.imuManager.yawRateRadS
            )

            // 3. Single-Stream Auditory Budgeting
            let decision = self.budgetManager.coordinate(
                obstacleResult: obsResult,
                kinematicsResult: kinResult
            )

            // 4. Update 3D Spatial Audio Engine (Realtime thread)
            self.audioEngine.update(decision: decision)

            // 5. Update UI state on Main Thread
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

// ── Escape Guidance Hero Banner (Human Centric Navigation) ─────────────────────
struct EscapeGuidanceBanner: View {
    let safeDirection: String
    let threatLevel: String
    let isPaused: Bool

    private var bannerColor: Color {
        guard !isPaused else { return Color.gray.opacity(0.3) }
        if safeDirection == "STOP" {
            return Color(red: 0.90, green: 0.20, blue: 0.20)
        } else if threatLevel == "CRITICAL" {
            return Color(red: 0.95, green: 0.50, blue: 0.10)
        } else if threatLevel == "WARNING" {
            return Color(red: 0.90, green: 0.70, blue: 0.10)
        } else {
            return Color(red: 0.12, green: 0.65, blue: 0.40)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Spacer()

            if isPaused {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                Text("HỆ THỐNG ĐANG TẠM DỪNG")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
            } else if safeDirection == "STOP" {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 22, weight: .bold))
                Text("DỪNG LẠI — VẬT CẢN CHẮN PHÍA TRƯỚC")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
            } else if safeDirection == "LEFT" {
                Image(systemName: "arrow.turn.up.left")
                    .font(.system(size: 22, weight: .black))
                Text("HƯỚNG AN TOÀN: RẼ TRÁI")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
            } else if safeDirection == "RIGHT" {
                Text("HƯỚNG AN TOÀN: RẼ PHẢI")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 22, weight: .black))
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 22, weight: .bold))
                Text("HÀNH LANG AN TOÀN — ĐI THẲNG")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
            }

            Spacer()
        }
        .foregroundColor(.white)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(bannerColor.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(bannerColor, lineWidth: 1.5)
                )
        )
        .shadow(color: bannerColor.opacity(0.4), radius: 10, y: 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: safeDirection)
        .accessibilityElement()
        .accessibilityLabel(safeDirection == "STOP" ? "Dừng lại, phía trước có vật cản" : (safeDirection == "LEFT" ? "Rẽ trái an toàn" : (safeDirection == "RIGHT" ? "Rẽ phải an toàn" : "Phía trước an toàn, tiếp tục đi thẳng")))
    }
}
