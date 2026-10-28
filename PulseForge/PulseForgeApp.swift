import SwiftUI
import Combine
import HealthKit
import Charts

@main
struct PulseForgeApp: App {
    @StateObject private var health = HealthDataStore()
    @StateObject private var insights = TrainingInsightsStore()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(health)
                .environmentObject(insights)
                .preferredColorScheme(.dark)
        }
    }
}

enum ForgeTab: String, CaseIterable {
    case today = "Today"
    case sleep = "Sleep"
    case strain = "Strain"
    case run = "Run"
    case device = "WHOOP"

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
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var insights: TrainingInsightsStore
    @State private var selected: ForgeTab = .today
    @StateObject private var bluetooth = WhoopBluetoothManager()

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
            .environmentObject(bluetooth)
            ForgeTabBar(selected: $selected)
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: health.isAuthorized) { _, authorized in
            if authorized { insights.refresh() }
        }
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
    @EnvironmentObject private var insights: TrainingInsightsStore
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                            .font(.system(size: 10, weight: .bold)).tracking(1.5)
                            .foregroundStyle(ForgeColors.muted)
                        Text("Today").font(.system(size: 32, weight: .bold, design: .rounded))
                            .tracking(-0.8)
                    }
                    Spacer()
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(ForgeColors.muted)
                }

                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "YOUR SCORES")
                    HStack(alignment: .top, spacing: 0) {
                        ScoreRing(title: "RECOVERY", value: insights.recoveryScore, tint: Color(red: 0.25, green: 0.82, blue: 0.48))
                        Spacer(minLength: 2)
                        ScoreRing(title: "SLEEP", value: nil, tint: Color(red: 0.35, green: 0.62, blue: 0.96))
                        Spacer(minLength: 2)
                        ScoreRing(title: "STRAIN", value: nil, tint: Color(red: 0.98, green: 0.58, blue: 0.27))
                    }
                    .padding(.vertical, 8)
                    Text("Scores will appear when the required WHOOP and sleep data is available.")
                        .font(.system(size: 11)).foregroundStyle(ForgeColors.muted)
                }
                .padding(18)
                .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(ForgeColors.stroke, lineWidth: 1))

                VStack(alignment: .leading, spacing: 13) {
                    SectionHeader(title: "HEALTH MONITOR", action: "View details")
                    HStack(spacing: 10) {
                        CompactMetric(title: "HRV", value: health.hrvMilliseconds.map { String(format: "%.0f", $0) } ?? "—", unit: "ms")
                        CompactMetric(title: "RESTING HR", value: health.restingHeartRate.map(String.init) ?? "—", unit: "bpm")
                        CompactMetric(title: "RESP. RATE", value: health.respiratoryRate.map { String(format: "%.1f", $0) } ?? "—", unit: "br/min")
                    }
                    HStack(spacing: 10) {
                        CompactMetric(title: "BLOOD O₂", value: health.bloodOxygenPercent.map { String(format: "%.0f", $0) } ?? "—", unit: "%")
                        CompactMetric(title: "SLEEP", value: health.sleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours")
                        CompactMetric(title: "LIVE HR", value: bluetooth.freshHeartRateBPM.map(String.init) ?? "—", unit: "bpm")
                    }
                }

                LiveHeartRateCard()
                LiveHeartRateChartCard(samples: bluetooth.liveHeartRateSamples, title: "LIVE HEART RATE")
                ConnectPrompt()
                JournalPrompt()
                HStack {
                    Text(health.lastRefreshDate.map { "DATA UPDATED · \($0.formatted(date: .omitted, time: .shortened))" } ?? "PULL DOWN TO REFRESH")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(ForgeColors.muted)
                    Spacer()
                    if health.isRefreshing { ProgressView().tint(ForgeColors.lime).scaleEffect(0.8) }
                }
                Text("Unavailable scores stay blank until the underlying data and calculation are verified.")
                    .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                    .padding(.bottom, 110)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
        }
        .refreshable { health.refresh(); insights.refresh() }
    }
}

struct ScoreRing: View {
    let title: String
    let value: Int?
    let tint: Color

    private var progress: Double { min(1, max(0, Double(value ?? 0) / 100)) }

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(ForgeColors.track, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: 82, height: 82)
            Text(title)
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(ForgeColors.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct LiveHeartRateCard: View {
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let heartRate = bluetooth.freshHeartRateBPM
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(ForgeColors.lime.opacity(0.12)).frame(width: 42, height: 42)
                    Image(systemName: "heart.fill").foregroundStyle(ForgeColors.lime)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHOOP · LIVE HEART RATE").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(ForgeColors.muted)
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
}

struct LiveHeartRateChartCard: View {
    let samples: [LiveHeartRateSample]
    let title: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let visibleSamples = samples.filter {
                let age = context.date.timeIntervalSince($0.timestamp)
                return age >= 0 && age <= 60
            }
            let low = visibleSamples.map(\.bpm).min() ?? 40
            let high = visibleSamples.map(\.bpm).max() ?? 180
            let lower = max(30, low - 8)
            let upper = min(220, max(lower + 20, high + 8))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.muted)
                    Spacer()
                    Text(visibleSamples.isEmpty ? "NO LIVE SAMPLES" : "\(visibleSamples.count) POINTS")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(ForgeColors.lime)
                }
                if visibleSamples.count >= 2 {
                    Chart(visibleSamples) { sample in
                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("BPM", sample.bpm)
                        )
                        .foregroundStyle(ForgeColors.lime.opacity(0.12))
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("BPM", sample.bpm)
                        )
                        .foregroundStyle(ForgeColors.lime)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .chartYScale(domain: lower...upper)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
                    }
                    .frame(height: 125)
                } else {
                    Text(visibleSamples.isEmpty ? "Live WHOOP heart-rate samples will draw here." : "Collecting live samples…")
                        .font(.system(size: 11)).foregroundStyle(ForgeColors.muted)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
                HStack {
                    Text("60 SEC WINDOW")
                    Spacer()
                    if let latest = visibleSamples.last {
                        Text("LATEST \(latest.bpm) BPM")
                    }
                }
                .font(.system(size: 8, weight: .semibold)).tracking(0.7).foregroundStyle(ForgeColors.muted)
            }
            .padding(16)
            .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ForgeColors.stroke, lineWidth: 1))
        }
    }
}

