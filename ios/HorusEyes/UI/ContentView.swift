import SwiftUI
import AVFoundation
import QuartzCore

final class DemoController: ObservableObject {
    let camera = CameraTorchManager()
    private let audio = SpatialAudioEngine()
    private let imu = IMUManager()
    @Published var active = false
    @Published var threat = "PAUSED"
    @Published var result: ObstacleDetectionResult?
    @Published var sourceTimestamp: Double = 0
    @Published var advisory = DirectionalAdvisory()
    private let lock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.horuseyes.inference", qos: .userInitiated)
    private var enabled = false
    private var busy = false
    private var generation = 0
    private var workerGeneration = -1
    private var depth: DepthEngine?
    private var kin = KinematicsEngine()
    private var budget = AuditoryBudgetManager()
    private var timer: Timer?
    private var started: Double = 0
    private var lastFrame: Double = 0
    private var yaw: Float = 0
    private var prevAngle: Double? = nil
    private var isAppeared: Bool = false
    private var lastAcceptedFrameId: UInt64 = 0
    private var lastAcceptedTimestamp: Double = 0.0
    private struct ObservationSnapshot {
        let frameId: UInt64
        let timestamp: Double
        let threat: String
        let state: String
        let angleDeg: Double?
        let confidence: Double
        let reasonCode: String
    }
    private var observationHistory: [ObservationSnapshot] = []

    func appear() {
        guard !isAppeared else { return }
        isAppeared = true

        camera.onFrameProcessed = { [weak self] buffer, frameId, settle, luma, capturedAt in
            guard let self = self else { return }
            self.lock.lock()
            self.lastFrame = capturedAt
            guard self.enabled && !self.busy else { self.lock.unlock(); return }
            self.busy = true
            let token = self.generation
            let rate = self.yaw
            self.lock.unlock()
            self.inferenceQueue.async {
                defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
                if self.workerGeneration != token {
                    self.kin = KinematicsEngine(); self.budget = AuditoryBudgetManager()
                    self.workerGeneration = token
                }
                if self.depth == nil { self.depth = DepthEngine() }
                let obs = self.depth!.processFrame(
                    pixelBuffer: buffer,
                    frameId: frameId,
                    sourceTimestamp: capturedAt,
                    aeSettleFramesRemaining: settle,
                    meanLuma: luma,
                    isZeroLuxBlind: luma < Config.luxZeroBlindThreshold
                )
                let risk = self.kin.compute(
                    obstacleResult: obs,
                    frameId: frameId,
                    timestamp: capturedAt,
                    aeSettleRemaining: settle,
                    imuYawRateRadS: rate
                )
                let decision = self.budget.coordinate(obstacleResult: obs, kinematicsResult: risk)
                DispatchQueue.main.async {
                    let consumedAt = CACurrentMediaTime()
                    self.lock.lock()
                    let current = self.enabled && self.generation == token
                    self.lock.unlock()
                    guard current else { return }

                    let age = consumedAt - obs.timestamp
                    guard obs.timestamp > 0 && !obs.timestamp.isNaN && !obs.timestamp.isInfinite else { return }
                    guard age >= -0.05 && age <= 0.75 else { return }
                    guard frameId > self.lastAcceptedFrameId && obs.timestamp >= self.lastAcceptedTimestamp else { return }

                    self.lastAcceptedFrameId = frameId
                    self.lastAcceptedTimestamp = obs.timestamp
                    self.result = obs.isValid ? obs : nil
                    self.sourceTimestamp = obs.timestamp
                    self.threat = risk.threatLevel
                    let rawAdv = estimateDirectionalAdvisory(
                        observation: obs,
                        threat: risk.threatLevel,
                        now: consumedAt,
                        prevAngle: self.prevAngle
                    )

                    var finalAdv = rawAdv

                    // Evidence-Aware Temporal Stability (P0-03)
                    if risk.threatLevel == "CRITICAL" || rawAdv.state == "STOP" {
                        // Critical hazard: immediate preemption with ZERO smoothing delay
                        self.observationHistory.removeAll()
                        finalAdv = rawAdv
                    } else if risk.threatLevel == "SENSOR_FAULT" || rawAdv.state == "UNKNOWN" {
                        self.observationHistory.removeAll()
                        finalAdv = rawAdv
                    } else if rawAdv.state == "AVAILABLE" {
                        self.observationHistory.append(ObservationSnapshot(
                            frameId: frameId,
                            timestamp: obs.timestamp,
                            threat: risk.threatLevel,
                            state: rawAdv.state,
                            angleDeg: rawAdv.angleDeg,
                            confidence: rawAdv.confidence ?? 0.55,
                            reasonCode: rawAdv.reasonCode
                        ))
                        if self.observationHistory.count > 4 {
                            self.observationHistory.removeFirst()
                        }
                        finalAdv = rawAdv
                    } else if rawAdv.state == "UNAVAILABLE" {
                        // Check for transient 1-frame degradation over otherwise stable, fresh observation
                        let recentValid = self.observationHistory.filter {
                            $0.state == "AVAILABLE" && (consumedAt - $0.timestamp) <= 0.28
                        }
                        if recentValid.count >= 2, let lastValid = recentValid.last, let heldAngle = lastValid.angleDeg {
                            // Bounded transient hold: maintain direction for this single frame
                            finalAdv = DirectionalAdvisory(
                                state: "AVAILABLE",
                                angleDeg: heldAngle,
                                confidence: lastValid.confidence * 0.85,
                                observedAngularRange: rawAdv.observedAngularRange,
                                sourceTimestamp: lastValid.timestamp,
                                reasonCode: "TRANSIENT_HOLD"
                            )
                            self.observationHistory.append(ObservationSnapshot(
                                frameId: frameId,
                                timestamp: obs.timestamp,
                                threat: risk.threatLevel,
                                state: "TRANSIENT_HOLD",
                                angleDeg: heldAngle,
                                confidence: lastValid.confidence * 0.85,
                                reasonCode: "TRANSIENT_HOLD"
                            ))
                            if self.observationHistory.count > 4 {
                                self.observationHistory.removeFirst()
                            }
                        } else {
                            self.observationHistory.removeAll()
                            finalAdv = rawAdv
                        }
                    }

                    self.advisory = finalAdv
                    self.prevAngle = finalAdv.state == "AVAILABLE" ? finalAdv.angleDeg : nil
                    self.audio.update(decision: decision)
                }
            }
        }
        camera.start()
        imu.startMotionTracking()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        lock.lock(); yaw = imu.yawRateRadS; let frameTime = lastFrame; lock.unlock()
        guard active else { return }
        let now = CACurrentMediaTime()
        if now-started > 1 && (now-frameTime > 1 || now-sourceTimestamp > 1) { fault() }
        // Preview remains live; stale boxes must disappear independently of frames.
        if now-sourceTimestamp > 0.25 { result = nil }
        // Expire directional advisory at 750ms
        if now-sourceTimestamp > 0.75 {
            if advisory.state == "AVAILABLE" {
                advisory = DirectionalAdvisory(state: "UNAVAILABLE", sourceTimestamp: sourceTimestamp, reasonCode: "SOURCE_FRAME_STALE")
            }
        }
    }

