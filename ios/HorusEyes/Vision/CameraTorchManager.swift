// HorusEyes 2.0 — CameraTorchManager.swift
// ════════════════════════════════════════════════════════════════════════════════
// Crash-Proof AVFoundation Camera Pipeline (Zero Hardware Access in init)
// ════════════════════════════════════════════════════════════════════════════════

import Foundation
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

    // Public access to capture session for SwiftUI preview layer
    var session: AVCaptureSession { captureSession }

    // ── Internal Hardware State ────────────────────────────────────────────────
    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "com.visef.horuseyes.cameraQueue", qos: .userInitiated)
    private var isSessionConfigured: Bool = false

    // Watchdog & Timing
    private var lastFrameTimestamp: CFTimeInterval = 0.0
    private var frameId: UInt64 = 0
    private var torchActivationTimestamp: CFTimeInterval = 0.0
    private(set) var aeSettleFramesRemaining: Int = 0

    // 0-Lux Hysteresis Counters
    private var darkFrameCount: Int = 0
    private var blindFrameCount: Int = 0
    private var isTorchForcedManual: Bool = false

    // FPS Meter
    private var fpsCounter: Int = 0
    private var lastFpsTimestamp: CFTimeInterval = 0.0

    // Haptic feedback
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .heavy)

    // Callbacks
    var onFrameProcessed: ((_ pixelBuffer: CVPixelBuffer, _ frameId: UInt64, _ aeSettle: Int, _ luma: Float) -> Void)?
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
            self.captureSession.sessionPreset = .vga640x480

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
                    let targetFps = Int32(Config.defaultFPS)
                    if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(targetFps) }) {
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: targetFps)
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: targetFps)
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
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)

            if self.captureSession.canAddOutput(videoOutput) {
                self.captureSession.addOutput(videoOutput)
            }

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
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
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSessionIfNeeded { [weak self] in
                self?.startRunningSession()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.setupCaptureSessionIfNeeded {
                        self?.startRunningSession()
                    }
                } else {
                    print("[HorusEyes] Camera permission denied by user.")
                }
            }
        case .denied, .restricted:
            print("[HorusEyes] Camera permission currently denied or restricted.")
        @unknown default:
            break
        }
    }

    private func startRunningSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            self.lastFpsTimestamp = CACurrentMediaTime()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.setHardwareTorch(on: false)
            self.captureSession.stopRunning()
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

        // 0-Lux Automatic Flash Safety State Machine
        processTorchLogic(meanY: luma, currentTime: now)

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

        onFrameProcessed?(pixelBuffer, frameId, aeSettleFramesRemaining, luma)
    }

    // ── Fast Plane 0 Luma Computation ─────────────────────────────────────────
    private func calculateMeanLuma(pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return 128.0
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        let bufferPtr = yPlane.assumingMemoryBound(to: UInt8.self)
        var sum: UInt64 = 0
        var samplesCount: UInt64 = 0

        let stepX = 8
        let stepY = 8

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
        guard let device = videoDevice, device.hasTorch else { return }

        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()

            DispatchQueue.main.async { [weak self] in
                self?.isTorchActive = on
            }
        } catch {
            print("[HorusEyes] Error setting torch: \(error)")
        }
    }

    // ── Manual Override Toggle ────────────────────────────────────────────────
    func toggleManualTorch() {
        hapticGenerator.impactOccurred()
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let newState = !self.isTorchActive
            self.isTorchForcedManual = newState
            self.setHardwareTorch(on: newState)
            self.aeSettleFramesRemaining = Config.flashAeSettleFrames
            self.onTorchToggled?(newState)
        }
    }
}
