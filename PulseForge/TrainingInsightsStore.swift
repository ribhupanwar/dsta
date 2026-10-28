import Foundation
import HealthKit
import Combine

/// Transparent, HealthKit-backed training insights. No score is emitted when its
/// required inputs or a usable baseline are missing.
@MainActor
final class TrainingInsightsStore: ObservableObject {
    @Published private(set) var sleepHours: Double?
    @Published private(set) var sleepDebtHours: Double?
    @Published private(set) var sleepNeedHours: Double = 8
    @Published private(set) var recoveryScore: Int?
    @Published private(set) var recoveryStatus = "Waiting for HRV and resting-HR baseline"
    @Published private(set) var cardioLoadPoints: Double?
    @Published private(set) var workoutCountToday = 0
    @Published private(set) var workoutMinutesToday: Double?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    private let healthStore = HKHealthStore()
    private let calendar = Calendar.current
    private let sleepTargetMinutes = 8.0 * 60.0

    func refresh() {
        guard HKHealthStore.isHealthDataAvailable(), !isRefreshing else { return }
        isRefreshing = true
        let group = DispatchGroup()

        group.enter()
        loadSleep { [weak self] hours, debt in
            self?.sleepHours = hours
            self?.sleepDebtHours = debt
            group.leave()
        }

        group.enter()
        loadRecovery { [weak self] score, status in
            self?.recoveryScore = score
            self?.recoveryStatus = status
            group.leave()
        }

        group.enter()
        loadTodayWorkouts { [weak self] count, minutes, load in
            self?.workoutCountToday = count
            self?.workoutMinutesToday = minutes
            self?.cardioLoadPoints = load
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            self?.lastUpdated = Date()
            self?.isRefreshing = false
        }
    }