struct WhoopMotionCard: View {
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager

    private var latestSample: WhoopIMUSample? { bluetooth.liveWhoopIMUSamples.last }

    private var accelerationMagnitude: Double? {
        guard let sample = latestSample else { return nil }
        return sqrt(
            sample.accelerationXG * sample.accelerationXG +
            sample.accelerationYG * sample.accelerationYG +
            sample.accelerationZG * sample.accelerationZG
        )
    }

    private var rotationMagnitude: Double? {
        guard let sample = latestSample else { return nil }
        return sqrt(
            sample.rotationXDPS * sample.rotationXDPS +
            sample.rotationYDPS * sample.rotationYDPS +
            sample.rotationZDPS * sample.rotationZDPS
        )
    }

    private var recentSamples: [WhoopIMUSample] {
        Array(bluetooth.liveWhoopIMUSamples.suffix(100))
    }

    private var accelerationVariability: Double? {
        let magnitudes = recentSamples.map {
            sqrt($0.accelerationXG * $0.accelerationXG +
                 $0.accelerationYG * $0.accelerationYG +
                 $0.accelerationZG * $0.accelerationZG)
        }
        guard magnitudes.count >= 2 else { return nil }
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let variance = magnitudes.reduce(0) { $0 + pow($1 - mean, 2) } / Double(magnitudes.count)
        return sqrt(variance)
    }

