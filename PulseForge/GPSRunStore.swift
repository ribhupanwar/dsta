import Foundation
import CoreLocation
import HealthKit
import Combine

struct GPSRunSplit: Codable, Identifiable {
    var id: Int { kilometre }
    let kilometre: Int
    let durationSeconds: TimeInterval
    var paceSecondsPerKm: Double { durationSeconds }
}

struct GPSRunPoint: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double

    var location: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: altitude, horizontalAccuracy: horizontalAccuracy,
                   verticalAccuracy: -1, timestamp: timestamp)
    }

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        timestamp = location.timestamp
        horizontalAccuracy = location.horizontalAccuracy
    }
}

struct GPSRunRecord: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: TimeInterval
    let distanceMeters: Double
    let splits: [GPSRunSplit]
    let route: [GPSRunPoint]

    var averagePaceSecondsPerKm: Double {
        guard distanceMeters > 0 else { return 0 }
        return durationSeconds / (distanceMeters / 1000)
    }
}

/// Outdoor GPS running recorder. It is independent of WHOOP connectivity:
/// location, elapsed time, distance and splits continue even if the band drops.
@MainActor
final class GPSRunStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var hasActiveRun = false
    @Published private(set) var isPaused = false
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var currentPaceSecondsPerKm: Double?
    @Published private(set) var splits: [GPSRunSplit] = []
    @Published private(set) var routePointCount = 0
    @Published private(set) var locationStatus = "GPS ready"
    @Published private(set) var saveStatus = "Completed GPS runs save to Apple Health"
    @Published private(set) var lastSavedRun: GPSRunRecord?
    @Published private(set) var recentRuns: [GPSRunRecord] = []

    private let manager = CLLocationManager()
    private let healthStore = HKHealthStore()
    private var wantsToStart = false
    private var startedAt: Date?
    private var activeSegmentStartedAt: Date?
    private var accumulatedActiveSeconds: TimeInterval = 0
    private var splitStartElapsed: TimeInterval = 0
    private var nextSplitDistance = 1_000.0
    private var previousLocation: CLLocation?
    private var route: [GPSRunPoint] = []
    private var acceptedLocationCount = 0
    private let minimumLocationAccuracy = 25.0
    private let maximumPlausibleSpeed = 8.0
    private let minimumSegmentDistance = 2.5

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        // Keep foreground-started outdoor runs recording while the app is backgrounded
        // or the iPhone is locked. The matching "location" background mode is declared
        // in Info.plist; When In Use permission is sufficient for this foreground-started flow.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        recentRuns = loadHistory()
    }

    var averagePaceSecondsPerKm: Double? {
        guard distanceMeters >= 20 else { return nil }
        return elapsedSeconds / (distanceMeters / 1000)
    }

    var distanceKilometres: Double { distanceMeters / 1000 }

    func displayedElapsed(at date: Date) -> TimeInterval {
        guard hasActiveRun, !isPaused, let activeSegmentStartedAt else { return elapsedSeconds }
        return accumulatedActiveSeconds + max(0, date.timeIntervalSince(activeSegmentStartedAt))
    }

    func startRun() {
        guard !hasActiveRun else { return }
        wantsToStart = true
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginRun()
        case .notDetermined:
            locationStatus = "Allow location access to record your run"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            wantsToStart = false
            locationStatus = "Location access is off · enable it in iPhone Settings"
        @unknown default:
            locationStatus = "Location permission status unavailable"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsToStart else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginRun()
        case .denied, .restricted:
            wantsToStart = false
            locationStatus = "Location access denied · enable it in Settings"
        default:
            break
        }
    }

    private func beginRun() {
        guard wantsToStart, !hasActiveRun else { return }
        wantsToStart = false
        startedAt = Date()
        activeSegmentStartedAt = Date()
        accumulatedActiveSeconds = 0
        splitStartElapsed = 0
        distanceMeters = 0
        elapsedSeconds = 0
        currentPaceSecondsPerKm = nil
        splits = []
        route = []
        acceptedLocationCount = 0
        routePointCount = 0
        nextSplitDistance = 1_000
        previousLocation = nil
        isPaused = false
        hasActiveRun = true
        locationStatus = "Acquiring GPS · wait for an accurate fix"
        manager.startUpdatingLocation()
    }

    func pauseOrResume() {
        guard hasActiveRun else { return }
        if isPaused {
            isPaused = false
            activeSegmentStartedAt = Date()
            previousLocation = nil
            locationStatus = "Run resumed · reacquiring GPS"
            manager.startUpdatingLocation()
        } else {
            accumulatedActiveSeconds = elapsedSeconds
            activeSegmentStartedAt = nil
            isPaused = true
            previousLocation = nil
            currentPaceSecondsPerKm = nil
            locationStatus = "Run paused"
            manager.stopUpdatingLocation()
        }
    }

    func finishRun() {
        guard hasActiveRun, let startedAt else { return }
        if !isPaused, let activeSegmentStartedAt {
            accumulatedActiveSeconds += max(0, Date().timeIntervalSince(activeSegmentStartedAt))
        }
        elapsedSeconds = accumulatedActiveSeconds
        manager.stopUpdatingLocation()
        isPaused = false
        hasActiveRun = false
        currentPaceSecondsPerKm = nil
        let endedAt = Date()
        let record = GPSRunRecord(id: UUID(), startedAt: startedAt, endedAt: endedAt,
                                  durationSeconds: elapsedSeconds, distanceMeters: distanceMeters,
                                  splits: splits, route: route)
        lastSavedRun = record
        if distanceMeters >= 20 {
            recentRuns.insert(record, at: 0)
            recentRuns = Array(recentRuns.prefix(20))
            persistHistory()
            exportToHealthKit(record)
        } else {
            saveStatus = "Run too short to export · \(route.count) GPS points retained for this session"
        }
        self.startedAt = nil
        activeSegmentStartedAt = nil
        previousLocation = nil
        locationStatus = "Run finished · \(routePointCount) GPS points"
    }

    func updateClock(at date: Date = Date()) {
        guard hasActiveRun, !isPaused, let activeSegmentStartedAt else { return }
        elapsedSeconds = accumulatedActiveSeconds + max(0, date.timeIntervalSince(activeSegmentStartedAt))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard hasActiveRun, !isPaused else { return }
        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= minimumLocationAccuracy,
                  abs(location.timestamp.timeIntervalSinceNow) <= 15 else { continue }
            accept(location)
        }
    }

    private func accept(_ location: CLLocation) {
        guard let previous = previousLocation else {
            previousLocation = location
            route.append(GPSRunPoint(location))
            routePointCount = route.count
            locationStatus = "GPS locked · recording route"
            return
        }

        let segmentDistance = location.distance(from: previous)
        let segmentTime = location.timestamp.timeIntervalSince(previous.timestamp)
        guard segmentTime > 0, segmentTime <= 20,
              segmentDistance >= minimumSegmentDistance,
              segmentDistance / segmentTime <= maximumPlausibleSpeed else {
            // Keep the last good fix as the next reference only when it is
            // spatially close; this prevents a single GPS jump inflating distance.
            if segmentTime > 0, segmentDistance < 60 { previousLocation = location }
            return
        }

        let elapsedBefore = elapsed(at: previous.timestamp)
        let elapsedAfter = elapsed(at: location.timestamp)
        let segmentElapsed = max(0.1, elapsedAfter - elapsedBefore)
        let distanceBefore = distanceMeters
        let distanceAfter = distanceBefore + segmentDistance

        while distanceAfter >= nextSplitDistance {
            let fraction = min(1, max(0, (nextSplitDistance - distanceBefore) / segmentDistance))
            let splitElapsedAtBoundary = elapsedBefore + segmentElapsed * fraction
            let splitDuration = max(0, splitElapsedAtBoundary - splitStartElapsed)
            let kilometre = splits.count + 1
            splits.append(GPSRunSplit(kilometre: kilometre, durationSeconds: splitDuration))
            splitStartElapsed = splitElapsedAtBoundary
            nextSplitDistance += 1_000
        }

        distanceMeters = distanceAfter
        elapsedSeconds = max(elapsedSeconds, elapsedAfter)
        previousLocation = location
        route.append(GPSRunPoint(location))
        routePointCount = route.count
        acceptedLocationCount += 1

        let speed = segmentDistance / segmentElapsed
        currentPaceSecondsPerKm = speed > 0 ? 1000 / speed : nil
        locationStatus = "GPS locked · ±\(Int(location.horizontalAccuracy)) m"
    }

    private func elapsed(at timestamp: Date) -> TimeInterval {
        guard let activeSegmentStartedAt else { return accumulatedActiveSeconds }
        return accumulatedActiveSeconds + max(0, timestamp.timeIntervalSince(activeSegmentStartedAt))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationStatus = "GPS issue · \(error.localizedDescription)"
    }

    private func exportToHealthKit(_ record: GPSRunRecord) {
        guard HKHealthStore.isHealthDataAvailable(),
              let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) else {
            saveStatus = "Run saved in PulseForge · Apple Health unavailable"
            return
        }

        // Request write access before creating the workout/route builders. Without this,
        // HealthKit can reject the workout or distance sample even when GPS recording worked.
        saveStatus = "Requesting Apple Health permission…"
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType(), distanceType],
                                         read: []) { [weak self] _, authorizationError in
            guard let self else { return }
            if let authorizationError {
                DispatchQueue.main.async {
                    self.saveStatus = "Apple Health permission failed · \(authorizationError.localizedDescription)"
                }
                return
            }
            DispatchQueue.main.async {
                self.buildAndSaveHealthWorkout(record, distanceType: distanceType)
            }
        }
    }

    private func buildAndSaveHealthWorkout(_ record: GPSRunRecord,
                                           distanceType: HKQuantityType) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration,
                                       device: HKDevice.local())
        let distanceSample = HKQuantitySample(type: distanceType,
                                              quantity: HKQuantity(unit: .meter(), doubleValue: record.distanceMeters),
                                              start: record.startedAt, end: record.endedAt)
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: HKDevice.local())
        let locations = record.route.map(\.location)

        saveStatus = "Saving running workout and GPS route to Apple Health…"
        builder.beginCollection(withStart: record.startedAt) { [weak self] began, error in
            guard let self else { return }
            guard began else {
                DispatchQueue.main.async { self.saveStatus = "Apple Health save failed · \(error?.localizedDescription ?? "could not begin workout")" }
                return
            }
            builder.add([distanceSample]) { added, addError in
                guard added else {
                    DispatchQueue.main.async { self.saveStatus = "Distance export failed · \(addError?.localizedDescription ?? "sample rejected")" }
                    return
                }
                builder.endCollection(withEnd: record.endedAt) { ended, endError in
                    guard ended else {
                        DispatchQueue.main.async { self.saveStatus = "Workout finalization failed · \(endError?.localizedDescription ?? "could not end workout")" }
                        return
                    }
                    builder.finishWorkout { workout, finishError in
                        guard let workout else {
                            DispatchQueue.main.async { self.saveStatus = "Workout save failed · \(finishError?.localizedDescription ?? "HealthKit returned no workout")" }
                            return
                        }
                        guard locations.count >= 2 else {
                            DispatchQueue.main.async { self.saveStatus = "Running workout saved · GPS route needs at least two accurate points" }
                            return
                        }
                        routeBuilder.insertRouteData(locations) { inserted, routeError in
                            guard inserted else {
                                DispatchQueue.main.async { self.saveStatus = "Workout saved · route export failed · \(routeError?.localizedDescription ?? "route points rejected")" }
                                return
                            }
                            routeBuilder.finishRoute(with: workout, metadata: nil) { route, finishRouteError in
                                DispatchQueue.main.async {
                                    self.saveStatus = route != nil
                                        ? "Saved running workout + GPS route to Apple Health"
                                        : "Workout saved · route finalization failed · \(finishRouteError?.localizedDescription ?? "unknown error")"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var historyURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PulseForge", isDirectory: true)
            .appendingPathComponent("gps-runs-v1.json")
    }

    private func loadHistory() -> [GPSRunRecord] {
        guard let url = historyURL, let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([GPSRunRecord].self, from: data) else { return [] }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    private func persistHistory() {
        guard let url = historyURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(recentRuns).write(to: url, options: .atomic)
        } catch {
            saveStatus = "Local run history save failed · \(error.localizedDescription)"
        }
    }
}
