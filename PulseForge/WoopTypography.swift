import SwiftUI

/// Typeface registry for the original WHOOP Android font binaries.
/// The matching font files are extracted byte-for-byte from Whoop.zip by CI
/// into PulseForge/Resources/Fonts and registered through UIAppFonts.
enum WoopTypography {
    static func proximaRegular(_ size: CGFloat) -> Font {
        .custom("ProximaNova-Regular", size: size)
    }

    static func proximaSemibold(_ size: CGFloat) -> Font {
        .custom("ProximaNova-Semibold", size: size)
    }

    static func proximaBold(_ size: CGFloat) -> Font {
        .custom("ProximaNova-Bold", size: size)
    }

    static func dDinRegular(_ size: CGFloat) -> Font {
        .custom("D-DIN", size: size)
    }

    static func dDinBold(_ size: CGFloat) -> Font {
        .custom("D-DIN-Bold", size: size)
    }

    static func dinProMedium(_ size: CGFloat) -> Font {
        .custom("DINPro-Medium", size: size)
    }

    static func dinProBold(_ size: CGFloat) -> Font {
        .custom("DINPro-Bold", size: size)
    }

    static func inter(_ size: CGFloat) -> Font {
        .custom("Inter-Regular", size: size)
    }
}
