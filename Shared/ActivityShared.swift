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
        var bpm: Double
        /// downsampled overview waveform: amplitude 0-255 per bar
        var amps: [UInt8]
        /// hue 0-255 (mapped to 0-360 degrees) per bar
        var hues: [UInt8]
    }

    var setID: String
    var title: String
    var duration: Double
}

/// LiveActivityIntents execute in the app's process; these closures are wired
/// to the real player at app launch. In the widget process they stay no-ops
/// (they're never invoked there).
enum PlayerIntentBridge {
    nonisolated(unsafe) static var toggle: @Sendable () async -> Void = {}
    nonisolated(unsafe) static var skip: @Sendable (Double) async -> Void = { _ in }
}

struct TogglePlaybackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Play or Pause" }

    func perform() async throws -> some IntentResult {
        await PlayerIntentBridge.toggle()
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
