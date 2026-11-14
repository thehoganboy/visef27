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
    private static var pairs: [(AVCaptureDevice, AVCaptureDevice)] {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return [] }
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        let sets = discovery.supportedMultiCamDeviceSets
        let candidates: [(AVCaptureDevice.DeviceType, AVCaptureDevice.DeviceType)] = [
            (.builtInWideAngleCamera, .builtInUltraWideCamera), (.builtInWideAngleCamera, .builtInTelephotoCamera),
            (.builtInUltraWideCamera, .builtInTelephotoCamera)
        ]
        return candidates.compactMap { first, second in
            for set in sets {
                if let a = set.first(where: { $0.deviceType == first && $0.position == .back }),
                   let b = set.first(where: { $0.deviceType == second && $0.position == .back }),
                   AVCaptureDevice.extrinsicMatrix(from: a, to: b) != nil { return (a, b) }
            }
            return nil
        }
    }

    static var supported: Bool { !pairs.isEmpty }
    private let session = AVCaptureMultiCamSession()
    private let queue = DispatchQueue(label: "com.visef.stereo", qos: .userInitiated)
    private let leftOutput = AVCaptureVideoDataOutput()
    private let rightOutput = AVCaptureVideoDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var devices: [AVCaptureDevice] = []
    private var extrinsics: simd_float4x3?
    private var observers: [NSObjectProtocol] = []
    private var calibration: StereoCalibration?
    private var snapshot: (id: UUID, completion: (URL?) -> Void)?
    private var processingMS: Double = 0
    private var previousPairTime = -Double.infinity
    private var cameraState: [(device: AVCaptureDevice, format: AVCaptureDevice.Format,
                               min: CMTime, max: CMTime, focus: AVCaptureDevice.FocusMode)] = []
    let onFrame: (DepthFrame, CVPixelBuffer?) -> Void
    let onError: (String) -> Void

    init(onFrame: @escaping (DepthFrame, CVPixelBuffer?) -> Void,
         onError: @escaping (String) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func start() {
        queue.async {
            self.calibration = (try? Data(contentsOf: StereoCalibration.file)).flatMap {
                try? JSONDecoder().decode(StereoCalibration.self, from: $0)
            }
            let pairs = Self.pairs
            let requested = self.calibration?.pair
            let preferred = pairs.first { [$0.0.uniqueID, $0.1.uniqueID] == requested }
            var configured = false
            for (a, b) in (preferred.map { [$0] } ?? []) + pairs.filter({ [$0.0.uniqueID, $0.1.uniqueID] != requested }) {
                self.session.beginConfiguration()
                let connected = self.connect(a, output: self.leftOutput) && self.connect(b, output: self.rightOutput)
                self.session.commitConfiguration()
                if connected, self.session.hardwareCost <= 1, self.session.systemPressureCost <= 1 {
                    self.devices = [a, b]
                    self.lockCalibrationFocus()
                    self.extrinsics = Self.matrix(AVCaptureDevice.extrinsicMatrix(from: a, to: b), as: simd_float4x3.self)
                    configured = true
                    break
                }
                self.restoreFormats()
            }
            guard configured else { self.onError("No rear stereo pair within camera budget"); return }
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
            self.snapshot = nil
            for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
            self.observers.removeAll()
            if self.session.isRunning { self.session.stopRunning() }
            self.restoreFormats()
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func lockCalibrationFocus() {
        for (index, device) in devices.enumerated() {
            guard device.isFocusModeSupported(.locked),
                  (try? device.lockForConfiguration()) != nil else { continue }
            let lens = index == 0 ? calibration?.left : calibration?.right
            if calibration?.pair == devices.map(\.uniqueID), let position = lens?.position,
               (0...1).contains(position), device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: position)
            } else {
                device.focusMode = .locked
            }
            device.unlockForConfiguration()
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
                if state.device.isFocusModeSupported(state.focus) { state.device.focusMode = state.focus }
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
        cameraState.append((device, device.activeFormat, device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration, device.focusMode))
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
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
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
        let original = CMSampleBufferGetPresentationTimeStamp(left.sampleBuffer)
        let other = CMSampleBufferGetPresentationTimeStamp(right.sampleBuffer)
        guard let clock = session.synchronizationClock else { return }
        let timestamp = CMSyncConvertTime(original, from: clock, to: CMClockGetHostTimeClock()).seconds
        let otherTimestamp = CMSyncConvertTime(other, from: clock, to: CMClockGetHostTimeClock()).seconds
        guard StereoCorrespondence.synchronized(timestamp, otherTimestamp),
              timestamp - previousPairTime >= 0.12 else { return }
        previousPairTime = timestamp
        let began = CACurrentMediaTime()
        let aK = Self.intrinsics(left.sampleBuffer)
        let bK = Self.intrinsics(right.sampleBuffer)
        let geometry = DepthGeometry(width: CVPixelBufferGetHeight(a), height: CVPixelBufferGetWidth(a),
                                     fx: aK?.columns.1.y ?? .nan,
                                     cx: Float(CVPixelBufferGetHeight(a) - 1) - (aK?.columns.2.y ?? .nan))
        var detail = "Intrinsics or extrinsics unavailable"
        var error: String? = "Distance unavailable"
        let mapWidth = 48
        let mapHeight = 64
        var cm = [Float](repeating: .nan, count: mapWidth * mapHeight)
        var confidence = [UInt8](repeating: 0, count: cm.count)
        if let ext = extrinsics, let aK, let bK, let rect = StereoCalibration.rectification(ext) {
            let ids = devices.map(\.uniqueID)
            let positions = devices.map(\.lensPosition)

            let verified = calibration.flatMap { profile -> StereoCalibration? in
                guard profile.verified(for: ids, factoryBaselineMM: rect.baseline),
                      profile.left.matches(width: CVPixelBufferGetWidth(a), height: CVPixelBufferGetHeight(a),
                                           intrinsics: aK, position: positions[0]),
                      profile.right.matches(width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b),
                                            intrinsics: bK, position: positions[1]),
                      devices.allSatisfy({ !$0.isAdjustingFocus }) else { return nil }
                return profile
            }
            let w = processingMS > 95 ? 192 : 256
            let h = w * 3 / 4
            let focal = aK.columns.0.x * Float(w) / Float(CVPixelBufferGetWidth(a))
            if let first = Self.warp(a, rotation: rect.basis, k: aK, lens: verified?.left, focal: focal, w: w, h: h),
               let second = Self.warp(b, rotation: rect.rotation * rect.basis, k: bK, lens: verified?.right, focal: focal, w: w, h: h) {
                let search = max(8, Int(min(Float(w / 3), (focal * rect.baseline / 230).rounded(.up))))
                let brightnessSamples = stride(from: 0, to: first.count, by: 29).map { first[$0] }.filter { $0 >= 0 }
                let brightEnough = !brightnessSamples.isEmpty
                    && brightnessSamples.reduce(0, +) >= 12 * brightnessSamples.count
                var disparities: [Float] = []
                var disparityGrid = snapshot == nil ? [] : [Float?](repeating: nil, count: w * h)
                let step = w == 256 ? 3 : 2
                for row in stride(from: 2, to: h - 2, by: step) {
                    for col in stride(from: 2, to: w - 2, by: step) {
                        guard let d = StereoCorrespondence.matchDisparity(left: first, right: second,
                            width: w, height: h, x: col, y: row, maxShift: search) else { continue }
                        disparities.append(d)
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
                let calibrationStatus = verified == nil ? "Unverified calibration" : "Verified profile"
                detail = "\(calibrationStatus) • disparity \(median) px [\(range)] • \(matched) matches"
                if let pending = snapshot {
                    snapshot = nil
                    let url = Self.exportPair(a, b, ids: ids, positions: positions, aK: aK, bK: bK, ext: ext,
                        timestamp: timestamp, disparity: disparityGrid, width: w, height: h, focal: focal)
                    DispatchQueue.main.async { pending.completion(url) }
                }
                if verified != nil {
                    if cells >= mapWidth * mapHeight / 10 { error = nil }
                    else { error = brightEnough ? "Distance unavailable: low texture or overlap" : "Distance unavailable: low light" }
                }
            }
        }
        processingMS = (CACurrentMediaTime() - began) * 1000
        onFrame(DepthFrame(source: .stereo, timestamp: timestamp, geometry: geometry,
                           width: mapWidth, height: mapHeight, centimeters: cm, confidence: confidence,
                           detail: detail, error: error, captureProcessingMS: processingMS), a)
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

    private static func exportPair(_ a: CVPixelBuffer, _ b: CVPixelBuffer, ids: [String],
                                   positions: [Float], aK: simd_float3x3, bK: simd_float3x3,
                                   ext: simd_float4x3, timestamp: Double, disparity: [Float?],
                                   width: Int, height: Int, focal: Float) -> URL? {
        func image(_ buffer: CVPixelBuffer, k: simd_float3x3, position: Float) -> [String: Any]? {
            guard CVPixelBufferIsPlanar(buffer),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            var pgm = Data("P5\n\(w) \(h)\n255\n".utf8)
            for y in 0..<h { pgm.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: w) }
            return ["width": w, "height": h, "intrinsics": [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y],
                    "position": position, "pgmBase64": pgm.base64EncodedString()]
        }
        guard let left = image(a, k: aK, position: positions[0]), let right = image(b, k: bK, position: positions[1]) else { return nil }
        let transform = (0..<4).map { i in [ext[i].x, ext[i].y, ext[i].z] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID()).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["pair": ids, "left": left, "right": right,
                "captureSeconds": timestamp, "factoryExtrinsicsColumnsMM": transform,
                "rectifiedWidth": width, "rectifiedHeight": height, "rectifiedFocalPx": focal,
                "disparityPx": disparity.map { $0.map { NSNumber(value: $0) as Any } ?? NSNull() }])
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func matrix<T>(_ data: Data?, as type: T.Type) -> T? {
        guard let data, data.count == MemoryLayout<T>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: type) }
    }

    private static func intrinsics(_ sample: CMSampleBuffer) -> simd_float3x3? {
        let attachment = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
        return matrix(attachment as? Data, as: simd_float3x3.self)
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
