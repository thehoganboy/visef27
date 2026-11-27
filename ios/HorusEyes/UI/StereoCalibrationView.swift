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
    private let ranges = [50, 100, 200, 300]

    private struct Shot {
        let url: URL
        let measuredCM: Double?
        let target: Int
        let quality: StereoCalibrationQuality
    }

    private var fitting: [Shot] { shots.filter { $0.target == 0 } }
    private var references: Set<Int> { Set(shots.map(\.target).filter { $0 > 0 }) }
    private var regions: Int {
        Set(fitting.map { shot in
            let a = shot.quality.a
            return min(2, Int(a.centerX * 3)) + 3 * min(2, Int(a.centerY * 3))
        }).count
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
                    Text("Use a flat, matte, asymmetric checkerboard with a white border. Count inner corners and measure one square. Keep the entire board inside both previews.")
                    TextField("Inner corner columns", text: $columns).keyboardType(.numberPad)
                    TextField("Inner corner rows", text: $rows).keyboardType(.numberPad)
                    TextField("Measured square size (mm)", text: $squareMM).keyboardType(.decimalPad)
                }
                .disabled(!shots.isEmpty)
                Section("Live pair quality") {
                    if let quality = model.calibrationQuality {
                        HStack(alignment: .top, spacing: 12) {
                            camera("Camera A", quality.a)
                            camera("Camera B", quality.b)
                        }
                        Text("Skew \(quality.skewMS, specifier: "%.1f") ms · \(quality.focusStable ? "Steady focus" : "Hold phone steady")")
                            .font(.caption.monospacedDigit())
                        Text("The workstation confirms full corner detection and pose geometry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Waiting for both physical cameras.")
                    }
                }
                Section(target == 0 ? "Fitting captures" : "Independent references") {
                    Picker("Trial", selection: $target) {
                        Text("Fitting pose").tag(0)
                        ForEach(ranges, id: \.self) { cm in
                            Text("Reference near \(cm) cm" + (references.contains(cm) ? " ✓" : "")).tag(cm)
                        }
                    }
                    .onChange(of: target) { _ in measured = "" }
                    .disabled(busy)
                    if target == 0 {
                        Text("Start centered at arm’s length to lock focus. Capture 20–25 pairs. Move across the shared field, vary distance, and tilt the board in both directions.")
                    } else {
                        Text("Center the board with its plane close to perpendicular to camera A. Measure the distance along its optical axis from the camera plane.")
                        TextField("Actual optical-axis distance (cm)", text: $measured).keyboardType(.decimalPad)
                    }
                    Button(busy ? "Checking pair…" : "Capture next steady pair") { takeShot() }
                        .disabled(busy || setup == nil || shots.count >= 64)
                    Text("\(fitting.count) fitting pairs · \(regions) image regions · \(references.count)/4 reference ranges")
                    if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                }
                Section("Export") {
                    Button("Prepare calibration dataset") { export() }
                        .disabled(busy || setup == nil || fitting.count < 15 || references.count < 4)
                    if let exportURL { ShareLink(item: exportURL) }
                    Text("Run the workstation fitter, then import its JSON profile in Camera options. Recapture the dataset if the camera pair, format or focus has changed.")
                }
            }
            .navigationTitle("Stereo calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
        }
        .onAppear { model.setCalibrationPreview(true) }
        .onDisappear {
            model.setCalibrationPreview(false)
            for shot in shots { try? FileManager.default.removeItem(at: shot.url) }
        }
    }

    private func camera(_ name: String, _ quality: StereoCalibrationQuality.Camera) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.subheadline.weight(.semibold))
            if let image = DemoController.disparityImage(quality.thumbnail) {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFit().frame(maxHeight: 145)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(quality.framingHint).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        message = "Hold the phone and checkerboard still."
        let trial = target
        model.captureCalibrationPair { url, quality in
            busy = false
            guard let url, let quality else {
                message = "No pair passed the live screen. Check both views, lighting, focus and pair skew."
                return
            }
            let repeated = trial == 0 && fitting.suffix(4).contains { shot in
                func near(_ a: StereoCalibrationQuality.Camera, _ b: StereoCalibrationQuality.Camera) -> Bool {
                    hypot(a.centerX - b.centerX, a.centerY - b.centerY) < 0.018 && abs(a.spread - b.spread) < 0.012
                }
                return near(shot.quality.a, quality.a) && near(shot.quality.b, quality.b)
            }
            if repeated {
                try? FileManager.default.removeItem(at: url)
                message = "Framing resembles a recent fitting pair. Move or tilt the board and try again."
                return
            }
            shots.append(Shot(url: url, measuredCM: reference, target: trial, quality: quality))
            exportURL = nil
            message = trial == 0 ? "Fitting pair saved. Change the board position or angle." : "Independent reference saved."
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