    private var meanRotation: Double? {
        let magnitudes = recentSamples.map {
            sqrt($0.rotationXDPS * $0.rotationXDPS +
                 $0.rotationYDPS * $0.rotationYDPS +
                 $0.rotationZDPS * $0.rotationZDPS)
        }
        guard !magnitudes.isEmpty else { return nil }
        return magnitudes.reduce(0, +) / Double(magnitudes.count)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("WHOOP MOTION SENSOR", systemImage: "gyroscope")
                        .font(.system(size: 9, weight: .bold)).tracking(0.9)
                        .foregroundStyle(ForgeColors.muted)
                    Spacer()
                    Circle()
                        .fill(bluetooth.whoopIMULastFrameAt.map { context.date.timeIntervalSince($0) < 10 } == true ? ForgeColors.lime : ForgeColors.muted)
                        .frame(width: 7, height: 7)
                    Text(bluetooth.whoopIMULastFrameAt.map { context.date.timeIntervalSince($0) < 10 } == true ? "LIVE" : "WAITING")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ForgeColors.muted)
                }
                HStack(spacing: 10) {
                    motionMetric("ACCELERATION", value: accelerationMagnitude.map { String(format: "%.3f", $0) } ?? "—", unit: "g")
                    motionMetric("ROTATION", value: rotationMagnitude.map { String(format: "%.1f", $0) } ?? "—", unit: "°/s")
                }
                HStack(spacing: 10) {
                    motionMetric("ACCEL VARIABILITY", value: accelerationVariability.map { String(format: "%.4f", $0) } ?? "—", unit: "g · 1s")
                    motionMetric("MEAN GYRO", value: meanRotation.map { String(format: "%.1f", $0) } ?? "—", unit: "°/s · 1s")
                }
                HStack {
                    motionCount("FRAMES", value: bluetooth.whoopIMUFrameCount)
                    motionCount("SAMPLES", value: bluetooth.whoopIMUSampleCount)
                    motionCount("WORKOUT", value: bluetooth.workoutWhoopIMUSamples.count)
                }
                Text(bluetooth.whoopIMUStatus)
                    .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                Text("One-second signal variability is diagnostic only; sensor scale and activity classification are not yet calibrated.")
                    .font(.system(size: 9)).foregroundStyle(ForgeColors.muted)
            }
            .padding(16)
            .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ForgeColors.stroke, lineWidth: 1))
        }
    }

    private func motionMetric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(ForgeColors.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 9)).foregroundStyle(ForgeColors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(ForgeColors.track.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
    }

    private func motionCount(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(0.5).foregroundStyle(ForgeColors.muted)
            Text(value.formatted()).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkoutRecordingCard: View {
    @ObservedObject var bluetooth: WhoopBluetoothManager
    @State private var expandedWorkoutID: UUID?

    private var averageBPM: Int? {
        guard !bluetooth.workoutHeartRateSamples.isEmpty else { return nil }
        let values = bluetooth.workoutHeartRateSamples.map(\.bpm)
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private var minBPM: Int? { bluetooth.workoutHeartRateSamples.map(\.bpm).min() }
    private var maxBPM: Int? { bluetooth.workoutHeartRateSamples.map(\.bpm).max() }

    private func durationText(at date: Date) -> String {
        let seconds: TimeInterval
        if bluetooth.workoutIsRecording, let start = bluetooth.workoutStartedAt {
            seconds = date.timeIntervalSince(start)
        } else {
            seconds = bluetooth.lastWorkoutDurationSeconds ?? 0
        }
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("WORKOUT RECORDING").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.muted)
                    Spacer()
                    Circle().fill(bluetooth.workoutIsRecording ? ForgeColors.lime : ForgeColors.muted).frame(width: 7, height: 7)
                    Text(bluetooth.workoutIsRecording ? "RECORDING" : "READY")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(bluetooth.workoutIsRecording ? ForgeColors.lime : ForgeColors.muted)
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LIVE HEART RATE")
                            .font(.system(size: 8, weight: .bold)).tracking(0.8)
                            .foregroundStyle(ForgeColors.muted)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(bluetooth.freshHeartRateBPM.map(String.init) ?? "—")
                                .font(.system(size: 38, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(bluetooth.freshHeartRateBPM == nil ? ForgeColors.muted : ForgeColors.lime)
                            Text("BPM").font(.system(size: 9, weight: .bold)).foregroundStyle(ForgeColors.muted)
                        }
                        Text(bluetooth.connectedName == nil ? "BAND DISCONNECTED" : (bluetooth.freshHeartRateBPM == nil ? "WAITING FOR FRESH HR" : "WHOOP CONNECTED"))
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .foregroundStyle(ForgeColors.muted)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("ELAPSED")
                            .font(.system(size: 8, weight: .bold)).tracking(0.8)
                            .foregroundStyle(ForgeColors.muted)
                        Text(durationText(at: context.date))
                            .font(.system(size: 23, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text("\(bluetooth.workoutHeartRateSamples.count) SAMPLES · AVG \(averageBPM.map(String.init) ?? "—")")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(ForgeColors.muted)
                    }
                }
                .padding(12)
                .background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                if let savedStart = bluetooth.lastWorkoutStartedAt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LAST SAVED SESSION · " + savedStart.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(ForgeColors.muted)
                        Text("\(bluetooth.lastWorkoutWasAutomatic == true ? "AUTOMATIC" : "MANUAL") · \(bluetooth.lastWorkoutWasInterrupted ? "INTERRUPTED / PARTIAL" : "COMPLETED")")
                            .font(.system(size: 9, weight: .bold)).tracking(0.5)
                            .foregroundStyle(bluetooth.lastWorkoutWasInterrupted ? ForgeColors.muted : ForgeColors.lime)
                    }
                }
                if !bluetooth.workoutHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("RECENT WORKOUTS")
                                .font(.system(size: 9, weight: .bold)).tracking(1)
                                .foregroundStyle(ForgeColors.muted)
                            Spacer()
                            Text("\(bluetooth.workoutHistory.count) SAVED")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(ForgeColors.muted)
                        }
                        ForEach(Array(bluetooth.workoutHistory.prefix(5))) { session in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedWorkoutID = expandedWorkoutID == session.id ? nil : session.id
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: session.wasInterrupted ? "exclamationmark.circle" : "checkmark.circle")
                                        .foregroundStyle(session.wasInterrupted ? ForgeColors.muted : ForgeColors.lime)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("\(session.wasAutomatic ? "AUTO" : "MANUAL") · \(session.wasInterrupted ? "PARTIAL" : "SAVED") · \(session.heartRateSamples.count) HR SAMPLES")
                                            .font(.system(size: 8, weight: .medium)).foregroundStyle(ForgeColors.muted)
                                    }
                                    Spacer()
                                    let seconds = max(0, Int(session.durationSeconds))
                                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                        .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                                    Image(systemName: expandedWorkoutID == session.id ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(ForgeColors.muted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expandedWorkoutID == session.id {
                                let values = session.heartRateSamples.map(\.bpm)
                                HStack(spacing: 12) {
                                    workoutStat("AVG", value: values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded()))
                                    workoutStat("MIN", value: values.min())
                                    workoutStat("MAX", value: values.max())
                                }
                                if session.heartRateSamples.count >= 2 {
                                    Chart(session.heartRateSamples) { sample in
                                        LineMark(x: .value("Time", sample.timestamp), y: .value("BPM", sample.bpm))
                                            .foregroundStyle(ForgeColors.lime)
                                        AreaMark(x: .value("Time", sample.timestamp), y: .value("BPM", sample.bpm))
                                            .foregroundStyle(ForgeColors.lime.opacity(0.10))
                                    }
                                    .chartXAxis(.hidden)
                                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                                    .frame(height: 105)
                                } else {
                                    Text("Not enough saved HR samples for a graph.")
                                        .font(.system(size: 9)).foregroundStyle(ForgeColors.muted)
                                }
                                HStack {
                                    Text("IMU SAMPLES · \(session.imuSamples.count)")
                                    Spacer()
                                    Text(session.wasInterrupted ? "PARTIAL SESSION" : "SESSION SAVED")
                                }
                                .font(.system(size: 8, weight: .semibold)).foregroundStyle(ForgeColors.muted)
                            }
                        }
                    }
                    .padding(10)
                    .background(ForgeColors.track.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 8) {
                    workoutStat("MIN", value: minBPM)
                    workoutStat("MAX", value: maxBPM)
                    workoutStat("LATEST", value: bluetooth.workoutHeartRateSamples.last?.bpm)
                }
                if bluetooth.workoutHeartRateSamples.count >= 2 {
                    Chart(bluetooth.workoutHeartRateSamples) { sample in
                        LineMark(x: .value("Time", sample.timestamp), y: .value("BPM", sample.bpm))
                            .foregroundStyle(ForgeColors.lime)
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Time", sample.timestamp), y: .value("BPM", sample.bpm))
                            .foregroundStyle(ForgeColors.lime.opacity(0.10))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 72)
                }
                Button {
                    if bluetooth.workoutIsRecording {
                        bluetooth.stopWorkoutRecording()
                    } else {
                        bluetooth.startWorkoutRecording()
                    }
                } label: {
                    Label(bluetooth.workoutIsRecording ? "STOP & SAVE SESSION" : "START WORKOUT", systemImage: bluetooth.workoutIsRecording ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold)).tracking(0.8)
                        .frame(maxWidth: .infinity).padding(14)
                        .background(bluetooth.workoutIsRecording ? ForgeColors.track : ForgeColors.lime, in: Capsule())
                        .foregroundStyle(bluetooth.workoutIsRecording ? .white : .black)
                }
                .buttonStyle(.plain)
                .disabled(!bluetooth.workoutIsRecording && bluetooth.connectedName == nil)
                Text(bluetooth.workoutIsRecording
                     ? (bluetooth.workoutRecordingIsAutomatic
                        ? "Automatically detected from sustained elevated HR. Activity type is not inferred yet."
                        : "Recording WHOOP heart-rate samples locally on this iPhone.")
                     : "Automatic detection monitors sustained HR elevation; manual start remains available.")
                    .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                Text("AUTO-DETECTION · " + bluetooth.workoutDetectionStatus.uppercased())
                    .font(.system(size: 8, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(ForgeColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ForgeColors.stroke, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func workoutStat(_ title: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(0.7).foregroundStyle(ForgeColors.muted)
            Text(value.map(String.init) ?? "—").font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(ForgeColors.track.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SleepDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var insights: TrainingInsightsStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HeaderView(eyebrow: "SLEEP", title: "Sleep")
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "SLEEP PERFORMANCE")
                    HStack(spacing: 20) {
                        ScoreRing(title: "PERFORMANCE", value: nil, tint: Color(red: 0.35, green: 0.62, blue: 0.96))
                            .frame(width: 112)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(health.sleepHours.map { String(format: "%.1f h", $0) } ?? "—")
                                .font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                            Text("Time asleep").font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                            Text("Sleep score needs a verified sleep target and complete sleep data.")
                                .font(.system(size: 11)).foregroundStyle(ForgeColors.muted)
                        }
                    }
                    Divider().overlay(ForgeColors.stroke)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SLEEP NEED").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(ForgeColors.muted)
                            Text(String(format: "%.1f h", insights.sleepNeedHours)).font(.system(size: 23, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("SLEEP DEBT").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(ForgeColors.muted)
                            Text(insights.sleepDebtHours.map { String(format: "%.1f h", $0) } ?? "—").font(.system(size: 23, weight: .semibold, design: .rounded))
                        }
                    }
                }
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 22))
                SectionHeader(title: "SLEEP STAGES")
                SleepStageBreakdown(deep: health.deepSleepMinutes, rem: health.remSleepMinutes, core: health.coreSleepMinutes, awake: health.awakeMinutes)
                SectionHeader(title: "SLEEP SUMMARY")
                HStack(spacing: 10) {
                    CompactMetric(title: "TOTAL SLEEP", value: health.sleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours")
                    CompactMetric(title: "DEEP SLEEP", value: health.deepSleepMinutes.map { String(format: "%.0f", $0) } ?? "—", unit: "min")
                    CompactMetric(title: "REM SLEEP", value: health.remSleepMinutes.map { String(format: "%.0f", $0) } ?? "—", unit: "min")
                }
                Text("Sleep stages are read from Apple Health. Sleep need, debt and performance remain blank until a reliable baseline is available.")
                    .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                Spacer(minLength: 110)
            }
            .padding(18).padding(.top, 16)
        }
        .refreshable { health.refresh(); insights.refresh() }
    }
}
struct StrainDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var insights: TrainingInsightsStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HeaderView(eyebrow: "CARDIOVASCULAR LOAD", title: "Strain")
                VStack(alignment: .leading, spacing: 15) {
                    SectionHeader(title: "TODAY'S STRAIN")
                    HStack(spacing: 22) {
                        ZStack {
                            Circle().stroke(ForgeColors.track, lineWidth: 9)
                            Circle().trim(from: 0, to: 0)
                                .stroke(Color(red: 0.98, green: 0.58, blue: 0.27), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("—").font(.system(size: 39, weight: .light, design: .rounded))
                        }
                        .frame(width: 132, height: 132)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("No strain score yet").font(.system(size: 18, weight: .semibold))
                            Text("A verified workout and heart-rate load model are needed to calculate daily strain.")
                                .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                        }
                    }
                }
                .padding(20).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 22))
                SectionHeader(title: "CARDIO LOAD")
                HStack(spacing: 10) {
                    CompactMetric(title: "CARDIO LOAD", value: insights.cardioLoadPoints.map { String(format: "%.0f", $0) } ?? "—", unit: "load pts")
                    CompactMetric(title: "ACTIVITIES", value: String(insights.workoutCountToday), unit: "today")
                    CompactMetric(title: "DURATION", value: insights.workoutMinutesToday.map { String(format: "%.0f", $0) } ?? "—", unit: "min")
                }
                SectionHeader(title: "LATEST RUN")
                VStack(spacing: 13) {
                    HStack {
                        Label("Distance", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        Spacer()
                        Text(health.latestRunDistanceKm.map { String(format: "%.2f km", $0) } ?? "—")
                    }
                    Divider().overlay(ForgeColors.stroke)
                    HStack {
                        Label("Average pace", systemImage: "speedometer")
                        Spacer()
                        Text(health.latestRunPaceMinutesPerKm.map { String(format: "%.2f min/km", $0) } ?? "—")
                    }
                    Divider().overlay(ForgeColors.stroke)
                    HStack {
                        Label("Duration", systemImage: "timer")
                        Spacer()
                        Text(health.latestRunDurationMinutes.map { String(format: "%.0f min", $0) } ?? "—")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
                Text("Strain and cardio load are intentionally not estimated from incomplete data.")
                    .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                Spacer(minLength: 110)
            }
            .padding(18).padding(.top, 16)
        }
        .refreshable { health.refresh(); insights.refresh() }
    }
}
struct RunningDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager
    @AppStorage("pulseforge.running.maxHeartRate") private var maxHeartRate = 0
    @State private var maxHeartRateDraft = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(eyebrow: "PERFORMANCE", title: "Running")
                WorkoutRecordingCard(bluetooth: bluetooth)
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "LATEST ACTIVITY")
                    Text(health.latestRunDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No run synced")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Your latest running workout from Apple Health.")
                        .font(.system(size: 11)).foregroundStyle(ForgeColors.muted)
                    HStack(spacing: 10) {
                        RunHighlight(value: health.latestRunDistanceKm.map { String(format: "%.2f", $0) } ?? "—", unit: "KM", label: "DISTANCE")
                        RunHighlight(value: health.latestRunPaceMinutesPerKm.map { String(format: "%.2f", $0) } ?? "—", unit: "MIN/KM", label: "AVG PACE")
                        RunHighlight(value: health.latestRunDurationMinutes.map { String(format: "%.0f", $0) } ?? "—", unit: "MIN", label: "TIME")
                    }
                    .padding(.top, 8)
                }
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 22))
                HStack(spacing: 10) {
                    CompactMetric(title: "AVERAGE HR", value: health.latestRunAverageHeartRate.map(String.init) ?? "—", unit: "bpm")
                    CompactMetric(title: "HR SAMPLES", value: health.latestRunHeartRateSampleCount.formatted(), unit: "points")
                    CompactMetric(title: "SPLITS", value: health.latestRunSplits.count.formatted(), unit: "km")
                }
                SectionHeader(title: "HEART RATE")
                WorkoutHeartRateChart(points: health.latestRunHeartRatePoints)
                SectionHeader(title: "HEART RATE ZONES")
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("MAX HEART RATE").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(ForgeColors.muted)
                        Spacer()
                        Text(maxHeartRate > 0 ? "\(maxHeartRate) BPM" : "NOT SET")
                            .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(ForgeColors.lime)
                    }
                    HStack(spacing: 10) {
                        TextField("Measured max HR", text: $maxHeartRateDraft)
                            .keyboardType(.numberPad).font(.system(size: 13, design: .rounded))
                            .padding(11).background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 10))
                        Button("SAVE") {
                            if let value = Int(maxHeartRateDraft), (100...240).contains(value) {
                                maxHeartRate = value
                                maxHeartRateDraft = ""
                            }
                        }
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 15).padding(.vertical, 12)
                        .background(ForgeColors.lime, in: Capsule())
                    }
                    Text("Enter a measured maximum from a reliable test; zones are not calculated from an age-based estimate.")
                        .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                    if maxHeartRate > 0 {
                        ForEach(Array(heartRateZones(maxHR: maxHeartRate, points: health.latestRunHeartRatePoints).enumerated()), id: \.offset) { _, zone in
                            ZoneRow(name: zone.name, color: zone.color, minutes: zone.minutes)
                        }
                    } else {
                        Text("Set your max HR to view time in each zone.")
                            .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                    }
                }
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
                SectionHeader(title: "PACE & SPLITS")
                VStack(spacing: 12) {
                    HStack {
                        Text("KM")
                        Spacer()
                        Text("PACE")
                        Spacer()
                        Text("DISTANCE")
                    }
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(ForgeColors.muted)
                    Divider().overlay(ForgeColors.stroke)
                    if health.latestRunSplits.isEmpty {
                        Text("No distance split samples available")
                            .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(health.latestRunSplits) { split in
                            HStack {
                                Text(split.label).frame(width: 42, alignment: .leading)
                                Spacer()
                                Text(split.paceText).monospacedDigit()
                                Spacer()
                                Text(String(format: "%.2f km", split.distanceKm)).foregroundStyle(ForgeColors.muted)
                            }
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        }
                    }
                }
                .padding(18).background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
                Text("Only synced workout measurements are displayed.")
                    .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
                Spacer(minLength: 110)
            }
            .padding(18).padding(.top, 16)
        }
        .refreshable { health.refresh() }
    }
}

