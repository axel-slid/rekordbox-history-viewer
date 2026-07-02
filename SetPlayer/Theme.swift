import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}

/// rekordbox-style colorway: near-black chrome, signature blue accent,
/// RGB waveform (low = blue, mid = amber, high = white).
enum Theme {
    static let background = Color(hex: 0x121419)
    static let panel = Color(hex: 0x1C1F26)
    static let panelBorder = Color(hex: 0x2A2E38)
    static let accent = Color(hex: 0x00AEEF)
    static let textDim = Color(hex: 0x8A919E)
    static let playhead = Color(hex: 0xFF3B30)

    static let waveLow = SIMD3<Float>(0.10, 0.36, 1.00)   // deep blue
    static let waveMid = SIMD3<Float>(1.00, 0.62, 0.13)   // amber
    static let waveHigh = SIMD3<Float>(1.00, 1.00, 1.00)  // white

    /// hot-cue palette for annotations
    static let cueColors: [Color] = [
        Color(hex: 0x2FD058), Color(hex: 0xFF8A1E), Color(hex: 0xF857C1),
        Color(hex: 0x19C8DE), Color(hex: 0xB67BFF), Color(hex: 0xFFD21E),
        Color(hex: 0xFF4D4D), Color(hex: 0x4D7BFF)
    ]

    static func cueColor(_ index: Int) -> Color {
        cueColors[index % cueColors.count]
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let secs = Int(t.rounded())
    let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

func formatSize(_ bytes: Int64) -> String {
    let b = Double(bytes)
    if b >= 1e9 { return String(format: "%.2f GB", b / 1e9) }
    if b >= 1e6 { return String(format: "%.1f MB", b / 1e6) }
    return String(format: "%.0f KB", b / 1e3)
}
