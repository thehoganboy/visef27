// HorusEyes 2.0 — CameraTorchManager.swift
// ════════════════════════════════════════════════════════════════════════════════
// AVFoundation High-Speed Camera Pipeline + 0-Lux Auto-Torch + Hardware Watchdog
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

    // ── Internal Hardware State ────────────────────────────────────────────────
    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "com.visef.horuseyes.cameraQueue", qos: .userInitiated)

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
        setupCaptureSession()
    }

    deinit {
        stop()
    }

    // ── Setup AVFoundation ────────────────────────────────────────────────────
    private func setupCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .vga640x480

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                print("[HorusEyes] Error: Back camera device not found.")
                self.captureSession.commitConfiguration()
                return
            }
            self.videoDevice = device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                // Lock to 30 FPS
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(Config.defaultFPS))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(Config.defaultFPS))
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = true
                }
                device.unlockForConfiguration()
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

            // CRITICAL: Safety orientation — Portrait upright, NO horizontal flip
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }
            }

            self.captureSession.commitConfiguration()
        }
    }

    func start() {
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

        // AE settling countdown
        if aeSettleFramesRemaining > 0 {
            aeSettleFramesRemaining -= 1
        }

        // Update FPS
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

        // Notify Vision Pipeline
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

        // Subsampled stride for sub-millisecond calculation (every 8th pixel)
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
        // Blind lens check (complete occlusion or absolute 0-lux without flash)
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

        // If user manually forced torch, don't auto-switch
        if isTorchForcedManual { return }

        // Condition 1: Automatic turn ON in darkness
        if meanY < Config.luxDarkOnThreshold {
            darkFrameCount += 1
            if darkFrameCount >= Config.luxDarkConfirmFrames && !isTorchActive {
                setHardwareTorch(on: true)
                torchActivationTimestamp = currentTime
                aeSettleFramesRemaining = Config.flashAeSettleFrames
                darkFrameCount = 0

                DispatchQueue.main.async { [weak self] in
                    self?.isTorchActive = true
                    self?.hapticGenerator.impactOccurred()
                    self?.onTorchToggled?(true)
                }
            }
        } else {
            darkFrameCount = 0
        }

        // Condition 2: Automatic turn OFF in daylight (anti-strobe with 5.0s minimum hold)
        if isTorchActive && meanY > Config.luxBrightOffThreshold {
            let holdDuration = currentTime - torchActivationTimestamp
            if holdDuration >= Double(Config.flashHoldMinSeconds) {
                setHardwareTorch(on: false)
                DispatchQueue.main.async { [weak self] in
                    self?.isTorchActive = false
                    self?.onTorchToggled?(false)
                }
            }
        }
    }

    // ── Hardware Torch Control ────────────────────────────────────────────────
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
        } catch {
            print("[HorusEyes] Failed to set hardware torch: \(error)")
        }
    }

    // ── Manual User Override (UI Button) ──────────────────────────────────────
    func toggleManualTorch() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let newState = !self.isTorchActive
            self.isTorchForcedManual = true
            self.setHardwareTorch(on: newState)

            DispatchQueue.main.async {
                self.isTorchActive = newState
                self.hapticGenerator.impactOccurred()
                self.onTorchToggled?(newState)
            }
        }
    }

    func resetToAutoTorch() {
        sessionQueue.async { [weak self] in
            self?.isTorchForcedManual = false
        }
    }
}