struct RunHighlight: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(ForgeColors.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 8, weight: .bold)).foregroundStyle(ForgeColors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct ZoneRow: View {
    let name: String
    let color: Color
    var minutes: Double? = nil
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 4, height: 20)
            Text(name).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(minutes.map { String(format: "%.1f min", $0) } ?? "—").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(ForgeColors.muted)
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

struct WhoopBatteryInline: View {
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager

    private var batterySymbol: String {
        guard let level = bluetooth.whoopBatteryPercent else { return "battery.0percent" }
        if level >= 75 { return "battery.100percent" }
        if level >= 50 { return "battery.75percent" }
        if level >= 25 { return "battery.50percent" }
        return "battery.25percent"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: batterySymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(bluetooth.whoopBatteryPercent == nil ? ForgeColors.muted : ForgeColors.lime)
            Text(bluetooth.whoopBatteryPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text("BATTERY")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(ForgeColors.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(ForgeColors.track, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("WHOOP battery \(bluetooth.whoopBatteryPercent.map { String(format: "%.0f percent", $0) } ?? "not received")")
    }
}

struct DeviceDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(eyebrow: "CONNECTED BAND", title: "WHOOP")
                HStack { Spacer(); WhoopBatteryInline() }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 24)).foregroundStyle(ForgeColors.lime)
                        Spacer()
                        Text(bluetooth.connectedName == nil ? "NOT CONNECTED" : "CONNECTED")
                            .font(.system(size: 9, weight: .bold)).tracking(1)
                            .foregroundStyle(bluetooth.connectedName == nil ? ForgeColors.muted : ForgeColors.lime)
                    }
                    Text(bluetooth.connectedName ?? (bluetooth.isConnecting ? "Connecting to WHOOP…" : "WHOOP 5.0"))
                        .font(.system(size: 19, weight: .semibold))
                    Text(bluetooth.statusText)
                        .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(bluetooth.freshHeartRateBPM == nil ? ForgeColors.muted : ForgeColors.lime)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bluetooth.freshHeartRateBPM.map(String.init) ?? "—")
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(bluetooth.freshHeartRateBPM == nil
                                 ? "CONNECTED · WAITING FOR HR DATA"
                                 : "LIVE · \(bluetooth.heartRateUpdateCount) UPDATE(S)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(ForgeColors.muted)
                            Text(bluetooth.lastHeartRateAt.map { "LAST HR · \($0.formatted(date: .omitted, time: .standard))" } ?? "NO HR PACKET RECEIVED")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(ForgeColors.muted)
                        }
                        Spacer()
                        Text("BPM")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ForgeColors.muted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                    }
                    LiveHeartRateChartCard(samples: bluetooth.liveHeartRateSamples, title: "LIVE · LAST 60 SECONDS")
                    WhoopMotionCard()
                    if bluetooth.connectedName != nil {
                        Button { bluetooth.disconnect() } label: {
                            Label("DISCONNECT BAND", systemImage: "xmark.circle")
                                .font(.system(size: 10, weight: .bold)).tracking(0.8)
                                .frame(maxWidth: .infinity).padding(14)
                                .background(ForgeColors.track, in: Capsule()).foregroundStyle(.white)
                        }
                    } else if bluetooth.isConnecting {
                        Button { bluetooth.disconnect() } label: {
                            Label("CANCEL CONNECTION", systemImage: "xmark.circle")
                                .font(.system(size: 10, weight: .bold)).tracking(0.8)
                                .frame(maxWidth: .infinity).padding(14)
                                .background(ForgeColors.track, in: Capsule()).foregroundStyle(.white)
                        }
                    } else {
                        Button { bluetooth.startScan() } label: {
                            Label("SCAN FOR WHOOP BAND", systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .bold)).tracking(0.8)
                                .frame(maxWidth: .infinity).padding(14)
                                .background(ForgeColors.lime, in: Capsule()).foregroundStyle(.black)
                        }
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
                                            if !device.advertisedServices.isEmpty {
                                                Text("ADV: " + device.advertisedServices.joined(separator: ", "))
                                                    .font(.system(size: 8, design: .monospaced))
                                                    .foregroundStyle(ForgeColors.muted).textSelection(.enabled)
                                            }
                                            if !device.serviceDataEntries.isEmpty {
                                                Text("Service data: " + device.serviceDataEntries.joined(separator: ", "))
                                                    .font(.system(size: 8, design: .monospaced))
                                                    .foregroundStyle(ForgeColors.muted).textSelection(.enabled)
                                            }
                                            if !device.solicitedServices.isEmpty {
                                                Text("Solicited: " + device.solicitedServices.joined(separator: ", "))
                                                    .font(.system(size: 8, design: .monospaced))
                                                    .foregroundStyle(ForgeColors.muted).textSelection(.enabled)
                                            }
                                            if !device.overflowServices.isEmpty {
                                                Text("Overflow: " + device.overflowServices.joined(separator: ", "))
                                                    .font(.system(size: 8, design: .monospaced))
                                                    .foregroundStyle(ForgeColors.muted).textSelection(.enabled)
                                            }
                                            if let byteCount = device.manufacturerDataByteCount {
                                                Text("Manufacturer data: \(byteCount) bytes")
                                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(ForgeColors.muted)
                                            }
                                            if let power = device.transmitPower {
                                                Text("TX power: \(power) dBm")
                                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(ForgeColors.muted)
                                            }
                                            if let connectable = device.isConnectable {
                                                Text(connectable ? "Connectable" : "Not connectable")
                                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(ForgeColors.muted)
                                            }
                                        }
                                        Spacer()
                                        Text("\(device.rssi) dBm").font(.system(size: 10, design: .monospaced)).foregroundStyle(ForgeColors.muted)
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(12).background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .disabled(bluetooth.isConnecting)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("LATEST BLE EVENT")
                                .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.lime)
                            Spacer()
                            ShareLink(item: bluetooth.diagnosticSnapshot) {
                                Label("EXPORT", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                                    .foregroundStyle(ForgeColors.lime)
                            }
                        }
                        Text(bluetooth.lastBLEEvent)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(ForgeColors.muted).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("NOTIFICATION CHANNEL STATUS")
                            .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.lime)
                        Text(bluetooth.notificationDiagnostics.joined(separator: "\\n"))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(ForgeColors.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                    if !bluetooth.discoveredProfile.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("DISCOVERED GATT PROFILE")
                                .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.lime)
                            Text(bluetooth.gattCapabilitySummary)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(ForgeColors.muted)
                            ForEach(Array(bluetooth.discoveredProfile.enumerated()), id: \.offset) { item in
                                Text(item.element).font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(ForgeColors.muted).textSelection(.enabled)
                            }
                        }
                        .padding(12).background(ForgeColors.track, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("WHOOP candidate detection is heuristic (device name and archive-derived UUID hints); it does not confirm device identity or service roles.")
                        .font(.system(size: 10)).foregroundStyle(ForgeColors.muted)
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
    @Published private(set) var deepSleepMinutes: Double?
    @Published private(set) var remSleepMinutes: Double?
    @Published private(set) var coreSleepMinutes: Double?
    @Published private(set) var awakeMinutes: Double?
    @Published private(set) var latestRunDistanceKm: Double?
    @Published private(set) var latestRunDurationMinutes: Double?
    @Published private(set) var latestRunPaceMinutesPerKm: Double?
    @Published private(set) var latestRunAverageHeartRate: Int?
    @Published private(set) var latestRunHeartRateSampleCount = 0
    @Published private(set) var latestRunHeartRatePoints: [WorkoutHeartRatePoint] = []
    @Published private(set) var latestRunSplits: [RunSplit] = []
    @Published private(set) var latestRunDate: Date?
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var isRefreshing = false
    private let store = HKHealthStore()

    func refresh() {
        guard isAuthorized, !isRefreshing else { return }
        isRefreshing = true
        let group = DispatchGroup()
        group.enter()
        loadHealthMetrics { group.leave() }
        group.enter()
        loadSleepDuration { group.leave() }
        group.enter()
        loadLatestRun { group.leave() }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.lastRefreshDate = Date()
            self.isRefreshing = false
        }
    }

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        // HealthKit may not expose every optional quantity/category type on
        // every OS/device configuration. Build the read set only from types
        // that are actually available instead of force-unwrapping them.
        var readTypes = Set<HKObjectType>()
        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .heartRate, .heartRateVariabilitySDNN, .restingHeartRate,
            .respiratoryRate, .oxygenSaturation, .distanceWalkingRunning
        ]
        for identifier in quantityIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            readTypes.insert(sleepType)
        }
        readTypes.insert(HKObjectType.workoutType())
        guard !readTypes.isEmpty else {
            isAuthorized = false
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            refresh()
        } catch {
            isAuthorized = false
        }
    }

    private func loadHealthMetrics(completion: @escaping () -> Void) {
        let group = DispatchGroup()
        let rateUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        group.enter()
        loadLatestQuantity(.heartRate, unit: rateUnit) { [weak self] value in self?.heartRate = value.map(Int.init); group.leave() }
        group.enter()
        loadLatestQuantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli)) { [weak self] value in self?.hrvMilliseconds = value; group.leave() }
        group.enter()
        loadLatestQuantity(.restingHeartRate, unit: rateUnit) { [weak self] value in self?.restingHeartRate = value.map(Int.init); group.leave() }
        group.enter()
        loadLatestQuantity(.respiratoryRate, unit: rateUnit) { [weak self] value in self?.respiratoryRate = value; group.leave() }
        group.enter()
        loadLatestQuantity(.oxygenSaturation, unit: HKUnit.percent(), multiplier: 100) { [weak self] value in self?.bloodOxygenPercent = value; group.leave() }
        group.notify(queue: .main, execute: completion)
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

    private func loadSleepDuration(completion: @escaping () -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { completion(); return }
        let start = Calendar.current.date(byAdding: .hour, value: -36, to: Date()) ?? Date().addingTimeInterval(-129600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1000, sortDescriptors: nil) { [weak self] _, samples, _ in
            let entries = samples as? [HKCategorySample] ?? []
            func mergedMinutes(for values: Set<Int>) -> Double {
                let intervals = entries
                    .filter { values.contains($0.value) }
                    .map { (start: $0.startDate, end: $0.endDate) }
                    .sorted { $0.start < $1.start }
                guard var current = intervals.first else { return 0 }
                var seconds = 0.0
                for interval in intervals.dropFirst() {
                    if interval.start <= current.end {
                        current.end = max(current.end, interval.end)
                    } else {
                        seconds += current.end.timeIntervalSince(current.start)
                        current = interval
                    }
                }
                seconds += current.end.timeIntervalSince(current.start)
                return seconds / 60
            }
            let deep = mergedMinutes(for: [HKCategoryValueSleepAnalysis.asleepDeep.rawValue])
            let rem = mergedMinutes(for: [HKCategoryValueSleepAnalysis.asleepREM.rawValue])
            let core = mergedMinutes(for: [HKCategoryValueSleepAnalysis.asleepCore.rawValue])
            let unspecified = mergedMinutes(for: [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue])
            let awake = mergedMinutes(for: [HKCategoryValueSleepAnalysis.awake.rawValue])
            let asleep = deep + rem + core + unspecified
            Task { @MainActor in
                self?.deepSleepMinutes = deep > 0 ? deep : nil
                self?.remSleepMinutes = rem > 0 ? rem : nil
                self?.coreSleepMinutes = (core + unspecified) > 0 ? core + unspecified : nil
                self?.awakeMinutes = awake > 0 ? awake : nil
                self?.sleepHours = asleep > 0 ? asleep / 60 : nil
                completion()
            }
        }
        store.execute(query)
    }

    private func loadLatestRun(completion: @escaping () -> Void) {
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let workout = samples?.first as? HKWorkout else {
                Task { @MainActor in
                    self?.latestRunDistanceKm = nil
                    self?.latestRunDurationMinutes = nil
                    self?.latestRunPaceMinutesPerKm = nil
                    self?.latestRunAverageHeartRate = nil
                    self?.latestRunHeartRateSampleCount = 0
                    self?.latestRunHeartRatePoints = []
                    self?.latestRunSplits = []
                    self?.latestRunDate = nil
                    completion()
                }
                return
            }
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
                let nested = DispatchGroup()
                nested.enter()
                self?.loadHeartRateForRun(workout) { nested.leave() }
                nested.enter()
                self?.loadDistanceSplits(for: workout) { nested.leave() }
                nested.notify(queue: .main, execute: completion)
            }
        }
        store.execute(query)
    }

    private func loadHeartRateForRun(_ workout: HKWorkout, completion: @escaping () -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            completion()
            return
        }
        let predicate = HKQuery.predicateForObjects(from: workout)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            let values = (samples as? [HKQuantitySample] ?? []).map {
                $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
            }
            let average = values.isEmpty ? nil : Int((values.reduce(0, +) / Double(values.count)).rounded())
            let points = (samples as? [HKQuantitySample] ?? []).map { sample in
                WorkoutHeartRatePoint(
                    elapsedMinutes: max(0, sample.startDate.timeIntervalSince(workout.startDate) / 60),
                    beatsPerMinute: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())),
                    durationSeconds: max(0, sample.endDate.timeIntervalSince(sample.startDate))
                )
            }
            Task { @MainActor in
                self?.latestRunAverageHeartRate = average
                self?.latestRunHeartRateSampleCount = values.count
                self?.latestRunHeartRatePoints = points
                completion()
            }
        }
        store.execute(query)
    }

    private func loadDistanceSplits(for workout: HKWorkout, completion: @escaping () -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) else {
            completion()
            return
        }
        let predicate = HKQuery.predicateForObjects(from: workout)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            let entries = (samples as? [HKQuantitySample] ?? []).sorted { $0.startDate < $1.startDate }
            var rows: [RunSplit] = []
            var splitDistance = 0.0
            var splitSeconds = 0.0
            var totalDistance = 0.0
            var splitNumber = 1
            for sample in entries {
                var remaining = max(0, sample.quantity.doubleValue(for: HKUnit.meter()))
                guard remaining > 0 else { continue }
                let sampleSeconds = max(0, sample.endDate.timeIntervalSince(sample.startDate))
                let secondsPerMeter = sampleSeconds / remaining
                while remaining > 0 {
                    let portion = min(remaining, 1000 - splitDistance)
                    splitDistance += portion
                    splitSeconds += portion * secondsPerMeter
                    totalDistance += portion
                    remaining -= portion
                    if splitDistance >= 999.999 {
                        rows.append(RunSplit(number: splitNumber, distanceKm: splitDistance / 1000, durationSeconds: splitSeconds))
                        splitNumber += 1
                        splitDistance = 0
                        splitSeconds = 0
                    }
                }
            }
            if splitDistance > 1 {
                rows.append(RunSplit(number: splitNumber, distanceKm: splitDistance / 1000, durationSeconds: splitSeconds))
            }
            Task { @MainActor in
                self?.latestRunSplits = rows
                completion()
            }
        }
        store.execute(query)
    }
}

