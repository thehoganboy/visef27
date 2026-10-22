// HorusEyes 2.0 — ContentView.swift
// ════════════════════════════════════════════════════════════════════════════════
// High-Contrast Accessible HUD + Giant Ergonomic Controls + VoiceOver Integration
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

    // ── Observable Pipeline Telemetry ─────────────────────────────────────────
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

    // Haptics
    private let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // ════════════════════════════════════════════════════════════════
                // UPPER HALF: Safety Navigation HUD & Telemetry
                // ════════════════════════════════════════════════════════════════
                ZStack {
                    Color.black.ignoresSafeArea()

                    VStack(spacing: 12) {
                        // Top Header: App Branding + Torch & Sensor Status
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HORUSEYES 2.0")
                                    .font(.system(size: 16, weight: .black, design: .monospaced))
                                    .foregroundColor(.cyan)
                                Text("A15 Bionic Safety Edition")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.gray)
                            }

                            Spacer()

                            // Torch Status Badge
                            HStack(spacing: 4) {
                                Image(systemName: cameraManager.isTorchActive ? "bolt.fill" : "bolt.slash")
                                    .foregroundColor(cameraManager.isTorchActive ? .yellow : .gray)
                                Text(cameraManager.isTorchActive ? "TORCH ON" : "TORCH OFF")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(cameraManager.isTorchActive ? .yellow : .gray)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.15))
                            .cornerRadius(6)

                            // Sensor Health Indicator
                            Circle()
                                .fill(cameraManager.isZeroLuxBlind ? Color.red : (cameraManager.isCameraHealthy ? Color.green : Color.orange))
                                .frame(width: 10, height: 10)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        // 3-Sector Visual Clearance Bars (LEFT | CENTER | RIGHT)
                        HStack(spacing: 8) {
                            SectorCard(name: "LEFT", distCM: sectorDists["LEFT"] ?? 250.0)
                            SectorCard(name: "CENTER", distCM: sectorDists["CENTER"] ?? 250.0)
                            SectorCard(name: "RIGHT", distCM: sectorDists["RIGHT"] ?? 250.0)
                        }
                        .padding(.horizontal, 16)

                        // Giant Escape Direction Guidance Banner
                        HStack {
                            Spacer()
                            if safeDirection == "STOP" {
                                Label("STOP — HAZARD BLOCKED", systemImage: "hand.raised.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundColor(.white)
                            } else if safeDirection == "LEFT" {
                                Label("ESCAPE: ◀ TURN LEFT", systemImage: "arrow.left.circle.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundColor(.white)
                            } else {
                                Label("ESCAPE: TURN RIGHT ▶", systemImage: "arrow.right.circle.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundColor(.white)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .background(escapeBannerColor)
                        .cornerRadius(10)
                        .padding(.horizontal, 16)
                        .accessibilityElement()
                        .accessibilityLabel("Hướng thoát hiểm: \(safeDirection == "STOP" ? "Dừng lại" : (safeDirection == "LEFT" ? "Rẽ trái" : "Rẽ phải"))")

                        // Telemetry Metrics Grid
                        VStack(spacing: 4) {
                            HStack {
                                MetricCell(title: "FPS", value: String(format: "%.1f", cameraManager.fps))
                                MetricCell(title: "LATENCY", value: String(format: "%.0f ms", depthEngine.inferenceLatencyMs))
                                MetricCell(title: "DIST Z", value: String(format: "%.0f cm", currentDistCM))
                                MetricCell(title: "V_Z", value: String(format: "%.0f cm/s", currentVz))
                            }
                            HStack {
                                MetricCell(title: "TTC", value: currentTTC.isFinite ? String(format: "%.1f s", currentTTC) : "SAFE")
                                MetricCell(title: "UNCERT (u)", value: String(format: "%.2f", currentUncertainty))
                                MetricCell(title: "CUE MODE", value: currentCueMode)
                                MetricCell(title: "LUMA (Y)", value: String(format: "%.0f", cameraManager.meanLuma))
                            }
                        }
                        .padding(10)
                        .background(Color(white: 0.12))
                        .cornerRadius(8)
                        .padding(.horizontal, 16)

                        Spacer()
                    }
                }
                .frame(height: geo.size.height * 0.52)

                // ════════════════════════════════════════════════════════════════
                // LOWER HALF: Giant Ergonomic Tactile Control Pads
                // ════════════════════════════════════════════════════════════════
                VStack(spacing: 12) {
                    // Button 1: Pause / Resume Giant Button
                    Button(action: togglePauseState) {
                        HStack(spacing: 16) {
                            Image(systemName: isSystemPaused ? "play.circle.fill" : "pause.circle.fill")
                                .font(.system(size: 40))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isSystemPaused ? "TIẾP TỤC DẪN ĐƯỜNG" : "TẠM DỪNG HỆ THỐNG")
                                    .font(.system(size: 20, weight: .black))
                                Text(isSystemPaused ? "Chạm để bật lại âm thanh và camera" : "Chạm để tắt âm thanh và dừng quét")
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(0.85)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(isSystemPaused ? Color.green : Color(red: 0.85, green: 0.25, blue: 0.20))
                        .foregroundColor(.white)
                        .cornerRadius(16)
                    }
                    .accessibilityLabel(isSystemPaused ? "Nút Tiếp tục dẫn đường" : "Nút Tạm dừng hệ thống")
                    .accessibilityHint("Nhấn hai lần để chuyển đổi trạng thái tạm dừng hoặc tiếp tục")

                    // Button 2: Auto / Manual Torch Giant Button
                    Button(action: toggleTorchState) {
                        HStack(spacing: 16) {
                            Image(systemName: cameraManager.isTorchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 40))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cameraManager.isTorchActive ? "ĐÈN FLASH: ĐANG BẬT" : "ĐÈN FLASH: TỰ ĐỘNG (0-LUX)")
                                    .font(.system(size: 20, weight: .black))
                                Text(cameraManager.isTorchActive ? "Chạm để tắt đèn thủ công" : "Tự bật khi tối < 28 Lux, chạm để bật cưỡng bức")
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(0.85)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(cameraManager.isTorchActive ? Color(red: 0.80, green: 0.60, blue: 0.10) : Color(white: 0.20))
                        .foregroundColor(.white)
                        .cornerRadius(16)
                    }
                    .accessibilityLabel(cameraManager.isTorchActive ? "Đèn flash đang bật, nhấn để tắt" : "Đèn flash tự động, nhấn để bật cưỡng bức")
                }
                .padding(16)
                .frame(height: geo.size.height * 0.48)
                .background(Color(white: 0.08))
            }
        }
        .onAppear(perform: startPipeline)
        .onDisappear(perform: stopPipeline)
    }

    // ── Escape Guidance Banner Background Color ───────────────────────────────
    private var escapeBannerColor: Color {
        if safeDirection == "STOP" {
            return Color.red
        } else if threatLevel == "CRITICAL" {
            return Color.orange
        } else {
            return Color(red: 0.10, green: 0.60, blue: 0.35)
        }
    }

    // ── Pipeline Lifecycle & Real-Time Sync ────────────────────────────────────
    private func startPipeline() {
        impactFeedback.prepare()
        audioEngine.start()
        cameraManager.start()

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
        impactFeedback.impactOccurred()
        audioEngine.playEarcon(type: isSystemPaused ? "PAUSE" : "MUTE")
        if isSystemPaused {
            audioEngine.update(decision: BudgetDecision(
                isActive: false, pan: 0, proximity: 0, distCM: 250, ttc: .infinity,
                priorityScore: 0, volumeFactor: 0, safeDirection: "STOP", cueMode: "MUTED",
                threatLevel: "SAFE", suppressedCount: 0
            ))
        }
    }

    private func toggleTorchState() {
        impactFeedback.impactOccurred()
        cameraManager.toggleManualTorch()
    }
}

// ── Sub-Components ─────────────────────────────────────────────────────────────
struct SectorCard: View {
    let name: String
    let distCM: Float

    var color: Color {
        if distCM <= Config.distCriticalCM {
            return .red
        } else if distCM <= Config.distDangerCM {
            return .orange
        } else if distCM <= Config.distWarningCM {
            return .yellow
        } else {
            return .green
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(String(format: "%.0f cm", distCM))
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(color)
            Rectangle()
                .fill(color)
                .frame(height: 4)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.16))
        .cornerRadius(6)
    }
}

struct MetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
