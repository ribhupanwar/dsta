import SwiftUI
import Combine
import HealthKit

@main
struct PulseForgeApp: App {
    @StateObject private var health = HealthDataStore()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(health)
                .preferredColorScheme(.dark)
        }
    }
}

enum ForgeTab: String, CaseIterable {
    case today = "Today"
    case sleep = "Sleep"
    case strain = "Strain"
    case run = "Run"
    case device = "Device"

    var symbol: String {
        switch self {
        case .today: "circle.grid.2x2.fill"
        case .sleep: "moon.zzz.fill"
        case .strain: "flame.fill"
        case .run: "figure.run"
        case .device: "waveform.path.ecg"
        }
    }
}

struct MainTabView: View {
    @State private var selected: ForgeTab = .today

    var body: some View {
        ZStack(alignment: .bottom) {
            ForgeColors.background.ignoresSafeArea()
            Group {
                switch selected {
                case .today: TodayDashboard()
                case .sleep: SleepDashboard()
                case .strain: StrainDashboard()
                case .run: RunningDashboard()
                case .device: DeviceDashboard()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ForgeTabBar(selected: $selected)
        }
        .ignoresSafeArea(.keyboard)
    }
}

struct ForgeTabBar: View {
    @Binding var selected: ForgeTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ForgeTab.allCases, id: \.self) { tab in
                Button { selected = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 18, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected == tab ? ForgeColors.lime : ForgeColors.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(ForgeColors.stroke).frame(height: 1) }
    }
}

struct TodayDashboard: View {
    @EnvironmentObject private var health: HealthDataStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HeaderView(eyebrow: "TUESDAY, 27 OCTOBER", title: "Your day")
                RecoveryHero()
                HStack(spacing: 12) {
                    MetricTile(title: "SLEEP", value: "—", unit: "performance", symbol: "moon.zzz.fill")
                    MetricTile(title: "STRAIN", value: "—", unit: "daily load", symbol: "flame.fill")
                }
                LiveHeartRateCard(heartRate: health.heartRate)
                SectionHeader(title: "YOUR HEALTH", action: "View trends")
                HStack(spacing: 12) {
                    CompactMetric(title: "HRV", value: health.hrvMilliseconds.map { String(format: "%.0f", $0) } ?? "—", unit: "ms")
                    CompactMetric(title: "RESTING HR", value: health.restingHeartRate.map(String.init) ?? "—", unit: "bpm")
                    CompactMetric(title: "SLEEP DEBT", value: "—", unit: "min")
                }
                SectionHeader(title: "HEALTH MONITOR")
                HStack(spacing: 12) {
                    CompactMetric(title: "RESP. RATE", value: health.respiratoryRate.map { String(format: "%.1f", $0) } ?? "—", unit: "br/min")
                    CompactMetric(title: "BLOOD O₂", value: health.bloodOxygenPercent.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
                    CompactMetric(title: "SKIN TEMP", value: "—", unit: "°")
                }
                ConnectPrompt()
                JournalPrompt()
                Text("Metrics appear after you connect a supported wearable or allow Apple Health access.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForgeColors.muted)
                    .padding(.bottom, 110)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
        }
    }
}

struct RecoveryHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("RECOVERY").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.8)
                    .foregroundStyle(ForgeColors.muted)
                Spacer()
                Image(systemName: "info.circle").foregroundStyle(ForgeColors.muted)
            }
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(ForgeColors.track, style: StrokeStyle(lineWidth: 10, lineCap: .round, dash: [3, 5]))
                    Text("—").font(.system(size: 42, weight: .light, design: .rounded)).foregroundStyle(.white)
                }
                .frame(width: 116, height: 116)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Waiting for data").font(.system(size: 19, weight: .semibold))
                    Text("Connect your band to calculate your recovery.")
                        .font(.system(size: 13)).foregroundStyle(ForgeColors.muted).fixedSize(horizontal: false, vertical: true)
                    Text("NO SCORE YET").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(ForgeColors.lime)
                        .padding(.top, 4)
                }
            }
        }
        .padding(20)
        .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(ForgeColors.stroke, lineWidth: 1))
    }
}

