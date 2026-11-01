import SwiftUI

/// Reference-style Home dashboard. All metrics are sourced from HealthKit or live stores.
struct WoopReferenceHomeScreen: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var insights: TrainingInsightsStore
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager
    @EnvironmentObject private var whoopImport: WHOOPImportStore
    @State private var showingRecovery = false
    @State private var showingSleep = false
    @State private var showingLoad = false
    @State private var showingWHOOPImport = false

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
                whoopImportEntry
                scoreRings
                monitors
                myDay
                activities
                trend
                Text("HealthKit measurements and PulseForge estimates are not WHOOP proprietary scores.")
                    .font(WoopTypography.body(9)).foregroundStyle(WoopReplicaPalette.muted)
                    .padding(.bottom, 110)
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
        .background(WoopReplicaPalette.canvas.ignoresSafeArea())
        .refreshable { health.refresh(); insights.refresh() }
        .sheet(isPresented: $showingRecovery) {
            NavigationStack {
                WoopReferenceRecoveryScreen()
                    .navigationTitle("Recovery")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingRecovery = false } } }
            }
            .environmentObject(health).environmentObject(insights).environmentObject(bluetooth)
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSleep) {
            NavigationStack {
                WoopReferenceSleepScreen()
                    .navigationTitle("Sleep")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingSleep = false } } }
            }
            .environmentObject(health).environmentObject(insights).environmentObject(bluetooth)
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingWHOOPImport) {
            WHOOPDataImportSheet().environmentObject(whoopImport)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingLoad) {
            NavigationStack {
                StrainDashboard()
                    .navigationTitle("Load")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingLoad = false } } }
            }
            .environmentObject(health).environmentObject(insights)
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("PULSEFORGE").font(WoopTypography.label(11)).tracking(2).foregroundStyle(WoopReplicaPalette.secondary)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(WoopTypography.emphasis(21)).foregroundStyle(WoopReplicaPalette.primary)
            }
            Spacer()
            Button { health.refresh(); insights.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(WoopTypography.emphasis(15))
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
            stripMetric("LOAD PTS", value: insights.cardioLoadPoints.map { String(format: "%.1f", $0) } ?? "—", tint: WoopReplicaPalette.recoveryMid) { showingLoad = true }
        }
        .padding(.vertical, 13).background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private var separator: some View { Rectangle().fill(WoopReplicaPalette.hairline).frame(width: 1, height: 32) }

    private func stripMetric(_ title: String, value: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title).font(WoopTypography.label(8)).tracking(0.7).foregroundStyle(WoopReplicaPalette.secondary)
                Text(value).font(WoopTypography.metric(16)).monospacedDigit().foregroundStyle(tint)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var deviceNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg").foregroundStyle(WoopReplicaPalette.sleep)
            VStack(alignment: .leading, spacing: 3) {
                Text("DEVICE · LIVE HEART RATE").font(WoopTypography.label(8)).tracking(0.7).foregroundStyle(WoopReplicaPalette.secondary)
                Text(bluetooth.freshHeartRateBPM.map { "\($0) BPM" } ?? "Waiting for wearable data")
                    .font(WoopTypography.emphasis(13)).monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
            }
            Spacer()
            Circle().fill(bluetooth.freshHeartRateBPM == nil ? WoopReplicaPalette.muted : WoopReplicaPalette.recoveryHigh).frame(width: 7, height: 7)
        }.padding(14).background(WoopReplicaPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 15))
    }

    private var whoopImportEntry: some View {
        Button { showingWHOOPImport = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WoopReplicaPalette.sleep)
                    .frame(width: 36, height: 36).background(WoopReplicaPalette.surface, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("IMPORT WHOOP DATA").font(WoopTypography.label(9)).tracking(0.8)
                        .foregroundStyle(WoopReplicaPalette.primary)
                    Text(whoopImport.nights.isEmpty ? "Choose your WHOOP export ZIP" : whoopImport.status)
                        .font(WoopTypography.body(10)).foregroundStyle(WoopReplicaPalette.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WoopReplicaPalette.muted)
            }
            .padding(12).background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var scoreRings: some View {
        HStack(spacing: 8) {
            ring("RECOVERY", value: insights.recoveryScore, tint: recoveryTint) { showingRecovery = true }
            ring("SLEEP", value: health.sleepHours.map { Int(($0 / max(1, insights.sleepNeedHours) * 100).rounded()) }, tint: WoopReplicaPalette.sleep) { showingSleep = true }
            Button { showingLoad = true } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(WoopReplicaPalette.homeTrack, lineWidth: 6)
                        VStack(spacing: 2) {
                            Text(insights.cardioLoadPoints.map { String(format: "%.1f", $0) } ?? "—")
                                .font(WoopTypography.metric(19)).monospacedDigit()
                                .foregroundStyle(WoopReplicaPalette.primary)
                            Text("PTS").font(WoopTypography.label(7)).foregroundStyle(WoopReplicaPalette.secondary)
                        }
                    }.frame(width: 68, height: 68)
                    Text("LOAD").font(WoopTypography.label(8)).tracking(0.6).foregroundStyle(WoopReplicaPalette.secondary)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
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
                    Text(value.map(String.init) ?? "—").font(WoopTypography.metric(22))
                        .monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
                }.frame(width: 68, height: 68)
                Text(title).font(WoopTypography.label(8)).tracking(0.6).foregroundStyle(WoopReplicaPalette.secondary)
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
            HStack(spacing: 9) {
                monitor("STEPS · APPLE HEALTH", value: health.stepsToday.map { $0.formatted() } ?? "—", unit: "steps", symbol: "figure.walk")
                Spacer(minLength: 0)
            }
        }
    }

    private func monitor(_ title: String, value: String, unit: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(WoopTypography.label(8)).tracking(0.3)
                .foregroundStyle(WoopReplicaPalette.secondary).lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(WoopTypography.metric(24)).monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
                Text(unit).font(WoopTypography.body(9)).foregroundStyle(WoopReplicaPalette.secondary)
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
            Text(title).font(WoopTypography.label(7)).tracking(0.4).foregroundStyle(WoopReplicaPalette.secondary)
            Text(value).font(WoopTypography.metric(16)).monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
        }.frame(maxWidth: .infinity)
    }

    private var activities: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("ACTIVITIES", trailing: "LATEST RUN")
            if let date = health.latestRunDate {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: "figure.run").font(WoopTypography.body(17)).foregroundStyle(WoopReplicaPalette.sleep)
                            .frame(width: 36, height: 36).background(WoopReplicaPalette.surfaceInset, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Running").font(WoopTypography.emphasis(12)).foregroundStyle(WoopReplicaPalette.primary)
                            Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(WoopTypography.body(9)).foregroundStyle(WoopReplicaPalette.secondary)
                        }
                        Spacer()
                        Text(health.latestRunDistanceKm.map { String(format: "%.2f km", $0) } ?? "Distance —")
                            .font(WoopTypography.emphasis(11)).foregroundStyle(WoopReplicaPalette.primary)
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
            importedSleepActivity
        }
    }

    private var importedSleepActivity: some View {
        Group {
            if let night = whoopImport.latestNight {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: "moon.zzz.fill").font(WoopTypography.body(16))
                            .foregroundStyle(WoopReplicaPalette.sleep)
                            .frame(width: 36, height: 36).background(WoopReplicaPalette.surfaceInset, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sleep · WHOOP Export").font(WoopTypography.emphasis(12)).foregroundStyle(WoopReplicaPalette.primary)
                            Text(night.wakeOnset?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? "Imported sleep")
                                .font(WoopTypography.body(9)).foregroundStyle(WoopReplicaPalette.secondary)
                        }
                        Spacer()
                        Text(night.asleepMinutes.map { String(format: "%.1f h", $0 / 60) } ?? "—")
                            .font(WoopTypography.emphasis(13)).foregroundStyle(WoopReplicaPalette.sleep)
                    }
                    HStack(spacing: 14) {
                        activityMetric("BEDTIME", night.sleepOnset?.formatted(date: .omitted, time: .shortened) ?? "—")
                        activityMetric("WAKE", night.wakeOnset?.formatted(date: .omitted, time: .shortened) ?? "—")
                        activityMetric("DEEP", night.deepMinutes.map { "\(Int($0.rounded())) min" } ?? "—")
                        activityMetric("REM", night.remMinutes.map { "\(Int($0.rounded())) min" } ?? "—")
                    }.padding(.leading, 45)
                }
                .padding(13).background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
            }
        }
    }

    private func activityMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WoopTypography.label(7)).foregroundStyle(WoopReplicaPalette.muted)
            Text(value).font(WoopTypography.metricBold(10)).foregroundStyle(WoopReplicaPalette.secondary)
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("7-DAY HEALTH TRENDS")
            HStack(spacing: 9) {
                trendMini("HRV", values: insights.trendHistory.map { $0.hrvMilliseconds }, tint: WoopReplicaPalette.sleep, unit: "ms")
                trendMini("SLEEP", values: insights.trendHistory.map { $0.sleepHours }, tint: WoopReplicaPalette.sleep, unit: "h")
            }
        }
    }

    private func trendMini(_ title: String, values: [Double?], tint: Color, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(WoopTypography.label(8)).tracking(0.7)
                .foregroundStyle(WoopReplicaPalette.secondary)
            WoopHealthTrendChart(values: Array(values.suffix(7)), tint: tint, unit: unit, height: 54, rangeLabel: "7D")
        }
        .frame(maxWidth: .infinity)
    }

    private func section(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title).font(WoopTypography.label(9)).tracking(1).foregroundStyle(WoopReplicaPalette.secondary)
            Spacer()
            if let trailing { Text(trailing).font(WoopTypography.label(8)).foregroundStyle(WoopReplicaPalette.muted) }
        }
    }

    private func emptyCard(_ message: String) -> some View {
        Text(message).font(WoopTypography.body(11)).lineSpacing(3).foregroundStyle(WoopReplicaPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading).padding(13)
            .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 15))
    }
}
