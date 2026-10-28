import SwiftUI

/// WHOOP-inspired home layout. Scores remain blank until PulseForge has enough
/// verified source data; unavailable stress and strain values are never fabricated.
struct WhoopStyleTodayDashboard: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var insights: TrainingInsightsStore
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager
    @State private var showingRecovery = false

    private let green = Color(red: 0.20, green: 0.91, blue: 0.18)
    private let blue = Color(red: 0.12, green: 0.61, blue: 0.95)
    private let mutedBlue = Color(red: 0.48, green: 0.67, blue: 0.79)

    private var sleepPercent: Int? {
        guard let hours = insights.sleepHours, insights.sleepNeedHours > 0 else { return nil }
        return min(100, max(0, Int((hours / insights.sleepNeedHours * 100).rounded())))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 19) {
                header
                scoreRow
                monitorRow
                myDay
                activities
                tonightSleep
                liveHeartRate
                Text("PulseForge estimates use available Apple Health and WHOOP data. Missing measurements are shown as unavailable, not guessed.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(mutedBlue.opacity(0.8))
                    .padding(.bottom, 112)
            }
            .padding(.horizontal, 17)
            .padding(.top, 12)
        }
        .refreshable { health.refresh(); insights.refresh() }
        .sheet(isPresented: $showingRecovery) {
            RecoveryDetailSheet()
                .environmentObject(health)
                .environmentObject(insights)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("PULSEFORGE")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .tracking(2.3)
                    .foregroundStyle(.white)
                Text("TODAY · " + Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(mutedBlue)
            }
            Spacer()
            Image(systemName: "figure.run.circle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.cyan)
        }
        .padding(.top, 7)
    }

    private var scoreRow: some View {
        HStack(alignment: .top, spacing: 4) {
            WhoopScoreRing(title: "SLEEP", value: sleepPercent.map(String.init) ?? "—",
                           percent: Double(sleepPercent ?? 0) / 100, tint: mutedBlue)
            WhoopScoreRing(title: "RECOVERY", value: insights.recoveryScore.map { "\($0)%" } ?? "—",
                           percent: Double(insights.recoveryScore ?? 0) / 100, tint: green)
            WhoopScoreRing(title: "STRAIN", value: insights.cardioLoadPoints.map { String(format: "%.1f", $0) } ?? "—",
                           percent: min(1, (insights.cardioLoadPoints ?? 0) / 21), tint: blue)
        }
        .padding(.top, 3)
    }

    private var monitorRow: some View {
        HStack(spacing: 11) {
            monitorCard(title: "HEALTH MONITOR", value: health.hrvMilliseconds == nil || health.restingHeartRate == nil ? "Waiting for baseline" : "Measurements available",
                        symbol: "heart.text.square", tint: mutedBlue)
            monitorCard(title: "STRESS MONITOR", value: "Not available yet",
                        symbol: "waveform.path", tint: blue)
        }
    }

    private func monitorCard(title: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(title).font(.system(size: 11, weight: .black)).tracking(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background(Color.white.opacity(0.105), in: RoundedRectangle(cornerRadius: 16))
    }

    private var myDay: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("My Day").font(.system(size: 23, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 42, height: 42)
                    .background(.white, in: RoundedRectangle(cornerRadius: 13))
            }
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(mutedBlue)
                Text("Ask PulseForge, get support…")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(16)
            .background(Color.white.opacity(0.105), in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private var activities: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("TODAY'S ACTIVITIES")
                    .font(.system(size: 12, weight: .black)).tracking(1.2)
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(blue).frame(width: 74, height: 62)
                    Image(systemName: "figure.run").font(.system(size: 27, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(insights.workoutCountToday > 0 ? "WORKOUTS" : "NO ACTIVITY YET")
                        .font(.system(size: 13, weight: .black)).tracking(1)
                    Text(insights.workoutMinutesToday.map { "\(Int($0.rounded())) MIN TOTAL" } ?? "Today's recorded sessions")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Text("\(insights.workoutCountToday)")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .padding(10)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            HStack(spacing: 10) {
                actionTile("ADD ACTIVITY", symbol: "plus")
                actionTile("START ACTIVITY", symbol: "stopwatch")
            }
        }
        .padding(15)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20))
    }

    private func actionTile(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
            Text(title).font(.system(size: 10, weight: .black)).tracking(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 49)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tonightSleep: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 9) {
                Text("TONIGHT'S SLEEP")
                    .font(.system(size: 12, weight: .black)).tracking(1.1)
                Text("SLEEP NEED")
                    .font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(mutedBlue)
                Text(String(format: "%.1f HOURS", insights.sleepNeedHours))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Spacer()
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(mutedBlue)
        }
        .padding(17)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18))
    }

    private var liveHeartRate: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("WHOOP · LIVE HEART RATE")
                    .font(.system(size: 11, weight: .black)).tracking(1)
                Spacer()
                Circle().fill(bluetooth.freshHeartRateBPM == nil ? .gray : .cyan).frame(width: 8, height: 8)
            }
            Text(bluetooth.freshHeartRateBPM.map { "\($0) BPM" } ?? "Waiting for sensor")
                .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
            LiveHeartRateChartCard(samples: bluetooth.liveHeartRateSamples, title: "LIVE HEART RATE")
        }
        .padding(15)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct WhoopScoreRing: View {
    let title: String
    let value: String
    let percent: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 7)
                Circle().trim(from: 0, to: min(1, max(0, percent)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(width: 91, height: 91)
            Text(title)
                .font(.system(size: 10, weight: .black)).tracking(1)
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
