import SwiftUI
import AVFoundation
import QuartzCore
import CoreImage

final class DemoController: ObservableObject {
    let camera = CameraTorchManager()
    private let audio = SpatialAudioEngine()
    private let imu = IMUManager()
    @Published private(set) var mode: DepthMode = .midas
    @Published private(set) var preview: CGImage?
    @Published private(set) var diagnostics = ""
    @Published private(set) var exportURL: URL?
    private let journal = DepthDiagnostics()
    private let imageContext = CIContext()
    private var epoch = DepthSourceEpoch()
    private var captureEpoch = 0
    private var sourceStarted = false
    private var stopping = false
    private var lidar: LiDARCapture?
    private var stereo: StereoCapture?
    private var sequence: UInt64 = 0
    private var modeReady = false
    @Published var active = false
    @Published var threat = "PAUSED"
    @Published var result: ObstacleDetectionResult?
    @Published var sourceTimestamp: Double = 0
    @Published var advisory = DirectionalAdvisory()
    private let lock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.horuseyes.inference", qos: .userInitiated)
    private var enabled = false
    private var busy = false
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

        reconcileCapture()
        imu.startMotionTracking()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    static func unsupported(_ mode: DepthMode) -> String? {
        switch mode {
        case .midas: return nil
        case .lidar:
            return mode.unavailableReason(hasHardware: LiDARCapture.supported)
        case .stereo:
            return mode.unavailableReason(hasHardware: StereoCapture.supported)
        }
    }

    func select(_ selected: DepthMode) {
        guard Self.unsupported(selected) == nil else { return }
        guard selected != mode || selected != .midas else { return }
        mode = selected
        resetEvidence(active)
        journal.switchRequested(selected)
        exportURL = nil
        diagnostics = ""
        preview = nil
        restartCapture()
    }

    private func restartCapture() {
        guard !stopping else { return }
        lock.lock()
        captureEpoch += 1
        lock.unlock()
        sourceStarted = false
        stopping = true
        let complete = { [weak self] in
            guard let self else { return }
            self.stopping = false
            self.reconcileCapture()
        }
        if let stereo {
            self.stereo = nil
            stereo.stop(completion: complete)
        } else {
            lidar?.stop()
            lidar = nil
            camera.setGuidanceActive(false)
            camera.stop(completion: complete)
        }
    }

