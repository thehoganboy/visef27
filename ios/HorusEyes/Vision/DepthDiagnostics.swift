import Foundation
import UIKit

final class DepthDiagnostics {
    private var rows: [String] = []
    private var precedingFrames: [Double] = []
    private var latencies: [Double] = []
    private var currentSource: DepthMode?
    private var lastRequest: (DepthMode, Date)?

    func label(frame: DepthFrame, observation: ObstacleDetectionResult?, latencyMS: Double) -> String {
        if currentSource != frame.source {
            precedingFrames.removeAll()
            latencies.removeAll()
            currentSource = frame.source
        }
        precedingFrames.append(frame.timestamp)
        precedingFrames.removeAll { frame.timestamp - $0 > 2 }
        let span = frame.timestamp - (precedingFrames.first ?? frame.timestamp)
        let fps = span > 0 ? Double(precedingFrames.count - 1) / span : 0
        latencies.append(latencyMS)
        if latencies.count > 120 { latencies.removeFirst() }
        let ranked = latencies.sorted()
        let timing = ranked.count >= 20
            ? String(format: "P50 %.0f / P95 %.0f ms", ranked[ranked.count / 2], ranked[Int(ceil(Double(ranked.count) * 0.95)) - 1])
            : String(format: "%.0f ms", latencyMS)
        let status = frame.error ?? frame.source.distanceLabel(observation?.sectorDists["CENTER"] ?? .nan)
        let confidence = frame.strongCoverage.map { String(format: " • %.0f%% high", $0 * 100) } ?? ""
        let stereo = frame.source == .stereo ? "\n" + frame.detail : ""
        let stages = frame.stereoMetrics.map {
            String(format: "\n%@ • rectify %.1f ms • match %.1f ms • B %.1f mm • f %.1f px • skew %.2f ms\nRejected range %d • uncertainty %d • projection %d",
                   $0.stage, $0.rectificationMS, $0.matchingMS, $0.baselineMM, $0.focalPx, $0.skewMS,
                   $0.rangeRejected, $0.uncertaintyRejected, $0.projectionRejected)
        } ?? ""
        return "\(frame.source.rawValue) • \(status) • " + String(format: "%.0f%% valid • %.1f FPS", frame.coverage * 100, fps)
            + confidence + " • " + timing + stereo + stages
    }

    func switchRequested(_ source: DepthMode) {
        if let (pending, _) = lastRequest { switchOutcome(pending, outcome: "superseded") }
        precedingFrames.removeAll()
        latencies.removeAll()
        lastRequest = (source, Date())
        append(["switch_request", source.rawValue, "", "", "", "", "", "", "", "", "", ""])
    }

    func switchOutcome(_ source: DepthMode, outcome: String, completing: Bool = true) {
        let elapsed = lastRequest.flatMap { $0.0 == source ? number(Date().timeIntervalSince($0.1) * 1000) : nil }
        if completing, lastRequest?.0 == source { lastRequest = nil }
        append(["switch_outcome", source.rawValue, "", "", "", "", "", "", "", "", elapsed ?? "", outcome])
    }

    func recordLifecycle(_ source: DepthMode, state: String, timestamp: Double) {
        append(["lifecycle", source.rawValue, number(timestamp), "", "", "", state])
    }

