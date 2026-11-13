// HorusEyes 2.0 — DepthEngine.swift
// ════════════════════════════════════════════════════════════════════════════════
// Core ML Apple Neural Engine Depth Estimation + Spatial Engine v8 Safety Pipeline
// High-Precision Multi-Obstacle Tracking & Non-Linear Proximity Acoustic Mapping
// ════════════════════════════════════════════════════════════════════════════════

import Foundation
import Combine
import CoreML
import Vision
import Accelerate
import CoreVideo
import QuartzCore

// ── Data Structures ────────────────────────────────────────────────────────────
struct SingleObstacle: Identifiable {
    let id: Int
    let x: Int
    let y: Int
    let bbox: (x: Int, y: Int, w: Int, h: Int)
    let pan: Float
    let proximity: Float
    let distCM: Float
    let modeText: String
    let uncertaintyScore: Float
    let isWall: Bool
}

struct SpatialBin {
    let binId: Int
    let angleMin: Float
    let angleMax: Float
    let angleCenter: Float
    let validRatio: Float
    let rawDepthStatistic: Float
    let distCM: Float
    let isValid: Bool
    let hasObstacle: Bool
    let bodyDistCM: Float
    let groundDistCM: Float
    let overheadDistCM: Float
}

struct ObstacleDetectionResult {
    let x: Int
    let y: Int
    let bbox: (x: Int, y: Int, w: Int, h: Int)
    let pan: Float
    let proximity: Float
    let distCM: Float
    let modeText: String
    let uncertaintyScore: Float
    let isWall: Bool
    let sectorDists: [String: Float]  // "LEFT", "CENTER", "RIGHT"
    let allObstacles: [SingleObstacle]
    let isZeroLuxBlind: Bool
    let isOverheadHazard: Bool
    let isDropOffHazard: Bool
    let camWidth: Int
    let camHeight: Int
    var isValid: Bool = true
    var spatialBins: [SpatialBin] = []
    var timestamp: Double = 0.0

    init(
        x: Int,
        y: Int,
        bbox: (x: Int, y: Int, w: Int, h: Int),
        pan: Float,
        proximity: Float,
        distCM: Float,
        modeText: String,
        uncertaintyScore: Float,
        isWall: Bool,
        sectorDists: [String: Float],
        allObstacles: [SingleObstacle],
        isZeroLuxBlind: Bool,
        isOverheadHazard: Bool,
        isDropOffHazard: Bool,
        camWidth: Int,
        camHeight: Int,
        isValid: Bool = true,
        spatialBins: [SpatialBin] = [],
        timestamp: Double = 0.0
    ) {
        self.x = x
        self.y = y
        self.bbox = bbox
        self.pan = pan
        self.proximity = proximity
        self.distCM = distCM
        self.modeText = modeText
        self.uncertaintyScore = uncertaintyScore
        self.isWall = isWall
        self.sectorDists = sectorDists
        self.allObstacles = allObstacles
        self.isZeroLuxBlind = isZeroLuxBlind
        self.isOverheadHazard = isOverheadHazard
        self.isDropOffHazard = isDropOffHazard
        self.camWidth = camWidth
        self.camHeight = camHeight
        self.isValid = isValid
        self.spatialBins = spatialBins
        self.timestamp = timestamp
    }
}

// ── Depth Engine ───────────────────────────────────────────────────────────────
final class DepthEngine: ObservableObject {
    @Published var lastResult: ObstacleDetectionResult?
    @Published var inferenceLatencyMs: Float = 0.0

    private var mlModel: MLModel?
    private var vnModel: VNCoreMLModel?
    private let pchip: PchipInterpolator

    // Grid Dimensions for Processing (4:3 Landscape aspect ratio)
    private let gridW = 48
    private let gridH = 64

    init() {
        self.pchip = PchipInterpolator(nodes: Config.calibrationNodes)
        setupCoreMLModel()
    }

    // ── Setup Core ML (computeUnits = .all for 16-core Apple Neural Engine) ────
    private func setupCoreMLModel() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.allowLowPrecisionAccumulationOnGPU = true