    private func reconcileCapture() {
        guard isAppeared, !stopping, !sourceStarted else { return }
        sourceStarted = true
        let captureToken = captureEpoch
        let selected = mode
        if selected == .midas {
            camera.setFrameHandler { [weak self] buffer, _, settle, luma, capturedAt in
                self?.submit(captureToken: captureToken, timestamp: capturedAt, settle: settle) {
                    if self?.depth == nil { self?.depth = DepthEngine() }
                    var frame: DepthFrame?
                    let obs = self?.depth?.processFrame(pixelBuffer: buffer, frameId: 0, sourceTimestamp: capturedAt,
                        aeSettleFramesRemaining: settle, meanLuma: luma,
                        isZeroLuxBlind: luma < Config.luxZeroBlindThreshold, onDepth: { frame = $0 })
                    return (obs, frame, nil)
                }
            }
            camera.setGuidanceActive(active)
            camera.start()
            return
        }

        let startNative = { [weak self] in
            guard let self, self.isAppeared, self.captureEpoch == captureToken else { return }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.sourceFailed("Camera access denied")
                return
            }
            let receive: (DepthFrame, CVPixelBuffer?) -> Void = { [weak self] frame, buffer in
                guard let self else { return }
                self.submit(captureToken: captureToken, timestamp: frame.timestamp, settle: 0, previewWhilePaused: true) {
                    let portrait = buffer.map { CIImage(cvPixelBuffer: $0).oriented(.right) }
                    let image = portrait.flatMap { self.imageContext.createCGImage($0, from: $0.extent) }
                    let observation = frame.error == nil && frame.source == .lidar ? frame.spatialObservation() : nil
                    return (observation, frame, image)
                }
            }
            let fail: (String) -> Void = { [weak self] reason in
                DispatchQueue.main.async {
                    guard let self, self.captureEpoch == captureToken else { return }
                    if self.diagnostics != reason { self.sourceFailed(reason) }
                }
            }
            if selected == .lidar {
                let source = LiDARCapture(onFrame: receive, onError: fail)
                self.lidar = source
                source.start()
            } else {
                let source = StereoCapture(onFrame: receive, onError: fail)
                self.stereo = source
                source.start()
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async(execute: startNative) }
        } else {
            startNative()
        }
    }

    private func submit(captureToken: Int, timestamp capturedAt: Double, settle: Int, previewWhilePaused: Bool = false,
                        work: @escaping () -> (ObstacleDetectionResult?, DepthFrame?, CGImage?)) {
        lock.lock()
        guard captureEpoch == captureToken, (enabled || previewWhilePaused), !busy else { lock.unlock(); return }
        lastFrame = capturedAt
        busy = true
        let token = epoch.value
        let rate = yaw
        sequence += 1
        let frameId = sequence
        let evaluate = enabled
        lock.unlock()
        inferenceQueue.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            let began = CACurrentMediaTime()
            let (observation, frame, image) = work()
            let inferenceMS = (CACurrentMediaTime() - began) * 1000 + (frame?.captureProcessingMS ?? 0)
            if let frame {
                DispatchQueue.main.async {
                    guard self.captureEpoch == captureToken, self.epoch.value == token,
                          (-0.05...0.75).contains(CACurrentMediaTime() - capturedAt) else { return }
                    if let image { self.preview = image }
                    self.diagnostics = self.journal.label(frame: frame, latencyMS: inferenceMS)
                    if frame.source == .stereo && !self.modeReady {
                        self.modeReady = true
                        self.journal.switchOutcome(frame.source, outcome: "diagnostics_ready")
                    } else if frame.error == nil && observation?.isValid == true, !self.modeReady {
                        self.modeReady = true
                        self.journal.switchOutcome(frame.source, outcome: "depth_ready")
                    }
                    if evaluate && frame.source != .midas && observation?.isValid != true {
                        self.sourceTimestamp = capturedAt
                        self.result = nil
                        self.prevAngle = nil
                        if frame.source == .stereo || self.modeReady || CACurrentMediaTime() - self.started > 1 {
                            self.threat = "UNAVAILABLE"
                            self.advisory = DirectionalAdvisory(state: "UNAVAILABLE", sourceTimestamp: capturedAt,
                                reasonCode: frame.error ?? "INSUFFICIENT_DEPTH")
                        }
                        self.audio.update(decision: self.silentDecision())
                    }
                    if evaluate && (observation?.isValid != true || frame.source == .stereo) {
                        self.journal.record(frame: frame, observation: observation, state: self.advisory.state,
                            inferenceMS: inferenceMS, endToEndMS: (CACurrentMediaTime() - capturedAt) * 1000)
                    }
                }
            }
            guard evaluate, let obs = observation,
                  frame?.source == .midas || obs.isValid else { return }
            if self.workerGeneration != token {
                self.kin = KinematicsEngine()
                self.workerGeneration = token
            }
            let risk = self.kin.compute(
                obstacleResult: obs,
                frameId: frameId,
                timestamp: capturedAt,
                aeSettleRemaining: settle,
                imuYawRateRadS: rate
            )

            DispatchQueue.main.async {
                let consumedAt = CACurrentMediaTime()
                self.lock.lock()
                let current = self.enabled && self.epoch.accepts(token, timestamp: obs.timestamp,
                    now: consumedAt, after: self.lastAcceptedTimestamp)
                self.lock.unlock()
                guard current, frameId > self.lastAcceptedFrameId else { return }

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
                } else if rawAdv.state == "UNAVAILABLE" && self.mode == .midas {
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

                if finalAdv.state == "UNKNOWN" && self.mode != .midas {
                    finalAdv.state = "UNAVAILABLE"
                }
                self.advisory = finalAdv
                if let frame, obs.isValid {
                    self.journal.record(frame: frame, observation: obs, state: finalAdv.state,
                        inferenceMS: inferenceMS, endToEndMS: (consumedAt - capturedAt) * 1000)
                }
                self.prevAngle = finalAdv.state == "AVAILABLE" ? finalAdv.angleDeg : nil

                // P0: Coordinate final authoritative advisory with auditory budget manager BEFORE updating audio
                let decision = self.budget.coordinate(obstacleResult: obs, kinematicsResult: risk, advisory: finalAdv)
                self.audio.update(decision: decision)
            }
        }
    }

    private func tick() {
        lock.lock(); yaw = imu.yawRateRadS; let frameTime = lastFrame; lock.unlock()
        guard active else { return }
        let now = CACurrentMediaTime()
        if now-started > 1 && (now-frameTime > 1 || now-sourceTimestamp > 1) {
            if mode == .midas { fault() }
            else if threat != "UNAVAILABLE" || result != nil { sourceFailed("Depth frames timed out") }
        }
        // Preview remains live; stale boxes must disappear independently of frames.
        if now-sourceTimestamp > 0.25 { result = nil }
        // Expire directional advisory and guidance-dependent audio at 750ms
        if now-sourceTimestamp > 0.75 {
            if advisory.state == "AVAILABLE" || (mode != .midas && advisory.state == "STOP") {
                advisory = DirectionalAdvisory(state: "UNAVAILABLE", sourceTimestamp: sourceTimestamp, reasonCode: "SOURCE_FRAME_STALE")
                prevAngle = nil
            }
            if mode != .midas || (threat != "CRITICAL" && threat != "SENSOR_FAULT") {
                audio.update(decision: silentDecision())
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

    private func sourceFailed(_ reason: String) {
        resetEvidence(active)
        diagnostics = reason
        if active {
            threat = "UNAVAILABLE"
            advisory = DirectionalAdvisory(state: "UNAVAILABLE", reasonCode: reason)
        }
        journal.switchOutcome(mode, outcome: reason)
    }

    func prepareExport() {
        do { exportURL = try journal.export() }
        catch { diagnostics = "Export failed: \(error.localizedDescription)" }
    }

    func setActive(_ value: Bool) {
        resetEvidence(value)
        if mode == .midas {
            camera.setGuidanceActive(value)
            if !value { camera.forceTorchOff() }
        }
        if value { audio.start() } else { audio.stop() }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func resetEvidence(_ value: Bool) {
        lock.lock()
        epoch.invalidate()
        enabled = value
        lastFrame = 0
        lock.unlock()
        active = value
        modeReady = false
        budget = AuditoryBudgetManager()
        result = nil
        advisory = DirectionalAdvisory()
        prevAngle = nil
        observationHistory.removeAll()
        lastAcceptedFrameId = 0; lastAcceptedTimestamp = 0.0
        started = CACurrentMediaTime(); sourceTimestamp = started
        threat = value ? "INITIALIZING" : "PAUSED"
        audio.update(decision: silentDecision())
    }

    func disappear() {
        guard isAppeared else { return }
        isAppeared = false

        camera.setGuidanceActive(false)
        camera.forceTorchOff()
        setActive(false); timer?.invalidate(); timer = nil
        restartCapture(); imu.stopMotionTracking(); audio.stop()
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
                    .fill(Color(white: 0.12).opacity(0.82))
                    .overlay(
                        Circle()
                            .stroke(
                                isTorchActive ?
                                    Color(red: 1.0, green: 0.84, blue: 0.04).opacity(0.90) :
                                    Color.white.opacity(0.28),
                                lineWidth: 2.0
                            )
                    )
                Image(systemName: isTorchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(isTorchActive ? Color(red: 1.0, green: 0.84, blue: 0.04) : Color.white.opacity(0.95))
                    .shadow(color: isTorchActive ? Color.yellow.opacity(0.6) : Color.clear, radius: 8)
            }
            .frame(width: 66, height: 66)
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            // Rounded Camera Preview Container (P1-01)
            ZStack {
                if model.mode == .midas {
                    CameraPreviewView(session: model.camera.session)
                } else if let preview = model.preview {
                    GeometryReader { geometry in
                        Image(decorative: preview, scale: 1)
                            .resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                } else {
                    Color.black
                }
                let isStop = model.advisory.state == "STOP" && model.threat != "PAUSED"
                TrackingOverlayView(result: model.result, threatLevel: model.threat, isStop: isStop)

                // Centered Direction Indicator & Status Badge
                VStack(spacing: 0) {
                    Spacer()
                    DirectionIndicator(advisory: model.advisory, threat: model.threat)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // Top-Right Floating Flashlight Button (Enlarged)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer()
                        FlashlightButton(isTorchActive: model.camera.isTorchActive) {
                            model.camera.toggleManualTorch()
                        }
                        .disabled(model.mode != .midas)
                        .opacity(model.mode == .midas ? 1 : 0.35)
                        .accessibilityHint(model.mode == .midas ? "" : "Torch control is available in MiDaS")
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            HStack(spacing: 3) {
                ForEach(DepthMode.allCases) { mode in
                    let unsupported = DemoController.unsupported(mode)
                    Button { model.select(mode) } label: {
                        Text(mode.rawValue)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(model.mode == mode ? Color.white.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(unsupported == nil ? Color.white : Color.gray)
                    .disabled(unsupported != nil)
                    .accessibilityHint(unsupported ?? "Select depth method")
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            let unsupported = DepthMode.allCases.compactMap(DemoController.unsupported)
            if !unsupported.isEmpty {
                Text(unsupported.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            HStack {
                Text(model.diagnostics.isEmpty ? model.mode.rawValue : model.diagnostics)
                    .font(.caption2.monospacedDigit())
                Spacer()
                if let url = model.exportURL {
                    Button { model.prepareExport() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh diagnostics export")
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share diagnostics")
                } else {
                    Button { model.prepareExport() } label: { Image(systemName: "doc.badge.arrow.up") }
                        .accessibilityLabel("Prepare diagnostics export")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)

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
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.appear() }
            else if phase == .background { model.disappear() }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 3D DIRECTIONAL ADVISORY INDICATOR (P0-01)
// ═══════════════════════════════════════════════════════════════════════════════
struct DirectionIndicator: View {
    let advisory: DirectionalAdvisory
    let threat: String

    var body: some View {
        ZStack {
            let isStop = advisory.state == "STOP" && threat != "PAUSED"
            let isPaused = threat == "PAUSED"

            if !isStop && !isPaused, let angle = advisory.drawableAngle(now: CACurrentMediaTime()) {
                // Perceptual visual rotation mapping (P0-01)
                let visualAngle = max(-45.0, min(45.0, angle * 1.4))
                let lateralOffset = max(-35.0, min(35.0, visualAngle * 0.9))

                Image(systemName: "arrow.up")
                    .font(.system(size: 84, weight: .heavy))
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
                let labelText = isPaused ? "PAUSED" : (isStop ? "STOP" : (threat == "INITIALIZING" ? "INITIALIZING" : "UNAVAILABLE"))
                let iconName = isStop ? "hand.raised.fill" : "minus.circle"

                Label(labelText, systemImage: iconName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(isStop ? Color(red: 1.0, green: 0.23, blue: 0.19) : Color(red: 0.95, green: 0.95, blue: 0.97))
                    .padding(.horizontal, 28)
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
        .frame(maxWidth: .infinity)
    }
}
