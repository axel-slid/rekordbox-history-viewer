import ActivityKit
import AppIntents
import Foundation

/// Live Activity payload shared between the app and the widget extension.
struct SetActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// wall-clock date at which the set's position was 0:00 - lets the
        /// widget animate elapsed time and progress without updates
        var startDate: Date
        var isPlaying: Bool
        /// position in seconds at the moment of the last update
        var position: Double
        /// in content state (not attributes) so renames show up live
        var title: String
        var bpm: Double
        /// downsampled overview waveform: amplitude 0-255 per bar
        var amps: [UInt8]
        /// hue 0-255 (mapped to 0-360 degrees) per bar
        var hues: [UInt8]
    }

    var setID: String
    var duration: Double
}

/// LiveActivityIntents execute in the app's process; these closures are wired
/// to the real player at app launch. In the widget process they stay no-ops
/// (they're never invoked there).
enum PlayerIntentBridge {
    nonisolated(unsafe) static var toggle: @Sendable () async -> Void = {}
    nonisolated(unsafe) static var skip: @Sendable (Double) async -> Void = { _ in }
    nonisolated(unsafe) static var seekFraction: @Sendable (Double) async -> Void = { _ in }
}

struct TogglePlaybackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Play or Pause" }

    func perform() async throws -> some IntentResult {
        await PlayerIntentBridge.toggle()
        return .result()
    }
}

struct SeekToFractionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Jump to Position" }

    @Parameter(title: "Fraction")
    var fraction: Double

    init() {}
    init(fraction: Double) {
        self.fraction = fraction
    }

    func perform() async throws -> some IntentResult {
        await PlayerIntentBridge.seekFraction(min(1, max(0, fraction)))
        return .result()
    }
}

struct SkipForwardIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Skip Forward 15 Seconds" }

    func perform() async throws -> some IntentResult {
        await PlayerIntentBridge.skip(15)
        return .result()
    }
}

struct SkipBackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Skip Back 15 Seconds" }

    func perform() async throws -> some IntentResult {
        await PlayerIntentBridge.skip(-15)
        return .result()
    }
}
