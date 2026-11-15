import ARKit
import AVFoundation
import QuartzCore
import UIKit
import simd

final class LiDARCapture: NSObject, ARSessionDelegate {
    static var supported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private let session = ARSession()
    private var running = false
    private let queue = DispatchQueue(label: "com.visef.lidar", qos: .userInitiated)
    let onFrame: (DepthFrame, CVPixelBuffer?) -> Void
    let onError: (String) -> Void

    init(onFrame: @escaping (DepthFrame, CVPixelBuffer?) -> Void,
         onError: @escaping (String) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
        super.init()
    }

    func start() {
        running = true
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        session.delegateQueue = queue
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        running = false
        session.delegate = nil
        session.pause()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onError(error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onError("LiDAR session interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.start()
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let image = frame.capturedImage
        let landscapeWidth = CVPixelBufferGetWidth(image)
        let landscapeHeight = CVPixelBufferGetHeight(image)
        let k = frame.camera.intrinsics
        // ARKit provides registered depth in camera-image coordinates. Rotate both
        // image and grid clockwise for the app's portrait coordinate system.
        let geometry = DepthGeometry(width: landscapeHeight, height: landscapeWidth,
                                     fx: k.columns.1.y, cx: Float(landscapeHeight - 1) - k.columns.2.y)
        guard let measurement = frame.sceneDepth, let confidence = measurement.confidenceMap else {
            onFrame(DepthFrame(source: .lidar, timestamp: frame.timestamp, geometry: geometry,
                               width: 0, height: 0, centimeters: [], confidence: [],
                               detail: "Raw scene depth", error: "Awaiting scene depth"), image)
            return
        }

        let depth = measurement.depthMap
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        let w = CVPixelBufferGetWidth(depth)
        let h = CVPixelBufferGetHeight(depth)
        guard CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h,
              let meters = CVPixelBufferGetBaseAddress(depth),
              let levels = CVPixelBufferGetBaseAddress(confidence) else { return }
        let depthStride = CVPixelBufferGetBytesPerRow(depth)
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        var cm = [Float](repeating: .nan, count: w * h)
        var quality = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let depthRow = meters.advanced(by: y * depthStride).assumingMemoryBound(to: Float.self)
            let confidenceRow = levels.advanced(by: y * confidenceStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let index = x * h + (h - 1 - y)
                quality[index] = confidenceRow[x]
                cm[index] = DepthFrame.centimeters(meters: depthRow[x], confidence: quality[index])
            }
        }
        onFrame(DepthFrame(source: .lidar, timestamp: frame.timestamp, geometry: geometry,
                           width: h, height: w, centimeters: cm, confidence: quality,
                           detail: "Raw scene depth"), image)
    }
}

final class StereoCapture: NSObject {
    private static var pairs: [(AVCaptureDevice, AVCaptureDevice)] {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return [] }
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        let sets = discovery.supportedMultiCamDeviceSets.map { Set($0.filter { $0.position == .back }) }
        let names = sets.map { Set($0.map { cameraName($0) }) }
        return StereoNegotiation.supportedPairs(in: names).compactMap { names in
            for set in sets {
                if let a = set.first(where: { cameraName($0) == names[0] }),
                   let b = set.first(where: { cameraName($0) == names[1] }) { return (a, b) }
            }
            return nil
        }
    }

