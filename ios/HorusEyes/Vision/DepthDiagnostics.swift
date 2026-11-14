import Foundation

final class DepthDiagnostics {
    private var rows: [String] = []
    private var precedingFrames: [Double] = []
    private var currentSource: DepthMode?
    private var lastRequest: (DepthMode, Date)?

    func label(frame: DepthFrame, latencyMS: Double) -> String {
        if currentSource != frame.source {
            precedingFrames.removeAll()
            currentSource = frame.source
        }
        precedingFrames.append(frame.timestamp)
        precedingFrames.removeAll { frame.timestamp - $0 > 2 }
        let span = frame.timestamp - (precedingFrames.first ?? frame.timestamp)
        let fps = span > 0 ? Double(precedingFrames.count - 1) / span : 0
        let status = frame.error ?? String(format: "%.0f%% valid", frame.coverage * 100)
        return "\(frame.source.rawValue) • \(status) • " + String(format: "%.1f FPS • %.1f ms", fps, latencyMS)
    }

    func switchRequested(_ source: DepthMode) {
        if let (pending, _) = lastRequest { switchOutcome(pending, outcome: "superseded") }
        precedingFrames.removeAll()
        lastRequest = (source, Date())
        append(["switch_request", source.rawValue, "", "", "", "", "", "", "", "", "", ""])
    }

    func switchOutcome(_ source: DepthMode, outcome: String) {
        let elapsed = lastRequest.flatMap { $0.0 == source ? number(Date().timeIntervalSince($0.1) * 1000) : nil }
        if lastRequest?.0 == source { lastRequest = nil }
        append(["switch_outcome", source.rawValue, "", "", "", "", "", "", "", "", elapsed ?? "", outcome])
    }

    func record(frame: DepthFrame, observation: ObstacleDetectionResult?, state: String,
                inferenceMS: Double, endToEndMS: Double) {
        // Central image ROI for comparison with an independently measured target.
        var roi: [Float] = []
        if frame.width > 0, frame.height > 0 {
            for y in (frame.height * 45 / 100)..<(frame.height * 55 / 100) {
                for x in (frame.width * 45 / 100)..<(frame.width * 55 / 100) {
                    let cm = frame.centimeters[y * frame.width + x]
                    if cm.isFinite && cm > 0 { roi.append(cm) }
                }
            }
        }
        roi.sort()
        append(["frame", frame.source.rawValue, number(frame.timestamp), number(frame.coverage),
                number(inferenceMS), number(endToEndMS), state,
                roi.isEmpty ? "" : number(Double(roi[roi.count / 2])),
                number(Double(observation?.sectorDists["CENTER"] ?? .nan)), frame.detail, "", frame.error ?? ""])
    }

    func export() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vampior-\(UUID().uuidString).csv")
        let header = "utc,event,source,capture_s,valid_fraction,processing_ms,end_to_end_ms,state,target_roi_cm,center_corridor_cm,detail,switch_ms,error"
        try ([header] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) : ""
    }

    private let dateFormatter = ISO8601DateFormatter()

    private func append(_ fields: [String]) {
        let values = [dateFormatter.string(from: Date())] + fields
        rows.append(values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ","))
        if rows.count > 6000 { rows.removeFirst(500) }
    }
}
