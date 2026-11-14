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

final class StereoCapture: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    private static let types: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .builtInTelephotoCamera
    ]

    private static var pair: (AVCaptureDevice, AVCaptureDevice)? {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        // Prefer the wide/tele pair to reduce distortion in the pinhole diagnostic.
        for set in discovery.supportedMultiCamDeviceSets {
            if let wide = set.first(where: { $0.deviceType == .builtInWideAngleCamera }),
               let tele = set.first(where: { $0.deviceType == .builtInTelephotoCamera }) {
                return (wide, tele)
            }
        }
        return nil
    }

    static var supported: Bool { pair != nil }
    private let session = AVCaptureMultiCamSession()
    private let queue = DispatchQueue(label: "com.visef.stereo", qos: .userInitiated)
    private let leftOutput = AVCaptureVideoDataOutput()
    private let rightOutput = AVCaptureVideoDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var devices: [AVCaptureDevice] = []
    private var extrinsics: simd_float4x3?
    private var observers: [NSObjectProtocol] = []
    private var previousPairTime = -Double.infinity
    private var cameraState: [(device: AVCaptureDevice, format: AVCaptureDevice.Format,
                               min: CMTime, max: CMTime)] = []
    let onFrame: (DepthFrame, CVPixelBuffer?) -> Void
    let onError: (String) -> Void

    init(onFrame: @escaping (DepthFrame, CVPixelBuffer?) -> Void,
         onError: @escaping (String) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func start() {
        queue.async {
            guard let (wide, tele) = Self.pair else { self.onError("Rear wide/tele pair unavailable"); return }
            self.devices = [wide, tele]
            let data = AVCaptureDevice.extrinsicMatrix(from: wide, to: tele)
            self.extrinsics = Self.matrix(data, as: simd_float4x3.self)
            self.session.beginConfiguration()
            let configured = self.connect(wide, output: self.leftOutput) && self.connect(tele, output: self.rightOutput)
            self.session.commitConfiguration()
            guard configured, self.session.hardwareCost <= 1, self.session.systemPressureCost <= 1 else {
                self.restoreFormats()
                self.onError("Stereo capture exceeds the camera budget or has no usable format")
                return
            }
            self.synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [self.leftOutput, self.rightOutput])
            self.synchronizer?.setDelegate(self, queue: self.queue)
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: self.session, queue: nil) { [weak self] _ in
                    self?.onError("Stereo capture interrupted. Reselect Stereo to restart.")
                }
                self.observers.append(observer)
            }
            self.session.startRunning()
            if !self.session.isRunning { self.onError("Stereo capture failed to start") }
        }
    }

    func stop(completion: @escaping () -> Void) {
        queue.async {
            self.synchronizer?.setDelegate(nil, queue: nil)
            self.synchronizer = nil
            for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
            self.observers.removeAll()
            if self.session.isRunning { self.session.stopRunning() }
            self.restoreFormats()
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func restoreFormats() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        for state in cameraState {
            if (try? state.device.lockForConfiguration()) != nil {
                state.device.activeFormat = state.format
                state.device.activeVideoMinFrameDuration = state.min
                state.device.activeVideoMaxFrameDuration = state.max
                state.device.unlockForConfiguration()
            }
        }
        cameraState.removeAll()
    }

    private func connect(_ device: AVCaptureDevice, output: AVCaptureVideoDataOutput) -> Bool {
        let formats = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return $0.isMultiCamSupported && size.width >= 480 && size.width <= 1920
                && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard let format = formats.min(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return a.width * a.height < b.width * b.height
        }), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input),
        (try? device.lockForConfiguration()) != nil else { return false }
        cameraState.append((device, device.activeFormat, device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration))
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
        session.addInputWithNoConnections(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output), let port = input.ports.first(where: { $0.mediaType == .video }) else { return false }
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else { return false }
        session.addConnection(connection)
        if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
        return true
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput data: AVCaptureSynchronizedDataCollection) {
        guard session.systemPressureCost <= 1, !devices.contains(where: {
            [.serious, .critical, .shutdown].contains($0.systemPressureState.level)
        }) else { onError("Stereo paused by camera pressure"); return }
        guard let left = data.synchronizedData(for: leftOutput) as? AVCaptureSynchronizedSampleBufferData,
              let right = data.synchronizedData(for: rightOutput) as? AVCaptureSynchronizedSampleBufferData,
              !left.sampleBufferWasDropped, !right.sampleBufferWasDropped,
              let a = CMSampleBufferGetImageBuffer(left.sampleBuffer),
              let b = CMSampleBufferGetImageBuffer(right.sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(left.sampleBuffer).seconds
        let otherTimestamp = CMSampleBufferGetPresentationTimeStamp(right.sampleBuffer).seconds
        guard StereoCorrespondence.synchronized(timestamp, otherTimestamp),
              timestamp - previousPairTime >= 0.12 else { return }
        previousPairTime = timestamp
        let began = CACurrentMediaTime()
        let aK = Self.intrinsics(left.sampleBuffer)
        let bK = Self.intrinsics(right.sampleBuffer)
        let geometry = DepthGeometry(width: CVPixelBufferGetHeight(a), height: CVPixelBufferGetWidth(a),
                                     fx: aK?.columns.1.y ?? .nan,
                                     cx: Float(CVPixelBufferGetHeight(a) - 1) - (aK?.columns.2.y ?? .nan))
        var detail = "Synchronized pair • calibration missing"
        if let ext = extrinsics, let aK, let bK,
           let rectified = Self.rectify(a, b, aK: aK, bK: bK, extrinsics: ext) {
            let w = Self.rectifiedWidth
            let h = Self.rectifiedHeight
            var matched = 0
            var total = 0
            for y in stride(from: 3, to: h - 3, by: 3) {
                for x in stride(from: 3, to: w - 3, by: 3) {
                    total += 1
                    if StereoCorrespondence.disparity(left: rectified.left, right: rectified.right,
                                                      width: w, height: h, x: x, y: y, maxShift: 32) != nil {
                        matched += 1
                    }
                }
            }
            detail = "Rectified matches \(matched)/\(total) • metric unverified"
        }
        onFrame(DepthFrame(source: .stereo, timestamp: timestamp, geometry: geometry, width: 0, height: 0,
                           centimeters: [], confidence: [], detail: detail,
                           error: "Metric stereo guidance unavailable",
                           captureProcessingMS: (CACurrentMediaTime() - began) * 1000), a)
    }

    private static func matrix<T>(_ data: Data?, as type: T.Type) -> T? {
        guard let data, data.count == MemoryLayout<T>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: type) }
    }

    private static func intrinsics(_ sample: CMSampleBuffer) -> simd_float3x3? {
        let attachment = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
        return matrix(attachment as? Data, as: simd_float3x3.self)
    }

    private static let rectifiedWidth = 128
    private static let rectifiedHeight = 96

    private static func rectify(_ a: CVPixelBuffer, _ b: CVPixelBuffer,
                                aK: simd_float3x3, bK: simd_float3x3,
                                extrinsics e: simd_float4x3) -> (left: [Int], right: [Int])? {
        let r = simd_float3x3(columns: (e.columns.0, e.columns.1, e.columns.2))
        let baseline = -(r.transpose * e.columns.3)
        guard simd_length(baseline).isFinite, simd_length(baseline) > 0,
              aK.columns.0.x.isFinite, aK.columns.0.x > 0,
              bK.columns.0.x.isFinite, bK.columns.0.x > 0 else { return nil }
        let across = simd_normalize(baseline)
        let forward = SIMD3<Float>(0, 0, 1) + r.transpose * SIMD3<Float>(0, 0, 1)
        let cross = simd_cross(forward, across)
        guard simd_length(cross) > 0.01 else { return nil }
        let down = simd_normalize(cross)
        let optical = simd_cross(across, down)
        let rectToA = simd_float3x3(columns: (across, down, optical))
        let focal = aK.columns.0.x * Float(rectifiedWidth) / Float(CVPixelBufferGetWidth(a))
        guard let left = warp(a, map: aK * rectToA, focal: focal),
              let right = warp(b, map: bK * r * rectToA, focal: focal) else { return nil }
        return (left, right)
    }

    private static func warp(_ image: CVPixelBuffer, map: simd_float3x3, focal: Float) -> [Int]? {
        guard CVPixelBufferIsPlanar(image),
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let plane = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        var pixels = [Int](repeating: -1, count: rectifiedWidth * rectifiedHeight)
        for y in 0..<rectifiedHeight {
            for x in 0..<rectifiedWidth {
                let ray = map * SIMD3((Float(x) - Float(rectifiedWidth - 1) / 2) / focal,
                                      (Float(y) - Float(rectifiedHeight - 1) / 2) / focal, 1)
                guard ray.z > 0 else { continue }
                let u = (ray.x / ray.z).rounded()
                let v = (ray.y / ray.z).rounded()
                guard u >= 0, u < Float(width), v >= 0, v < Float(height) else { continue }
                pixels[y * rectifiedWidth + x] = Int(plane[Int(v) * stride + Int(u)])
            }
        }
        return pixels
    }
}