struct WorkoutHeartRatePoint: Identifiable {
    let elapsedMinutes: Double
    let beatsPerMinute: Double
    let durationSeconds: Double
    var id: Double { elapsedMinutes }
}

struct WorkoutHeartRateChart: View {
    let points: [WorkoutHeartRatePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BPM").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(ForgeColors.muted)
                Spacer()
                Text(points.isEmpty ? "NO WORKOUT SAMPLES" : "\(points.count) SAMPLES")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(ForgeColors.muted)
            }
            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(
                        x: .value("Elapsed time", point.elapsedMinutes),
                        y: .value("Heart rate", point.beatsPerMinute)
                    )
                    .foregroundStyle(ForgeColors.lime)
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("Elapsed time", point.elapsedMinutes),
                        y: .value("Heart rate", point.beatsPerMinute)
                    )
                    .foregroundStyle(ForgeColors.lime.opacity(0.12))
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxisLabel("Minutes")
                .chartYAxisLabel("BPM")
                .frame(height: 170)
            } else {
                Text(points.isEmpty ? "Heart-rate samples for this run will appear here after Apple Health sync." : "At least two heart-rate samples are needed to draw the chart.")
                    .font(.system(size: 12)).foregroundStyle(ForgeColors.muted)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
        }
        .padding(18)
        .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct HeartRateZoneSummary {
    let name: String
    let color: Color
    let minutes: Double
}

