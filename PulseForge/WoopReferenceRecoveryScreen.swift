import SwiftUI
import HealthKit

/// First native SwiftUI port of the supplied Woop recovery screen.
/// Values are sourced from PulseForge HealthKit/calculation stores; no sample scores are fabricated.
struct WoopReferenceRecoveryScreen: View {
    @EnvironmentObject private var health: HealthDataStore
    @EnvironmentObject private var insights: TrainingInsightsStore
    @State private var selectedRange = "WEEK"

    private var score: Int? { insights.recoveryScore }
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
                trendSection
                explanation
                Color.clear.frame(height: 112)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .background(WoopReplicaPalette.canvas.ignoresSafeArea())
        .refreshable {
            health.refresh()
            insights.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("RECOVERY")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(WoopReplicaPalette.secondary)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(WoopTypography.emphasis(22))
                    .foregroundStyle(WoopReplicaPalette.primary)
            }
            Spacer()
            Image(systemName: "calendar")
                .font(.system(size: 17, weight: .medium))
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
                    Text(score == nil ? "WAITING FOR DATA" : insights.recoveryStatus.uppercased())
                        .font(WoopTypography.label(9))
                        .tracking(1.1)
                        .foregroundStyle(scoreTint)
                }
            }
            .frame(width: 214, height: 214)
            Text(score == nil
                 ? "Recovery will appear when enough valid health measurements are available."
                 : "Your recovery estimate combines your available HRV and resting heart-rate baseline.")
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
                metricTile(title: "HRV", value: health.hrvMilliseconds.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", symbol: "waveform.path.ecg")
                metricTile(title: "RESTING HEART RATE", value: health.restingHeartRate.map(String.init) ?? "—", unit: "bpm", symbol: "heart")
            }
            HStack(spacing: 10) {
                metricTile(title: "SLEEP", value: health.sleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours", symbol: "moon.zzz")
                metricTile(title: "SLEEP NEED", value: String(format: "%.1f", insights.sleepNeedHours), unit: "hours · estimate", symbol: "bed.double")
            }
        }
    }

    private func metricTile(title: String, value: String, unit: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(WoopTypography.label(9)).tracking(0.7)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(WoopReplicaPalette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(WoopTypography.metric(27)).monospacedDigit()
                    .foregroundStyle(WoopReplicaPalette.primary)
                Text(unit).font(.system(size: 10, weight: .medium))
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
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(WoopReplicaPalette.muted)
                Text("Your trend will appear as daily measurements are collected.")
                    .font(WoopTypography.body(11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(WoopReplicaPalette.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 116)
            .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
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
            Text("Recovery is an on-device PulseForge estimate, not WHOOP's proprietary score. It is displayed only when the underlying measurements support a calculation.")
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

enum WoopReplicaPalette {
    static let canvas = Color(red: 16/255, green: 20/255, blue: 24/255)
    static let surface = Color(red: 41/255, green: 54/255, blue: 62/255)
    static let surfaceRaised = Color(red: 52/255, green: 67/255, blue: 75/255)
    static let surfaceInset = Color(red: 27/255, green: 39/255, blue: 46/255)
    static let primary = Color.white
    static let secondary = Color(red: 176/255, green: 181/255, blue: 186/255)
    static let muted = Color(red: 127/255, green: 135/255, blue: 141/255)
    static let hairline = Color(red: 43/255, green: 48/255, blue: 52/255)
    static let homeTrack = Color(red: 43/255, green: 48/255, blue: 52/255)
    static let recoveryLow = Color(red: 1, green: 0, blue: 38/255)
    static let recoveryMid = Color(red: 1, green: 222/255, blue: 0)
    static let recoveryHigh = Color(red: 0, green: 232/255, blue: 45/255)
    static let sleep = Color(red: 91/255, green: 166/255, blue: 224/255)
    static let deepSleep = Color(red: 75/255, green: 91/255, blue: 190/255)
    static let remSleep = Color(red: 132/255, green: 105/255, blue: 220/255)
    static let coreSleep = Color(red: 52/255, green: 153/255, blue: 221/255)
}
