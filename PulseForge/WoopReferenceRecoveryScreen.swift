import SwiftUI

/// First native SwiftUI port of the supplied Woop recovery screen.
/// Values are sourced from PulseForge HealthKit/calculation stores; no sample scores are fabricated.
struct WoopReferenceRecoveryScreen: View {
    @EnvironmentObject private var bluetooth: WhoopBluetoothManager
    @EnvironmentObject private var whoopImport: WHOOPImportStore
    @State private var selectedRange = "WEEK"

    private var importedNight: WHOOPImportedNight? { whoopImport.latestNight }
    private var score: Int? { importedNight?.recoveryScore.map { Int($0.rounded()) } }
    private var importedSleepHours: Double? { importedNight?.asleepMinutes.map { $0 / 60 } }
    private var importedSleepNeedHours: Double? { importedNight?.sleepNeedMinutes.map { $0 / 60 } }
    private var importedSleepDebtHours: Double? { importedNight?.sleepDebtMinutes.map { $0 / 60 } }
    private var importedHRV: Double? { importedNight?.hrvMilliseconds }
    private var importedRHR: Double? { importedNight?.restingHeartRate }
    private var historyNights: [WHOOPImportedNight] { whoopImport.nights }
    private var scoreTint: Color {
        guard let score else { return WoopReplicaPalette.muted }
        if score >= 67 { return WoopReplicaPalette.recoveryHigh }
        if score >= 34 { return WoopReplicaPalette.recoveryMid }
        return WoopReplicaPalette.recoveryLow
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                hero
                metrics
                whoopBandMetrics
                trendSection
                explanation
                Color.clear.frame(height: 112)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .background(WoopReplicaPalette.canvas.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("RECOVERY")
                    .font(WoopTypography.label(11))
                    .tracking(2.2)
                    .foregroundStyle(WoopReplicaPalette.secondary)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(WoopTypography.emphasis(22))
                    .foregroundStyle(WoopReplicaPalette.primary)
            }
            Spacer()
            Image(systemName: "calendar")
                .font(WoopTypography.body(17))
                .foregroundStyle(WoopReplicaPalette.secondary)
                .frame(width: 42, height: 42)
                .background(WoopReplicaPalette.surfaceRaised, in: Circle())
        }
    }

    private var hero: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle().stroke(WoopReplicaPalette.homeTrack, lineWidth: 13)
                if let score {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(100, max(0, score))) / 100)
                        .stroke(scoreTint, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.7), value: score)
                }
                VStack(spacing: 4) {
                    Text("RECOVERY")
                        .font(WoopTypography.label(10))
                        .tracking(1.8)
                        .foregroundStyle(WoopReplicaPalette.secondary)
                    Text(score.map(String.init) ?? "—")
                        .font(WoopTypography.metric(54))
                        .monospacedDigit()
                        .foregroundStyle(WoopReplicaPalette.primary)
                    Text(score == nil ? "IMPORT WHOOP HISTORY" : "WHOOP EXPORT · HISTORICAL")
                        .font(WoopTypography.label(9))
                        .tracking(1.1)
                        .foregroundStyle(scoreTint)
                }
            }
            .frame(width: 214, height: 214)
            Text(score == nil
                 ? "Import your WHOOP export to show its historical Recovery scores."
                 : "Showing the Recovery score recorded by WHOOP for the latest imported cycle.")
                .font(WoopTypography.body(12))
                .multilineTextAlignment(.center)
                .foregroundStyle(WoopReplicaPalette.secondary)
                .frame(maxWidth: 290)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("KEY CONTRIBUTORS", trailing: "TODAY")
            HStack(spacing: 10) {
                metricTile(title: "HRV", value: importedHRV.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", symbol: "waveform.path.ecg")
                metricTile(title: "RESTING HEART RATE", value: importedRHR.map(String.init) ?? "—", unit: "bpm", symbol: "heart")
            }
            HStack(spacing: 10) {
                metricTile(title: "SLEEP", value: importedSleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours", symbol: "moon.zzz")
                metricTile(title: "SLEEP NEED", value: importedSleepNeedHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours · estimate", symbol: "bed.double")
            }
            HStack(spacing: 10) {
                metricTile(title: "SLEEP DEBT", value: importedSleepDebtHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours · 7-night estimate", symbol: "moon.zzz")
                metricTile(title: "TYPICAL SLEEP", value: (historyNights.compactMap { $0.asleepMinutes }.sorted().dropFirst(max(0, historyNights.compactMap { $0.asleepMinutes }.count / 2)).first).map { String(format: "%.1f", $0 / 60) } ?? "—", unit: "hours · 28-day median", symbol: "calendar")
            }
        }
    }

    private var whoopBandMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("WHOOP BAND · HISTORICAL", trailing: "GEN5")
            HStack(spacing: 10) {
                metricTile(
                    title: "BAND RMSSD",
                    value: bluetooth.whoopHistoricalRecoveryMetrics?.overnightRMSSDMilliseconds.map { String(format: "%.1f", $0) } ?? "—",
                    unit: "ms · estimate",
                    symbol: "waveform.path.ecg"
                )
                metricTile(
                    title: "BAND RHR",
                    value: bluetooth.whoopHistoricalRecoveryMetrics?.restingHeartRateBPM.map { String(format: "%.1f", $0) } ?? "—",
                    unit: "bpm · estimate",
                    symbol: "heart"
                )
            }
            Text(bluetooth.whoopHistoricalRecoveryMetricsStatus)
                .font(WoopTypography.body(10))
                .foregroundStyle(WoopReplicaPalette.secondary)
            Text("Band values are independently calculated from archived Gen5 RR/HR samples. They are not WHOOP's official nightly HRV, RHR or Recovery score.")
                .font(WoopTypography.body(9))
                .lineSpacing(2)
                .foregroundStyle(WoopReplicaPalette.muted)
        }
        .padding(15)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private func metricTile(title: String, value: String, unit: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(WoopTypography.body(12))
                Text(title).font(WoopTypography.label(9)).tracking(0.7)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(WoopReplicaPalette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(WoopTypography.metric(27)).monospacedDigit()
                    .foregroundStyle(WoopReplicaPalette.primary)
                Text(unit).font(WoopTypography.body(10))
                    .foregroundStyle(WoopReplicaPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("RECOVERY TREND")
                Spacer()
                HStack(spacing: 0) {
                    rangeButton("WEEK")
                    rangeButton("MONTH")
                }
                .padding(3)
                .background(WoopReplicaPalette.surfaceInset, in: Capsule())
            }
            VStack(spacing: 12) {
                WoopHealthTrendChart(
                    values: Array(historyNights.suffix(selectedRange == "WEEK" ? 7 : 30).map { $0.hrvMilliseconds }),
                    tint: WoopReplicaPalette.sleep,
                    unit: "ms",
                    height: 92,
                    rangeLabel: selectedRange == "WEEK" ? "7 DAYS AGO" : "30 DAYS AGO"
                )
                WoopHealthTrendChart(
                    values: Array(historyNights.suffix(selectedRange == "WEEK" ? 7 : 30).map { $0.restingHeartRate }),
                    tint: WoopReplicaPalette.recoveryHigh,
                    unit: "bpm",
                    height: 82,
                    rangeLabel: selectedRange == "WEEK" ? "7 DAYS AGO" : "30 DAYS AGO"
                )
                if !historyNights.contains(where: { $0.hrvMilliseconds != nil || $0.restingHeartRate != nil }) {
                    Text("Import WHOOP history to populate date-wise HRV and RHR trends.")
                        .font(WoopTypography.body(10))
                        .foregroundStyle(WoopReplicaPalette.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func rangeButton(_ title: String) -> some View {
        Button { selectedRange = title } label: {
            Text(title)
                .font(WoopTypography.label(8))
                .tracking(0.6)
                .foregroundStyle(selectedRange == title ? WoopReplicaPalette.primary : WoopReplicaPalette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    if selectedRange == title {
                        Capsule().fill(WoopReplicaPalette.surfaceRaised)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("ABOUT RECOVERY")
            Text("Recovery, HRV, RHR and sleep contributors shown here are imported from your WHOOP export. No Apple Health fallback is used for these values.")
                .font(WoopTypography.body(11))
                .lineSpacing(3)
                .foregroundStyle(WoopReplicaPalette.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
    }

    private func sectionTitle(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title).font(WoopTypography.label(10)).tracking(1.1)
                .foregroundStyle(WoopReplicaPalette.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(WoopTypography.label(9)).tracking(0.8)
                    .foregroundStyle(WoopReplicaPalette.muted)
            }
        }
    }
}
