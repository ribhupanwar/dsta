import SwiftUI

/// Layout tokens decoded from com.woop.ui.theme.WoopSpacing, WoopRadii and WoopMetrics.
enum WoopReplicaMetrics {
    enum Spacing {
        static let hairline: CGFloat = 1
        static let xTiny: CGFloat = 2
        static let tiny: CGFloat = 3
        static let xSmall: CGFloat = 4
        static let smallGap: CGFloat = 5
        static let snug: CGFloat = 6
        static let small: CGFloat = 8
        static let smallInset: CGFloat = 9
        static let controlInset: CGFloat = 10
        static let compact: CGFloat = 12
        static let compactGap: CGFloat = 14
        static let medium: CGFloat = 16
        static let mediumLarge: CGFloat = 18
        static let card: CGFloat = 20
        static let iconInset: CGFloat = 22
        static let section: CGFloat = 24
        static let large: CGFloat = 32
        static let screenGutter: CGFloat = 20
        static let sectionGap: CGFloat = 28
        static let homeGutter: CGFloat = 16
        static let homeHeroGap: CGFloat = 44
    }
    enum Radius {
        static let small: CGFloat = 8
        static let control: CGFloat = 12
        static let card: CGFloat = 18
        static let sheet: CGFloat = 28
        static let pill: CGFloat = 100
    }
    enum Size {
        static let floatingNavigationClearance: CGFloat = 120
        static let sleepHeroRing: CGFloat = 264
        static let sleepHeroStroke: CGFloat = 16
        static let ringDiameter: CGFloat = 92
        static let ringStroke: CGFloat = 7
        static let activityLiveDial: CGFloat = 244
        static let activityLiveDialStroke: CGFloat = 16
        static let trendChartHeight: CGFloat = 164
        static let homeChartHeight: CGFloat = 228
        static let homeMonitorHeight: CGFloat = 94
    }
}