struct LiveHeartRateCard: View {
    let heartRate: Int?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(ForgeColors.lime.opacity(0.12)).frame(width: 42, height: 42)
                Image(systemName: "heart.fill").foregroundStyle(ForgeColors.lime)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("LATEST HEART RATE · APPLE HEALTH").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(ForgeColors.muted)
                Text(heartRate.map { "\($0) BPM" } ?? "Waiting for sensor")
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Spacer()
            Circle().fill(ForgeColors.lime.opacity(heartRate == nil ? 0.3 : 1)).frame(width: 7, height: 7)
        }
        .padding(16)
        .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ForgeColors.stroke, lineWidth: 1))
    }
}

struct SleepDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(eyebrow: "SLEEP", title: "Recharge")
                BigPlaceholderCard(title: "SLEEP PERFORMANCE", subtitle: "Connect a data source to see your sleep performance.", icon: "moon.stars.fill")
                SectionHeader(title: "SLEEP BREAKDOWN")
                HStack(spacing: 8) {
                    SleepStage(name: "Deep", color: Color(red: 0.38, green: 0.34, blue: 0.9))
                    SleepStage(name: "REM", color: Color(red: 0.42, green: 0.64, blue: 0.95))
                    SleepStage(name: "Light", color: ForgeColors.lime)
                    SleepStage(name: "Awake", color: ForgeColors.muted)
                }
                .frame(height: 8)
                HStack(spacing: 12) {
                    MetricTile(title: "SLEEP HOURS", value: health.sleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours", symbol: "bed.double.fill")
                    MetricTile(title: "SLEEP DEBT", value: "—", unit: "minutes", symbol: "hourglass")
                }
                Text("Sleep stages and sleep need will populate from supported sensor data or Apple Health.")
                    .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                Spacer(minLength: 110)
            }
            .padding(20).padding(.top, 18)
        }
    }
}

struct StrainDashboard: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(eyebrow: "TRAINING LOAD", title: "Strain")
                BigPlaceholderCard(title: "DAILY STRAIN", subtitle: "Your cardiovascular load will appear after a workout or wearable sync.", icon: "flame.fill")
                SectionHeader(title: "TRAINING")
                HStack(spacing: 12) {
                    MetricTile(title: "CARDIO LOAD", value: "—", unit: "today", symbol: "waveform.path")
                    MetricTile(title: "ACTIVITIES", value: "—", unit: "sessions", symbol: "figure.run")
                }
                SectionHeader(title: "RUNNING")
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("PACE").foregroundStyle(ForgeColors.muted); Spacer(); Text("— /km") }
                    Divider().overlay(ForgeColors.stroke)
                    HStack { Text("AVERAGE HR").foregroundStyle(ForgeColors.muted); Spacer(); Text("— bpm") }
                    Divider().overlay(ForgeColors.stroke)
                    HStack { Text("DISTANCE").foregroundStyle(ForgeColors.muted); Spacer(); Text("— km") }
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 110)
            }
            .padding(20).padding(.top, 18)
        }
    }
}