    private func silentDecision() -> BudgetDecision {
        BudgetDecision(isActive: false, pan: 0, proximity: 0, distCM: .nan, ttc: .infinity,
            priorityScore: 0, volumeFactor: 0, safeDirection: "NONE", cueMode: "MUTED", threatLevel: "UNKNOWN", suppressedCount: 0)
    }

    private func fault() {
        threat = "SENSOR_FAULT"; result = nil; advisory = DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: CACurrentMediaTime(), reasonCode: "SENSOR_FAULT"); prevAngle = nil
        observationHistory.removeAll()
        audio.update(decision: BudgetDecision(isActive: true, pan: 0, proximity: 0.4, distCM: .nan,
            ttc: .infinity, priorityScore: 99, volumeFactor: 0.35, safeDirection: "STOP",
            cueMode: "SYSTEM_FAULT_TONE", threatLevel: "SENSOR_FAULT", suppressedCount: 0))
    }

    func toggle() { setActive(!active) }

    func setActive(_ value: Bool) {
        lock.lock(); generation += 1; enabled = value; lock.unlock()
        active = value; result = nil; advisory = DirectionalAdvisory(); prevAngle = nil
        observationHistory.removeAll()
        camera.resetManualTorchLock()
        if !value {
            camera.forceTorchOff()
        }
        lastAcceptedFrameId = 0; lastAcceptedTimestamp = 0.0
        started = CACurrentMediaTime(); sourceTimestamp = started
        threat = value ? "INITIALIZING" : "PAUSED"
        audio.update(decision: silentDecision())
        if value { audio.start() } else { audio.stop() }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func disappear() {
        guard isAppeared else { return }
        isAppeared = false

        camera.forceTorchOff()
        setActive(false); timer?.invalidate(); timer = nil
        camera.stop(); imu.stopMotionTracking(); audio.stop()
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// APPLE-INSPIRED LIQUID GLASS BUTTON STYLE
// ═══════════════════════════════════════════════════════════════════════════════
struct LiquidButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 30, weight: .bold))
            .foregroundColor(isActive ? Color.white : Color(white: 0.08))
            .frame(maxWidth: .infinity, minHeight: 124)
            .background(
                ZStack {
                    if isActive {
                        // Active DỪNG state: Apple System Red liquid gradient with specular top highlight
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.27, blue: 0.23), Color(red: 0.85, green: 0.12, blue: 0.09)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.45), Color.white.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    } else {
                        // Paused CHẠY state: Frosted glass finish with subtle specular highlight
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.97, green: 0.97, blue: 0.98), Color(red: 0.89, green: 0.89, blue: 0.92)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.8), Color.white.opacity(0.2)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                }
            )
            .shadow(color: isActive ? Color.red.opacity(0.3) : Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MANUAL FLASHLIGHT BUTTON (P1-01)
// ═══════════════════════════════════════════════════════════════════════════════
struct FlashlightButton: View {
    let isTorchActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(white: 0.10).opacity(0.75))
                    .overlay(
                        Circle()
                            .stroke(
                                isTorchActive ?
                                    Color(red: 1.0, green: 0.84, blue: 0.04).opacity(0.85) :
                                    Color.white.opacity(0.22),
                                lineWidth: 1.5
                            )
                    )
                Image(systemName: isTorchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isTorchActive ? Color(red: 1.0, green: 0.84, blue: 0.04) : Color.white.opacity(0.92))
                    .shadow(color: isTorchActive ? Color.yellow.opacity(0.5) : Color.clear, radius: 6)
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
        }
        .accessibilityLabel(isTorchActive ? "Tắt đèn pin" : "Bật đèn pin")
        .accessibilityHint("Nhấn để bật hoặc tắt đèn pin hỗ trợ môi trường thiếu sáng")
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN APPLICATION VIEW
// ═══════════════════════════════════════════════════════════════════════════════
struct ContentView: View {
    @StateObject private var model = DemoController()

