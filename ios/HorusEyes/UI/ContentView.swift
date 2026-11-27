import SwiftUI
import AVFoundation
import QuartzCore
import CoreImage
import UniformTypeIdentifiers

final class DemoController: ObservableObject {
    let camera = CameraTorchManager()
    private let audio = SpatialAudioEngine()
    private let imu = IMUManager()
    @Published private(set) var mode: DepthMode = .midas
    @Published private(set) var preview: CGImage?
    @Published private(set) var diagnostics = ""
    @Published private(set) var exportURL: URL?
    @Published private(set) var stereoPairURL: URL?
    @Published private(set) var stereoHealth = ""
    @Published private(set) var stereoStrategy: StereoDeliveryStrategy = .automatic
    @Published private(set) var stereoCaptureOnly = false
    @Published var showStereoDisparity = false { didSet { updateStereoProcessing() } }
    @Published var showStereoDepth = false { didSet { updateStereoProcessing() } }
    @Published private(set) var stereoDepth: CGImage?
    @Published private(set) var stereoDisparity: CGImage?
    @Published private(set) var stereoPairFailed = false
    private let journal = DepthDiagnostics()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var epoch = DepthSourceEpoch()
    private var captureEpoch = 0
    private var sourceStarted = false
    private var stopping = false
    private var lidar: LiDARCapture?
    private var stereo: StereoCapture?
    private var sequence: UInt64 = 0
    private var modeReady = false
    private var stereoDiagnosticReady = false
    private var lastStereoPreviewAt: Double = 0
    @Published var active = false
    @Published private(set) var lifecycle: PerceptionLifecycle = .paused
    @Published private(set) var readiness: DepthReadiness = .captureReady
    @Published private(set) var risk: PerceptionRisk = .unknown
    @Published private(set) var displayTracks: [MetricObstacleTracker.Track] = []
    @Published private(set) var provisionalROICM: Float?
    @Published var result: ObstacleDetectionResult?
    @Published var advisory = DirectionalAdvisory()
    private let lock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.horuseyes.inference", qos: .userInitiated)
    private var enabled = false
    private var busy = false
    private var workerGeneration = -1
    private var depth: DepthEngine?
    private var kin = KinematicsEngine()
    private var tracker = MetricObstacleTracker()
    private var coordinator = AdvisoryCoordinator()
    private var unavailableSince: Double?
    private var statusCueUntil = 0.0
    private var lastStatusCueAt = -Double.infinity
    private var budget = AuditoryBudgetManager()
    private var timer: Timer?
    private var started: Double = 0
    private var yaw: Float = 0
    private var prevAngle: Double? = nil
    private var isAppeared: Bool = false
    private var lastAcceptedFrameId: UInt64 = 0
    private var lastAcceptedTimestamp: Double = 0.0
    func appear() {
        guard !isAppeared else { return }
        isAppeared = true
        if let reason = StereoCapture.unsupportedReason {
            journal.recordStereo(.init(stage: "capability", error: reason))
        }

        reconcileCapture()
        imu.startMotionTracking()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in self?.tick() }
    }

    static func unsupported(_ mode: DepthMode) -> String? {
        switch mode {
        case .midas: return nil
        case .lidar:
            return mode.unavailableReason(hasHardware: LiDARCapture.supported)
        case .stereo:
            return StereoCapture.unsupportedReason
        }
    }

    func select(_ selected: DepthMode) {
        guard Self.unsupported(selected) == nil else { return }
        guard selected != mode || selected != .midas else { return }
        mode = selected
        resetEvidence(active)
        journal.switchRequested(selected)
        exportURL = nil
        stereoPairURL = nil
        stereoDisparity = nil
        stereoDepth = nil
        stereoHealth = ""
        stereoPairFailed = false
        diagnostics = selected == .stereo ? "CAPTURE INITIALIZING" : ""
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
                self?.submit(captureToken: captureToken, timestamp: capturedAt, settle: settle) { _ in
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
                if selected == .stereo { self.journal.recordStereo(.init(stage: "permission", error: "Camera access denied")) }
                self.sourceFailed("Camera access denied")
                return
            }
            let receive: (DepthFrame, CVPixelBuffer?) -> Void = { [weak self] frame, buffer in
                guard let self else { return }
                self.submit(captureToken: captureToken, timestamp: frame.timestamp, settle: 0, previewWhilePaused: true) { evaluate in
                    let portrait = buffer.map { CIImage(cvPixelBuffer: $0).oriented(.right) }
                    let image = portrait.flatMap { self.imageContext.createCGImage($0, from: $0.extent) }
                    let observation = evaluate && frame.error == nil ? frame.spatialObservation() : nil
                    return (observation, frame, image)
                }
            }
            let fail: (String) -> Void = { [weak self] reason in
                DispatchQueue.main.async {
                    guard let self, self.captureEpoch == captureToken else { return }
                    if self.diagnostics != reason {
                        self.sourceFailed(reason)
                        self.preview = nil
                        self.stereoDisparity = nil
                        self.stereoDepth = nil
                    }
                }
            }
            if selected == .lidar {
                let source = LiDARCapture(onFrame: receive, onError: fail)
                self.lidar = source
                source.start()
            } else {
                let source = StereoCapture(onFrame: receive, onError: fail,
                    strategy: self.stereoStrategy, captureOnly: self.stereoCaptureOnly,
                    depthRequested: self.wantsStereoDepth, motionRate: { [weak self] in self?.currentYaw() ?? 0 },
                    onReset: { [weak self] in
                        DispatchQueue.main.async {
                            guard let self, self.captureEpoch == captureToken else { return }
                            self.resetEvidence(self.active)
                            self.preview = nil
                            self.stereoDisparity = nil
                            self.stereoDepth = nil
                            self.stereoPairURL = nil
                            self.stereoHealth = ""
                        }
                    }) { [weak self] event in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.journal.recordStereo(event)
                        guard self.captureEpoch == captureToken else { return }
                        if !event.message.isEmpty { self.diagnostics = event.message }
                        self.stereoHealth = Self.stereoSummary(event)
                    }
                }
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

    private var wantsStereoDepth: Bool { active || showStereoDepth || showStereoDisparity }

    private func updateStereoProcessing() {
        stereo?.setDepthRequested(wantsStereoDepth)
    }

    private func currentYaw() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return yaw
    }

    private func submit(captureToken: Int, timestamp capturedAt: Double, settle: Int, previewWhilePaused: Bool = false,
                        work: @escaping (Bool) -> (ObstacleDetectionResult?, DepthFrame?, CGImage?)) {
        lock.lock()
        guard captureEpoch == captureToken, (enabled || previewWhilePaused), !busy else {
            lock.unlock()
            return
        }
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
            let (observation, frame, image) = work(evaluate)
            var obs = observation
            var display: [MetricObstacleTracker.Track] = []
            var kinematics: KinematicsResult?
            if evaluate {
                if self.workerGeneration != token {
                    self.kin = KinematicsEngine()
                    self.tracker = MetricObstacleTracker()
                    self.workerGeneration = token
                }
                if var measured = obs {
                    if frame?.source != .midas, measured.isValid {
                        let update = self.tracker.update(measured.allObstacles, timestamp: capturedAt,
                            imageSize: CGSize(width: measured.camWidth, height: measured.camHeight), yawRate: rate)
                        measured.allObstacles = update.observations
                        measured.primaryTrackID = update.observations.first {
                            $0.x == measured.x && $0.y == measured.y && $0.distCM == measured.distCM
                        }?.id
                        display = update.display
                    }
                    obs = measured
                    kinematics = self.kin.compute(obstacleResult: measured, frameId: frameId, timestamp: capturedAt,
                        aeSettleRemaining: settle, imuYawRateRadS: rate)
                }
            }
            let inferenceMS = (CACurrentMediaTime() - began) * 1000 + (frame?.captureProcessingMS ?? 0)
            let acceptedObservation = obs
            let acceptedTracks = display
            let acceptedRisk = kinematics
            DispatchQueue.main.async {
                let now = CACurrentMediaTime()
                guard self.captureEpoch == captureToken, self.epoch.value == token,
                      frameId > self.lastAcceptedFrameId else { return }
                guard self.epoch.accepts(token, timestamp: capturedAt, now: now, after: self.lastAcceptedTimestamp) else {
                    if let frame, now - capturedAt > 0.75 {
                        self.journal.record(frame: frame, observation: nil, state: "UNAVAILABLE",
                            reason: "SOURCE_FRAME_STALE", inferenceMS: inferenceMS, endToEndMS: (now - capturedAt) * 1000)
                    }
                    return
                }
                self.lastAcceptedFrameId = frameId
                self.lastAcceptedTimestamp = capturedAt
                if let image { self.preview = image }
                if let frame {
                    self.updateDiagnostics(frame, observation: acceptedObservation, latencyMS: inferenceMS)
                }
                guard evaluate else { return }
                self.publishDecision(observation: acceptedObservation, tracks: acceptedTracks, frame: frame,
                    risk: acceptedRisk, yawRate: rate, timestamp: capturedAt, now: now, inferenceMS: inferenceMS)
            }
        }
    }

    private func updateDiagnostics(_ frame: DepthFrame, observation: ObstacleDetectionResult?, latencyMS: Double) {
        if frame.source == .stereo {
            lastStereoPreviewAt = frame.timestamp
            stereoDisparity = frame.stereoDisparity.flatMap(Self.disparityImage)
            stereoDepth = frame.stereoDepthPreview.flatMap(Self.disparityImage)
            provisionalROICM = frame.provisionalROICM
            if !stereoDiagnosticReady {
                stereoDiagnosticReady = true
                journal.switchOutcome(frame.source, outcome: "capture_ready")
            }
        }
        readiness = frame.readiness
        diagnostics = journal.label(frame: frame, observation: observation, latencyMS: latencyMS)
        if observation?.isValid == true, !modeReady {
            modeReady = true
            journal.switchOutcome(frame.source, outcome: "depth_ready")
        }
    }

    private func publishDecision(observation: ObstacleDetectionResult?, tracks: [MetricObstacleTracker.Track],
                                 frame: DepthFrame?, risk kinematics: KinematicsResult?, yawRate: Float,
                                 timestamp: Double, now: Double, inferenceMS: Double) {
        if let observation, observation.isValid, let kinematics {
            lifecycle = .running
            risk = PerceptionRisk(kinematics.threatLevel)
            result = observation
            displayTracks = tracks
            advisory = coordinator.decide(source: mode, observation: observation, risk: kinematics,
                now: now, yawRate: yawRate, previousAngle: prevAngle)
            prevAngle = advisory.status == .available ? advisory.angleDeg : nil
            let decision = budget.coordinate(obstacleResult: observation, kinematicsResult: kinematics, advisory: advisory)
            if decision.isActive {
                clearStatusCue()
                audio.update(decision: decision)
            } else if advisory.status == .unavailable {
                indicateUnavailable(now: now)
            } else {
                clearStatusCue()
                audio.update(decision: decision)
            }
        } else {
            if frame?.readiness == .depthReady { readiness = .insufficientEvidence }
            let reason = frame?.error ?? (mode == .stereo ? "INSUFFICIENT_DEPTH_COVERAGE" : "INSUFFICIENT_EVIDENCE")
            withhold(reason, at: timestamp, now: now, fault: observation?.isZeroLuxBlind == true)
        }
        if let frame {
            journal.record(frame: frame, observation: observation, state: advisory.state,
                reason: advisory.reasonCode, inferenceMS: inferenceMS, endToEndMS: (now - timestamp) * 1000,
                tracks: tracks)
        }
    }

    private func tick() {
        lock.lock()
        yaw = imu.yawRateRadS
        lock.unlock()
        let now = CACurrentMediaTime()
        if mode == .stereo, now - lastStereoPreviewAt > 0.75 {
            stereoDepth = nil
            stereoDisparity = nil
            provisionalROICM = nil
        }
        guard active else { return }
        let age = now - lastAcceptedTimestamp
        if age > 0.25 {
            result = nil
            displayTracks = []
        }
        if (lastAcceptedTimestamp > 0 && age > 0.75) || (mode != .stereo && now - started > 1.5 && lastAcceptedTimestamp == 0) {
            readiness = .stale
            withhold("SOURCE_FRAME_STALE", at: lastAcceptedTimestamp, now: now, fault: true)
        } else if unavailableSince != nil {
            indicateUnavailable(now: now)
        }
    }

    private func silentDecision() -> BudgetDecision {
        BudgetDecision(isActive: false, pan: 0, proximity: 0, distCM: .nan, ttc: .infinity,
            priorityScore: 0, volumeFactor: 0, safeDirection: "NONE", cueMode: "MUTED", threatLevel: "UNKNOWN", suppressedCount: 0)
    }

    private func indicateUnavailable(now: Double) {
        if unavailableSince == nil { unavailableSince = now }
        if let since = unavailableSince, now - since >= 0.20, lastStatusCueAt < since,
           now - lastStatusCueAt >= 2.5 {
            lastStatusCueAt = now
            statusCueUntil = now + 0.35
        }
        if now < statusCueUntil {
            audio.update(decision: BudgetDecision(isActive: true, pan: 0, proximity: 0.4, distCM: .nan,
                ttc: .infinity, priorityScore: 0, volumeFactor: 0.35, safeDirection: "NONE",
                cueMode: "SYSTEM_FAULT_TONE", threatLevel: "SENSOR_FAULT", suppressedCount: 0))
        } else {
            audio.update(decision: silentDecision())
        }
    }

    private func clearStatusCue() {
        unavailableSince = nil
        statusCueUntil = 0
    }

    private func withhold(_ reason: String, at timestamp: Double, now: Double, fault: Bool = false) {
        lifecycle = fault ? .sensorFault : .running
        risk = .unknown
        result = nil
        displayTracks = []
        prevAngle = nil
        coordinator = AdvisoryCoordinator()
        advisory = DirectionalAdvisory(state: "UNAVAILABLE", sourceTimestamp: timestamp, reasonCode: reason)
        indicateUnavailable(now: now)
    }

    func toggle() { setActive(!active) }

    private func sourceFailed(_ reason: String) {
        resetEvidence(active)
        diagnostics = reason
        if active { withhold(reason, at: 0, now: CACurrentMediaTime(), fault: true) }
        journal.switchOutcome(mode, outcome: reason)
    }

    func configureStereo(strategy: StereoDeliveryStrategy, captureOnly: Bool) {
        stereoStrategy = strategy
        stereoCaptureOnly = captureOnly
        select(.stereo)
    }

    private static func stereoSummary(_ event: StereoCapture.Event) -> String {
        let format = [event.formatA, event.formatB].map { $0.split(separator: "/").first.map(String.init) ?? "?" }
        let profile = "\(event.pair) \(format.joined(separator: " / ")) @ \(event.fps) • \(event.strategy)"
        guard let stats = event.telemetry else { return event.stage + " • " + profile }
        let a = stats.cameras[0], b = stats.cameras[1]
        let statusA = a.samples > 0 ? "CAMERA A READY" : "A waiting"
        let statusB = b.samples > 0 ? "CAMERA B READY" : "B waiting"
        let rejected = stats.rejectionFraction * 100
        let skew = [stats.medianSkewMS ?? stats.candidateMedianSkewMS, stats.p95SkewMS ?? stats.candidateP95SkewMS].map { $0.map { String(format: "%.1f", $0) } ?? "–" }
        return profile + "\n" + event.stage + " • " + statusA + " / " + statusB + "\n"
            + String(format: "A %.1f / B %.1f / pair %.1f FPS • reject %.0f%%", a.fps, b.fps, stats.pairFPS, rejected)
            + "\n" + (stats.medianSkewMS == nil ? "Candidate" : "Paired") + " skew median/P95 " + skew.joined(separator: "/") + " ms"
    }

    private static func disparityImage(_ disparity: StereoDisparityPreview) -> CGImage? {
        guard let provider = CGDataProvider(data: disparity.pixels as CFData) else { return nil }
        return CGImage(width: disparity.width, height: disparity.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: disparity.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func captureCalibrationPair(_ completion: @escaping (URL?) -> Void) {
        guard mode == .stereo, let stereo else { completion(nil); return }
        let token = captureEpoch
        stereo.requestPair(calibration: true) { [weak self] url in
            guard self?.captureEpoch == token else { completion(nil); return }
            completion(url)
        }
    }

    func importStereoCalibration(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 else { throw CalibrationImportError(message: "Invalid profile file size") }
        let data = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(StereoCalibration.self, from: data)
        let issues = profile.validationIssues()
        guard issues.isEmpty else { throw CalibrationImportError(message: issues.joined(separator: "\n")) }
        try profile.save(data)
        select(.stereo)
    }

    private struct CalibrationImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func captureStereoPair() {
        guard let stereo else { return }
        stereoPairURL = nil
        stereoPairFailed = false
        let token = captureEpoch
        stereo.requestPair { [weak self] url in
            guard let self, self.captureEpoch == token else { return }
            self.stereoPairURL = url
            self.stereoPairFailed = url == nil
        }
    }

    func prepareExport() {
        do { exportURL = try journal.export() }
        catch { diagnostics = "Export failed: \(error.localizedDescription)" }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        resetEvidence(value)
        if mode == .midas {
            camera.setGuidanceActive(value)
            if !value { camera.forceTorchOff() }
        }
        if value { audio.start() } else { audio.stop() }
        updateStereoProcessing()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func resetEvidence(_ value: Bool) {
        lock.lock()
        epoch.invalidate()
        enabled = value
        lock.unlock()
        active = value
        lifecycle = value ? .initializing : .paused
        readiness = .captureReady
        risk = .unknown
        modeReady = false
        stereoDiagnosticReady = false
        coordinator = AdvisoryCoordinator()
        budget = AuditoryBudgetManager()
        result = nil
        displayTracks = []
        provisionalROICM = nil
        advisory = DirectionalAdvisory()
        prevAngle = nil
        lastAcceptedFrameId = 0
        lastAcceptedTimestamp = 0
        started = CACurrentMediaTime()
        clearStatusCue()
        lastStatusCueAt = -.infinity
        audio.update(decision: silentDecision())
    }

    func disappear() {
        guard isAppeared else { return }
        isAppeared = false

        camera.setGuidanceActive(false)
        camera.forceTorchOff()
        setActive(false); timer?.invalidate(); timer = nil
        preview = nil
        stereoDisparity = nil
        stereoHealth = ""
        diagnostics = ""
        restartCapture(); imu.stopMotionTracking(); audio.stop()
    }
}


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
    @State private var diagnosticsSheet = false
    @State private var calibrationSheet = false
    @State private var calibrationImporter = false
    @State private var calibrationError: String?
    @Environment(\.scenePhase) private var scenePhase

    private var showingDepth: Bool {
        model.mode == .stereo && (model.showStereoDepth || model.showStereoDisparity)
    }

    var body: some View {
        VStack(spacing: 12) {
            camera
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityElement(children: .contain)

            HStack(spacing: 4) {
                ForEach(DepthMode.allCases) { mode in
                    let unsupported = DemoController.unsupported(mode)
                    Button { model.select(mode) } label: {
                        Text(mode.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(model.mode == mode ? Color.white.opacity(0.17) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(unsupported != nil)
                    .foregroundStyle(unsupported == nil ? Color.primary : Color.secondary)
                    .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
                    .accessibilityHint(unsupported ?? "Select depth source")
                }
            }
            .padding(3)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            if model.mode == .stereo && (model.readiness == .calibrationRequired || model.readiness == .calibrationInvalid) {
                Button { openCalibration() } label: {
                    Label(model.readiness == .calibrationInvalid ? "Review Stereo calibration" : "Calibrate Stereo",
                          systemImage: "viewfinder")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
            }
            runControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $calibrationSheet) { StereoCalibrationView(model: model) }
        .sheet(isPresented: $diagnosticsSheet) { diagnostics }
        .fileImporter(isPresented: $calibrationImporter, allowedContentTypes: [.json]) { result in
            do { try model.importStereoCalibration(result.get()) }
            catch let error as CocoaError where error.code == .userCancelled { return }
            catch { calibrationError = error.localizedDescription }
        }
        .alert("Calibration import", isPresented: Binding(get: { calibrationError != nil },
              set: { if !$0 { calibrationError = nil } })) {
            Button("OK", role: .cancel) { calibrationError = nil }
        } message: {
            Text(calibrationError ?? "")
        }
        .onAppear { if scenePhase == .active { model.appear() } }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.appear() }
            else { model.disappear() }
        }
    }

    private var camera: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                if showingDepth {
                    let image = model.showStereoDepth ? model.stereoDepth : model.stereoDisparity
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.none).scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Text(model.showStereoDepth ? "Calibrated depth unavailable" : "Disparity unavailable")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if model.mode == .midas {
                    CameraPreviewView(session: model.camera.session)
                } else if let preview = model.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .background(Color(white: 0.07))

            if !showingDepth {
                TrackingOverlayView(result: model.result, tracks: model.displayTracks,
                    risk: model.risk, mode: model.mode, isStop: model.advisory.status == .stop)
            }

            DirectionIndicator(advisory: model.advisory, lifecycle: model.lifecycle, risk: model.risk)
                .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if model.mode == .midas {
                    FlashlightButton(isTorchActive: model.camera.isTorchActive) {
                        model.camera.toggleManualTorch()
                    }
                }
                Menu {
                    Button { diagnosticsSheet = true } label: { Label("Research diagnostics", systemImage: "waveform.path") }
                    if model.mode == .stereo {
                        Button { openCalibration() } label: { Label("Acquire calibration dataset", systemImage: "viewfinder") }
                        Button { calibrationImporter = true } label: { Label("Import calibration profile", systemImage: "square.and.arrow.down") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Camera options")
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    private func openCalibration() {
        model.setActive(false)
        calibrationSheet = true
    }

    @ViewBuilder private var runControl: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Button(action: model.toggle) { runLabel }
                .buttonStyle(.glassProminent)
                .tint(.white)
        } else {
            legacyRunControl
        }
        #else
        legacyRunControl
        #endif
    }

    private var legacyRunControl: some View {
        Button(action: model.toggle) { runLabel }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.white)
    }

    private var runLabel: some View {
        Label(model.active ? "T?m d?ng" : "B?t ??u", systemImage: model.active ? "pause.fill" : "play.fill")
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityHint(model.active ? "Stops guidance and audio" : "Starts obstacle perception and guidance")
    }

    private var diagnostics: some View {
        NavigationStack {
            Form {
                Section(model.mode.rawValue) {
                    Text(model.diagnostics.isEmpty ? "Waiting for frames" : model.diagnostics)
                        .font(.footnote.monospacedDigit())
                    Text(model.advisory.reasonCode)
                        .font(.caption.monospaced())
                    if model.mode == .stereo {
                        Text(model.stereoHealth.isEmpty ? "Waiting for synchronized capture" : model.stereoHealth)
                            .font(.footnote.monospacedDigit())
                        if let value = model.provisionalROICM {
                            Text("Unvalidated factory estimate, central region: \(value, specifier: "%.0f") cm")
                        }
                    }
                }
                if model.mode == .stereo {
                    Section("Stereo research controls") {
                        Toggle("Show disparity", isOn: $model.showStereoDisparity)
                            .onChange(of: model.showStereoDisparity) { if $0 { model.showStereoDepth = false } }
                        Toggle("Show calibrated depth", isOn: $model.showStereoDepth)
                            .onChange(of: model.showStereoDepth) { if $0 { model.showStereoDisparity = false } }
                        Picker("Delivery", selection: Binding(get: { model.stereoStrategy },
                               set: { model.configureStereo(strategy: $0, captureOnly: model.stereoCaptureOnly) })) {
                            ForEach(StereoDeliveryStrategy.allCases) { strategy in Text(strategy.rawValue).tag(strategy) }
                        }
                        Toggle("Capture only", isOn: Binding(get: { model.stereoCaptureOnly },
                               set: { model.configureStereo(strategy: model.stereoStrategy, captureOnly: $0) }))
                        Button("Capture synchronized pair") { model.captureStereoPair() }
                        if model.stereoPairFailed { Text("Pair unavailable") }
                        if let url = model.stereoPairURL { ShareLink("Share pair", item: url) }
                    }
                }
                Section("Telemetry") {
                    Button("Prepare CSV export") { model.prepareExport() }
                    if let url = model.exportURL { ShareLink("Share CSV", item: url) }
                }
            }
            .navigationTitle("Research diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { diagnosticsSheet = false } }
        }
    }
}

struct DirectionIndicator: View {
    let advisory: DirectionalAdvisory
    let lifecycle: PerceptionLifecycle
    let risk: PerceptionRisk

    var body: some View {
        if lifecycle == .running, let angle = advisory.drawableAngle(now: CACurrentMediaTime()) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, risk == .critical ? Color.red : risk == .warning ? .orange : .white)
                .rotationEffect(.degrees(angle))
                .accessibilityLabel(angle < -2 ? "Direction left" : angle > 2 ? "Direction right" : "Direction ahead")
        } else {
            Label(status.0, systemImage: status.1)
                .font(.callout.weight(.semibold))
                .foregroundStyle(status.2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var status: (String, String, Color) {
        if lifecycle == .paused { return ("T?m d?ng", "pause.fill", .white) }
        if lifecycle == .initializing { return ("?ang kh?i ??ng", "hourglass", .white) }
        if advisory.isFreshStop(now: CACurrentMediaTime()) { return ("D?ng l?i", "hand.raised.fill", .red) }
        if risk == .critical { return ("Nguy hi?m ? Ch?a r? h??ng", "exclamationmark.triangle.fill", .red) }
        if risk == .warning || risk == .unresolved { return ("C?n th?n ? Ch?a r? h??ng", "exclamationmark.triangle", .orange) }
        if lifecycle == .sensorFault { return ("C?m bi?n gi?n ?o?n", "sensor.fill", .white) }
        return ("Ch?a ?? d? li?u", "minus.circle", .white)
    }
}
