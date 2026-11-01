import SwiftUI

/// Color tokens transcribed from the decompiled original WHOOP APK:
/// com.woop.ui.theme.WoopColors. Values are exact 8-bit sRGB channel values.
enum WoopReplicaPalette {
    static let canvas = Color(red: 16/255, green: 20/255, blue: 24/255)
    static let surface = Color(red: 41/255, green: 54/255, blue: 62/255)       // 0xFF29363E
    static let surfaceRaised = Color(red: 52/255, green: 67/255, blue: 75/255) // 0xFF34434B
    static let surfaceInset = Color(red: 48/255, green: 62/255, blue: 70/255)  // 0xFF303E46
    static let primary = Color.white
    static let secondary = Color(red: 176/255, green: 181/255, blue: 186/255) // 0xFFB0B5BA
    static let muted = Color(red: 127/255, green: 135/255, blue: 141/255)     // 0xFF7F878D
    static let hairline = Color(red: 43/255, green: 48/255, blue: 52/255)     // 0xFF2B3034
    static let homeTrack = Color(red: 51/255, green: 65/255, blue: 73/255)    // 0xFF334149
    static let sleep = Color(red: 109/255, green: 151/255, blue: 177/255)     // 0xFF6D97B1
    static let recoveryLow = Color(red: 255/255, green: 0/255, blue: 38/255)  // 0xFFFF0026
    static let recoveryMid = Color(red: 255/255, green: 222/255, blue: 0/255) // 0xFFFFDE00
    static let recoveryHigh = Color(red: 0/255, green: 232/255, blue: 45/255)// 0xFF00E82D
    static let deepSleep = Color(red: 82/255, green: 76/255, blue: 173/255)
    static let remSleep = Color(red: 105/255, green: 163/255, blue: 242/255)
    static let coreSleep = Color(red: 109/255, green: 151/255, blue: 177/255)
}
