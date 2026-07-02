import SwiftUI

/// Scrolling waveform, playhead fixed at center, beat-grid ticks along the top
/// and bottom edges. Drag horizontally to scrub.
struct ScrollingWaveform: View {
    let set: DJSet

    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var waveStore = WaveformStore.shared

    @State private var scrubBase: TimeInterval?

    private let pxPerSecond: CGFloat = 55

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in
                guard let wf = waveStore.waveforms[set.id], wf.count > 0, player.duration > 0 else { return }

                let midX = size.width / 2
                let midY = size.height / 2
                let now = player.liveTime()
                let binDur = player.duration / Double(wf.count)
                let halfSpan = Double(midX / pxPerSecond)

                // faint center line
                ctx.fill(
                    Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
                    with: .color(.white.opacity(0.07)))

                // waveform bars
                let barW: CGFloat = 2
                let step: CGFloat = 3
                var x: CGFloat = 0
                while x < size.width {
                    let t = now + Double((x - midX) / pxPerSecond)
                    if t >= 0 && t < player.duration {
                        let bin = min(wf.count - 1, max(0, Int(t / binDur)))
                        let amp = CGFloat(wf.amps[bin])
                        let h = max(2, amp * size.height * 0.88)
                        let color = Color(
                            red: Double(wf.r[bin]),
                            green: Double(wf.g[bin]),
                            blue: Double(wf.b[bin]))
                        let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                    }
                    x += step
                }

                // beat grid ticks (every 4th beat stronger, CDJ style)
                if !wf.beats.isEmpty {
                    let from = Float(max(0, now - halfSpan))
                    let to = Float(now + halfSpan)
                    var i = wf.firstBeat(after: from)
                    while i < wf.beats.count, wf.beats[i] <= to {
                        let bx = midX + (CGFloat(Double(wf.beats[i]) - now)) * pxPerSecond
                        let strong = i % 4 == 0
                        let tickH: CGFloat = strong ? 12 : 7
                        let alpha: Double = strong ? 0.85 : 0.4
                        ctx.fill(
                            Path(CGRect(x: bx - 0.5, y: 0, width: strong ? 1.6 : 1, height: tickH)),
                            with: .color(.white.opacity(alpha)))
                        ctx.fill(
                            Path(CGRect(x: bx - 0.5, y: size.height - tickH, width: strong ? 1.6 : 1, height: tickH)),
                            with: .color(.white.opacity(alpha)))
                        i += 1
                    }
                }

                // annotation markers
                for (index, cue) in set.annotations.enumerated() {
                    let cx = midX + (cue.time - now) * pxPerSecond
                    guard cx > -20, cx < size.width + 20 else { continue }
                    let color = Theme.cueColors[index % Theme.cueColors.count]
                    ctx.fill(
                        Path(CGRect(x: cx - 0.75, y: 0, width: 1.5, height: size.height)),
                        with: .color(color.opacity(0.9)))
                    var flag = Path()
                    flag.move(to: CGPoint(x: cx, y: 0))
                    flag.addLine(to: CGPoint(x: cx + 11, y: 0))
                    flag.addLine(to: CGPoint(x: cx, y: 11))
                    flag.closeSubpath()
                    ctx.fill(flag, with: .color(color))
                }

                // center playhead with cap
                ctx.fill(
                    Path(CGRect(x: midX - 1, y: 0, width: 2, height: size.height)),
                    with: .color(Theme.playhead))
                var cap = Path()
                cap.move(to: CGPoint(x: midX - 6, y: 0))
                cap.addLine(to: CGPoint(x: midX + 6, y: 0))
                cap.addLine(to: CGPoint(x: midX, y: 7))
                cap.closeSubpath()
                ctx.fill(cap, with: .color(Theme.playhead))
            }
            .overlay {
                if waveStore.generating.contains(set.id) {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Analyzing waveform & beat grid…")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if scrubBase == nil { scrubBase = player.liveTime() }
                    if let base = scrubBase {
                        player.seek(to: base - Double(value.translation.width / pxPerSecond))
                    }
                }
                .onEnded { _ in scrubBase = nil }
        )
    }
}

/// Full-set overview in rainbow color: tap or drag anywhere to jump.
struct OverviewWaveform: View {
    let set: DJSet

    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var waveStore = WaveformStore.shared

    var body: some View {
        TimelineView(.animation) { _ in
            GeometryReader { geo in
                Canvas { ctx, size in
                    guard let wf = waveStore.waveforms[set.id], wf.count > 0, player.duration > 0 else { return }

                    let midY = size.height / 2
                    let now = player.liveTime()
                    let playedX = CGFloat(now / player.duration) * size.width

                    let step: CGFloat = 2
                    var x: CGFloat = 0
                    while x < size.width {
                        let bin = min(wf.count - 1, Int(CGFloat(wf.count) * x / size.width))
                        let h = max(1.5, CGFloat(wf.amps[bin]) * size.height * 0.85)
                        let played = x <= playedX
                        let color = Color(
                            red: Double(wf.r[bin]),
                            green: Double(wf.g[bin]),
                            blue: Double(wf.b[bin]))
                        ctx.fill(
                            Path(CGRect(x: x, y: midY - h / 2, width: 1.4, height: h)),
                            with: .color(played ? color : color.opacity(0.28)))
                        x += step
                    }

                    for (index, cue) in set.annotations.enumerated() {
                        let cx = CGFloat(cue.time / player.duration) * size.width
                        ctx.fill(
                            Path(CGRect(x: cx - 0.75, y: 0, width: 1.5, height: size.height)),
                            with: .color(Theme.cueColors[index % Theme.cueColors.count]))
                    }

                    ctx.fill(
                        Path(CGRect(x: playedX - 0.75, y: 0, width: 1.5, height: size.height)),
                        with: .color(.white))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let frac = max(0, min(1, value.location.x / geo.size.width))
                            player.seek(to: Double(frac) * player.duration)
                        }
                )
            }
        }
    }
}