    var body: some View {
        VStack(spacing: 0) {
            // Rounded Camera Preview Container (P1-01)
            ZStack(alignment: .topTrailing) {
                CameraPreviewView(session: model.camera.session)
                TrackingOverlayView(result: model.result, threatLevel: model.threat)

                // Top-Right Floating Flashlight Button (P1-01)
                FlashlightButton(isTorchActive: model.camera.isTorchActive) {
                    model.camera.toggleManualTorch()
                }
                .padding(.top, 14)
                .padding(.trailing, 14)

                VStack {
                    Spacer()
                    DirectionIndicator(advisory: model.advisory, threat: model.threat)
                        .padding(.bottom, 24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .background(Color.black)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Enlarged Liquid START/STOP Button (P0-03)
            Button(action: model.toggle) {
                Text(model.active ? "DỪNG" : "CHẠY")
            }
            .buttonStyle(LiquidButtonStyle(isActive: model.active))
            .accessibilityLabel(model.active ? "Dừng nhận thức tránh va chạm" : "Bắt đầu nhận thức tránh va chạm")
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.05)) // Apple Dark Chassis (#0A0A0C)
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 3D DIRECTIONAL ADVISORY INDICATOR (P0-01)
// ═══════════════════════════════════════════════════════════════════════════════
struct DirectionIndicator: View {
    let advisory: DirectionalAdvisory
    let threat: String

    var body: some View {
        Group {
            let isStop = (advisory.state == "STOP" || threat == "CRITICAL") && threat != "PAUSED"
            let isPaused = threat == "PAUSED"

            if !isStop && !isPaused, let angle = advisory.drawableAngle(now: CACurrentMediaTime()) {
                // Perceptual visual rotation mapping (P0-01)
                let visualAngle = max(-45.0, min(45.0, angle * 1.4))
                let lateralOffset = max(-35.0, min(35.0, visualAngle * 0.9))

                Image(systemName: "arrow.up")
                    .font(.system(size: 80, weight: .heavy))
                    .rotation3DEffect(.degrees(22), axis: (x: 1, y: 0, z: 0)) // 3D road perspective
                    .rotationEffect(.degrees(visualAngle))
                    .offset(x: lateralOffset)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color(red: 0.88, green: 0.88, blue: 0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color.black.opacity(0.75), radius: 6, x: 0, y: 5)
                    .animation(.spring(response: 0.22, dampingFraction: 0.75), value: angle)
                    .accessibilityLabel("Estimated direction advisory")
            } else {
                let labelText = isPaused ? "PAUSED" : (isStop ? "STOP" : "UNAVAILABLE")
                let iconName = isStop ? "hand.raised.fill" : "minus.circle"

                Label(labelText, systemImage: iconName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(isStop ? Color(red: 1.0, green: 0.23, blue: 0.19) : Color(red: 0.95, green: 0.95, blue: 0.97))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(white: 0.05).opacity(0.85))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    )
                    .accessibilityLabel(isStop ? "Stop. Obstacle detected" : (isPaused ? "Perception paused" : "Direction unavailable"))
            }
        }
    }
}
