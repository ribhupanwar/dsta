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
    case device = "Device"

    var symbol: String {
        switch self {
        case .today: "circle.grid.2x2.fill"
        case .sleep: "moon.zzz.fill"
        case .strain: "flame.fill"
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
                    CompactMetric(title: "HRV", value: "—", unit: "ms")
                    CompactMetric(title: "RESTING HR", value: "—", unit: "bpm")
                    CompactMetric(title: "SLEEP DEBT", value: "—", unit: "min")
                }
                ConnectPrompt()
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
                    Circle().stroke(ForgeColors.track, lineWidth: 10)
                    Circle().trim(from: 0, to: 0.72).stroke(ForgeColors.lime, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90)).opacity(0.25)
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
                Text("LIVE HEART RATE").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(ForgeColors.muted)
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
                    MetricTile(title: "SLEEP NEED", value: "—", unit: "hours", symbol: "bed.double.fill")
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

struct DeviceDashboard: View {
    @EnvironmentObject private var health: HealthDataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(eyebrow: "CONNECTIONS", title: "Your device")
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 24)).foregroundStyle(ForgeColors.lime)
                        Spacer()
                        Text("NOT CONNECTED").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.muted)
                    }
                    Text("WHOOP-compatible band").font(.system(size: 19, weight: .semibold))
                    Text("Bluetooth pairing will be enabled after the device profile and packet format are verified from the archive and hardware tests.")
                        .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                    Button {} label: {
                        Text("DEVICE SUPPORT IN PROGRESS")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .frame(maxWidth: .infinity).padding(14)
                            .background(ForgeColors.track, in: Capsule())
                            .foregroundStyle(ForgeColors.muted)
                    }
                    .disabled(true)
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
                    Text("Allow access to heart rate, HRV, resting heart rate, sleep and workouts.")
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
    }
}

@MainActor
final class HealthDataStore: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var heartRate: Int?
    private let store = HKHealthStore()

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.workoutType()
        ]
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            await loadLatestHeartRate()
        } catch {
            isAuthorized = false
        }
    }

    private func loadLatestHeartRate() async {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            Task { @MainActor in self?.heartRate = bpm }
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
