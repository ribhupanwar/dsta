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

    /// Refresh WHOOP-only sleep/recovery placeholders without discarding an
    /// independently calculated workout load already derived from saved strap HR.
    func refresh() {
        sleepHours = nil
        sleepDebtHours = nil
        typicalSleepHours = nil
        sleepNeedHours = nil
        recoveryScore = nil
        recoveryStatus = "Unavailable · WHOOP overnight HRV/RHR not yet validated"
        sleepSourceStatus = "No verified WHOOP sleep session yet"
        recoverySourceStatus = "No verified WHOOP overnight HRV + resting HR baseline yet"
        lastUpdated = Date()
        isRefreshing = false
    }

    /// Computes a transparent PulseForge cardio-load estimate from saved WHOOP
    /// workout HR recordings. It is not WHOOP's proprietary 0–21 Strain score.
    func refreshWorkoutLoad(sessions: [WorkoutSessionRecord],
                            measuredMaxHeartRate: Int,
                            now: Date = Date(),
                            calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let todays = sessions.filter { $0.startedAt >= start && $0.startedAt < end }
        workoutCountToday = todays.count
        workoutMinutesToday = todays.isEmpty ? nil :
            todays.reduce(0) { $0 + max(0, $1.durationSeconds) / 60 }
        cardioLoadPoints = CardioLoadCalculator.dailyWorkoutLoad(
            sessions: todays,
            dayStart: start,
            nextDay: end,
            measuredMaxHeartRate: measuredMaxHeartRate
        )
        if cardioLoadPoints != nil {
            strainSourceStatus = "PulseForge cardio-load estimate · saved WHOOP workout HR · not WHOOP Strain"
        } else if todays.isEmpty {
            strainSourceStatus = "No saved WHOOP workout HR session today"
        } else if measuredMaxHeartRate == 0 {
            strainSourceStatus = "Set measured maximum HR to calculate cardio load"
        } else {
            strainSourceStatus = "No valid timestamped WHOOP workout HR samples for today's load"
        }
        lastUpdated = now
    }
}
