// HorusEyes 2.0 — IMUManager.swift
// ════════════════════════════════════════════════════════════════════════════════
// CoreMotion Real-Time Inertial Measurement: Yaw Rate & Step Cadence Kinematics
// ════════════════════════════════════════════════════════════════════════════════

import Foundation
import Combine
import CoreMotion

final class IMUManager: ObservableObject {
    @Published var yawRateRadS: Float = 0.0
    @Published var estimatedWalkSpeedCmS: Float = 120.0
    @Published var isActivelyTurning: Bool = false

    private let motionManager = CMMotionManager()
    private let updateInterval: TimeInterval = 1.0 / 50.0 // 50 Hz IMU polling

    // Turning Intent State
    private var turnDirectionHistory: [Float] = []
    private let turnHistoryCapacity = 10

    // Step / Walking Cadence Estimator
    private var lastStepTimestamp: TimeInterval = 0.0
    private var stepCountInWindow: Int = 0

    init() {
        // DO NOT call startMotionTracking() here. It will be started in ContentView.onAppear.
    }

    deinit {
        stopMotionTracking()
    }

    func startMotionTracking() {
        guard motionManager.isDeviceMotionAvailable else {
            print("[HorusEyes] Notice: Device motion (IMU) unavailable on this device/simulator.")
            return
        }

        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion, error == nil else { return }
            self.processMotionSample(motion)
        }
    }

    func stopMotionTracking() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }

    private func processMotionSample(_ motion: CMDeviceMotion) {
        // Yaw rate (vertical axis rotation, radians/sec)
        let yawRate = Float(motion.rotationRate.y)
        self.yawRateRadS = yawRate

        // Check if user is actively turning head/body (> 0.35 rad/s)
        turnDirectionHistory.append(yawRate)
        if turnDirectionHistory.count > turnHistoryCapacity {
            turnDirectionHistory.removeFirst()
        }

        let avgYaw = turnDirectionHistory.reduce(0.0, +) / Float(turnDirectionHistory.count)
        let isTurning = abs(avgYaw) > 0.35
        self.isActivelyTurning = isTurning

        // User linear forward acceleration (z-axis or magnitude)
        let accel = motion.userAcceleration
        let accelMagnitude = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)

        // Basic pedestrian dead-reckoning / step detector
        if accelMagnitude > 0.30 {
            // Active walking detected
            self.estimatedWalkSpeedCmS = Config.userWalkSpeedCmS
        } else {
            // Stationary / paused
            self.estimatedWalkSpeedCmS = max(0.0, self.estimatedWalkSpeedCmS * 0.90)
        }
    }
}