    func record(frame: DepthFrame, observation: ObstacleDetectionResult?, state: String, reason: String = "",
                inferenceMS: Double, endToEndMS: Double, tracks: [MetricObstacleTracker.Track] = [],
                angle: Double? = nil, risk: String = "", audioCue: String = "", captureFPS: Double? = nil) {
        // Central image ROI for comparison with an independently measured target.
        var roi: [Float] = []
        var roiSigma: [Float] = []
        var roiTotal = 0
        if frame.width > 0, frame.height > 0, frame.centimeters.count == frame.width * frame.height {
            for y in (frame.height * 45 / 100)..<(frame.height * 55 / 100) {
                for x in (frame.width * 45 / 100)..<(frame.width * 55 / 100) {
                    let i = y * frame.width + x
                    let cm = frame.centimeters[i]
                    roiTotal += 1
                    if frame.isValidSample(i) {
                        roi.append(cm)
                        if i < frame.stereoUncertaintyCM.count { roiSigma.append(frame.stereoUncertaintyCM[i]) }
                    }
                }
            }
        }
        roi.sort()
        roiSigma = roiSigma.filter(\.isFinite).sorted()
        let central = observation?.spatialBins.filter { abs($0.angleCenter) <= 5 } ?? []
        let centralCoverage = central.isEmpty ? "" : number(Double(central.map(\.validRatio).reduce(0, +)) / Double(central.count))
        let fields = ["frame", frame.source.rawValue, number(frame.timestamp), number(frame.coverage),
                      number(inferenceMS), number(endToEndMS), state,
                      roi.isEmpty ? "" : number(Double(roi[roi.count / 2])),
                      number(Double(observation?.sectorDists["CENTER"] ?? .nan)), frame.detail, "",
                      frame.error ?? "", frame.strongCoverage.map(number) ?? ""]
        let extras = [reason, roiTotal > 0 ? number(Double(roi.count) / Double(roiTotal)) : "",
                      roiSigma.isEmpty ? "" : number(Double(roiSigma[roiSigma.count / 2])), centralCoverage]
        var stages = [frame.calibration.rawValue, frame.readiness.rawValue]
        if let m = frame.stereoMetrics {
            stages += [m.stage, String(m.width), String(m.height), String(m.overlapPixels), String(m.disparityPixels),
                       String(m.rangeRejected), String(m.uncertaintyRejected), String(m.projectionRejected),
                       number(m.skewMS), number(Double(m.focalPx)), number(Double(m.baselineMM)),
                       number(Double(m.motionPx)), number(m.rectificationMS), number(m.matchingMS),
                       frame.provisionalROICM.map { number(Double($0)) } ?? ""]
        } else {
            stages += Array(repeating: "", count: 15)
        }
        let trackFields = tracks.map { track in
            let box = [track.box.minX, track.box.minY, track.box.width, track.box.height].map { number(Double($0)) }
            return ([String(track.id)] + box + [number(Double(track.distanceCM)), number(Double(track.confidence))]).joined(separator: ":")
        }
        let components = (observation?.allObstacles ?? []).prefix(48).map { object in
            let b = object.bbox
            return [String(object.componentID ?? object.id), String(b.x), String(b.y), String(b.w), String(b.h),
                    number(Double(object.distCM))].joined(separator: ":")
        }
        let decision = [angle.map(number) ?? "", risk, audioCue, captureFPS.map(number) ?? ""]
        append(fields + Array(repeating: "", count: 16) + extras + stages + [trackFields.joined(separator: "|"),
            components.joined(separator: "|")] + decision)
    }

    private lazy var deviceModel: String = {
        var info = utsname()
        guard uname(&info) == 0 else { return UIDevice.current.model }
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    func recordStereo(_ event: StereoCapture.Event) {
        let json = event.telemetry.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        append(["stereo_capture", DepthMode.stereo.rawValue, "", "", "", "", "", "", "", event.message, "",
                event.error, "", deviceModel, UIDevice.current.systemVersion, event.pair, event.formatA, event.formatB,
                event.fps, String(event.configured), event.hardware, event.pressure, event.pressureLevel,
                event.stage, String(event.accepted), String(event.rejected), number(event.pairFPS), event.strategy, json])
    }

    func export() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vampior-\(UUID().uuidString).csv")
        try ([Self.header] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) : ""
    }

    private let dateFormatter = ISO8601DateFormatter()
    private static let header = "utc,event,source,capture_s,valid_fraction,processing_ms,end_to_end_ms,state,target_roi_cm,center_corridor_cm,detail,switch_ms,error,high_confidence_fraction,device_model,ios_version,camera_pair,format_a,format_b,requested_fps,configured,hardware_cost,pressure_cost,pressure_level,capture_stage,accepted_pairs,rejected_pairs,pair_fps,capture_strategy,delivery_telemetry_json,decision_reason,target_roi_valid_fraction,target_roi_sigma_cm,central_body_valid_fraction,calibration,readiness,stereo_processing_stage,rectified_width,rectified_height,overlap_px,disparity_px,range_rejected_px,uncertainty_rejected_px,projection_rejected_px,skew_ms,focal_px,baseline_mm,yaw_skew_px,rectification_ms,matching_ms,provisional_roi_cm,tracks_id_xywh_cm_confidence,components_id_xywh_cm,advisory_angle_deg,risk,audio_cue,source_capture_fps"
    private static let columns = header.split(separator: ",").count

    private func append(_ fields: [String]) {
        let values = [dateFormatter.string(from: Date())] + fields + Array(repeating: "", count: max(0, Self.columns - fields.count - 1))
        rows.append(values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ","))
        if rows.count > 6000 { rows.removeFirst(500) }
    }
}
