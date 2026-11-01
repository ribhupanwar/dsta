import SwiftUI

/// Reference-style Home dashboard. All metrics are sourced from HealthKit or live stores.
struct WoopReferenceHomeScreen: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var insights: TrainingInsightsStore
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager
    @State private var showingRecovery = false
    @State private var showingSleep = false

    private var recoveryTint: Color {
        guard let score = insights.recoveryScore else { return WoopReplicaPalette.muted }
        return score >= 67 ? WoopReplicaPalette.recoveryHigh : (score >= 34 ? WoopReplicaPalette.recoveryMid : WoopReplicaPalette.recoveryLow)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 17) {
                header
                scoreStrip
                deviceNotice
                scoreRings
                monitors
                myDay
                activities
                trend
                Text("HealthKit measurements and PulseForge estimates are not WHOOP proprietary scores.")
                    .font(.system(size: 9)).foregroundStyle(WoopReplicaPalette.muted)
                    .padding(.bottom, 110)
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
        .background(WoopReplicaPalette.canvas.ignoresSafeArea())
        .refreshable { health.refresh(); insights.refresh() }
        .sheet(isPresented: $showingRecovery) {
            WoopReferenceRecoveryScreen().environmentObject(health).environmentObject(insights).preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingSleep) {
            WoopReferenceSleepScreen().environmentObject(health).environmentObject(insights).preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("PULSEFORGE").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(WoopReplicaPalette.secondary)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(WoopReplicaPalette.primary)
            }
            Spacer()
            Button { health.refresh(); insights.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WoopReplicaPalette.secondary).frame(width: 40, height: 40)
                    .background(WoopReplicaPalette.surfaceRaised, in: Circle())
            }.buttonStyle(.plain)
        }
    }

    private var scoreStrip: some View {
        HStack(spacing: 0) {
            stripMetric("RECOVERY", value: insights.recoveryScore.map { "\($0)%" } ?? "—", tint: recoveryTint) { showingRecovery = true }
            separator
            stripMetric("SLEEP", value: health.sleepHours.map { String(format: "%.1f h", $0) } ?? "—", tint: WoopReplicaPalette.sleep) { showingSleep = true }
            separator
            stripMetric("STRAIN", value: insights.cardioLoadPoints.map { String(format: "%.1f", $0) } ?? "—", tint: WoopReplicaPalette.recoveryMid) {}
        }
        .padding(.vertical, 13).background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private var separator: some View { Rectangle().fill(WoopReplicaPalette.hairline).frame(width: 1, height: 32) }

    private func stripMetric(_ title: String, value: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 8, weight: .bold)).tracking(0.7).foregroundStyle(WoopReplicaPalette.secondary)
                Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var deviceNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg").foregroundStyle(WoopReplicaPalette.sleep)
            VStack(alignment: .leading, spacing: 3) {
                Text("DEVICE · LIVE HEART RATE").font(.system(size: 8, weight: .bold)).tracking(0.7).foregroundStyle(WoopReplicaPalette.secondary)
                Text(bluetooth.freshHeartRateBPM.map { "\($0) BPM" } ?? "Waiting for wearable data")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
            }
            Spacer()
            Circle().fill(bluetooth.freshHeartRateBPM == nil ? WoopReplicaPalette.muted : WoopReplicaPalette.recoveryHigh).frame(width: 7, height: 7)
        }.padding(14).background(WoopReplicaPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 15))
    }

    private var scoreRings: some View {
        HStack(spacing: 8) {
            ring("RECOVERY", value: insights.recoveryScore, tint: recoveryTint) { showingRecovery = true }
            ring("SLEEP", value: health.sleepHours.map { Int(($0 / max(1, insights.sleepNeedHours) * 100).rounded()) }, tint: WoopReplicaPalette.sleep) { showingSleep = true }
            ring("STRAIN", value: nil, tint: WoopReplicaPalette.recoveryMid) {}
        }.padding(.vertical, 16).background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func ring(_ title: String, value: Int?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(WoopReplicaPalette.homeTrack, lineWidth: 6)
                    if let value {
                        Circle().trim(from: 0, to: CGFloat(min(100, max(0, value))) / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    Text(value.map(String.init) ?? "—").font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
                }.frame(width: 68, height: 68)
                Text(title).font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(WoopReplicaPalette.secondary)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var monitors: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("MONITORS")
            HStack(spacing: 9) {
                monitor("HEART RATE", value: health.heartRate.map(String.init) ?? "—", unit: "bpm", symbol: "heart.fill")
                monitor("RESPIRATORY", value: health.respiratoryRate.map { String(format: "%.1f", $0) } ?? "—", unit: "br/min", symbol: "lungs.fill")
            }
            HStack(spacing: 9) {
                monitor("BLOOD OXYGEN", value: health.bloodOxygenPercent.map { String(format: "%.0f", $0) } ?? "—", unit: "%", symbol: "drop.fill")
                monitor("RESTING HR", value: health.restingHeartRate.map(String.init) ?? "—", unit: "bpm", symbol: "heart")
            }
        }
    }

    private func monitor(_ title: String, value: String, unit: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.system(size: 8, weight: .bold)).tracking(0.3)
                .foregroundStyle(WoopReplicaPalette.secondary).lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
                Text(unit).font(.system(size: 9)).foregroundStyle(WoopReplicaPalette.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).padding(12)
            .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
    }

    private var myDay: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("MY DAY")
            HStack(spacing: 0) {
                dayMetric("WORKOUTS", value: "\(insights.workoutCountToday)")
                separator
                dayMetric("ACTIVE TIME", value: insights.workoutMinutesToday.map { "\(Int($0.rounded())) min" } ?? "—")
                separator
                dayMetric("WEEKLY RUNS", value: "\(health.weeklyRunCount)")
            }.padding(.vertical, 13).background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func dayMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 7, weight: .bold)).tracking(0.4).foregroundStyle(WoopReplicaPalette.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
        }.frame(maxWidth: .infinity)
    }

    private var activities: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("ACTIVITIES", trailing: "LATEST RUN")
            if let date = health.latestRunDate {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: "figure.run").font(.system(size: 17)).foregroundStyle(WoopReplicaPalette.sleep)
                            .frame(width: 36, height: 36).background(WoopReplicaPalette.surfaceInset, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Running").font(.system(size: 12, weight: .semibold)).foregroundStyle(WoopReplicaPalette.primary)
                            Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.system(size: 9)).foregroundStyle(WoopReplicaPalette.secondary)
                        }
                        Spacer()
                        Text(health.latestRunDistanceKm.map { String(format: "%.2f km", $0) } ?? "Distance —")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(WoopReplicaPalette.primary)
                    }
                    HStack(spacing: 14) {
                        activityMetric("DURATION", health.latestRunDurationMinutes.map { "\(Int($0.rounded())) min" } ?? "—")
                        activityMetric("PACE", health.latestRunPaceMinutesPerKm.map { String(format: "%.2f /km", $0) } ?? "—")
                        activityMetric("AVG HR", health.latestRunAverageHeartRate.map { "\($0) bpm" } ?? "—")
                    }.padding(.leading, 45)
                }.padding(13).background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
            } else {
                emptyCard("No running workout found in Apple Health yet.")
            }
        }
    }

    private func activityMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 7, weight: .bold)).foregroundStyle(WoopReplicaPalette.muted)
            Text(value).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(WoopReplicaPalette.secondary)
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("RECOVERY · EFFORT TREND")
            emptyCard("Daily history is not loaded yet. Trend lines will appear when date-wise measurements are available.")
        }
    }

    private func section(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(WoopReplicaPalette.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 8, weight: .bold)).foregroundStyle(WoopReplicaPalette.muted) }
        }
    }

    private func emptyCard(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).lineSpacing(3).foregroundStyle(WoopReplicaPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading).padding(13)
            .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
    }
}
