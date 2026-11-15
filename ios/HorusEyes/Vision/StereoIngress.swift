import AVFoundation
import QuartzCore
import simd

// One instance per attempt. AVFoundation and the two independent delegates
// share this delivery queue; the session queue only pulls a bounded snapshot.
final class StereoIngress: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    struct Image {
        let buffer: CVPixelBuffer
        let intrinsics: simd_float3x3?
        let raw: Double
        let host: Double
        let collection: UInt64?
    }

    struct Pair {
        let a: Image
        let b: Image
    }

    struct Status: Encodable {
        let cameras: [StereoStreamStats]
        let accepted: Int
        let rejected: Int
        let pairFPS: Double
        let nativeCollections: Int
        let recombinedCollections: Int
        let downstreamSkipped: Int
        let histogram: [Int]
        let medianSkewMS: Double?
        let p95SkewMS: Double?
        let candidateMedianSkewMS: Double?
        let candidateP95SkewMS: Double?
        let rejectionFraction: Double
        let offsetMS: Double?
        let jitterMS: Double?
        let lastPairHost: Double?
        var ready: Bool

        var failure: String {
            if cameras[0].samples == 0 && cameras[1].samples == 0 { return "Neither camera delivered usable frames" }
            if cameras[0].samples == 0 { return "Camera A delivered no usable frames" }
            if cameras[1].samples == 0 { return "Camera B delivered no usable frames" }
            if !ready { return "Both cameras delivered frames, but paired delivery was insufficient (≤8 ms required)" }
            return "Camera pair was ready"
        }
    }

    final class Delegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var ingress: StereoIngress?
        let camera: StereoCamera

        init(_ ingress: StereoIngress, camera: StereoCamera) {
            self.ingress = ingress
            self.camera = camera
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            ingress?.receive(sampleBuffer, camera: camera, collection: nil)
        }

        func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
            let raw = reason.map { String(describing: $0) } ?? "unspecified"
            let standard: String
            switch raw {
            case kCMSampleBufferDroppedFrameReason_FrameWasLate as String: standard = "lateData"
            case kCMSampleBufferDroppedFrameReason_OutOfBuffers as String: standard = "outOfBuffers"
            case kCMSampleBufferDroppedFrameReason_Discontinuity as String: standard = "discontinuity"
            default: standard = raw
            }
            ingress?.recordDrop(camera: camera, reason: standard)
        }
    }

    private let outputs: [AVCaptureVideoDataOutput]
    private let session: AVCaptureSession
    let queue = DispatchQueue(label: "com.visef.stereo.delivery", qos: .userInteractive)
    private var cameras = [StereoStreamStats(), StereoStreamStats()]
    private var matcher = StereoPairing<Image>()
    private var delivery = StereoNegotiation.Delivery()
    private var latestPair: Pair?
    private var collectionID: UInt64 = 0
    private var nativeCollections = 0
    private var recombinedCollections = 0
    private var downstreamSkipped = 0
    private var ended = false
    private let phase: StereoDeliveryPhase

    init(session: AVCaptureSession, a: AVCaptureVideoDataOutput, b: AVCaptureVideoDataOutput,
         phase: StereoDeliveryPhase) {
        self.session = session
        outputs = [a, b]
        self.phase = phase
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard !ended else { return }
        collectionID += 1
        let records = outputs.map { collection.synchronizedData(for: $0) as? AVCaptureSynchronizedSampleBufferData }
        for camera in StereoCamera.allCases {
            let index = camera.rawValue
            guard let record = records[index] else { cameras[index].missing += 1; continue }
            if record.sampleBufferWasDropped {
                let reason: String
                switch record.droppedReason {
                case .lateData: reason = "lateData"
                case .outOfBuffers: reason = "outOfBuffers"
                case .discontinuity: reason = "discontinuity"
                case .none: reason = "none"
                @unknown default: reason = "unknown(\(record.droppedReason.rawValue))"
                }
                cameras[index].drop(reason: reason)
                continue
            }
            receive(record.sampleBuffer, camera: camera, collection: collectionID)
        }
    }

    private func recordDrop(camera: StereoCamera, reason: String) {
        if !ended { cameras[camera.rawValue].drop(reason: reason) }
    }

    private func receive(_ sample: CMSampleBuffer, camera: StereoCamera, collection: UInt64?) {
        guard !ended else { return }
        let index = camera.rawValue
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
            cameras[index].invalidate("missingImage")
            return
        }
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else {
            cameras[index].invalidate("unexpectedPixelFormat")
            return
        }
        guard let clock = session.synchronizationClock else {
            cameras[index].invalidate("missingClock")
            return
        }
        let raw = CMSampleBufferGetPresentationTimeStamp(sample)
        let host = CMSyncConvertTime(raw, from: clock, to: CMClockGetHostTimeClock()).seconds
        let now = CACurrentMediaTime()
        guard raw.seconds.isFinite, host.isFinite, (-0.05...0.25).contains(now - host),
              cameras[index].lastHost.map({ host > $0 }) ?? true else {
            cameras[index].invalidate("invalidStaleOrNonmonotonicTimestamp")
            return
        }
        cameras[index].sample(raw: raw.seconds, host: host, arrived: now,
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer))
        let attachment = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
        let intrinsics = (attachment as? Data).flatMap { data in
            data.count == MemoryLayout<simd_float3x3>.size
                ? data.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) } : nil
        }
        let image = Image(buffer: buffer, intrinsics: intrinsics, raw: raw.seconds, host: host, collection: collection)
        guard let pair = matcher.ingest(.init(timestamp: host, payload: image), camera: camera) else { return }
        delivery.sample(timestamp: pair.0.timestamp)
        if phase != .independent {
            if let collection = pair.0.payload.collection, collection == pair.1.payload.collection {
                nativeCollections += 1
            } else {
                recombinedCollections += 1
            }
        }
        if latestPair != nil { downstreamSkipped += 1 }
        latestPair = Pair(a: pair.0.payload, b: pair.1.payload)
    }

    func read(takePair: Bool, now: Double) -> (Status, Pair?) {
        let connections = outputs.map { output -> (Bool, Bool, Bool, String) in
            let connection = output.connection(with: .video)
            let ports = connection?.inputPorts.map {
                "\($0.sourceDeviceType.rawValue)/\($0.isEnabled)"
            }.joined(separator: ",") ?? ""
            return (session.outputs.contains { $0 === output }, connection?.isEnabled ?? false,
                    connection?.isActive ?? false, ports)
        }
        return queue.sync {
            for (index, graph) in connections.enumerated() {
                cameras[index].attached = graph.0
                cameras[index].enabled = graph.1
                cameras[index].active = graph.2
                cameras[index].ports = graph.3
            }
            let skew = matcher.skew
            let candidate = matcher.candidateSkew
            let rejected = matcher.rejected + matcher.obsolete + cameras.reduce(0) { total, stats in
                total + stats.invalid + stats.dropped.values.reduce(0, +)
            }
            let fresh = delivery.last.map { (-0.05...0.75).contains(now - $0) } ?? false
            let samples = 2 * delivery.accepted + rejected
            let result = Status(cameras: cameras, accepted: delivery.accepted, rejected: rejected, pairFPS: delivery.fps,
                nativeCollections: nativeCollections, recombinedCollections: recombinedCollections,
                downstreamSkipped: downstreamSkipped, histogram: matcher.histogram, medianSkewMS: skew.median,
                p95SkewMS: skew.p95, candidateMedianSkewMS: candidate.median, candidateP95SkewMS: candidate.p95,
                rejectionFraction: samples > 0 ? Double(rejected) / Double(samples) : 0, offsetMS: skew.offset, jitterMS: skew.jitter, lastPairHost: delivery.last,
                ready: fresh && delivery.ready)
            let pair = takePair ? latestPair : nil
            if takePair { latestPair = nil }
            return (result, pair)
        }
    }

    func finish() {
        queue.sync {
            ended = true
            latestPair = nil
            matcher = StereoPairing()
        }
    }
}
