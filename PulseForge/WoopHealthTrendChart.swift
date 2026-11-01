import SwiftUI

struct DailyHealthTrend: Identifiable {
    let date: Date
    let hrvMilliseconds: Double?
    let restingHeartRate: Double?
    let sleepHours: Double?
    var id: Date { date }
}

/// Compact WHOOP-inspired trend line. Missing dates remain gaps; no values are interpolated.
struct WoopHealthTrendChart: View {
    let values: [Double?]
    let tint: Color
    let unit: String
    var height: CGFloat = 126
    var rangeLabel: String = "30 DAYS AGO"

    private var finiteValues: [Double] {
        values.compactMap { value in
            guard let value, value.isFinite else { return nil }
            return value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let latest = finiteValues.last {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.0f", latest))
                        .font(WoopTypography.metric(23)).monospacedDigit()
                        .foregroundStyle(WoopReplicaPalette.primary)
                    Text(unit)
                        .font(WoopTypography.body(10))
                        .foregroundStyle(WoopReplicaPalette.secondary)
                    Spacer()
                    Text("\(finiteValues.count) DAYS WITH DATA")
                        .font(WoopTypography.label(8)).tracking(0.7)
                        .foregroundStyle(WoopReplicaPalette.muted)
                }
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let chartHeight = proxy.size.height
                Canvas { context, size in
                    guard finiteValues.count >= 2 else { return }
                    let minValue = finiteValues.min() ?? 0
                    let maxValue = finiteValues.max() ?? 1
                    let spread = max(1, maxValue - minValue)
                    let inset: CGFloat = 7
                    let points: [(Int, CGPoint)] = values.enumerated().compactMap { index, item in
                        guard let value = item, value.isFinite else { return nil }
                        let x = inset + CGFloat(index) / CGFloat(max(1, values.count - 1)) * (size.width - inset * 2)
                        let y = size.height - inset - CGFloat((value - minValue) / spread) * (size.height - inset * 2)
                        return (index, CGPoint(x: x, y: y))
                    }

                    for fraction in [0.25, 0.5, 0.75] {
                        var grid = Path()
                        let y = size.height * fraction
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(grid, with: .color(WoopReplicaPalette.hairline), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                    }

                    var segment = Path()
                    var previousIndex: Int?
                    for (index, point) in points {
                        if let previousIndex, index != previousIndex + 1 {
                            context.stroke(segment, with: .color(tint), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                            segment = Path()
                        }
                        if segment.isEmpty { segment.move(to: point) } else { segment.addLine(to: point) }
                        previousIndex = index
                    }
                    context.stroke(segment, with: .color(tint), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                    if let last = points.last?.1 {
                        let dot = CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)
                        context.fill(Path(ellipseIn: dot), with: .color(tint))
                    }
                }
                .frame(width: width, height: chartHeight)
            }
            .frame(height: height)

            HStack {
                Text(rangeLabel)
                Spacer()
                Text("15 DAYS")
                Spacer()
                Text("LATEST")
            }
            .font(WoopTypography.label(7)).tracking(0.5)
            .foregroundStyle(WoopReplicaPalette.muted)
        }
        .padding(15)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }
}
