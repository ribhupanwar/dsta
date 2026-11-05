import Foundation
import Combine

/// WHOOP-device-only training insights.
/// Apple Health is intentionally not queried for Sleep, Recovery or Strain.
/// Metrics remain unavailable until WHOOP-native history and timestamps are verified.
@MainActor
final class TrainingInsightsStore: ObservableObject {
    @Published private(set) var sleepHours: Double?
    @Published private(set) var sleepDebtHours: Double?
    @Published private(set) var typicalSleepHours: Double?
    @Published private(set) var sleepNeedHours: Double?
    @Published private(set) var recoveryScore: Int?
    @Published private(set) var recoveryStatus = "Waiting for verified WHOOP overnight HRV + resting HR"
    @Published private(set) var cardioLoadPoints: Double?
    @Published private(set) var workoutCountToday = 0
    @Published private(set) var workoutMinutesToday: Double?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    @Published private(set) var sleepSourceStatus = "WHOOP history pending · Apple Health excluded"
    @Published private(set) var recoverySourceStatus = "WHOOP overnight RR/RHR validation pending"
    @Published private(set) var strainSourceStatus = "WHOOP HR + verified motion load pending"

    /// Refresh deliberately clears prior HealthKit-derived values. This prevents
    /// Apple Watch or WHOOP-app HealthKit exports from masquerading as direct strap data.
    func refresh() {
        sleepHours = nil
        sleepDebtHours = nil
        typicalSleepHours = nil
        sleepNeedHours = nil
        recoveryScore = nil
        recoveryStatus = "Unavailable · WHOOP overnight HRV/RHR not yet validated"
        cardioLoadPoints = nil
        workoutCountToday = 0
        workoutMinutesToday = nil
        sleepSourceStatus = "No verified WHOOP sleep session yet"
        recoverySourceStatus = "No verified WHOOP overnight HRV + resting HR baseline yet"
        strainSourceStatus = "Waiting for WHOOP workout HR + validated motion stream"
        lastUpdated = Date()
        isRefreshing = false
    }
}
