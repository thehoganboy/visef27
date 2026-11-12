import Foundation

@main struct BehaviorTests {
    static func obs(_ distance: Float = 30, objects: Bool = true, valid: Bool = true) -> ObstacleDetectionResult {
        let o = SingleObstacle(id: 1, x: 96, y: 128, bbox: (76,98,40,60), pan: 0,
            proximity: 1, distCM: distance, modeText: "OBSTACLE", uncertaintyScore: 0.1, isWall: false)
        return ObstacleDetectionResult(x: 96,y: 128,bbox: o.bbox,pan: 0,proximity: 1,distCM: distance,
            modeText: "OBSTACLE",uncertaintyScore: 0.1,isWall: false,
            sectorDists: ["LEFT":250,"CENTER":distance,"RIGHT":250],allObstacles: objects ? [o] : [],
            isZeroLuxBlind: false,isOverheadHazard: false,isDropOffHazard: false,camWidth: 192,camHeight: 256,isValid: valid)
    }
    static func main() {
        let kin = KinematicsEngine(), budget = AuditoryBudgetManager()
        for i in 1...12 {
            let result = kin.compute(obstacleResult: obs(),frameId: UInt64(i),timestamp: 10+Double(i)*0.1,aeSettleRemaining: 0)
            precondition(result.threatLevel == "CRITICAL" && result.primaryTTC.isInfinite, "Static proximity must not invent TTC")
            precondition(budget.coordinate(obstacleResult: obs(),kinematicsResult: result).isActive)
        }
        for i in 13...32 {
            let result = kin.compute(obstacleResult: obs(250,objects:false),frameId: UInt64(i),timestamp:10+Double(i)*0.1,aeSettleRemaining:0,imuYawRateRadS:0.6)
            precondition(result.threatLevel != "SAFE", "Rotation must not clear hazard")
            precondition(result.primaryTTC.isInfinite)
        }
        let fault = kin.compute(obstacleResult:obs(.nan,valid:false),frameId:33,timestamp:14,aeSettleRemaining:0)
        precondition(fault.threatLevel == "SENSOR_FAULT")
        precondition(budget.coordinate(obstacleResult:obs(.nan,valid:false),kinematicsResult:fault).cueMode == "SYSTEM_FAULT_TONE")
        print("PASS Swift: static TTC, active critical audio, rotation/loss, invalid model precedence")
    }
}
