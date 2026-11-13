import SwiftUI
import AVFoundation
import QuartzCore

struct DirectionalAdvisory {
    var state = "UNKNOWN"
    var angleDeg: Double? = nil
    var confidence: Double? = nil
    var observedAngularRange: ClosedRange<Double>? = nil
    var sourceTimestamp: Double = 0
    func drawableAngle(now: Double) -> Double? {
        guard state == "AVAILABLE", let angle = angleDeg, angle.isFinite,
              let confidence = confidence, confidence > 0, confidence <= 1,
              let range = observedAngularRange, range.lowerBound >= -90, range.upperBound <= 90,
              range.contains(angle), (0...1).contains(now-sourceTimestamp) else { return nil }
        return angle
    }
}

func estimateDirectionalAdvisory(
    observation: ObstacleDetectionResult?,
    threat: String,
    now: Double,
    hfovDeg: Double = 65.0,
    prevAngle: Double? = nil
) -> DirectionalAdvisory {
    if threat == "PAUSED" || threat == "INITIALIZING" || threat == "SENSOR_FAULT" || observation == nil || !(observation?.isValid ?? false) {
        return DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: now)
    }
    guard let obs = observation, !obs.isZeroLuxBlind else {
        return DirectionalAdvisory(state: "UNKNOWN", sourceTimestamp: now)
    }

    let halfFov = hfovDeg / 2.0
    let obsRange = (-halfFov)...halfFov
    let camW = Double(obs.camWidth > 0 ? obs.camWidth : 192)
    let cx = camW / 2.0
    let fx = cx / tan(halfFov * .pi / 180.0)

    // Explicit validity-aware sector extraction (no fabricated 250cm defaults)
    let zLeftRaw = obs.sectorDists["LEFT"]
    let validL = zLeftRaw != nil && zLeftRaw!.isFinite && zLeftRaw! > 0
    let zLeft = validL ? Double(zLeftRaw!) : Double.nan

    var zCenterRaw = obs.sectorDists["CENTER"] ?? obs.distCM
    let validC = zCenterRaw.isFinite && zCenterRaw > 0
    let zCenter = validC ? Double(zCenterRaw) : Double.nan

    let zRightRaw = obs.sectorDists["RIGHT"]
    let validR = zRightRaw != nil && zRightRaw!.isFinite && zRightRaw! > 0
    let zRight = validR ? Double(zRightRaw!) : Double.nan

    if validC && zCenter < 50.0 && validL && zLeft < 60.0 && validR && zRight < 60.0 {
        return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: now)
    }

    struct ObsProfile {
        let angCenter: Double
        let radius: Double
        let weight: Double
        let zObs: Double
        let isValidDist: Bool
    }
    var profiles: [ObsProfile] = []

    for o in obs.allObstacles {
        let l = Double(o.bbox.x)
        let r = Double(o.bbox.x + o.bbox.w)
        let isDistValid = o.distCM.isFinite && o.distCM > 0
        let angLeft = atan2(l - cx, fx) * 180.0 / .pi
        let angRight = atan2(r - cx, fx) * 180.0 / .pi
        let angCenter = (angLeft + angRight) / 2.0
        let angHalfW = max(2.0, (angRight - angLeft) / 2.0)
        let totalRadius: Double
        let weight: Double
        let zVal: Double
        if isDistValid {
            zVal = max(10.0, Double(o.distCM))
            let marginDeg = min(22.0, max(4.0, atan2(20.0, zVal) * 180.0 / .pi))
            totalRadius = angHalfW + marginDeg
            if zVal < 50.0 { weight = 20.0 }
            else if zVal < 80.0 { weight = 10.0 }
            else if zVal < 150.0 { weight = 4.0 }
            else { weight = 1.0 }
        } else {
            // Unknown-distance obstacle: retain image-space angular occupancy without fabricating 100cm
            zVal = Double.nan
            let marginDeg = 8.0
            totalRadius = angHalfW + marginDeg
            weight = 12.0
        }
        profiles.append(ObsProfile(angCenter: angCenter, radius: totalRadius, weight: weight, zObs: zVal, isValidDist: isDistValid))
    }

    if profiles.isEmpty && validC && zCenter < 150.0 {
        let angCenter = Double(obs.pan) * halfFov
        let weight = zCenter < 80.0 ? 15.0 : 5.0
        profiles.append(ObsProfile(angCenter: angCenter, radius: 12.0, weight: weight, zObs: zCenter, isValidDist: true))
    }

    // Clear frame with no detected obstacles: only permitted if ALL 3 sectors are valid & clear
    if profiles.isEmpty {
        if validC && validL && validR && zCenter >= 150.0 && zLeft >= 150.0 && zRight >= 150.0 {
            let angOut = (prevAngle != nil && prevAngle!.isFinite) ? (0.3 * 0.0 + 0.7 * prevAngle!) : 0.0
            return DirectionalAdvisory(state: "AVAILABLE", angleDeg: angOut, confidence: 0.55, observedAngularRange: obsRange, sourceTimestamp: now)
        } else if !validC && !validL && !validR {
            return DirectionalAdvisory(state: "UNAVAILABLE", observedAngularRange: obsRange, sourceTimestamp: now)
        }
    }

    // Step 5A: Generate all candidate headings across observed FOV
    var allCandidateAngles: [Double] = []
    var aStep = -halfFov + 2.5
    while aStep <= halfFov - 2.5 + 1e-4 {
        allCandidateAngles.append(aStep)
        aStep += 2.5
    }

    // Step 5B: Determine eligibility for each candidate heading (P0-01 Hard Rejection)
    struct Candidate {
        let ang: Double
        let zSec: Double
        let risk: Double
    }
    var eligibleCandidates: [Candidate] = []
    var obstructedCount = 0

    for cand in allCandidateAngles {
        let (secValid, zSec): (Bool, Double)
        if cand < -10.0 {
            secValid = validL; zSec = zLeft
        } else if cand > 10.0 {
            secValid = validR; zSec = zRight
        } else {
            secValid = validC; zSec = zCenter
        }
        if !secValid { continue }

        var isBlocked = false
        if zSec < 40.0 { isBlocked = true }

        if !isBlocked {
            for p in profiles {
                let dAng = abs(cand - p.angCenter)
                if !p.isValidDist {
                    if dAng < p.radius { isBlocked = true; break }
                } else {
                    if p.zObs < 50.0 && dAng < p.radius { isBlocked = true; break }
                    if p.zObs < 35.0 && dAng < (p.radius + 2.0) { isBlocked = true; break }
                }
            }
        }

        if isBlocked {
            obstructedCount += 1
            continue
        }

        var risk = 0.0
        for p in profiles {
            let dAng = abs(cand - p.angCenter)
            if dAng < p.radius {
                let penetration = 1.0 - (dAng / p.radius)
                risk += p.weight * (penetration * penetration) * 15.0
            } else {
                let dEdge = dAng - p.radius
                if dEdge < 15.0 {
                    risk += p.weight * exp(-((dEdge * dEdge) / 40.0)) * 2.0
                }
            }
        }

        if zSec < 80.0 { risk += ((80.0 - zSec) / 10.0) * 4.0 }
        else if zSec < 150.0 { risk += ((150.0 - zSec) / 70.0) * 1.5 }

        risk += 0.05 * abs(cand)

        if let prev = prevAngle, prev.isFinite, abs(cand - prev) <= 3.5 {
            risk -= 1.0
        }

        eligibleCandidates.append(Candidate(ang: cand, zSec: zSec, risk: risk))
    }

    // Step 5C: Evaluate outcomes when no candidate is eligible
    if eligibleCandidates.isEmpty {
        if obstructedCount > 0 && (obstructedCount >= allCandidateAngles.count / 2 || (validC && zCenter < 50.0)) {
            return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: now)
        } else {
            return DirectionalAdvisory(state: "UNAVAILABLE", observedAngularRange: obsRange, sourceTimestamp: now)
        }
    }

    // ── Step 6: Hierarchical Movement Policy (Directive Section 3) ──

    // Priority 1: HOLD FORWARD
    var fwdEligible = false
    var fwdDist = Double.nan
    var fwdRisk = Double.infinity
    for c in eligibleCandidates {
        if abs(c.ang - 0.0) < 1.5 {
            fwdEligible = true
            fwdDist = c.zSec
            fwdRisk = c.risk
            break
        }
    }

    let fwdEncroached = profiles.contains { p in abs(p.angCenter) < p.radius }

    if fwdEligible && !fwdEncroached && fwdDist >= 75.0 && fwdRisk <= 4.0 {
        var angleOut = 0.0
        if let prev = prevAngle, prev.isFinite {
            angleOut = 0.35 * 0.0 + 0.65 * prev
            if abs(angleOut) < 1.0 { angleOut = 0.0 }
        }
        return DirectionalAdvisory(state: "AVAILABLE", angleDeg: angleOut, confidence: 0.55, observedAngularRange: obsRange, sourceTimestamp: now)
    }

    // Priority 2: SMALL CORRECTION
    let smallCandidates = eligibleCandidates.filter { abs($0.ang) <= 12.5 }
    if !smallCandidates.isEmpty {
        if let bestSc = smallCandidates.min(by: { ($0.risk + 0.08 * abs($0.ang)) < ($1.risk + 0.08 * abs($1.ang)) }) {
            if bestSc.risk < 20.0 && (!fwdEligible || fwdEncroached || bestSc.risk < fwdRisk - 0.5) {
                var scAngle = bestSc.ang
                if let prev = prevAngle, prev.isFinite {
                    scAngle = 0.45 * scAngle + 0.55 * prev
                }
                scAngle = max(-halfFov, min(halfFov, scAngle))
                let conf = max(0.35, min(0.55, 1.0 - (bestSc.risk / 35.0)))
                return DirectionalAdvisory(state: "AVAILABLE", angleDeg: scAngle, confidence: conf, observedAngularRange: obsRange, sourceTimestamp: now)
            }
        }
    }

    // Priority 3: ALTERNATIVE HEADING
    var bestCand = 0.0
    var minCost = Double.infinity
    for c in eligibleCandidates {
        var cost = c.risk + 0.08 * abs(c.ang)
        if let prev = prevAngle, prev.isFinite {
            cost += 0.05 * abs(c.ang - prev)
        }
        if cost < minCost {
            minCost = cost
            bestCand = c.ang
        }
    }

    if minCost > 30.0 || (threat == "CRITICAL" && validC && zCenter < 40.0) {
        return DirectionalAdvisory(state: "STOP", observedAngularRange: obsRange, sourceTimestamp: now)
    }

    let conf = max(0.30, min(0.55, 1.0 - (minCost / 35.0)))
    var selected = bestCand
    if let prev = prevAngle, prev.isFinite {
        selected = 0.45 * selected + 0.55 * prev
    }
    selected = max(-halfFov, min(halfFov, selected))

    return DirectionalAdvisory(state: "AVAILABLE", angleDeg: selected, confidence: conf, observedAngularRange: obsRange, sourceTimestamp: now)
}