struct RunningDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(eyebrow: "ENDURANCE", title: "Running")
                VStack(alignment: .leading, spacing: 8) {
                    Text("LAST RUN").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(ForgeColors.muted)
                    Text("No activity synced").font(.system(size: 20, weight: .semibold))
                    Text("Your distance, pace, heart-rate zones and splits will appear here after a workout sync.")
                        .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 10) {
                    MetricTile(title: "DISTANCE", value: health.latestRunDistanceKm.map { String(format: "%.2f", $0) } ?? "—", unit: "km", symbol: "point.topleft.down.to.point.bottomright.curvepath")
                    MetricTile(title: "AVG PACE", value: health.latestRunPaceMinutesPerKm.map { String(format: "%.2f", $0) } ?? "—", unit: "/km", symbol: "speedometer")
                }
                HStack(spacing: 10) {
                    MetricTile(title: "AVG HEART RATE", value: "—", unit: "bpm", symbol: "heart.fill")
                    MetricTile(title: "DURATION", value: health.latestRunDurationMinutes.map { String(format: "%.0f", $0) } ?? "—", unit: "min", symbol: "timer")
                }
                SectionHeader(title: "HEART RATE ZONES")
                VStack(spacing: 13) {
                    ZoneRow(name: "Zone 5 · Maximum", color: Color(red: 0.96, green: 0.31, blue: 0.27))
                    ZoneRow(name: "Zone 4 · Threshold", color: Color(red: 1.0, green: 0.58, blue: 0.22))
                    ZoneRow(name: "Zone 3 · Aerobic", color: Color(red: 0.96, green: 0.82, blue: 0.25))
                    ZoneRow(name: "Zone 2 · Easy", color: ForgeColors.lime)
                    ZoneRow(name: "Zone 1 · Recovery", color: Color(red: 0.32, green: 0.67, blue: 0.92))
                }
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
                SectionHeader(title: "PACE & SPLITS")
                VStack(spacing: 12) {
                    HStack { Text("KM"); Spacer(); Text("PACE"); Spacer(); Text("AVG HR") }
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(ForgeColors.muted)
                    Divider().overlay(ForgeColors.stroke)
                    Text("No split data yet").font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
                Text("Running metrics are kept blank until verified workout data is available; no sample performance is presented as real.")
                    .font(.system(size: 11)).foregroundStyle(ForgeColors.muted)
                Spacer(minLength: 110)
            }
            .padding(20).padding(.top, 18)
        }
    }
}

struct ZoneRow: View {
    let name: String
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 4, height: 20)
            Text(name).font(.system(size: 11, weight: .medium))
            Spacer()
            Text("—").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(ForgeColors.muted)
        }
    }
}

struct JournalPrompt: View {
    @State private var showingJournal = false
    @AppStorage("pulseforge.journal.savedDate") private var savedDate = ""
    @AppStorage("pulseforge.journal.mood") private var mood = ""
    @AppStorage("pulseforge.journal.soreness") private var soreness = ""
    @AppStorage("pulseforge.journal.notes") private var notes = ""

