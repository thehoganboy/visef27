// HorusEyes 2.0 — CameraTorchManager.swift
// ════════════════════════════════════════════════════════════════════════════════
// Crash-Proof AVFoundation Camera Pipeline (Zero Hardware Access in init)
// ════════════════════════════════════════════════════════════════════════════════

import Foundation
import Combine
import AVFoundation
import UIKit
import CoreVideo
import QuartzCore

final class CameraTorchManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // ── Observable UI & System State ───────────────────────────────────────────
    @Published var isTorchActive: Bool = false
    @Published var isZeroLuxBlind: Bool = false
    @Published var meanLuma: Float = 128.0
    @Published var fps: Float = 0.0
    @Published var isGuidanceActive: Bool = false

    // Public access to capture session for SwiftUI preview layer
    var session: AVCaptureSession { captureSession }

    // ── Internal Hardware State ────────────────────────────────────────────────
    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "com.visef.horuseyes.cameraQueue", qos: .userInitiated)
    private var wantsCapture = false
    private var captureRequest = 0
    private var isSessionConfigured: Bool = false
    private var sessionGeneration: Int = 0
    private var guidanceActiveInternal: Bool = false

    // Watchdog & Timing
    private var lastFrameTimestamp: CFTimeInterval = 0.0
    private var frameId: UInt64 = 0
    private var torchActivationTimestamp: CFTimeInterval = 0.0
    private(set) var aeSettleFramesRemaining: Int = 0

    // 0-Lux Hysteresis Counters
    private var darkFrameCount: Int = 0
    private var blindFrameCount: Int = 0
    private var isTorchForcedManual: Bool = false
    private var lastTorchToggleTime: CFTimeInterval = 0.0

    // FPS Meter
    private var fpsCounter: Int = 0
    private var lastFpsTimestamp: CFTimeInterval = 0.0

    // Haptic feedback
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .heavy)

    // Callbacks
    private var onFrameProcessed: ((_ pixelBuffer: CVPixelBuffer, _ frameId: UInt64, _ aeSettle: Int, _ luma: Float, _ sourceTimestamp: Double) -> Void)?

    func setFrameHandler(_ handler: @escaping (CVPixelBuffer, UInt64, Int, Float, CFTimeInterval) -> Void) {
        sessionQueue.async { [weak self] in self?.onFrameProcessed = handler }
    }
    var onTorchToggled: ((_ isOn: Bool) -> Void)?

    // ── Health Watchdog ────────────────────────────────────────────────────────
    var isCameraHealthy: Bool {
        guard lastFrameTimestamp > 0.0 else { return false }
        return (CACurrentMediaTime() - lastFrameTimestamp) < 0.50
    }

    override init() {
        super.init()
        hapticGenerator.prepare()
        // DO NOT call setupCaptureSession() here. Hardware is configured safely after permission is verified.
    }

    deinit {
        stop()
    }

    // ── Safe Lazy Session Setup ───────────────────────────────────────────────
    private func setupCaptureSessionIfNeeded(completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isSessionConfigured else {
                completion()
                return
            }

            self.captureSession.beginConfiguration()
            if self.captureSession.canSetSessionPreset(.hd1280x720) {
                self.captureSession.sessionPreset = .hd1280x720
            } else {
                self.captureSession.sessionPreset = .vga640x480
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                print("[HorusEyes] Notice: Back camera device not found.")
                self.captureSession.commitConfiguration()
                completion()
                return
            }
            self.videoDevice = device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                // Lock to 30 FPS safely if supported
                do {
                    try device.lockForConfiguration()
                    let targetFps = Double(Config.defaultFPS)
                    if let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
                        $0.minFrameRate <= targetFps && targetFps <= $0.maxFrameRate
                    }) {
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(targetFps))
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(targetFps))
                    }
                    if device.isLowLightBoostSupported {
                        device.automaticallyEnablesLowLightBoostWhenAvailable = true
                    }
                    device.unlockForConfiguration()
                } catch {
                    print("[HorusEyes] Notice: Device frame rate lock skipped: \(error)")
                }
            } catch {
                print("[HorusEyes] Error configuring camera input: \(error)")
            }

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            let availableFormats = videoOutput.availableVideoPixelFormatTypes
            var chosenFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if !availableFormats.contains(chosenFormat) {
                if availableFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                    chosenFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                } else if let first = availableFormats.first {
                    chosenFormat = first
                }
            }
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(chosenFormat)
            ]
            videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)

            if self.captureSession.canAddOutput(videoOutput) {
                self.captureSession.addOutput(videoOutput)
            }

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }
            }

            self.captureSession.commitConfiguration()
            self.isSessionConfigured = true
            completion()
        }
    }

    // ── Safe Permission & Startup ─────────────────────────────────────────────
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsCapture = true
            self.captureRequest += 1
            let request = self.captureRequest
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.prepareCapture(request: request)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard granted else { return }
                    self?.prepareCapture(request: request)
                }
            default:
                break
            }
        }
    }

    private func prepareCapture(request: Int) {
        setupCaptureSessionIfNeeded { [weak self] in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.wantsCapture, self.captureRequest == request, !self.captureSession.isRunning else { return }
                self.captureSession.startRunning()
                self.lastFpsTimestamp = CACurrentMediaTime()
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            if let self {
                self.wantsCapture = false
                self.captureRequest += 1
                if self.captureSession.isRunning {
                    self.setHardwareTorch(on: false)
                    self.captureSession.stopRunning()
                }
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    func updateVideoOrientation(for interfaceOrientation: UIInterfaceOrientation) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let videoOrientation: AVCaptureVideoOrientation = .portrait
            if let output = self.captureSession.outputs.first as? AVCaptureVideoDataOutput,
               let conn = output.connection(with: .video),
               conn.isVideoOrientationSupported {
                conn.videoOrientation = videoOrientation
            }
        }
    }

    // ── Frame Delegate ────────────────────────────────────────────────────────
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        lastFrameTimestamp = now
        frameId += 1

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Fast Luma extraction from Plane 0 (Y channel)
        let luma = calculateMeanLuma(pixelBuffer: pixelBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.meanLuma = luma
        }

        // 0-Lux Automatic Flash Safety State Machine (Evaluated only during active guidance session)
        if guidanceActiveInternal {
            processTorchLogic(meanY: luma, currentTime: now)
        } else {
            darkFrameCount = 0
        }

        if aeSettleFramesRemaining > 0 {
            aeSettleFramesRemaining -= 1
        }

        fpsCounter += 1
        let elapsed = now - lastFpsTimestamp
        if elapsed >= 1.0 {
            let currentFps = Float(fpsCounter) / Float(elapsed)
            DispatchQueue.main.async { [weak self] in
                self?.fps = currentFps
            }
            fpsCounter = 0
            lastFpsTimestamp = now
        }

        onFrameProcessed?(pixelBuffer, frameId, aeSettleFramesRemaining, luma, now)
    }

    // ── Fast Plane 0 Luma Computation (Planar & Non-Planar Crash-Proof) ─────
    private func calculateMeanLuma(pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let baseAddr: UnsafeMutableRawPointer?
        let width: Int
        let height: Int
        let bytesPerRow: Int

        if isPlanar && planeCount > 0 {
            baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        } else {
            baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer)
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        }

        guard let buffer = baseAddr, width > 0, height > 0, bytesPerRow > 0 else {
            return 128.0
        }

        let bufferPtr = buffer.assumingMemoryBound(to: UInt8.self)
        var sum: UInt64 = 0
        var samplesCount: UInt64 = 0

        let stepX = max(4, width / 24)
        let stepY = max(4, height / 32)

        for y in stride(from: 0, to: height, by: stepY) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: stepX) {
                sum += UInt64(bufferPtr[rowOffset + x])
                samplesCount += 1
            }
        }

        guard samplesCount > 0 else { return 128.0 }
        return Float(sum) / Float(samplesCount)
    }

    // ── 0-Lux Auto-Torch Logic & Anti-Strobe Hysteresis ────────────────────────
    private func processTorchLogic(meanY: Float, currentTime: CFTimeInterval) {
        if meanY < Config.luxZeroBlindThreshold {
            blindFrameCount += 1
            if blindFrameCount >= 10 {
                DispatchQueue.main.async { [weak self] in
                    self?.isZeroLuxBlind = true
                }
            }
        } else {
            blindFrameCount = 0
            if isZeroLuxBlind {
                DispatchQueue.main.async { [weak self] in
                    self?.isZeroLuxBlind = false
                }
            }
        }

        guard !isTorchForcedManual else { return }

        if meanY < Config.luxDarkOnThreshold {
            darkFrameCount += 1
            if darkFrameCount >= Config.luxDarkConfirmFrames && !isTorchActive {
                setHardwareTorch(on: true)
                torchActivationTimestamp = currentTime
                aeSettleFramesRemaining = Config.flashAeSettleFrames
                onTorchToggled?(true)
            }
        } else {
            darkFrameCount = 0
        }

        if meanY > Config.luxBrightOffThreshold && isTorchActive {
            let holdDuration = currentTime - torchActivationTimestamp
            if holdDuration >= Double(Config.flashHoldMinSeconds) {
                setHardwareTorch(on: false)
                aeSettleFramesRemaining = Config.flashAeSettleFrames
                onTorchToggled?(false)
            }
        }
    }

    // ── Hardware Torch Actuator ───────────────────────────────────────────────
    private func setHardwareTorch(on: Bool) {
        guard let device = videoDevice, device.hasTorch, device.isTorchAvailable else { return }

        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isTorchActive = on
                self.aeSettleFramesRemaining = Config.flashAeSettleFrames
                self.onTorchToggled?(on)
            }
        } catch {
            print("[HorusEyes] Error setting torch: \(error)")
            // Hardware failure: do not report successful toggle; sync to physical state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isTorchActive = (self.videoDevice?.torchMode == .on)
            }
        }
    }

    // ── Manual Override Toggle ────────────────────────────────────────────────
    func toggleManualTorch() {
        let now = CACurrentMediaTime()
        // P1-E: Debounce rapid repeated taps (250ms guard) to prevent desynchronization
        guard now - lastTorchToggleTime >= 0.25 else { return }
        // Manual toggle is accepted only during an active guidance session
        guard isGuidanceActive else { return }
        lastTorchToggleTime = now
        hapticGenerator.impactOccurred()
        let token = sessionGeneration
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Ensure manual torch action cannot race with session stop/restart and guidance remains active
            guard self.sessionGeneration == token && self.guidanceActiveInternal else { return }
            let newState = !self.isTorchActive
            self.isTorchForcedManual = true // Lock manual choice for this running session
            self.setHardwareTorch(on: newState)
        }
    }

    func setGuidanceActive(_ active: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sessionGeneration += 1
            self.guidanceActiveInternal = active
            self.darkFrameCount = 0
            self.blindFrameCount = 0
            if !active {
                self.isTorchForcedManual = false
                self.setHardwareTorch(on: false)
            } else {
                // Restore automatic lighting policy on new CHẠY session
                self.isTorchForcedManual = false
            }
            DispatchQueue.main.async {
                self.isGuidanceActive = active
            }
        }
    }

    func resetManualTorchLock() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isTorchForcedManual = false
        }
    }

    func forceTorchOff() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sessionGeneration += 1
            self.guidanceActiveInternal = false
            self.isTorchForcedManual = false
            self.setHardwareTorch(on: false)
            DispatchQueue.main.async {
                self.isGuidanceActive = false
            }
        }
    }
}