    private static func cameraName(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInWideAngleCamera: return "wide"
        case .builtInUltraWideCamera: return "ultrawide"
        case .builtInTelephotoCamera: return "tele"
        default: return device.deviceType.rawValue
        }
    }

    static let unsupportedReason: String? = {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return "Stereo: MultiCam unsupported" }
        return pairs.isEmpty ? "Stereo: no supported rear physical camera pair" : nil
    }()

    private struct Plan {
        let a: AVCaptureDevice
        let b: AVCaptureDevice
        let formatA: AVCaptureDevice.Format
        let formatB: AVCaptureDevice.Format
        let candidate: StereoNegotiation.Candidate
        var name: String { StereoCapture.cameraName(a) + "/" + StereoCapture.cameraName(b) }
    }

    struct Event {
        let stage: String
        var message = ""
        var error = ""
        var pair = ""
        var formatA = ""
        var formatB = ""
        var fps = ""
        var configured = false
        var hardware = ""
        var pressure = ""
        var pressureLevel = ""
        var accepted = 0
        var rejected = 0
        var pairFPS = 0.0
        var strategy = ""
        var telemetry: StereoIngress.Status?
    }

    private struct SetupError: LocalizedError {
        let stage: String
        let errorDescription: String?
        init(_ stage: String, _ reason: String) { self.stage = stage; self.errorDescription = reason }
    }

    private let session = AVCaptureMultiCamSession()
    private let queue = DispatchQueue(label: "com.visef.stereo", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.visef.stereo.processing", qos: .userInitiated)
    private var processingBusy = false
    private let leftOutput = AVCaptureVideoDataOutput()
    private let rightOutput = AVCaptureVideoDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var ingress: StereoIngress?
    private var streamDelegates: [StereoIngress.Delegate] = []
    private var phase: StereoDeliveryPhase = .synchronizer
    private var status: StereoIngress.Status?
    private var attemptID = 0
    private var downstreamEnabled = false
    private var negotiationDeadline = Double.infinity
    private let strategy: StereoDeliveryStrategy
    private let captureOnly: Bool
    let onReset: () -> Void
    private var devices: [AVCaptureDevice] = []
    private var extrinsics: simd_float4x3?
    private var observers: [NSObjectProtocol] = []
    private var calibration: StereoCalibration?
    private var snapshot: (id: UUID, completion: (URL?) -> Void)?
    private var processingMS: Double = 0
    private var previousPairTime = -Double.infinity
    private var cameraState: [(device: AVCaptureDevice, format: AVCaptureDevice.Format,
                               min: CMTime, max: CMTime, focus: AVCaptureDevice.FocusMode,
                               lensPosition: Float)] = []
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var plans: [Plan] = []
    private var current: Plan?
    private var planIndex = 0
    private var configured = false
    private var captureReady = false
    private var installedAt = 0.0
    private var lastHealthLog = 0.0
    private var geometryStatus = ""
    private var captureSignature: [String] = []
    private var finalFailure = "No viable capture configuration"
    let onEvent: (Event) -> Void
    let onFrame: (DepthFrame, CVPixelBuffer?) -> Void
    let onError: (String) -> Void

    init(onFrame: @escaping (DepthFrame, CVPixelBuffer?) -> Void,
         onError: @escaping (String) -> Void, strategy: StereoDeliveryStrategy, captureOnly: Bool,
         onReset: @escaping () -> Void, onEvent: @escaping (Event) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
        self.onEvent = onEvent
        self.strategy = strategy
        self.captureOnly = captureOnly
        self.onReset = onReset
    }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    func start() {
        queue.async {
            guard !self.isCancelled else { return }
            if let reason = Self.unsupportedReason {
                self.onEvent(Event(stage: "capability", error: reason))
                self.onError(reason)
                return
            }
            self.calibration = (try? Data(contentsOf: StereoCalibration.file)).flatMap {
                try? JSONDecoder().decode(StereoCalibration.self, from: $0)
            }
            let pairs = Self.pairs
            self.onEvent(Event(stage: "capability", pair: pairs.map {
                Self.cameraName($0.0) + "/" + Self.cameraName($0.1)
            }.joined(separator: ", ")))
            let requested = self.calibration?.pair
            let preferred = pairs.filter { [$0.0.uniqueID, $0.1.uniqueID] == requested }
            let ranked = preferred + pairs.filter { [$0.0.uniqueID, $0.1.uniqueID] != requested }
            var alternatives: [[Plan]] = []
            for (a, b) in ranked {
                let af = a.formats, bf = b.formats
                let pair = Self.cameraName(a) + "/" + Self.cameraName(b)
                let signatures = [a.uniqueID, b.uniqueID] == requested ? self.calibration?.captureSignature?.compactMap { $0.split(separator: "|").first.map(String.init) } : nil
                let candidates = StereoNegotiation.candidates(af.enumerated().map { Self.describe($0.element, id: $0.offset) },
                    bf.enumerated().map { Self.describe($0.element, id: $0.offset) }, preferred: signatures)
                if candidates.isEmpty {
                    self.onEvent(Event(stage: "formats", error: "No shared supported frame duration", pair: pair))
                }
                let primary = candidates.filter { [30, 24, 15].contains($0.rate.fps) }
                let filtered = Array(primary.prefix(3))
                let prioritized = filtered + candidates.filter { !filtered.contains($0) }
                alternatives.append(prioritized.prefix(5).map {
                    Plan(a: a, b: b, formatA: af[$0.a], formatB: bf[$0.b], candidate: $0)
                })
            }
            self.plans = (0..<5).flatMap { index in alternatives.compactMap { $0.count > index ? $0[index] : nil } }
            self.negotiationDeadline = CACurrentMediaTime() + 35
            if self.plans.isEmpty { self.finalFailure = "No shared supported MultiCam format and frame rate" }
            self.tryNext()
        }
    }

    private func tryNext() {
        guard !isCancelled else { return }
        guard planIndex < plans.count, CACurrentMediaTime() < negotiationDeadline else {
            onError("Stereo: \(finalFailure). See CSV for attempts.")
            return
        }
        let plan = plans[planIndex]
        planIndex += 1
        startAttempt(plan, phase: strategy.phases(probeLateDrops: false)[0])
    }

    private func startAttempt(_ plan: Plan, phase: StereoDeliveryPhase) {
        guard !isCancelled else { return }
        if CACurrentMediaTime() >= negotiationDeadline {
            onError("Stereo: \(finalFailure). Retry budget exhausted. See CSV.")
            return
        }
        current = plan
        self.phase = phase
        attemptID += 1
        devices = [plan.a, plan.b]
        let duration = CMTime(value: plan.candidate.rate.interval, timescale: plan.candidate.rate.frames)
        do {
            try configure(plan, duration: duration)
        } catch let error as SetupError {
            reject(stage: error.stage, error: error.localizedDescription)
            return
        } catch {
            reject(stage: "configuration", error: error.localizedDescription)
            return
        }
        configured = true
        guard session.hardwareCost <= 1 else { reject(stage: "hardware_cost", error: "Hardware cost exceeds 1"); return }
        guard !overPressure else { reject(stage: "pressure", error: "Camera pressure exceeds sustainable limits"); return }
        guard !isCancelled else { return }

        session.automaticallyConfiguresApplicationAudioSession = false
        let ingress = StereoIngress(session: session, a: leftOutput, b: rightOutput, phase: phase)
        self.ingress = ingress
        if phase == .independent {
            streamDelegates = StereoCamera.allCases.map { StereoIngress.Delegate(ingress, camera: $0) }
            leftOutput.setSampleBufferDelegate(streamDelegates[0], queue: ingress.queue)
            rightOutput.setSampleBufferDelegate(streamDelegates[1], queue: ingress.queue)
        } else {
            let data = AVCaptureDataOutputSynchronizer(dataOutputs: [leftOutput, rightOutput])
            synchronizer = data
            data.setDelegate(ingress, queue: ingress.queue)
        }
        let attempt = attemptID
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                let interrupted = note.name == AVCaptureSession.wasInterruptedNotification
                let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                    ?? (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber).map { "Interruption reason \($0)" }
                    ?? (interrupted ? "Camera interrupted" : "AVFoundation runtime error")
                self?.queue.async { [weak self] in
                    guard let self, !self.isCancelled, self.attemptID == attempt, self.current != nil else { return }
                    self.reject(stage: interrupted ? "interrupted" : "runtime", error: detail, retry: !interrupted)
                }
            }
            observers.append(observer)
        }
        session.startRunning()
        status = ingress.read(takePair: false, now: CACurrentMediaTime()).0
        guard session.isRunning else { reject(stage: "start", error: "Session did not start"); return }
        installedAt = CACurrentMediaTime()
        emit("waiting", message: "Stereo: \(plan.name) • PAIRING ACTIVE (\(phase.rawValue))")
        watch(attempt: attempt)
    }

    private func configure(_ plan: Plan, duration: CMTime) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        captureSignature = [
            try connect(plan.a, format: plan.formatA, duration: duration, output: leftOutput, side: "A"),
            try connect(plan.b, format: plan.formatB, duration: duration, output: rightOutput, side: "B")
        ]
        // Apply profile focus only to the recorded camera/format geometry.
        if calibration?.pair == devices.map(\.uniqueID), calibration?.matchesCapture(captureSignature) == true {
            lockCalibrationFocus()
        }
        extrinsics = Self.matrix(AVCaptureDevice.extrinsicMatrix(from: plan.a, to: plan.b), as: simd_float4x3.self)
    }

    private var overPressure: Bool {
        session.systemPressureCost > 1 || devices.contains {
            [.serious, .critical, .shutdown].contains($0.systemPressureState.level)
        }
    }

    private func watch(attempt: Int) {
        queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, !self.isCancelled, self.attemptID == attempt,
                  let plan = self.current, let ingress = self.ingress else { return }
            let now = CACurrentMediaTime()
            let takePair = self.phase != .lateDropProbe && !self.processingBusy
                && (self.snapshot != nil || (self.downstreamEnabled && !self.captureOnly))
            let (status, pair) = ingress.read(takePair: takePair, now: now)
            self.status = status
            if self.overPressure {
                self.reject(stage: "pressure", error: "Camera pressure rose during capture")
                return
            }
            if !self.session.isRunning {
                self.reject(stage: "runtime", error: "Session stopped")
                return
            }

            let elapsed = now - self.installedAt
            let ready = status.ready && status.pairFPS >= max(3, plan.candidate.rate.fps * 0.3)
            if !self.captureReady && ready {
                self.captureReady = true
                if self.phase == .lateDropProbe {
                    self.emit("probe_capture_ready")
                } else {
                    self.emit("capture_ready", message: "STEREO CAPTURE READY")
                }
            }
            // Brief capture-only baseline on every attempt. A no-drop experiment
            // remains capture-only and always ends with the default restored.
            if ready && elapsed >= 0.8 && self.phase != .lateDropProbe { self.downstreamEnabled = true }
            if self.phase == .lateDropProbe && elapsed >= 1.2 {
                self.reject(stage: "late_drop_probe", error: status.failure)
                return
            }
            if !self.captureReady && elapsed >= 2.5 {
                self.reject(stage: "synchronization", error: status.failure)
                return
            }
            if self.captureReady && (status.lastPairHost.map { now - $0 > 1 } ?? true) {
                self.reject(stage: "synchronization", error: "Synchronized delivery stopped")
                return
            }
            if now - self.lastHealthLog >= (self.captureReady ? 2 : 1) {
                self.lastHealthLog = now
                self.emit("health")
            }
            if ready, self.downstreamEnabled, let pair { self.processPair(pair, attempt: attempt) }
            self.watch(attempt: attempt)
        }
    }

    private func reject(stage: String, error: String, retry: Bool = true) {
        finalFailure = error
        let plan = current
        let late = status?.cameras.contains { ($0.dropped["lateData"] ?? 0) >= 3 } ?? false
        let samePlanPhases = strategy.phases(probeLateDrops: late || phase == .lateDropProbe)
        let nextPhase = samePlanPhases.firstIndex(of: phase).flatMap { index in
            index + 1 < samePlanPhases.count ? samePlanPhases[index + 1] : nil
        }
        let mayChangePhase = ["start", "runtime", "synchronization", "late_drop_probe"].contains(stage)
        let next = mayChangePhase ? nextPhase : nil
        let retrying = retry && CACurrentMediaTime() < negotiationDeadline && (next != nil || planIndex < plans.count)
        if !isCancelled {
            emit(stage, message: retrying ? "Stereo: \(error) • trying next configuration" : "", error: error)
            if captureReady { onReset() }
        }
        guard tearDown() else {
            if !isCancelled { onError("Stereo: camera settings could not be restored. Reselect Stereo to retry.") }
            return
        }
        if retrying {
            queue.async { [weak self] in
                guard let self else { return }
                if let plan, let next { self.startAttempt(plan, phase: next) }
                else { self.tryNext() }
            }
        } else if !isCancelled {
            onError("Stereo: \(error). See CSV for attempts.")
        }
    }

    private func emit(_ stage: String, message: String = "", error: String = "") {
        onEvent(Event(stage: stage, message: message, error: error, pair: current?.name ?? "",
            formatA: captureSignature.first ?? current.map { Self.describe($0.formatA, id: 0).signature } ?? "",
            formatB: captureSignature.last ?? current.map { Self.describe($0.formatB, id: 0).signature } ?? "",
            fps: current.map { String(format: "%.3f", $0.candidate.rate.fps) } ?? "",
            configured: configured, hardware: String(session.hardwareCost), pressure: String(session.systemPressureCost),
            pressureLevel: devices.map { $0.systemPressureState.level.rawValue }.joined(separator: "/"),
            accepted: status?.accepted ?? 0, rejected: status?.rejected ?? 0, pairFPS: status?.pairFPS ?? 0,
            strategy: current == nil ? "" : phase.rawValue, telemetry: status))
    }

    func stop(completion: @escaping () -> Void) {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        queue.async {
            if self.current != nil { self.emit("stopped") }
            _ = self.tearDown()
            self.plans.removeAll()
            self.snapshot = nil
            DispatchQueue.main.async(execute: completion)
        }
    }

    @discardableResult
    private func tearDown() -> Bool {
        synchronizer?.setDelegate(nil, queue: nil)
        synchronizer = nil
        leftOutput.setSampleBufferDelegate(nil, queue: nil)
        rightOutput.setSampleBufferDelegate(nil, queue: nil)
        ingress?.finish()
        ingress = nil
        streamDelegates.removeAll()
        status = nil
        downstreamEnabled = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if session.isRunning { session.stopRunning() }
        let restored = restoreFormats()
        current = nil
        devices.removeAll()
        extrinsics = nil
        configured = false
        geometryStatus = ""
        captureSignature.removeAll()
        captureReady = false
        previousPairTime = -.infinity
        lastHealthLog = 0
        processingMS = 0
        return restored
    }

    private func lockCalibrationFocus() {
        for (index, device) in devices.enumerated() {
            guard device.isFocusModeSupported(.locked),
                  (try? device.lockForConfiguration()) != nil else { continue }
            let lens = index == 0 ? calibration?.left : calibration?.right
            if calibration?.pair == devices.map(\.uniqueID), let position = lens?.position,
               (0...1).contains(position), device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: position)
            }
            device.unlockForConfiguration()
        }
    }

    private func restoreFormats() -> Bool {
        session.beginConfiguration()
        for connection in session.connections { session.removeConnection(connection) }
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()

        let pending = Array(cameraState.reversed())
        cameraState.removeAll()
        for state in pending {
            do {
                try state.device.lockForConfiguration()
                defer { state.device.unlockForConfiguration() }
                state.device.activeFormat = state.format
                state.device.activeVideoMinFrameDuration = state.min
                state.device.activeVideoMaxFrameDuration = state.max
                if state.focus == .locked, state.device.isLockingFocusWithCustomLensPositionSupported {
                    state.device.setFocusModeLocked(lensPosition: state.lensPosition)
                } else if state.device.isFocusModeSupported(state.focus) {
                    state.device.focusMode = state.focus
                }
            } catch {
                cameraState.append(state)
                emit("rollback", error: error.localizedDescription)
            }
        }
        return cameraState.isEmpty
    }

    private static func describe(_ format: AVCaptureDevice.Format, id: Int) -> StereoNegotiation.Format {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return StereoNegotiation.Format(id: id, multicam: format.isMultiCamSupported,
            width: Int(size.width), height: Int(size.height), pixelFormat: CMFormatDescriptionGetMediaSubType(format.formatDescription),
            binned: format.isVideoBinned, fov: Double(format.videoFieldOfView),
            rates: StereoNegotiation.Rate.candidates.filter { rate in
                let duration = CMTime(value: rate.interval, timescale: rate.frames)
                return format.videoSupportedFrameRateRanges.contains {
                    CMTimeCompare(duration, $0.minFrameDuration) >= 0 && CMTimeCompare(duration, $0.maxFrameDuration) <= 0
                }
            })
    }

    private func connect(_ device: AVCaptureDevice, format: AVCaptureDevice.Format, duration: CMTime,
                         output: AVCaptureVideoDataOutput, side: String) throws -> String {
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw SetupError("input_\(side)", error.localizedDescription) }
        guard session.canAddInput(input) else { throw SetupError("input_\(side)", "Session rejected camera input \(side)") }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            cameraState.append((device, device.activeFormat, device.activeVideoMinFrameDuration,
                                device.activeVideoMaxFrameDuration, device.focusMode, device.lensPosition))
            device.activeFormat = format
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch { throw SetupError("device_\(side)", error.localizedDescription) }
        session.addInputWithNoConnections(input)
        input.videoMinFrameDurationOverride = duration

        output.videoSettings = [:]
        output.alwaysDiscardsLateVideoFrames = phase != .lateDropProbe
        guard session.canAddOutput(output) else { throw SetupError("output_\(side)", "Session rejected video output \(side)") }
        session.addOutputWithNoConnections(output)
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            throw SetupError("port_\(side)", "Camera \(side) has no video port")
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw SetupError("connection_\(side)", "Session rejected video connection \(side)")
        }
        session.addConnection(connection)
        let formats = output.availableVideoPixelFormatTypes
        let choices = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        guard let pixelFormat = choices.first(where: { formats.contains($0) }) else {
            throw SetupError("pixel_format_\(side)", "Camera \(side) exposes no supported 8-bit luma output")
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
        connection.isEnabled = true
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
        return Self.describe(format, id: 0).signature + "|\(pixelFormat)|landscapeRight|\(device.videoZoomFactor)"
    }

    private func processPair(_ pair: StereoIngress.Pair, attempt: Int) {
        let timestamp = pair.a.host
        guard !processingBusy, (-0.05...0.45).contains(CACurrentMediaTime() - timestamp),
              snapshot != nil || timestamp - previousPairTime >= max(0.12, processingMS / 1000 * 2) else { return }
        processingBusy = true
        previousPairTime = timestamp
        let a = pair.a.buffer, b = pair.b.buffer
        let aK = pair.a.intrinsics, bK = pair.b.intrinsics
        let ext = extrinsics
        let ids = devices.map(\.uniqueID)
        let positions = devices.map(\.lensPosition)
        let focused = devices.allSatisfy { !$0.isAdjustingFocus }
        let calibration = self.calibration
        let captureSignature = self.captureSignature
        let width = processingMS > 95 ? 192 : 256
        let pending = snapshot
        let captureOnly = self.captureOnly
        let phase = self.phase.rawValue
        processingQueue.async { [weak self] in
            let (frame, url) = Self.process(a, b, timestamp: timestamp, aK: aK, bK: bK, ext: ext,
                ids: ids, positions: positions, focused: focused, calibration: calibration,
                captureSignature: captureSignature, width: width, export: pending != nil,
                captureOnly: captureOnly, pair: pair, strategy: phase)
            guard let self else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.queue.async {
                self.processingBusy = false
                guard !self.isCancelled, self.attemptID == attempt, self.captureReady, self.status?.ready == true,
                      self.current != nil, !self.overPressure else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.processingMS = frame.captureProcessingMS
                if frame.detail.contains("Intrinsics or extrinsics unavailable"), self.geometryStatus != frame.detail {
                    self.emit("geometry_unavailable", error: frame.detail)
                }
                self.geometryStatus = frame.detail
                if let pending, self.snapshot?.id == pending.id, let url {
                    self.snapshot = nil
                    DispatchQueue.main.async { pending.completion(url) }
                } else if let url {
                    try? FileManager.default.removeItem(at: url)
                }
                if !captureOnly { self.onFrame(frame, a) }
            }
        }
    }

    private static func process(_ a: CVPixelBuffer, _ b: CVPixelBuffer, timestamp: Double,
                                aK: simd_float3x3?, bK: simd_float3x3?, ext: simd_float4x3?,
                                ids: [String], positions: [Float], focused: Bool, calibration: StereoCalibration?,
                                captureSignature: [String], width: Int, export: Bool, captureOnly: Bool,
                                pair: StereoIngress.Pair, strategy: String) -> (DepthFrame, URL?) {
        let began = CACurrentMediaTime()
        var exportURL: URL?
        var preview: StereoDisparityPreview?
        let geometry = DepthGeometry(width: CVPixelBufferGetHeight(a), height: CVPixelBufferGetWidth(a),
                                     fx: aK?.columns.1.y ?? .nan,
                                     cx: Float(CVPixelBufferGetHeight(a) - 1) - (aK?.columns.2.y ?? .nan))
        var detail = "Intrinsics or extrinsics unavailable"
        var error: String? = "Distance unavailable"
        let mapWidth = 48
        let mapHeight = 64
        var cm = [Float](repeating: .nan, count: mapWidth * mapHeight)
        var confidence = [UInt8](repeating: 0, count: cm.count)
        var exportedDisparity: (pixels: [Float?], width: Int, height: Int, focal: Float)?
        if !captureOnly, let ext, let aK, let bK, let rect = StereoCalibration.rectification(ext) {

            let verified = calibration.flatMap { profile -> StereoCalibration? in
                guard profile.matchesCapture(captureSignature),
                      profile.verified(for: ids, factoryBaselineMM: rect.baseline),
                      profile.left.matches(width: CVPixelBufferGetWidth(a), height: CVPixelBufferGetHeight(a),
                                           intrinsics: aK, position: positions[0]),
                      profile.right.matches(width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b),
                                            intrinsics: bK, position: positions[1]),
                      focused else { return nil }
                return profile
            }
            let w = width
            let h = w * 3 / 4
            let focal = aK.columns.0.x * Float(w) / Float(CVPixelBufferGetWidth(a))
            if let first = Self.warp(a, rotation: rect.basis, k: aK, lens: verified?.left, focal: focal, w: w, h: h),
               let second = Self.warp(b, rotation: rect.rotation * rect.basis, k: bK, lens: verified?.right, focal: focal, w: w, h: h) {
                let search = max(8, Int(min(Float(w / 3), (focal * rect.baseline / 230).rounded(.up))))
                let brightnessSamples = stride(from: 0, to: first.count, by: 29).map { first[$0] }.filter { $0 >= 0 }
                let brightEnough = !brightnessSamples.isEmpty
                    && brightnessSamples.reduce(0, +) >= 12 * brightnessSamples.count
                var disparities: [Float] = []
                var disparityImage = [UInt8](repeating: 0, count: w * h)
                var disparityGrid = !export ? [] : [Float?](repeating: nil, count: w * h)
                let step = w == 256 ? 3 : 2
                for row in stride(from: 2, to: h - 2, by: step) {
                    for col in stride(from: 2, to: w - 2, by: step) {
                        guard let d = StereoCorrespondence.matchDisparity(left: first, right: second,
                            width: w, height: h, x: col, y: row, maxShift: search) else { continue }
                        disparities.append(d)
                        let intensity = UInt8(min(255, max(24, Int(d / Float(search) * 255))))
                        for dy in 0..<step {
                            for dx in 0..<step { disparityImage[(row + dy) * w + col + dx] = intensity }
                        }
                        if !disparityGrid.isEmpty { disparityGrid[row * w + col] = d }
                        guard brightEnough, let verified, d >= 1.5 else { continue }
                        let rectDepth = StereoCorrespondence.depthCM(focalPixels: focal, baselineMM: verified.baselineMM, subpixelDisparity: d)
                        let ray = rect.basis * Self.rectRay(x: col, y: row, w: w, h: h, focal: focal)
                        guard let pixel = verified.left.project(ray, k: aK), pixel.x.isFinite, pixel.y.isFinite else { continue }
                        let px = Float(geometry.width - 1) - pixel.y
                        let py = pixel.x
                        guard px >= 0, py >= 0, px < Float(geometry.width), py < Float(geometry.height),
                              (20...600).contains(rectDepth * ray.z) else { continue }
                        let index = Int(py * Float(mapHeight) / Float(geometry.height)) * mapWidth
                            + Int(px * Float(mapWidth) / Float(geometry.width))
                        let value = rectDepth * ray.z
                        if !cm[index].isFinite || value < cm[index] {
                            cm[index] = value
                            confidence[index] = d >= 4 ? 2 : 1
                        }
                    }
                }
                disparities.sort()
                let matched = disparities.count
                let cells = confidence.filter { $0 > 0 }.count
                let median = matched > 0 ? String(format: "%.2f", disparities[matched / 2]) : "N/A"
                let range = matched > 0 ? String(format: "%.1f–%.1f", disparities[0], disparities[matched - 1]) : "N/A"
                let calibrationStatus = verified == nil ? "CALIBRATION REQUIRED" : "Verified profile"
                if matched > 0 { preview = StereoDisparityPreview(width: w, height: h, pixels: Data(disparityImage)) }
                let disparityStatus = matched > 0 ? "DISPARITY READY" : "Disparity unavailable"
                detail = "\(calibrationStatus) • \(disparityStatus) • disparity \(median) px [\(range)] • \(matched) matches"
                if export { exportedDisparity = (disparityGrid, w, h, focal) }
                if verified != nil {
                    if cells >= mapWidth * mapHeight / 10 {
                        error = nil
                        detail = "METRIC DEPTH READY • " + detail
                    }
                    else { error = brightEnough ? "Distance unavailable: low texture or overlap" : "Distance unavailable: low light" }
                }
            }
        }
        if export {
            exportURL = Self.exportPair(pair, ids: ids, positions: positions, ext: ext,
                disparity: exportedDisparity, captureSignature: captureSignature, strategy: strategy)
        }
        let frame = DepthFrame(source: .stereo, timestamp: timestamp, geometry: geometry,
            width: mapWidth, height: mapHeight, centimeters: cm, confidence: confidence,
            detail: "Capture ready • " + detail, error: error,
            captureProcessingMS: (CACurrentMediaTime() - began) * 1000, stereoDisparity: preview)
        return (frame, exportURL)
    }

    func requestPair(_ completion: @escaping (URL?) -> Void) {
        queue.async {
            let id = UUID()
            self.snapshot = (id, completion)
            self.queue.asyncAfter(deadline: .now() + 3) {
                guard let pending = self.snapshot, pending.id == id else { return }
                self.snapshot = nil
                DispatchQueue.main.async { pending.completion(nil) }
            }
        }
    }

    private static func exportPair(_ pair: StereoIngress.Pair, ids: [String], positions: [Float],
                                   ext: simd_float4x3?,
                                   disparity: (pixels: [Float?], width: Int, height: Int, focal: Float)?,
                                   captureSignature: [String], strategy: String) -> URL? {
        func image(_ sample: StereoIngress.Image, position: Float) -> [String: Any]? {
            let buffer = sample.buffer
            guard CVPixelBufferIsPlanar(buffer),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            var pgm = Data("P5\n\(w) \(h)\n255\n".utf8)
            for y in 0..<h { pgm.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: w) }
            var result: [String: Any] = ["width": w, "height": h, "pixelFormat": CVPixelBufferGetPixelFormatType(buffer),
                "position": position, "pgmBase64": pgm.base64EncodedString(), "rawSeconds": sample.raw, "hostSeconds": sample.host]
            if let k = sample.intrinsics {
                result["intrinsics"] = [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y]
            }
            return result
        }
        guard let left = image(pair.a, position: positions[0]), let right = image(pair.b, position: positions[1]) else { return nil }
        var payload: [String: Any] = ["pair": ids, "left": left, "right": right, "strategy": strategy,
            "captureSeconds": pair.a.host, "skewMS": (pair.b.host - pair.a.host) * 1000, "captureSignature": captureSignature]
        if let ext { payload["factoryExtrinsicsColumnsMM"] = (0..<4).map { i in [ext[i].x, ext[i].y, ext[i].z] } }
        if let disparity {
            payload["rectifiedWidth"] = disparity.width
            payload["rectifiedHeight"] = disparity.height
            payload["rectifiedFocalPx"] = disparity.focal
            payload["disparityPx"] = disparity.pixels.map { $0.map { NSNumber(value: $0) as Any } ?? NSNull() }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID()).json")
        do {
            try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    private static func matrix<T>(_ data: Data?, as type: T.Type) -> T? {
        guard let data, data.count == MemoryLayout<T>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: type) }
    }

    private static func rectRay(x: Int, y: Int, w: Int, h: Int, focal: Float) -> SIMD3<Float> {
        SIMD3((Float(x) - Float(w - 1) / 2) / focal, (Float(y) - Float(h - 1) / 2) / focal, 1)
    }

    private static func warp(_ image: CVPixelBuffer, rotation: simd_float3x3, k: simd_float3x3,
                             lens: StereoCalibration.Lens?, focal: Float, w: Int, h: Int) -> [Int]? {
        guard focal.isFinite, focal > 0, CVPixelBufferIsPlanar(image),
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let plane = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        var pixels = [Int](repeating: -1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let ray = rotation * rectRay(x: x, y: y, w: w, h: h, focal: focal)
                guard ray.z > 0 else { continue }
                let point = k * ray
                let pixel = lens?.project(ray, k: k) ?? SIMD2(point.x / point.z, point.y / point.z)
                guard pixel.x >= 0, pixel.x < Float(width - 1), pixel.y >= 0, pixel.y < Float(height - 1) else { continue }
                let ix = Int(pixel.x), iy = Int(pixel.y)
                let dx = pixel.x - Float(ix), dy = pixel.y - Float(iy)
                let offset = iy * stride + ix
                let top = Float(plane[offset]) * (1 - dx) + Float(plane[offset + 1]) * dx
                let bottom = Float(plane[offset + stride]) * (1 - dx) + Float(plane[offset + stride + 1]) * dx
                pixels[y * w + x] = Int(top * (1 - dy) + bottom * dy)
            }
        }
        return pixels
    }
}