    private var hasEntryToday: Bool {
        savedDate == Calendar.current.startOfDay(for: Date()).formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    var body: some View {
        Button { showingJournal = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill").font(.system(size: 20)).foregroundStyle(ForgeColors.lime)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Daily journal").font(.system(size: 14, weight: .semibold))
                    Text(hasEntryToday ? "Today's check-in saved · Edit entry" : "Log mood, soreness and recovery context")
                        .font(.system(size: 11)).foregroundStyle(ForgeColors.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(ForgeColors.muted)
            }
            .foregroundStyle(.white)
            .padding(16).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingJournal) {
            JournalEntrySheet(mood: $mood, soreness: $soreness, notes: $notes) {
                savedDate = Calendar.current.startOfDay(for: Date()).formatted(.iso8601.year().month().day().dateSeparator(.dash))
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

struct JournalEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var mood: String
    @Binding var soreness: String
    @Binding var notes: String
    let onSave: () -> Void

    private let moods = ["Great", "Good", "Okay", "Low"]
    private let sorenessLevels = ["None", "Mild", "Moderate", "High"]

    var body: some View {
        NavigationStack {
            Form {
                Section("How are you feeling?") {
                    Picker("Mood", selection: $mood) {
                        Text("Select mood").tag("")
                        ForEach(moods, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Muscle soreness", selection: $soreness) {
                        Text("Select level").tag("")
                        ForEach(sorenessLevels, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Notes") {
                    TextField("Training, hydration, stress, habits…", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Text("Your journal stays on this device in this build. It does not alter recovery or strain scores.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Daily check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(); dismiss() }
                        .disabled(mood.isEmpty && soreness.isEmpty && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DeviceDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    @StateObject private var bluetooth = WhoopBluetoothManager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(eyebrow: "CONNECTIONS", title: "Your device")
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 24)).foregroundStyle(ForgeColors.lime)
                        Spacer()
                        Text(bluetooth.connectedName == nil ? "NOT CONNECTED" : "CONNECTED")
                            .font(.system(size: 9, weight: .bold)).tracking(1)
                            .foregroundStyle(bluetooth.connectedName == nil ? ForgeColors.muted : ForgeColors.lime)
                    }
                    Text(bluetooth.connectedName ?? "WHOOP-compatible band")
                        .font(.system(size: 19, weight: .semibold))
                    Text(bluetooth.statusText)
                        .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                    Button { bluetooth.startScan() } label: {
                        Label("SCAN FOR WHOOP BAND", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .bold)).tracking(0.8)
                            .frame(maxWidth: .infinity).padding(14)
                            .background(ForgeColors.lime, in: Capsule()).foregroundStyle(.black)
                    }
                    if !bluetooth.devices.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(bluetooth.devices) { device in
                                Button { bluetooth.connect(to: device) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(device.name).font(.system(size: 13, weight: .semibold))
                                            Text(device.id.uuidString.prefix(8))
                                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(ForgeColors.muted)
                                        }
                                        Spacer()
                                        Text("\(device.rssi) dBm").font(.system(size: 10, design: .monospaced)).foregroundStyle(ForgeColors.muted)
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(12).background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !bluetooth.discoveredProfile.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("DISCOVERED GATT PROFILE")
                                .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.lime)
                            ForEach(Array(bluetooth.discoveredProfile.enumerated()), id: \.offset) { item in
                                Text(item.element).font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(ForgeColors.muted).textSelection(.enabled)
                            }
                        }
                        .padding(12).background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("This first pass only scans, connects and lists GATT services/characteristics. It does not send commands or guess the live-HR packet format.")
                        .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                }
                .padding(20).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 22))
                SectionHeader(title: "APPLE HEALTH")
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Health data access", systemImage: "heart.text.square")
                        Spacer()
                        Text(health.isAuthorized ? "REQUESTED" : "NOT SET UP")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(health.isAuthorized ? ForgeColors.lime : ForgeColors.muted)
                    }
                    Text("Allow access to heart rate, HRV, resting heart rate, respiratory rate, blood oxygen, sleep and workouts.")
                        .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                    Button { Task { await health.requestAccess() } } label: {
                        Text(health.isAuthorized ? "ACCESS REQUESTED" : "CONNECT APPLE HEALTH")
                            .font(.system(size: 11, weight: .bold)).tracking(1)
                            .frame(maxWidth: .infinity).padding(14)
                            .background(ForgeColors.lime, in: Capsule()).foregroundStyle(.black)
                    }
                    .disabled(health.isAuthorized)
                }
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 110)
            }
            .padding(20).padding(.top, 18)
        }
        .onDisappear { bluetooth.stopScan() }
    }
}

