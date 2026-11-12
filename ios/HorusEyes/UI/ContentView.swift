import SwiftUI
import AVFoundation
import QuartzCore

struct DirectionalAdvisory {
    var state = "UNKNOWN"
    var angleDeg: Double? = nil
    var confidence: Double? = nil
    var observedAngularRange: ClosedRange<Double>? = nil
    var sourceTimestamp: Double = 0
    func drawableAngle(now: Double) -> Double? {
        guard state == "AVAILABLE", let angle = angleDeg, angle.isFinite,
              let confidence = confidence, confidence > 0, confidence <= 1,
              let range = observedAngularRange, range.lowerBound >= -90, range.upperBound <= 90,
              range.contains(angle), (0...1).contains(now-sourceTimestamp) else { return nil }
        return angle
    }
}

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

    func appear() {
        camera.onFrameProcessed = { [weak self] buffer, frameId, settle, luma in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            self.lock.lock()
            self.lastFrame = now
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
                let obs = self.depth!.processFrame(pixelBuffer: buffer, frameId: frameId,
                    aeSettleFramesRemaining: settle, meanLuma: luma, isZeroLuxBlind: luma < 10)
                let risk = self.kin.compute(obstacleResult: obs, frameId: frameId,
                    timestamp: now, aeSettleRemaining: settle, imuYawRateRadS: rate)
                let decision = self.budget.coordinate(obstacleResult: obs, kinematicsResult: risk)
                DispatchQueue.main.async {
                    self.lock.lock()
                    let current = self.enabled && self.generation == token
                    self.lock.unlock()
                    guard current else { return }
                    guard CACurrentMediaTime()-now <= 1 else { self.fault(); return }
                    self.result = obs.isValid ? obs : nil
                    self.sourceTimestamp = now
                    self.threat = risk.threatLevel
                    self.advisory = DirectionalAdvisory(state: risk.threatLevel == "CRITICAL" ? "STOP" : "UNAVAILABLE", sourceTimestamp: now)
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
    }
    private func silentDecision() -> BudgetDecision {
        BudgetDecision(isActive: false, pan: 0, proximity: 0, distCM: .nan, ttc: .infinity,
            priorityScore: 0, volumeFactor: 0, safeDirection: "NONE", cueMode: "MUTED", threatLevel: "UNKNOWN", suppressedCount: 0)
    }
    private func fault() {
        threat = "SENSOR_FAULT"; result = nil; advisory = DirectionalAdvisory()
        audio.update(decision: BudgetDecision(isActive: true, pan: 0, proximity: 0.4, distCM: .nan,
            ttc: .infinity, priorityScore: 99, volumeFactor: 0.35, safeDirection: "STOP",
            cueMode: "SYSTEM_FAULT_TONE", threatLevel: "SENSOR_FAULT", suppressedCount: 0))
    }
    func toggle() { setActive(!active) }
    func setActive(_ value: Bool) {
        lock.lock(); generation += 1; enabled = value; lock.unlock()
        active = value; result = nil; advisory = DirectionalAdvisory()
        started = CACurrentMediaTime(); sourceTimestamp = started
        threat = value ? "INITIALIZING" : "PAUSED"
        audio.update(decision: silentDecision())
        if value { audio.start() }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    func disappear() {
        setActive(false); timer?.invalidate(); timer = nil
        camera.stop(); imu.stopMotionTracking(); audio.stop()
    }
}

struct ContentView: View {
    @StateObject private var model = DemoController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreviewView(session: model.camera.session)
                TrackingOverlayView(result: model.result, threatLevel: model.threat)
                VStack {
                    Spacer()
                    DirectionIndicator(advisory: model.advisory, threat: model.threat)
                        .padding(.bottom, 30)
                }
            }.clipped()
            Button(action: model.toggle) {
                Text(model.active ? "STOP" : "START")
                    .font(.system(size: 26, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .foregroundColor(Color(white: 0.08))
                    .background(Color(white: 0.88)).cornerRadius(16)
            }
            .accessibilityLabel(model.active ? "Stop perception" : "Start perception")
            .padding(20)
        }
        .background(Color(white: 0.07))
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.appear() } else { model.disappear() }
        }
    }
}

struct DirectionIndicator: View {
    let advisory: DirectionalAdvisory
    let threat: String
    var body: some View {
        Group {
            if let angle = advisory.drawableAngle(now: CACurrentMediaTime()), threat != "PAUSED" {
                Image(systemName: "arrow.up")
                    .font(.system(size: 64, weight: .heavy))
                    .rotationEffect(.degrees(angle)).scaleEffect(x: 1, y: 0.7)
                    .foregroundStyle(LinearGradient(colors: [.white, .gray], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black, radius: 1, x: 4, y: 7)
                    .animation(.easeOut(duration: 0.15), value: angle)
                    .accessibilityLabel("Estimated direction advisory")
            } else {
                Label(threat == "CRITICAL" ? "STOP" : threat == "PAUSED" ? "PAUSED" : "UNAVAILABLE",
                    systemImage: threat == "CRITICAL" ? "hand.raised.fill" : "minus.circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(threat == "CRITICAL" ? .red : .white)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(Color.black.opacity(0.8)).cornerRadius(16)
                    .accessibilityLabel(threat == "CRITICAL" ? "Stop. Obstacle detected" : "Direction unavailable")
            }
        }
    }
}