func heartRateZones(maxHR: Int, points: [WorkoutHeartRatePoint]) -> [HeartRateZoneSummary] {
    let definitions: [(String, Double, Double, Color)] = [
        ("Zone 5 · Maximum", 0.90, 1.01, Color(red: 0.96, green: 0.31, blue: 0.27)),
        ("Zone 4 · Threshold", 0.80, 0.90, Color(red: 1.0, green: 0.58, blue: 0.22)),
        ("Zone 3 · Aerobic", 0.70, 0.80, Color(red: 0.96, green: 0.82, blue: 0.25)),
        ("Zone 2 · Easy", 0.60, 0.70, ForgeColors.lime),
        ("Zone 1 · Recovery", 0.50, 0.60, Color(red: 0.32, green: 0.67, blue: 0.92))
    ]
    var seconds = Array(repeating: 0.0, count: definitions.count)
    for (index, point) in points.enumerated() {
        let nextGap = index + 1 < points.count
            ? max(0, (points[index + 1].elapsedMinutes - point.elapsedMinutes) * 60)
            : 0
        let sampleDuration = point.durationSeconds > 0 ? point.durationSeconds : min(nextGap, 30)
        let duration = min(max(sampleDuration, 0), 30)
        guard duration > 0 else { continue }
        for (zoneIndex, definition) in definitions.enumerated() {
            let lower = Double(maxHR) * definition.1
            let upper = Double(maxHR) * definition.2
            if point.beatsPerMinute >= lower && point.beatsPerMinute < upper {
                seconds[zoneIndex] += duration
                break
            }
        }
    }
    return definitions.enumerated().map { index, definition in
        HeartRateZoneSummary(name: definition.0, color: definition.3, minutes: seconds[index] / 60)
    }
}

