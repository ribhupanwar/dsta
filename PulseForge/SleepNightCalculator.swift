import Foundation

/// Groups HealthKit asleep intervals into sleep sessions without double-counting
/// overlapping stage/source samples. A session is assigned to its wake-up day.
enum SleepNightCalculator {
    struct Night: Equatable {
        let wakeDate: Date
        let durationMinutes: Double
        let startDate: Date
        let endDate: Date
    }

    private struct Session {
        var start: Date
        var end: Date
        var asleepDuration: TimeInterval
    }

    struct Summary: Equatable {
        let latestNight: Night?
        let nights: [Night]
        let sleepDebtHours: Double?
        /// Median of the longest recorded sleep session per wake day in the supplied history.
        let typicalSleepHours: Double?
    }

    static func summarize(intervals: [DateInterval],
                          now: Date,
                          calendar: Calendar,
                          targetMinutes: Double = 480,
                          debtWindowNights: Int = 7,
                          sessionGapMinutes: Double = 90) -> Summary {
        guard targetMinutes.isFinite, targetMinutes > 0,
              debtWindowNights > 0,
              sessionGapMinutes.isFinite, sessionGapMinutes >= 0 else {
            return Summary(latestNight: nil, nights: [], sleepDebtHours: nil, typicalSleepHours: nil)
        }

        let valid = intervals
            .filter { $0.start < $0.end && $0.end <= now }
            .sorted { $0.start < $1.start }

        // First union overlapping samples (e.g. duplicate Apple Health sources).
        var merged: [DateInterval] = []
        for interval in valid {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                merged.append(interval)
            }
        }

        // Then join fragments separated by short awakenings into one night.
        let gap = sessionGapMinutes * 60
        var sessions: [Session] = []
        for interval in merged {
            guard var last = sessions.popLast() else {
                sessions.append(Session(start: interval.start, end: interval.end, asleepDuration: interval.duration))
                continue
            }
            if interval.start.timeIntervalSince(last.end) <= gap {
                // Keep the night grouped, but do not count the awake gap as sleep.
                last.end = interval.end
                last.asleepDuration += interval.duration
                sessions.append(last)
            } else {
                sessions.append(last)
                sessions.append(Session(start: interval.start, end: interval.end, asleepDuration: interval.duration))
            }
        }

        let allSessions = sessions.map { session in
            Night(
                wakeDate: calendar.startOfDay(for: session.end),
                durationMinutes: session.asleepDuration / 60,
                startDate: session.start,
                endDate: session.end
            )
        }

        // Multiple sleep sessions can end on the same wake day (for example,
        // a daytime nap). Until naps are independently classified, use the
        // longest session for that day so a nap is never mistaken for another
        // full night of sleep debt.
        let nights = Dictionary(grouping: allSessions, by: \.wakeDate)
            .compactMap { _, sameDaySessions in
                sameDaySessions.max { $0.durationMinutes < $1.durationMinutes }
            }
            .sorted { $0.endDate > $1.endDate }

        let debtNights = Array(nights.prefix(debtWindowNights))
        let debt = debtNights.isEmpty ? nil :
            debtNights.reduce(0.0) { $0 + max(0, targetMinutes - $1.durationMinutes) } / 60

        // One main session per wake day feeds the 28-day median pattern metric.
        let mainSessionHours = nights.map { $0.durationMinutes / 60 }.sorted()
        let typicalSleepHours: Double?
        if mainSessionHours.isEmpty {
            typicalSleepHours = nil
        } else {
            let middle = mainSessionHours.count / 2
            typicalSleepHours = mainSessionHours.count.isMultiple(of: 2)
                ? (mainSessionHours[middle - 1] + mainSessionHours[middle]) / 2
                : mainSessionHours[middle]
        }

        return Summary(
            latestNight: nights.first,
            nights: nights,
            sleepDebtHours: debt,
            typicalSleepHours: typicalSleepHours
        )
    }
}
