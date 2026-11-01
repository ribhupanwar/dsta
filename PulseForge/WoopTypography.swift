import SwiftUI

/// PostScript names verified from the name tables inside the original APK-extracted font binaries.
/// Keep the source font files byte-for-byte; these names are not family-name guesses.
enum WoopTypography {
    static func proximaRegular(_ size: CGFloat) -> Font { .custom("ProximaNova-Regular", size: size) }
    static func proximaSemibold(_ size: CGFloat) -> Font { .custom("ProximaNova-Semibold", size: size) }
    static func proximaBold(_ size: CGFloat) -> Font { .custom("ProximaNova-Bold", size: size) }
    static func dDinRegular(_ size: CGFloat) -> Font { .custom("D-DIN", size: size) }
    static func dDinBold(_ size: CGFloat) -> Font { .custom("D-DIN-Bold", size: size) }
    static func dinProMedium(_ size: CGFloat) -> Font { .custom("DINPro-Medium", size: size) }
    static func dinProBold(_ size: CGFloat) -> Font { .custom("DINPro-Bold", size: size) }
    static func inter(_ size: CGFloat) -> Font { .custom("Inter-Regular", size: size) }

    /// WHOOP's standard UI text face, verified against the APK's Proxima Nova regular binary.
    static func body(_ size: CGFloat) -> Font { proximaRegular(size) }
    static func label(_ size: CGFloat) -> Font { dinProBold(size) }
    static func metric(_ size: CGFloat) -> Font { dDinRegular(size) }
    static func emphasis(_ size: CGFloat) -> Font { proximaSemibold(size) }
}
