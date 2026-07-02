import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let accent = Color(red: 0, green: 0.68, blue: 0.94)
private let dimText = Color(white: 0.62)

@main
struct SetPlayerWidgetBundle: WidgetBundle {
    var body: some Widget {
        SetActivityWidget()
    }
}

struct SetActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SetActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.06, green: 0.07, blue: 0.09))
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Button(intent: TogglePlaybackIntent()) {
                        Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsed(context)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 6) {
                        Text(context.state.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        if context.state.bpm > 0 {
                            Text(String(format: "%.0f", context.state.bpm))
                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                .foregroundStyle(accent)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        WaveStrip(context: context)
                            .frame(height: 44)
                        progress(context)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                CompactWaveStrip(context: context)
                    .frame(width: 44, height: 18)
            } compactTrailing: {
                elapsed(context)
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(accent)
                    .frame(maxWidth: 60)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(accent)
            }
        }
    }
}

/// Elapsed set time; ticks automatically while playing, static when paused.
private func elapsed(_ context: ActivityViewContext<SetActivityAttributes>) -> Text {
    if context.state.isPlaying {
        let end = context.state.startDate.addingTimeInterval(context.attributes.duration)
        return Text(
            timerInterval: context.state.startDate...end,
            countsDown: false,
            showsHours: true)
    }
    return Text(format(context.state.position))
}

@ViewBuilder
private func progress(_ context: ActivityViewContext<SetActivityAttributes>) -> some View {
    if context.state.isPlaying {
        let end = context.state.startDate.addingTimeInterval(context.attributes.duration)
        ProgressView(timerInterval: context.state.startDate...end, countsDown: false) {
        } currentValueLabel: {
        }
        .progressViewStyle(.linear)
        .tint(accent)
    } else {
        ProgressView(value: min(1, context.state.position / max(1, context.attributes.duration)))
            .progressViewStyle(.linear)
            .tint(dimText)
    }
}

private func format(_ t: Double) -> String {
    let secs = Int(t.rounded())
    let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

/// Position at render time. Live Activity views are static snapshots
/// (TimelineView does not tick in them), so the waveform playhead moves on
/// each periodic content update from the app; while playing we extrapolate
/// from startDate so every re-render lands in the right place.
private func livePosition(_ context: ActivityViewContext<SetActivityAttributes>) -> Double {
    let duration = max(1, context.attributes.duration)
    if context.state.isPlaying {
        return min(duration, max(0, Date().timeIntervalSince(context.state.startDate)))
    }
    return min(duration, max(0, context.state.position))
}

/// Mini rainbow waveform; played portion at full brightness.
struct WaveStrip: View {
    let context: ActivityViewContext<SetActivityAttributes>

    var body: some View {
        Canvas { ctx, size in
            let amps = context.state.amps
            guard !amps.isEmpty else { return }
            let hues = context.state.hues
            let playedFrac = min(1, livePosition(context) / max(1, context.attributes.duration))
            let midY = size.height / 2
            let n = amps.count
            let barSpace = size.width / CGFloat(n)

            for i in 0..<n {
                let x = CGFloat(i) * barSpace
                let amp = CGFloat(amps[i]) / 255
                let h = max(2, amp * size.height * 0.96)
                let hue = Double(i < hues.count ? hues[i] : 128) / 255
                let played = CGFloat(i) / CGFloat(n) <= CGFloat(playedFrac)
                let color = Color(hue: hue, saturation: 0.85, brightness: played ? 1.0 : 0.4)
                ctx.fill(
                    Path(roundedRect: CGRect(
                        x: x, y: midY - h / 2,
                        width: max(1.2, barSpace * 0.68), height: h), cornerRadius: 1),
                    with: .color(played ? color : color.opacity(0.45)))
            }

            let px = size.width * CGFloat(playedFrac)
            ctx.fill(
                Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)),
                with: .color(.white))
        }
    }
}

/// ~14-bar waveform for the compact Dynamic Island slot.
struct CompactWaveStrip: View {
    let context: ActivityViewContext<SetActivityAttributes>

    var body: some View {
        Canvas { ctx, size in
            let source = context.state.amps
            guard !source.isEmpty else { return }
            let hues = context.state.hues
            let playedFrac = min(1, livePosition(context) / max(1, context.attributes.duration))
            let n = 14
            let midY = size.height / 2
            let barSpace = size.width / CGFloat(n)

            for i in 0..<n {
                let start = i * source.count / n
                let end = max(start + 1, (i + 1) * source.count / n)
                let amp = CGFloat(source[start..<min(end, source.count)].max() ?? 0) / 255
                let hue = Double(hues[min(start, hues.count - 1)]) / 255
                let h = max(2, amp * size.height)
                let played = CGFloat(i) / CGFloat(n) <= CGFloat(playedFrac)
                let color = Color(hue: hue, saturation: 0.85, brightness: played ? 1.0 : 0.45)
                ctx.fill(
                    Path(roundedRect: CGRect(
                        x: CGFloat(i) * barSpace, y: midY - h / 2,
                        width: max(1, barSpace * 0.62), height: h), cornerRadius: 0.5),
                    with: .color(played ? color : color.opacity(0.5)))
            }
        }
    }
}

/// Lock-screen card. iOS clips Live Activities past ~160pt of content, so
/// this layout stays deliberately tight — nothing below gets cut off.
struct LockScreenView: View {
    let context: ActivityViewContext<SetActivityAttributes>

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.footnote)
                    .foregroundStyle(accent)
                Text(context.state.title)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                if context.state.bpm > 0 {
                    Text(String(format: "%.0f BPM", context.state.bpm))
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.15), in: Capsule())
                }
                Spacer()
                elapsed(context)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
            }

            WaveStrip(context: context)
                .frame(height: 46)

            progress(context)

            HStack(spacing: 40) {
                Spacer()
                Button(intent: SkipBackIntent()) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                Button(intent: SkipForwardIntent()) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