struct RunSplit: Identifiable {
    let number: Int
    let distanceKm: Double
    let durationSeconds: Double
    var id: Int { number }
    var label: String { String(format: "%02d", number) }
    var paceText: String {
        guard distanceKm > 0 else { return "—" }
        let secondsPerKm = durationSeconds / distanceKm
        return String(format: "%d:%02d /km", Int(secondsPerKm) / 60, Int(secondsPerKm) % 60)
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

struct SleepStageBreakdown: View {
    let deep: Double?
    let rem: Double?
    let core: Double?
    let awake: Double?

    private var stages: [(String, Double?, Color)] {
        [
            ("Deep", deep, Color(red: 0.38, green: 0.34, blue: 0.9)),
            ("REM", rem, Color(red: 0.42, green: 0.64, blue: 0.95)),
            ("Light", core, ForgeColors.lime),
            ("Awake", awake, ForgeColors.muted)
        ]
    }
    private var total: Double { stages.reduce(0) { $0 + ($1.1 ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(stages, id: \.0) { stage in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(stage.2.opacity(stage.1 == nil ? 0.18 : 1))
                            .frame(width: total > 0 ? max(3, proxy.size.width * (stage.1 ?? 0) / total) : proxy.size.width / 4)
                    }
                }
            }
            .frame(height: 9)
            ForEach(stages, id: \.0) { stage in
                HStack(spacing: 8) {
                    Circle().fill(stage.2).frame(width: 7, height: 7)
                    Text(stage.0).font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(stage.1.map { "\(Int($0.rounded())) min" } ?? "—")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(stage.1 == nil ? ForgeColors.muted : .white)
                }
            }
        }
        .padding(16)
        .background(ForgeColors.card, in: RoundedRectangle(cornerRadius: 18))
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
