import SwiftUI

/// Sleep tab port using measured HealthKit sleep and transparent PulseForge estimates.
struct WoopReferenceSleepScreen: View {
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager
    @EnvironmentObject private var whoopImport: WHOOPImportStore

    private var latestNight: WHOOPImportedNight? { whoopImport.latestNight }
    private var historyNights: [WHOOPImportedNight] { whoopImport.nights }
    private var sleepHours: Double? { latestNight?.asleepMinutes.map { $0 / 60 } }
    private var sleepNeedHours: Double? { latestNight?.sleepNeedMinutes.map { $0 / 60 } }
    private var sleepDebtHours: Double? { latestNight?.sleepDebtMinutes.map { $0 / 60 } }
    private var totalSleep: String { sleepHours.map { String(format: "%.1f", $0) } ?? "—" }
    private var deepMinutes: Double? { latestNight?.deepMinutes }
    private var remMinutes: Double? { latestNight?.remMinutes }
    private var lightMinutes: Double? { latestNight?.lightMinutes }
    private var awakeMinutes: Double? { latestNight?.awakeMinutes }

    private var typicalSleepHours: Double? {
        let values = historyNights.compactMap { $0.asleepMinutes }.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2] / 60
    }

    private var sleepStageTotal: Double {
        [deepMinutes, remMinutes, lightMinutes, awakeMinutes]
            .compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
    }

    private var hasSleepStages: Bool {
        [deepMinutes, remMinutes, lightMinutes, awakeMinutes].contains { ($0 ?? 0) > 0 }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                sleepHero
                whoopBandSleepData
                sleepNeed
                stages
                consistency
                explanation
                Color.clear.frame(height: 108)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .background(WoopReplicaPalette.canvas.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("SLEEP").font(WoopTypography.label(11))
                    .tracking(2.2).foregroundStyle(WoopReplicaPalette.secondary)
                Text(latestNight?.wakeOnset?.formatted(.dateTime.month(.abbreviated).day()) ?? "WHOOP history not imported").font(WoopTypography.emphasis(19))
                    .foregroundStyle(WoopReplicaPalette.primary)
            }
            Spacer()
            Image(systemName: "moon.stars")
                .font(WoopTypography.body(17))
                .foregroundStyle(WoopReplicaPalette.secondary)
                .frame(width: 42, height: 42)
                .background(WoopReplicaPalette.surfaceRaised, in: Circle())
        }
    }

    private var sleepHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TIME ASLEEP").font(WoopTypography.label(9)).tracking(1.2)
                        .foregroundStyle(WoopReplicaPalette.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(totalSleep).font(WoopTypography.metric(48))
                            .monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
                        Text("HRS").font(WoopTypography.label(10))
                            .foregroundStyle(WoopReplicaPalette.secondary)
                    }
                }
                Spacer()
                ZStack {
                    Circle().stroke(WoopReplicaPalette.homeTrack, lineWidth: 10)
                    Circle().trim(from: 0, to: min(1, max(0, (sleepHours ?? 0) / max(1, sleepNeedHours ?? 8))))
                        .stroke(WoopReplicaPalette.sleep, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.7), value: sleepHours)
                    Image(systemName: "moon.zzz.fill").font(WoopTypography.body(22))
                        .foregroundStyle(WoopReplicaPalette.sleep)
                }
                .frame(width: 92, height: 92)
            }
            Rectangle().fill(WoopReplicaPalette.hairline).frame(height: 1)
            HStack {
                metric("SLEEP NEED", value: sleepNeedHours.map { String(format: "%.1f h", $0) } ?? "—")
                Spacer()
                metric("SLEEP DEBT", value: sleepDebtHours.map { String(format: "%.1f h", $0) } ?? "—")
                Spacer()
                metric("TYPICAL SLEEP", value: typicalSleepHours.map { String(format: "%.1f h", $0) } ?? "—")
            }
        }
        .padding(20)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(WoopTypography.label(8)).tracking(0.5)
                .foregroundStyle(WoopReplicaPalette.secondary)
            Text(value).font(WoopTypography.metricBold(17))
                .monospacedDigit().foregroundStyle(WoopReplicaPalette.primary)
        }
    }

    private var whoopBandSleepData: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                sectionTitle("WHOOP BAND DATA")
                Spacer()
                Text("GEN5 · RAW")
                    .font(WoopTypography.label(8))
                    .tracking(0.8)
                    .foregroundStyle(WoopReplicaPalette.muted)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(bluetooth.whoopHistoricalSleepStateSampleCount)")
                    .font(WoopTypography.metric(27))
                    .monospacedDigit()
                    .foregroundStyle(WoopReplicaPalette.primary)
                Text("sleep-state samples received")
                    .font(WoopTypography.body(10))
                    .foregroundStyle(WoopReplicaPalette.secondary)
                Spacer()
                if let raw = bluetooth.whoopHistoricalLatestSleepStateRaw {
                    Text(String(format: "0x%02X", raw))
                        .font(WoopTypography.metricBold(15))
                        .monospacedDigit()
                        .foregroundStyle(WoopReplicaPalette.sleep)
                }
            }
            Text(bluetooth.whoopHistoricalRRSource)
                .font(WoopTypography.body(10))
                .foregroundStyle(WoopReplicaPalette.secondary)
            Text("Raw sleep-state bytes are being retained for protocol analysis. Deep, REM and Core labels stay disabled until their Gen5 state mapping is verified against real WHOOP sleep records.")
                .font(WoopTypography.body(9))
                .lineSpacing(2)
                .foregroundStyle(WoopReplicaPalette.muted)
        }
        .padding(15)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private var sleepNeed: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("SLEEP NEED")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Estimated need").font(WoopTypography.body(13))
                        .foregroundStyle(WoopReplicaPalette.primary)
                    Spacer()
                    Text(sleepNeedHours.map { String(format: "%.1f hours", $0) } ?? "—")
                        .font(WoopTypography.metricBold(17))
                        .foregroundStyle(WoopReplicaPalette.primary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(WoopReplicaPalette.homeTrack)
                        Capsule().fill(WoopReplicaPalette.sleep)
                            .frame(width: proxy.size.width * min(1, max(0, (sleepHours ?? 0) / max(1, sleepNeedHours ?? 8))))
                    }
                }.frame(height: 9)
                Text(sleepHours == nil
                     ? "Import a WHOOP export to populate historical sleep duration."
                     : "Measured sleep compared with your current estimated sleep need.")
                    .font(WoopTypography.body(10)).foregroundStyle(WoopReplicaPalette.secondary)
            }
            .padding(16)
            .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
        }
    }

    private var stages: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("SLEEP STAGES")
            if hasSleepStages {
                VStack(spacing: 0) {
                    stageRow("Deep", value: deepMinutes, color: WoopReplicaPalette.deepSleep, symbol: "moon.fill")
                    Divider().overlay(WoopReplicaPalette.hairline)
                    stageRow("REM", value: remMinutes, color: WoopReplicaPalette.remSleep, symbol: "brain.head.profile")
                    Divider().overlay(WoopReplicaPalette.hairline)
                    stageRow("Core", value: lightMinutes, color: WoopReplicaPalette.coreSleep, symbol: "circle.fill")
                    Divider().overlay(WoopReplicaPalette.hairline)
                    stageRow("Awake", value: awakeMinutes, color: WoopReplicaPalette.muted, symbol: "sun.max")
                }
                .padding(.horizontal, 15)
                .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
            } else {
                Text("WHOOP sleep-stage history will appear after importing your export.")
                    .font(WoopTypography.body(11))
                    .foregroundStyle(WoopReplicaPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
            }
        }
    }

    private func stageRow(_ title: String, value: Double?, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(WoopTypography.body(12)).foregroundStyle(color).frame(width: 18)
                Text(title).font(WoopTypography.body(12)).foregroundStyle(WoopReplicaPalette.primary)
                Spacer()
                Text(value.map { String(format: "%.0f min", $0) } ?? "—")
                    .font(WoopTypography.metricBold(12)).monospacedDigit()
                    .foregroundStyle(WoopReplicaPalette.secondary)
            }
            GeometryReader { proxy in
                Capsule().fill(WoopReplicaPalette.homeTrack)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: proxy.size.width * min(1, max(0, (value ?? 0) / max(1, sleepStageTotal))))
                    }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 11)
    }

    private var consistency: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("SLEEP HISTORY")
            WoopHealthTrendChart(
                values: historyNights.map { $0.asleepMinutes.map { $0 / 60 } },
                tint: WoopReplicaPalette.sleep,
                unit: "hours",
                height: 112
            )
            if !historyNights.contains(where: { $0.asleepMinutes != nil }) {
                Text("Your imported WHOOP sleep history appears here by night.")
                    .font(WoopTypography.body(10))
                    .foregroundStyle(WoopReplicaPalette.secondary)
            }
        }
    }

    private var explanation: some View {
        Text("Sleep duration, stages, sleep need and sleep debt are read from your imported WHOOP export. Values remain unavailable when the export has no measurement.")
            .font(WoopTypography.body(10)).lineSpacing(3)
            .foregroundStyle(WoopReplicaPalette.secondary)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WoopReplicaPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 15))
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value).font(WoopTypography.label(10)).tracking(1.3)
            .foregroundStyle(WoopReplicaPalette.secondary)
    }
}