        // Look for compiled .mlmodelc or .mlpackage in main bundle
        if let modelUrl = Bundle.main.url(forResource: "DepthModel", withExtension: "mlmodelc") {
            loadModel(at: modelUrl, configuration: configuration)
        } else if let pkgUrl = Bundle.main.url(forResource: "DepthModel", withExtension: "mlpackage") {
            do {
                let compiledUrl = try MLModel.compileModel(at: pkgUrl)
                loadModel(at: compiledUrl, configuration: configuration)
            } catch { print("[HorusEyes] Model compile failed: \(error)") }
        } else {
            print("[HorusEyes] DepthModel absent; perception unavailable.")
        }
    }

    private func loadModel(at url: URL, configuration: MLModelConfiguration) {
        do {
            let model = try MLModel(contentsOf: url, configuration: configuration)
            self.mlModel = model
            self.vnModel = try VNCoreMLModel(for: model)
            print("[HorusEyes] Core ML DepthModel loaded; computeUnits all (actual device placement unverified).")
        } catch {
            print("[HorusEyes] Failed to load Core ML model: \(error)")
        }
    }

    // ── Primary Pipeline Execution ────────────────────────────────────────────
    func processFrame(
        pixelBuffer: CVPixelBuffer,
        frameId: UInt64,
        sourceTimestamp: Double = CACurrentMediaTime(),
        aeSettleFramesRemaining: Int,
        meanLuma: Float,
        isZeroLuxBlind: Bool
    ) -> ObstacleDetectionResult {
        let startTime = CACurrentMediaTime()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Step 0: Immediate Zero-Lux Blind check (Sensor Fault Mode)
        if isZeroLuxBlind || meanLuma < 12 || meanLuma > 245 {
            let blindResult = ObstacleDetectionResult(
                x: width / 2, y: height / 2,
                bbox: (x: width / 4, y: height / 4, w: width / 2, h: height / 2),
                pan: 0.0, proximity: 0.4, distCM: .nan,
                modeText: "SENSOR_BLIND (0-Lux)",
                uncertaintyScore: 0.95, isWall: false,
                sectorDists: ["LEFT": 0.0, "CENTER": 0.0, "RIGHT": 0.0],
                allObstacles: [],
                isZeroLuxBlind: true,
                isOverheadHazard: false,
                isDropOffHazard: false,
                camWidth: width,
                camHeight: height, isValid: false,
                timestamp: sourceTimestamp
            )
            DispatchQueue.main.async { self.lastResult = blindResult }
            return blindResult
        }

        // Generate disparity map (via CoreML ANE Vision or Native Spatial Fallback)
        guard let rawDisparity = inferDisparity(pixelBuffer: pixelBuffer),
              rawDisparity.count == gridW * gridH,
              rawDisparity.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return ObstacleDetectionResult(x: 0, y: 0, bbox: (0,0,0,0), pan: 0,
                proximity: 0.4, distCM: .nan, modeText: "MODEL_UNAVAILABLE", uncertaintyScore: 1,
                isWall: false, sectorDists: [:], allObstacles: [], isZeroLuxBlind: false,
                isOverheadHazard: false, isDropOffHazard: false, camWidth: width, camHeight: height,
                isValid: false, timestamp: sourceTimestamp)
        }

        // Execute Spatial Engine v8 Rules
        let result = evaluateSpatialEngineV8(
            rawDisparity: rawDisparity,
            w: width,
            h: height,
            meanLuma: meanLuma,
            sourceTimestamp: sourceTimestamp
        )

        let elapsedMs = Float((CACurrentMediaTime() - startTime) * 1000.0)
        DispatchQueue.main.async {
            self.inferenceLatencyMs = elapsedMs
            self.lastResult = result
        }

        return result
    }

    // ── Disparity Inference ───────────────────────────────────────────────────
    private func inferDisparity(pixelBuffer: CVPixelBuffer) -> [Float]? {
        if let vn = self.vnModel {
            var extractedGrid: [Float]?
            let request = VNCoreMLRequest(model: vn) { [weak self] req, err in
                if let results = req.results as? [VNCoreMLFeatureValueObservation],
                   let multiArray = results.first?.featureValue.multiArrayValue {
                    extractedGrid = self?.extractDisparityGrid(from: multiArray)
                }
            }
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                if let grid = extractedGrid {
                    return grid
                }
            } catch {
                print("[HorusEyes] Vision inference error: \(error)")
            }
        }

        return nil
    }

    private func extractDisparityGrid(from array: MLMultiArray) -> [Float]? {
        let shape = array.shape.map { $0.intValue }
        guard shape == [1, 256, 192] else { return nil }
        // MLMultiArray indexing respects strides and data type, unlike pointer
        // assumptions about a contiguous Float32 buffer.
        var grid = [Float](repeating: 0, count: gridW * gridH)
        for y in 0..<gridH {
            for x in 0..<gridW {
                grid[y * gridW + x] = array[[0, NSNumber(value: y * 256 / gridH),
                    NSNumber(value: x * 192 / gridW)]].floatValue
            }
        }
        return grid
    }

    // ── Non-Linear Proximity Mapping (100% Parity with Python dist_to_proximity) ──
    func distToProximity(distCM: Float) -> Float {
        if distCM <= Config.distCriticalCM {
            return 1.0
        } else if distCM < Config.distDangerCM {
            return 0.70 + 0.30 * (Config.distDangerCM - distCM) / (Config.distDangerCM - Config.distCriticalCM)
        } else if distCM < Config.distWarningCM {
            return 0.35 + 0.35 * (Config.distWarningCM - distCM) / (Config.distWarningCM - Config.distDangerCM)
        } else if distCM < Config.distAlertCM {
            return 0.05 + 0.30 * (Config.distAlertCM - distCM) / (Config.distAlertCM - Config.distWarningCM)
        } else {
            return 0.0
        }
    }

    // ── Spatial Engine v8 Multi-Hazard Safety Arbiter ─────────────────────────
    private func evaluateSpatialEngineV8(
        rawDisparity: [Float],
        w: Int,
        h: Int,
        meanLuma: Float,
        sourceTimestamp: Double = CACurrentMediaTime()
    ) -> ObstacleDetectionResult {
        // Step 1: Lens Saturation check (>25% center area >= 800.0 raw)
        let centerBoxX1 = Int(Double(gridW) * 0.25)
        let centerBoxX2 = Int(Double(gridW) * 0.75)
        let centerBoxY1 = Int(Double(gridH) * 0.25)
        let centerBoxY2 = Int(Double(gridH) * 0.75)

        var centerSatCount = 0
        var centerTotal = 0
        var centerValues = [Float]()

        for y in centerBoxY1..<centerBoxY2 {
            for x in centerBoxX1..<centerBoxX2 {
                let val = rawDisparity[y * gridW + x]
                centerValues.append(val)
                if val >= Config.saturationRawThreshold {
                    centerSatCount += 1
                }
                centerTotal += 1
            }
        }

        let centerSatRatio = centerTotal > 0 ? Float(centerSatCount) / Float(centerTotal) : 0.0
        if centerSatRatio >= Config.saturationCenterRatio {
            let satDist = 13.0 as Float
            let satBbox = (x: w / 4, y: h / 4, w: w / 2, h: h / 2)
            let satObs = SingleObstacle(
                id: 1, x: w / 2, y: h / 2, bbox: satBbox, pan: 0.0,
                proximity: 1.0, distCM: satDist, modeText: "CRITICAL_SATURATED",
                uncertaintyScore: 0.05, isWall: false
            )
            let satBins = computeSpatialBins(rawDisparity: rawDisparity, w: w, h: h, detectedObstacles: [satObs])
            return ObstacleDetectionResult(
                x: w / 2, y: h / 2, bbox: satBbox, pan: 0.0, proximity: 1.0,
                distCM: satDist, modeText: "CRITICAL_SATURATED",
                uncertaintyScore: 0.05, isWall: false,
                sectorDists: ["LEFT": 13.0, "CENTER": 13.0, "RIGHT": 13.0],
                allObstacles: [satObs],
                isZeroLuxBlind: false,
                isOverheadHazard: false,
                isDropOffHazard: false,
                camWidth: w,
                camHeight: h,
                spatialBins: satBins,
                timestamp: sourceTimestamp
            )
        }

        // Step 2: 3-Sector Distance Calculation using 80th percentile of raw disparity (P20 distance)
        let secW = gridW / 3
        var leftRaws = [Float]()
        var centerRaws = [Float]()
        var rightRaws = [Float]()

        let activeY1 = Int(Double(gridH) * 0.15)
        let activeY2 = Int(Double(gridH) * 0.85)

        for y in activeY1..<activeY2 {
            for x in 0..<secW {
                leftRaws.append(rawDisparity[y * gridW + x])
            }
            for x in secW..<(2 * secW) {
                centerRaws.append(rawDisparity[y * gridW + x])
            }
            for x in (2 * secW)..<gridW {
                rightRaws.append(rawDisparity[y * gridW + x])
            }
        }

        let rawL = Self.percentile(leftRaws, 0.80)
        let rawC = Self.percentile(centerRaws, 0.80)
        let rawR = Self.percentile(rightRaws, 0.80)

        let distL = pchip.interpolate(rawL)
        let distC = pchip.interpolate(rawC)
        let distR = pchip.interpolate(rawR)
        let sectorDists: [String: Float] = ["LEFT": distL, "CENTER": distC, "RIGHT": distR]

        // Step 3: Overhead Hazard Check (top 15% ROI)
        var isOverhead = false
        let topCut = max(1, Int(Double(gridH) * Double(Config.topMaskRatio)))
        var topRaws = [Float]()
        for y in 0..<topCut {
            for x in 0..<gridW {
                topRaws.append(rawDisparity[y * gridW + x])
            }
        }
        if !topRaws.isEmpty {
            let topFgRaw = Self.percentile(topRaws, 0.85)
            let topFgDist = pchip.interpolate(topFgRaw)
            let topBgRaw = Self.percentile(topRaws, 0.30)
            let topBgDist = pchip.interpolate(topBgRaw)
            if topFgDist < (topBgDist - Config.overheadDepthDeltaCM) && topFgDist < Config.distWarningCM {
                isOverhead = true
            }
        }

        // Step 4: Drop-Off Hazard Check (bottom 15% ROI)
        var isDropOff = false
        let botCut = Int(Double(gridH) * (1.0 - Double(Config.bottomMaskRatio)))
        var groundRaws = [Float]()
        var aboveGroundRaws = [Float]()
        for y in botCut..<gridH {
            for x in 0..<gridW {
                groundRaws.append(rawDisparity[y * gridW + x])
            }
        }
        let aboveYStart = max(0, botCut - Int(Double(gridH) * 0.05))
        for y in aboveYStart..<botCut {
            for x in 0..<gridW {
                aboveGroundRaws.append(rawDisparity[y * gridW + x])
            }
        }
        if !groundRaws.isEmpty && !aboveGroundRaws.isEmpty {
            let groundMed = Self.median(groundRaws)
            let aboveMed = Self.median(aboveGroundRaws)
            let gradRatio = abs(aboveMed - groundMed) / max(aboveMed, 1.0)
            if gradRatio > Config.dropOffGradientThresh && groundMed < aboveMed * 0.6 {
                isDropOff = true
            }
        }

        // Step 5: Multi-Obstacle Blob Clustering (Connected-Component Search)
        let peakRaw = rawDisparity.max() ?? 200.0
        let clusterThresh = max(Config.baseActivationRaw, peakRaw - 160.0)

        var visited = [Bool](repeating: false, count: gridW * gridH)
        var clusters = [(minX: Int, maxX: Int, minY: Int, maxY: Int, rawVals: [Float])]()

        for y in activeY1..<activeY2 {
            for x in 0..<gridW {
                let idx = y * gridW + x
                if !visited[idx] && rawDisparity[idx] >= clusterThresh {
                    // BFS Flood fill
                    var q = [(x, y)]
                    visited[idx] = true
                    var cMinX = x, cMaxX = x, cMinY = y, cMaxY = y
                    var cVals = [Float]()

                    var head = 0
                    while head < q.count {
                        let (cx, cy) = q[head]
                        head += 1
                        cVals.append(rawDisparity[cy * gridW + cx])
                        cMinX = min(cMinX, cx); cMaxX = max(cMaxX, cx)
                        cMinY = min(cMinY, cy); cMaxY = max(cMaxY, cy)

                        // 4 neighbors
                        let neighbors = [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                        for (nx, ny) in neighbors {
                            if nx >= 0 && nx < gridW && ny >= activeY1 && ny < activeY2 {
                                let nIdx = ny * gridW + nx
                                if !visited[nIdx] && rawDisparity[nIdx] >= clusterThresh {
                                    visited[nIdx] = true
                                    q.append((nx, ny))
                                }
                            }
                        }
                    }

                    // Keep clusters that are substantial or slender vertical objects
                    let cW = cMaxX - cMinX + 1
                    let cH = cMaxY - cMinY + 1
                    let isSlender = (cH >= 6 && cW >= 1)
                    if cVals.count >= 4 || isSlender {
                        clusters.append((cMinX, cMaxX, cMinY, cMaxY, cVals))
                    }
                }
            }
        }

        // Sort clusters by peak proximity (highest disparity first)
        clusters.sort { c1, c2 in
            let p1 = Self.percentile(c1.rawVals, 0.90)
            let p2 = Self.percentile(c2.rawVals, 0.90)
            return p1 > p2
        }

        var detectedObstacles = [SingleObstacle]()
        for (idx, cl) in clusters.prefix(3).enumerated() {
            let clRaw = Self.percentile(cl.rawVals, 0.90)
            let clDist = pchip.interpolate(clRaw)
            let clProx = distToProximity(distCM: clDist)

            let centerX = (cl.minX + cl.maxX) / 2
            let centerY = (cl.minY + cl.maxY) / 2
            let pan = (Float(centerX) - Float(gridW) / 2.0) / (Float(gridW) / 2.0)

            let screenX = Int(Float(cl.minX) / Float(gridW) * Float(w))
            let screenY = Int(Float(cl.minY) / Float(gridH) * Float(h))
            let screenW = max(50, Int(Float(cl.maxX - cl.minX + 1) / Float(gridW) * Float(w)))
            let screenH = max(50, Int(Float(cl.maxY - cl.minY + 1) / Float(gridH) * Float(h)))
            let bbox = (x: screenX, y: screenY, w: screenW, h: screenH)

            let mText: String
            if clDist <= Config.distCriticalCM {
                mText = "CRITICAL (\(Int(clDist))cm)"
            } else if clDist <= Config.distDangerCM {
                mText = "DANGER (\(Int(clDist))cm)"
            } else if clDist <= Config.distWarningCM {
                mText = "WARNING (\(Int(clDist))cm)"
            } else {
                mText = "CAUTION (\(Int(clDist))cm)"
            }

            detectedObstacles.append(SingleObstacle(
                id: idx + 1,
                x: screenX + screenW / 2,
                y: screenY + screenH / 2,
                bbox: bbox,
                pan: pan,
                proximity: clProx,
                distCM: clDist,
                modeText: mText,
                uncertaintyScore: 0.12,
                isWall: false
            ))
        }

        // Primary Obstacle Decision
        let primaryObs: SingleObstacle
        if let first = detectedObstacles.first {
            primaryObs = first
        } else {
            let safeDist = distC
            let dummyBbox = (x: w / 4, y: h / 4, w: w / 2, h: h / 2)
            primaryObs = SingleObstacle(
                id: 1, x: w / 2, y: h / 2, bbox: dummyBbox, pan: 0.0,
                proximity: 0.0, distCM: safeDist, modeText: "SAFE (Clear Path)",
                uncertaintyScore: 0.05, isWall: false
            )
        }

        var modeText = primaryObs.modeText
        if isOverhead {
            modeText = "OVERHEAD_HAZARD"
        } else if isDropOff {
            modeText = "DROP_OFF_HAZARD"
        } else if primaryObs.distCM > Config.distSafeCM {
            modeText = "SAFE (Clear Path)"
        }

        let bins = computeSpatialBins(rawDisparity: rawDisparity, w: w, h: h, detectedObstacles: detectedObstacles)

        return ObstacleDetectionResult(
            x: primaryObs.x,
            y: primaryObs.y,
            bbox: primaryObs.bbox,
            pan: primaryObs.pan,
            proximity: primaryObs.proximity,
            distCM: primaryObs.distCM,
            modeText: modeText,
            uncertaintyScore: primaryObs.uncertaintyScore,
            isWall: primaryObs.isWall,
            sectorDists: sectorDists,
            allObstacles: detectedObstacles,
            isZeroLuxBlind: false,
            isOverheadHazard: isOverhead,
            isDropOffHazard: isDropOff,
            camWidth: w,
            camHeight: h,
            spatialBins: bins,
            timestamp: sourceTimestamp
        )
    }

    // ── Numerical Utilities ───────────────────────────────────────────────────
    private static func percentile(_ array: [Float], _ p: Float) -> Float {
        guard !array.isEmpty else { return 0.0 }
        let sorted = array.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * p)))
        return sorted[idx]
    }

    private static func median(_ array: [Float]) -> Float {
        Self.percentile(array, 0.50)
    }

    func computeSpatialBins(
        rawDisparity: [Float],
        w: Int,
        h: Int,
        detectedObstacles: [SingleObstacle] = [],
        numBins: Int = 24,
        hfovDeg: Float = 65.0
    ) -> [SpatialBin] {
        let cx = Float(w) / 2.0
        let halfFov = hfovDeg / 2.0
        let fx = cx / tan(halfFov * .pi / 180.0)

        // Multi-band vertical boundaries in 48x64 disparity grid
        let cy1B = Int(Float(gridH) * 0.20) // ~12
        let cy2B = Int(Float(gridH) * 0.65) // ~41
        let cy1G = Int(Float(gridH) * 0.65) // ~41
        let cy2G = Int(Float(gridH) * 0.85) // ~54
        let cy1O = 0
        let cy2O = Int(Float(gridH) * 0.20) // ~12

        let colsPerBin = max(1, gridW / numBins) // 48 / 24 = 2 columns per bin
        let binW = Float(w) / Float(numBins)

        var bins: [SpatialBin] = []

        for i in 0..<numBins {
            let x1 = Int(round(Float(i) * binW))
            let x2 = max(x1 + 1, min(w, Int(round(Float(i + 1) * binW))))

            let angMin = atan2(Float(x1) - cx, fx) * 180.0 / .pi
            let angMax = atan2(Float(x2) - cx, fx) * 180.0 / .pi
            let angCenter = (angMin + angMax) / 2.0

            let gx1 = i * colsPerBin
            let gx2 = min(gridW, (i + 1) * colsPerBin)

            var validRatio: Float = 0.0
            var rawP80: Float = .nan
            var bodyDistCM: Float = .nan
            var groundDistCM: Float = .nan
            var overheadDistCM: Float = .nan
            var distCM: Float = .nan
            var isValid = false

            // 1. Body band [0.20h, 0.65h]
            var bodySamples: [Float] = []
            var totalBody = 0
            for y in cy1B..<cy2B {
                for x in gx1..<gx2 {
                    totalBody += 1
                    let v = rawDisparity[y * gridW + x]
                    if v.isFinite && v > 0 {
                        bodySamples.append(v)
                    }
                }
            }
            validRatio = totalBody > 0 ? Float(bodySamples.count) / Float(totalBody) : 0.0
            if validRatio >= 0.35 && !bodySamples.isEmpty {
                rawP80 = Self.percentile(bodySamples, 0.80)
                bodyDistCM = pchip.interpolate(rawP80)
                distCM = bodyDistCM
                isValid = bodyDistCM.isFinite && bodyDistCM > 0
            }

            // 2. Ground band [0.65h, 0.85h]
            var groundSamples: [Float] = []
            var totalGround = 0
            for y in cy1G..<cy2G {
                for x in gx1..<gx2 {
                    totalGround += 1
                    let v = rawDisparity[y * gridW + x]
                    if v.isFinite && v > 0 {
                        groundSamples.append(v)
                    }
                }
            }
            if totalGround > 0 && Float(groundSamples.count) / Float(totalGround) >= 0.35 && !groundSamples.isEmpty {
                let gP80 = Self.percentile(groundSamples, 0.80)
                groundDistCM = pchip.interpolate(gP80)
            }

            // 3. Overhead band [0.0h, 0.20h]
            var overheadSamples: [Float] = []
            var totalOverhead = 0
            for y in cy1O..<cy2O {
                for x in gx1..<gx2 {
                    totalOverhead += 1
                    let v = rawDisparity[y * gridW + x]
                    if v.isFinite && v > 0 {
                        overheadSamples.append(v)
                    }
                }
            }
            if totalOverhead > 0 && Float(overheadSamples.count) / Float(totalOverhead) >= 0.35 && !overheadSamples.isEmpty {
                let oP80 = Self.percentile(overheadSamples, 0.80)
                overheadDistCM = pchip.interpolate(oP80)
            }

            // Obstacle overlap
            var hasObs = false
            for obs in detectedObstacles {
                let ox1 = obs.bbox.x
                let ox2 = obs.bbox.x + obs.bbox.w
                if !(x2 <= ox1 || x1 >= ox2) {
                    hasObs = true
                    break
                }
            }

            bins.append(SpatialBin(
                binId: i,
                angleMin: round(angMin * 100) / 100,
                angleMax: round(angMax * 100) / 100,
                angleCenter: round(angCenter * 100) / 100,
                validRatio: round(validRatio * 1000) / 1000,
                rawDepthStatistic: rawP80,
                distCM: distCM,
                isValid: isValid,
                hasObstacle: hasObs,
                bodyDistCM: bodyDistCM,
                groundDistCM: groundDistCM,
                overheadDistCM: overheadDistCM
            ))
        }

        return bins
    }
}
