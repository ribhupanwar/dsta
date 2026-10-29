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
            self?.sleepNeedHours = SleepNeedCalculator.calculate(sleepDebtHours: debt)
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
                HKCategoryValueSleepAnalysis.asleep.rawValue, // Legacy HealthKit sleep samples.
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            let intervals = (samples as? [HKCategorySample] ?? [])
                .filter { asleepValues.contains($0.value) }
                .map { DateInterval(start: $0.startDate, end: $0.endDate) }
            let summary = SleepNightCalculator.summarize(
                intervals: intervals,
                now: end,
                calendar: self.calendar,
                targetMinutes: self.sleepTargetMinutes,
                debtWindowNights: 7,
                sessionGapMinutes: 90
            )
            let latestHours = summary.latestNight.map { $0.durationMinutes / 60 }
            DispatchQueue.main.async {
                completion(latestHours, summary.sleepDebtHours)
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
            let hrvByDay = Dictionary(grouping: hrvSamples.filter { $0.endDate < today }) {
                self.calendar.startOfDay(for: $0.endDate)
            }.values.map { samples in
                samples.map { $0.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli)) }
                    .reduce(0, +) / Double(samples.count)
            }
            let rhrByDay = Dictionary(grouping: rhrSamples.filter { $0.endDate < today }) {
                self.calendar.startOfDay(for: $0.endDate)
            }.values.map { samples in
                samples.map { $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())) }
                    .reduce(0, +) / Double(samples.count)
            }
            guard let currentHRV, let currentRHR else {
                completion(nil, "Need today's HRV + resting HR")
                return
            }
            let hrvNow = currentHRV.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            let rhrNow = currentRHR.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
            guard let result = RecoveryScoreCalculator.calculate(
                currentHRV: hrvNow,
                currentRestingHeartRate: rhrNow,
                baselineHRV: hrvByDay,
                baselineRestingHeartRate: rhrByDay,
                minimumBaselineDays: 3
            ) else {
                completion(nil, "Building baseline · need 3 prior days of HRV + resting HR")
                return
            }
            completion(result.score, "PulseForge estimate · HRV 60% + resting HR 40% · 3+ day median baseline")
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
            guard let self else {
                completion(workouts.count, minutes > 0 ? minutes : nil, nil)
                return
            }
            let maxHR = UserDefaults.standard.integer(forKey: "pulseforge.running.maxHeartRate")
            guard maxHR > 0 else {
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
                let values = (samples as? [HKQuantitySample] ?? []).map { sample in
                    CardioLoadCalculator.Sample(
                        timestamp: sample.startDate,
                        endDate: sample.endDate,
                        bpm: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
                    )
                }
                let workoutLoad = CardioLoadCalculator.calculate(
                    samples: values,
                    measuredMaxHeartRate: maxHR
                ) ?? 0
                lock.lock()
                totalLoad += workoutLoad
                lock.unlock()
                group.leave()
            }
            self.healthStore.execute(query)
        }
        group.notify(queue: .main) { completion(totalLoad > 0 ? totalLoad : nil) }
    }
}