@MainActor
final class HealthDataStore: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var heartRate: Int?
    @Published private(set) var hrvMilliseconds: Double?
    @Published private(set) var restingHeartRate: Int?
    @Published private(set) var respiratoryRate: Double?
    @Published private(set) var bloodOxygenPercent: Double?
    @Published private(set) var sleepHours: Double?
    @Published private(set) var latestRunDistanceKm: Double?
    @Published private(set) var latestRunDurationMinutes: Double?
    @Published private(set) var latestRunPaceMinutesPerKm: Double?
    @Published private(set) var latestRunDate: Date?
    private let store = HKHealthStore()

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.workoutType()
        ]
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            loadHealthMetrics()
            loadSleepDuration()
            loadLatestRun()
        } catch {
            isAuthorized = false
        }
    }

    private func loadHealthMetrics() {
        let rateUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        loadLatestQuantity(.heartRate, unit: rateUnit) { [weak self] value in self?.heartRate = value.map(Int.init) }
        loadLatestQuantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli)) { [weak self] value in self?.hrvMilliseconds = value }
        loadLatestQuantity(.restingHeartRate, unit: rateUnit) { [weak self] value in self?.restingHeartRate = value.map(Int.init) }
        loadLatestQuantity(.respiratoryRate, unit: rateUnit) { [weak self] value in self?.respiratoryRate = value }
        loadLatestQuantity(.oxygenSaturation, unit: HKUnit.percent(), multiplier: 100) { [weak self] value in self?.bloodOxygenPercent = value }
    }

    private func loadLatestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, multiplier: Double = 1, completion: @escaping (Double?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { completion(nil); return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            let sample = samples?.first as? HKQuantitySample
            let value = sample.map { $0.quantity.doubleValue(for: unit) * multiplier }
            Task { @MainActor in completion(value) }
        }
        store.execute(query)
    }

    private func loadSleepDuration() {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let start = Calendar.current.date(byAdding: .hour, value: -36, to: Date()) ?? Date().addingTimeInterval(-129600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1000, sortDescriptors: nil) { [weak self] _, samples, _ in
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            let seconds = (samples as? [HKCategorySample] ?? [])
                .filter { asleepValues.contains($0.value) }
                .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            Task { @MainActor in self?.sleepHours = seconds > 0 ? seconds / 3600 : nil }
        }
        store.execute(query)
    }

    private func loadLatestRun() {
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let workout = samples?.first as? HKWorkout else { return }
            let distance: Double?
            if let totalDistance = workout.totalDistance {
                distance = totalDistance.doubleValue(for: HKUnit.meter()) / 1000
            } else {
                distance = nil
            }
            let duration = workout.duration / 60
            let pace = distance.flatMap { $0 > 0 ? duration / $0 : nil }
            Task { @MainActor in
                self?.latestRunDistanceKm = distance
                self?.latestRunDurationMinutes = duration
                self?.latestRunPaceMinutesPerKm = pace
                self?.latestRunDate = workout.endDate
            }
        }
        store.execute(query)
    }
}

struct HeaderView: View {
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(ForgeColors.lime)
            HStack {
                Text(title).font(.system(size: 31, weight: .bold, design: .rounded)).tracking(-0.8)
                Spacer()
                Image(systemName: "person.crop.circle").font(.system(size: 25, weight: .light)).foregroundStyle(ForgeColors.muted)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var action: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1.4)
            Spacer()
            if let action { Text(action).font(.system(size: 11, weight: .semibold)).foregroundStyle(ForgeColors.lime) }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol).foregroundStyle(ForgeColors.lime)
                Spacer()
                Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 29, weight: .semibold, design: .rounded))
                Text(unit).font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ForgeColors.stroke, lineWidth: 1))
    }
}

struct CompactMetric: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(0.7).foregroundStyle(ForgeColors.muted)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded))
            Text(unit).font(.system(size: 9)).foregroundStyle(ForgeColors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 15))
    }
}

struct BigPlaceholderCard: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: icon).font(.system(size: 23)).foregroundStyle(ForgeColors.lime)
            Text(title).font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(ForgeColors.muted)
            Text("—").font(.system(size: 56, weight: .light, design: .rounded))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(ForgeColors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(ForgeColors.stroke, lineWidth: 1))
    }
}

struct SleepStage: View {
    let name: String
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(color).overlay(alignment: .bottom) {
            Text(name).font(.system(size: 9, weight: .medium)).foregroundStyle(ForgeColors.muted).offset(y: 20)
        }
    }
}

struct ConnectPrompt: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 22)).foregroundStyle(ForgeColors.lime)
            VStack(alignment: .leading, spacing: 3) {
                Text("Make your data count").font(.system(size: 14, weight: .semibold))
                Text("Connect a wearable to unlock your dashboard.").font(.system(size: 11)).foregroundStyle(ForgeColors.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(ForgeColors.muted)
        }
        .padding(16).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

enum ForgeColors {
    static let background = Color(red: 0.025, green: 0.03, blue: 0.035)
    static let card = Color(red: 0.075, green: 0.085, blue: 0.09)
    static let track = Color(red: 0.16, green: 0.18, blue: 0.18)
    static let stroke = Color.white.opacity(0.07)
    static let muted = Color(red: 0.55, green: 0.59, blue: 0.59)
    static let lime = Color(red: 0.72, green: 0.95, blue: 0.24)
}