    private func loadSleep(completion: @escaping (Double?, Double?) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(nil, nil)
            return
        }
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -9, to: end) ?? end.addingTimeInterval(-9 * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) {
            [weak self] _, samples, _ in
            guard let self else { completion(nil, nil); return }
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            let asleep = (samples as? [HKCategorySample] ?? [])
                .filter { asleepValues.contains($0.value) }
                .map { DateInterval(start: $0.startDate, end: $0.endDate) }
                .sorted { $0.start < $1.start }

            // Merge overlapping samples across sources/stages so duplicated
            // Apple Health intervals are not counted twice.
            var merged: [DateInterval] = []
            for interval in asleep {
                guard let last = merged.last else { merged.append(interval); continue }
                if interval.start <= last.end {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
                } else {
                    merged.append(interval)
                }
            }

            var minutesByNight: [Date: Double] = [:]
            for interval in merged {
                // Assign a sleep interval to the morning on which it ended.
                let night = self.calendar.startOfDay(for: interval.end)
                minutesByNight[night, default: 0] += interval.duration / 60
            }
            let today = self.calendar.startOfDay(for: Date())
            let latestNight = minutesByNight.keys.filter { $0 <= today }.max()
            let latestHours = latestNight.flatMap { minutesByNight[$0] }.map { $0 / 60 }

            // Only completed prior nights contribute to debt; missing nights
            // are not silently treated as zero hours.
            let completedNights = minutesByNight.keys
                .filter { $0 <= today }
                .sorted(by: >)
                .prefix(7)
            let debtMinutes = completedNights.reduce(0.0) { partial, night in
                partial + max(0, self.sleepTargetMinutes - (minutesByNight[night] ?? 0))
            }
            DispatchQueue.main.async {
                completion(latestHours, completedNights.isEmpty ? nil : debtMinutes / 60)
            }
        }
        healthStore.execute(query)
    }

    private func loadRecovery(completion: @escaping (Int?, String) -> Void) {
        let group = DispatchGroup()
        var hrvSamples: [HKQuantitySample] = []
        var rhrSamples: [HKQuantitySample] = []
        group.enter()
        loadQuantity(.heartRateVariabilitySDNN, days: 8) { hrvSamples = $0; group.leave() }
        group.enter()
        loadQuantity(.restingHeartRate, days: 8) { rhrSamples = $0; group.leave() }
        group.notify(queue: .main) {
            let today = self.calendar.startOfDay(for: Date())
            let currentHRV = hrvSamples.filter { $0.endDate >= today }.max { $0.endDate < $1.endDate }
            let currentRHR = rhrSamples.filter { $0.endDate >= today }.max { $0.endDate < $1.endDate }
            let baselineHRVValues = hrvSamples.filter { $0.endDate < today }.map {
                $0.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            }
            let baselineRHRValues = rhrSamples.filter { $0.endDate < today }.map {
                $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
            }
            guard let currentHRV, let currentRHR,
                  !baselineHRVValues.isEmpty, !baselineRHRValues.isEmpty else {
                completion(nil, "Need today's HRV + resting HR and prior-day baselines")
                return
            }
            let hrvNow = currentHRV.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            let rhrNow = currentRHR.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
            let hrvBaseline = baselineHRVValues.reduce(0, +) / Double(baselineHRVValues.count)
            let rhrBaseline = baselineRHRValues.reduce(0, +) / Double(baselineRHRValues.count)
            guard hrvBaseline > 0, rhrBaseline > 0 else {
                completion(nil, "Baseline data is not valid yet")
                return
            }
            let hrvComponent = min(100, max(0, 50 + 50 * ((hrvNow / hrvBaseline) - 1) / 0.30))
            let rhrComponent = min(100, max(0, 50 + 5 * (rhrBaseline - rhrNow)))
            let score = Int((0.60 * hrvComponent + 0.40 * rhrComponent).rounded())
            completion(score, "PulseForge estimate · HRV 60% + resting HR 40%")
        }
    }

    private func loadQuantity(_ identifier: HKQuantityTypeIdentifier, days: Int,
                              completion: @escaping ([HKQuantitySample]) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            completion([])
            return
        }
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -days, to: end) ?? end.addingTimeInterval(-Double(days) * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]) {
            _, samples, _ in
            DispatchQueue.main.async {
                completion(samples as? [HKQuantitySample] ?? [])
            }
        }
        healthStore.execute(query)
    }

    private func loadTodayWorkouts(completion: @escaping (Int, Double?, Double?) -> Void) {
        let start = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) {
            [weak self] _, samples, _ in
            let workouts = samples as? [HKWorkout] ?? []
            let minutes = workouts.reduce(0.0) { $0 + $1.duration / 60 }
            // A defensible cardiovascular load needs workout HR samples and a
            // user-measured max HR. Until both are available, leave it blank.
            guard let self,
                  let maxHR = UserDefaults.standard.string(forKey: "pulseforge.running.maxHeartRate").flatMap(Int.init),
                  maxHR > 0 else {
                completion(workouts.count, minutes > 0 ? minutes : nil, nil)
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion(workouts.count, minutes > 0 ? minutes : nil, nil)
                    return
                }
                self.loadWorkoutHeartRate(workouts, maxHR: maxHR) { load in
                    completion(workouts.count, minutes > 0 ? minutes : nil, load)
                }
            }
        }
        healthStore.execute(query)
    }

    private func loadWorkoutHeartRate(_ workouts: [HKWorkout], maxHR: Int,
                                      completion: @escaping (Double?) -> Void) {
        guard !workouts.isEmpty,
              let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            completion(nil)
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var totalLoad = 0.0
        for workout in workouts {
            group.enter()
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) {
                _, samples, _ in
                let values = samples as? [HKQuantitySample] ?? []
                for (index, sample) in values.enumerated() {
                    let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
                    let nextGap = index + 1 < values.count
                        ? values[index + 1].startDate.timeIntervalSince(sample.startDate)
                        : sample.endDate.timeIntervalSince(sample.startDate)
                    let minutes = min(1.0, max(0, nextGap) / 60)
                    let intensity = min(1, max(0, bpm / Double(maxHR)))
                    lock.lock()
                    totalLoad += minutes * intensity * 100
                    lock.unlock()
                }
                group.leave()
            }
            self.healthStore.execute(query)
        }
        group.notify(queue: .main) { completion(totalLoad > 0 ? totalLoad : nil) }
    }
}