final class DemoController: ObservableObject {
    let camera = CameraTorchManager()
    private let audio = SpatialAudioEngine()
    private let imu = IMUManager()
    @Published var active = false
    @Published var threat = "PAUSED"
    @Published var result: ObstacleDetectionResult?
    @Published var sourceTimestamp: Double = 0
    @Published var advisory = DirectionalAdvisory()
    private let lock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.horuseyes.inference", qos: .userInitiated)
    private var enabled = false
    private var busy = false
    private var generation = 0
    private var workerGeneration = -1
    private var depth: DepthEngine?
    private var kin = KinematicsEngine()
    private var budget = AuditoryBudgetManager()
    private var timer: Timer?
    private var started: Double = 0
    private var lastFrame: Double = 0
    private var yaw: Float = 0
    private var prevAngle: Double? = nil
    private var isAppeared: Bool = false

    func appear() {
        guard !isAppeared else { return }
        isAppeared = true

        camera.onFrameProcessed = { [weak self] buffer, frameId, settle, luma in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            self.lock.lock()
            self.lastFrame = now
            guard self.enabled && !self.busy else { self.lock.unlock(); return }
            self.busy = true
            let token = self.generation
            let rate = self.yaw
            self.lock.unlock()
            self.inferenceQueue.async {
                defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
                if self.workerGeneration != token {
                    self.kin = KinematicsEngine(); self.budget = AuditoryBudgetManager()
                    self.workerGeneration = token
                }
                if self.depth == nil { self.depth = DepthEngine() }
                let obs = self.depth!.processFrame(pixelBuffer: buffer, frameId: frameId,
                    aeSettleFramesRemaining: settle, meanLuma: luma, isZeroLuxBlind: luma < 10)
                let risk = self.kin.compute(obstacleResult: obs, frameId: frameId,
                    timestamp: now, aeSettleRemaining: settle, imuYawRateRadS: rate)
                let decision = self.budget.coordinate(obstacleResult: obs, kinematicsResult: risk)
                DispatchQueue.main.async {
                    self.lock.lock()
                    let current = self.enabled && self.generation == token
                    self.lock.unlock()
                    guard current else { return }
                    guard CACurrentMediaTime()-now <= 1 else { self.fault(); return }
                    self.result = obs.isValid ? obs : nil
                    self.sourceTimestamp = now
                    self.threat = risk.threatLevel
                    let adv = estimateDirectionalAdvisory(observation: obs, threat: risk.threatLevel, now: now, prevAngle: self.prevAngle)
                    self.advisory = adv
                    self.prevAngle = adv.state == "AVAILABLE" ? adv.angleDeg : nil
                    self.audio.update(decision: decision)
                }
            }
        }
        camera.start()
        imu.startMotionTracking()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func tick() {
        lock.lock(); yaw = imu.yawRateRadS; let frameTime = lastFrame; lock.unlock()
        guard active else { return }
        let now = CACurrentMediaTime()
        if now-started > 1 && (now-frameTime > 1 || now-sourceTimestamp > 1) { fault() }
        // Preview remains live; stale boxes must disappear independently of frames.
        if now-sourceTimestamp > 0.25 { result = nil }
    }
    private func silentDecision() -> BudgetDecision {
        BudgetDecision(isActive: false, pan: 0, proximity: 0, distCM: .nan, ttc: .infinity,
            priorityScore: 0, volumeFactor: 0, safeDirection: "NONE", cueMode: "MUTED", threatLevel: "UNKNOWN", suppressedCount: 0)
    }
    private func fault() {
        threat = "SENSOR_FAULT"; result = nil; advisory = DirectionalAdvisory(); prevAngle = nil
        audio.update(decision: BudgetDecision(isActive: true, pan: 0, proximity: 0.4, distCM: .nan,
            ttc: .infinity, priorityScore: 99, volumeFactor: 0.35, safeDirection: "STOP",
            cueMode: "SYSTEM_FAULT_TONE", threatLevel: "SENSOR_FAULT", suppressedCount: 0))
    }
    func toggle() { setActive(!active) }
    func setActive(_ value: Bool) {
        lock.lock(); generation += 1; enabled = value; lock.unlock()
        active = value; result = nil; advisory = DirectionalAdvisory(); prevAngle = nil
        started = CACurrentMediaTime(); sourceTimestamp = started
        threat = value ? "INITIALIZING" : "PAUSED"
        audio.update(decision: silentDecision())
        if value { audio.start() }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    func disappear() {
        guard isAppeared else { return }
        isAppeared = false

        setActive(false); timer?.invalidate(); timer = nil
        camera.stop(); imu.stopMotionTracking(); audio.stop()
    }
}

struct ContentView: View {
    @StateObject private var model = DemoController()
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreviewView(session: model.camera.session)
                TrackingOverlayView(result: model.result, threatLevel: model.threat)
                VStack {
                    Spacer()
                    DirectionIndicator(advisory: model.advisory, threat: model.threat)
                        .padding(.bottom, 30)
                }
            }.clipped()
            Button(action: model.toggle) {
                Text(model.active ? "DỪNG" : "CHẠY")
                    .font(.system(size: 28, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .foregroundColor(model.active ? Color.white : Color(white: 0.08))
                    .background(model.active ? Color(red: 0.92, green: 0.31, blue: 0.31) : Color(white: 0.88)).cornerRadius(20)
            }
            .accessibilityLabel(model.active ? "Dừng nhận thức tránh va chạm" : "Bắt đầu nhận thức tránh va chạm")
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(white: 0.07))
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}

struct DirectionIndicator: View {
    let advisory: DirectionalAdvisory
    let threat: String
    var body: some View {
        Group {
            if let angle = advisory.drawableAngle(now: CACurrentMediaTime()), threat != "PAUSED" {
                Image(systemName: "arrow.up")
                    .font(.system(size: 64, weight: .heavy))
                    .rotationEffect(.degrees(angle)).scaleEffect(x: 1, y: 0.7)
                    .foregroundStyle(LinearGradient(colors: [.white, .gray], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black, radius: 1, x: 4, y: 7)
                    .animation(.easeOut(duration: 0.15), value: angle)
                    .accessibilityLabel("Estimated direction advisory")
            } else {
                Label(threat == "CRITICAL" ? "STOP" : threat == "PAUSED" ? "PAUSED" : "UNAVAILABLE",
                    systemImage: threat == "CRITICAL" ? "hand.raised.fill" : "minus.circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(threat == "CRITICAL" ? .red : .white)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(Color.black.opacity(0.8)).cornerRadius(16)
                    .accessibilityLabel(threat == "CRITICAL" ? "Stop. Obstacle detected" : "Direction unavailable")
            }
        }
    }
}
