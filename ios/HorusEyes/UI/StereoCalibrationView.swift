import SwiftUI

struct StereoCalibrationView: View {
    @ObservedObject var model: DemoController
    @Environment(\.dismiss) private var dismiss
    @State private var columns = "8"
    @State private var rows = "5"
    @State private var squareMM = ""
    @State private var target = 0
    @State private var measured = ""
    @State private var shots: [Shot] = []
    @State private var busy = false
    @State private var message = ""
    @State private var exportURL: URL?

    private struct Shot {
        let url: URL
        let measuredCM: Double?
    }

    private var setup: (Int, Int, Double)? {
        guard let cols = Int(columns), let rows = Int(rows), (4...20).contains(cols), (4...20).contains(rows),
              cols != rows, let mm = number(squareMM), (1...200).contains(mm) else { return nil }
        return (cols, rows, mm)
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Checkerboard") {
                    TextField("Inner corner columns", text: $columns).keyboardType(.numberPad)
                    TextField("Inner corner rows", text: $rows).keyboardType(.numberPad)
                    TextField("Measured square size (mm)", text: $squareMM).keyboardType(.decimalPad)
                }
                .disabled(!shots.isEmpty)
                Section("Acquire pairs") {
                    if let image = model.preview {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 200)
                    }
                    Text("Use a flat, asymmetric checkerboard. Start with the full board visible in both cameras. The first shot locks focus. Capture 20–25 varied poses to retain at least 15 usable fitting pairs.")
                    Picker("Trial", selection: $target) {
                        Text("Calibration pose").tag(0)
                        ForEach([50, 100, 200, 300], id: \.self) { cm in Text("Reference near \(cm) cm").tag(cm) }
                    }
                    if target > 0 { TextField("Actual optical-axis distance (cm)", text: $measured).keyboardType(.decimalPad) }
                    Button("Capture synchronized checkerboard") { takeShot() }
                        .disabled(busy || setup == nil || shots.count >= 64)
                    Text("\(shots.filter { $0.measuredCM == nil }.count) fitting captures • \(shots.filter { $0.measuredCM != nil }.count) reference captures")
                    if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                }
                Section("Export") {
                    Button("Prepare calibration dataset") { export() }
                        .disabled(busy || setup == nil || shots.filter { $0.measuredCM == nil }.count < 15)
                    if let exportURL { ShareLink(item: exportURL) }
                }
            }
            .navigationTitle("Stereo calibration")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func takeShot() {
        var reference: Double?
        if target > 0 {
            guard let value = number(measured), abs(value - Double(target)) <= Double(target) * 0.1 else {
                message = "Enter the independently measured distance within 10% of the selected range."
                return
            }
            reference = value
        }
        busy = true
        message = "Checking synchronized images"
        model.captureCalibrationPair { url in
            busy = false
            guard let url else {
                message = "No qualifying pair. Check capture readiness, lighting, blur, focus and visibility in both views."
                return
            }
            shots.append(Shot(url: url, measuredCM: reference))
            exportURL = nil
            message = "Pair saved. Change the board position or angle before the next fitting shot."
        }
    }

    private func export() {
        guard let setup else { return }
        let entries = shots
        busy = true
        message = "Preparing export"
        DispatchQueue.global(qos: .utility).async {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-dataset-\(UUID()).jsonl")
            do {
                try Data().write(to: url)
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                func record(_ object: [String: Any]) throws {
                    try file.write(contentsOf: JSONSerialization.data(withJSONObject: object))
                    try file.write(contentsOf: Data([10]))
                }
                try record(["columns": setup.0, "rows": setup.1, "squareMM": setup.2, "schema": 1])
                for entry in entries {
                    let pair = try JSONSerialization.jsonObject(with: Data(contentsOf: entry.url))
                    var row: [String: Any] = ["capture": pair]
                    if let reference = entry.measuredCM { row["measuredCM"] = reference }
                    try record(row)
                }
                DispatchQueue.main.async {
                    exportURL = url
                    busy = false
                    message = "Dataset ready for the workstation fitting utility."
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    busy = false
                    message = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
