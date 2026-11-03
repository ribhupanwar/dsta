import Foundation
import Combine

/// Keeps WHOOP-native Recovery separate from clearly labelled Apple Health sleep fallback metrics.
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

    @Published private(set) var sleepSourceStatus = "Waiting for dated sleep history"
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

    /// Latest Apple Health sleep duration is a separately labelled fallback.
    func updateHealthKitSleep(_ hours: Double?) {
        guard let hours, hours.isFinite, (0.1...24).contains(hours) else { return }
        sleepHours = hours
        sleepSourceStatus = "Apple Health sleep duration · WHOOP-native sleep not yet validated"
    }

    /// Builds a personal sleep baseline and rolling debt from dated Apple Health
    /// sleep sessions. These estimates are never presented as WHOOP-native values
    /// and never feed Recovery. Baseline requires 14 nights in 28 days.
    func updateHealthKitSleepHistory(_ nights: [SleepNightCalculator.Night],
                                     now: Date = Date(),
                                     calendar: Calendar = .current) {
        let result = SleepNeedHistoryCalculator.calculate(nights: nights, now: now, calendar: calendar)
        typicalSleepHours = result.baselineHours
        sleepDebtHours = result.sleepDebtHours
        sleepNeedHours = result.sleepNeedHours

        if let baseline = result.baselineHours {
            let debtText = result.sleepDebtHours.map { String(format: "%.1f h debt", $0) }
                ?? "building 7-night debt history · \(result.debtNightCount)/5 nights"
            sleepSourceStatus = String(format: "Apple Health estimate · personal baseline %.1f h · %@ · WHOOP sleep pending", baseline, debtText)
        } else {
            sleepSourceStatus = "Apple Health estimate · learning personal baseline · \(result.baselineNightCount)/14 nights in 28 days"
        }
    }

    /// Computes a transparent PulseForge cardio-load estimate from saved WHOOP
    /// workout HR recordings. It is not WHOOP's proprietary 0–21 Strain score.
    func refreshWorkoutLoad(sessions: [WorkoutSessionRecord],
                            measuredMaxHeartRate: Int,
                            now: Date = Date(),
                            calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        // Count only the part of each saved session that overlaps this local day.
        // A workout that crosses midnight contributes to both days, without
        // assigning its full duration or HR load to either day.
        let overlapMinutes = sessions.compactMap { session -> TimeInterval? in
            guard session.durationSeconds.isFinite, session.durationSeconds > 0 else { return nil }
            let sessionEnd = session.startedAt.addingTimeInterval(session.durationSeconds)
            guard sessionEnd > session.startedAt,
                  sessionEnd.timeIntervalSince1970.isFinite else { return nil }
            let overlapStart = max(session.startedAt, start)
            let overlapEnd = min(sessionEnd, end)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            return overlap > 0 ? overlap / 60 : nil
        }
        workoutCountToday = overlapMinutes.count
        workoutMinutesToday = overlapMinutes.isEmpty ? nil : overlapMinutes.reduce(0, +)

        // Pass the complete history so the calculator can include sessions that
        // began before midnight but still contain HR samples inside today's window.
        cardioLoadPoints = CardioLoadCalculator.dailyWorkoutLoad(
            sessions: sessions,
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
