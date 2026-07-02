import AVFoundation
import Foundation
import UIKit

/// Downsampled waveform with rainbow spectral coloring (bass = red, highs = violet)
/// plus a detected beat grid and BPM.
struct Waveform: Codable {
    var amps: [Float]
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var beats: [Float] = []
    var bpm: Float = 0

    var count: Int { amps.count }

    /// index of first beat at or after time t (beats are sorted)
    func firstBeat(after t: Float) -> Int {
        var lo = 0, hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()

    @Published private(set) var waveforms: [UUID: Waveform] = [:]
    @Published private(set) var generating: Set<UUID> = []
    @Published private(set) var progress: [UUID: Double] = [:]

    private init() {
        try? FileManager.default.createDirectory(
            at: Self.cacheDir, withIntermediateDirectories: true)
    }

    nonisolated static var cacheDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("waveforms", isDirectory: true)
    }

    // v2: rainbow colors + beat grid (older caches are ignored and regenerated)
    nonisolated static func diskCacheURL(for id: UUID) -> URL {
        cacheDir.appendingPathComponent("\(id.uuidString)-v2.json")
    }

    private func cacheURL(for id: UUID) -> URL {
        Self.diskCacheURL(for: id)
    }

    func removeCache(for id: UUID) {
        waveforms[id] = nil
        try? FileManager.default.removeItem(at: cacheURL(for: id))
        try? FileManager.default.removeItem(
            at: Self.cacheDir.appendingPathComponent("\(id.uuidString).json"))
    }

    private var pendingQueue: [(id: UUID, url: URL)] = []
    private var workerRunning = false
    private var suspended = false
    private var currentAbort: AbortFlag?

    final class AbortFlag: @unchecked Sendable {
        var isSet = false
    }

    /// iOS kills background-audio apps that sustain heavy CPU while
    /// backgrounded, which took playback down with it. Analysis therefore
    /// runs only in the foreground; the interrupted set is re-queued and
    /// BGProcessingTask windows handle the rest.
    func setSuspended(_ value: Bool) {
        suspended = value
        if value {
            currentAbort?.isSet = true
        } else {
            processNext()
        }
    }

    /// Loads from the on-disk cache if present, otherwise queues background
    /// analysis. Sets analyze one at a time; `urgent` (the set being opened)
    /// jumps to the front of the queue.
    func request(for set: DJSet, url: URL, urgent: Bool = false) {
        let id = set.id
        if waveforms[id] != nil { return }

        if let data = try? Data(contentsOf: cacheURL(for: id)),
           let cached = try? JSONDecoder().decode(Waveform.self, from: data) {
            waveforms[id] = cached
            return
        }

        if generating.contains(id) {
            if urgent, let idx = pendingQueue.firstIndex(where: { $0.id == id }) {
                pendingQueue.insert(pendingQueue.remove(at: idx), at: 0)
                }
            return
        }

        generating.insert(id)
        if urgent {
            pendingQueue.insert((id, url), at: 0)
        } else {
            pendingQueue.append((id, url))
        }
        processNext()
    }

    private func processNext() {
        guard !workerRunning, !suspended, !pendingQueue.isEmpty else { return }
        workerRunning = true
        let job = pendingQueue.removeFirst()
        let cacheURL = cacheURL(for: job.id)
        progress[job.id] = 0

        let abort = AbortFlag()
        currentAbort = abort

        Task.detached(priority: .utility) {
            let wf = Self.generate(
                url: job.url, bins: 2000,
                onProgress: { pct in
                    Task { @MainActor in self.progress[job.id] = pct }
                },
                shouldAbort: { abort.isSet })
            if let wf, let data = try? JSONEncoder().encode(wf) {
                try? data.write(to: cacheURL)
            }
            await MainActor.run {
                self.progress[job.id] = nil
                self.currentAbort = nil
                self.workerRunning = false
                if let wf {
                    self.generating.remove(job.id)
                    self.waveforms[job.id] = wf
                    if PlayerManager.shared.current?.id == job.id {
                        PlayerManager.shared.refreshLiveActivity()
                    }
                } else if abort.isSet {
                    // suspended mid-file: keep it queued for foreground return
                    self.pendingQueue.insert(job, at: 0)
                } else {
                    self.generating.remove(job.id) // unreadable file
                }
                self.processNext()
            }
        }
    }

    // MARK: - analysis

    /// Streams the file once: per display bin, peak amplitude + 6-band energy split
    /// via cascaded one-pole lowpasses (rainbow hue), and a fine-grained energy
    /// envelope (512-frame hops) for beat detection.
    nonisolated static func generate(
        url: URL, bins: Int,
        onProgress: @escaping (Double) -> Void = { _ in },
        shouldAbort: @escaping () -> Bool = { false }
    ) -> Waveform? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return nil }

        let format = file.processingFormat
        let sampleRate = Float(format.sampleRate)
        let framesPerBin = max(1, totalFrames / bins)
        let binCount = min(bins, totalFrames / framesPerBin)

        var amps = [Float](repeating: 0, count: binCount)
        // 6 bands: <80, 80-200, 200-500, 500-1500, 1500-4000, >4000 Hz
        let cutoffs: [Float] = [80, 200, 500, 1500, 4000]
        let alphas = cutoffs.map { 1 - exp(-2 * Float.pi * $0 / sampleRate) }
        var lp = [Float](repeating: 0, count: 5)
        var bandE = [[Float]](repeating: [Float](repeating: 0, count: binCount), count: 6)

        // beat-detection envelope: one value per 512-frame hop
        let hopSize = 512
        var envelope: [Float] = []
        envelope.reserveCapacity(totalFrames / hopSize + 1)
        var hopAcc: Float = 0
        var hopFill = 0
        var lastReported = 0.0

        let chunkFrames: AVAudioFrameCount = 1 << 17
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }

        var frameIndex = 0
        while frameIndex < totalFrames {
            if shouldAbort() { return nil }
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let ch = buffer.floatChannelData?[0] else { break }

            for i in 0..<n {
                let x = ch[i]
                for k in 0..<5 { lp[k] += alphas[k] * (x - lp[k]) }

                let bin = min(binCount - 1, (frameIndex + i) / framesPerBin)
                let ax = abs(x)
                if ax > amps[bin] { amps[bin] = ax }

                let b0 = lp[0]
                let b1 = lp[1] - lp[0]
                let b2 = lp[2] - lp[1]
                let b3 = lp[3] - lp[2]
                let b4 = lp[4] - lp[3]
                let b5 = x - lp[4]
                bandE[0][bin] += b0 * b0
                bandE[1][bin] += b1 * b1
                bandE[2][bin] += b2 * b2
                bandE[3][bin] += b3 * b3
                bandE[4][bin] += b4 * b4
                bandE[5][bin] += b5 * b5

                hopAcc += x * x
                hopFill += 1
                if hopFill == hopSize {
                    envelope.append(sqrt(hopAcc / Float(hopSize)))
                    hopAcc = 0
                    hopFill = 0
                }
            }
            frameIndex += n

            // streaming pass is ~90% of the work; report whole percents only
            let pct = 0.9 * Double(frameIndex) / Double(totalFrames)
            if Int(pct * 100) != Int(lastReported * 100) {
                lastReported = pct
                onProgress(pct)
            }
        }

        let peak = max(amps.max() ?? 1, 0.0001)
        for i in 0..<binCount { amps[i] = min(1, amps[i] / peak) }

        // rainbow: blend band hues weighted by (boosted) energy share
        let hues: [Float] = [0, 30, 55, 120, 200, 275]
        let boost: [Float] = [1.0, 1.0, 1.6, 2.2, 3.2, 4.5]
        var r = [Float](repeating: 0, count: binCount)
        var g = [Float](repeating: 0, count: binCount)
        var b = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            var total: Float = 0
            var hue: Float = 0
            for k in 0..<6 {
                let w = bandE[k][i] * boost[k]
                total += w
                hue += w * hues[k]
            }
            let color = total > 1e-9
                ? hsv(hue / total, 0.9, 1.0)
                : SIMD3<Float>(0.3, 0.3, 0.35)
            r[i] = color.x; g[i] = color.y; b[i] = color.z
        }

        onProgress(0.92)
        let grid = detectBeats(envelope: envelope, rate: sampleRate / Float(hopSize))
        onProgress(1.0)
        return Waveform(
            amps: amps, r: r, g: g, b: b,
            beats: grid?.beats ?? [], bpm: grid?.bpm ?? 0)
    }

    nonisolated static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let c = v * s
        let hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let rgb: SIMD3<Float>
        switch Int(hp) {
        case 0: rgb = SIMD3(c, x, 0)
        case 1: rgb = SIMD3(x, c, 0)
        case 2: rgb = SIMD3(0, c, x)
        case 3: rgb = SIMD3(0, x, c)
        case 4: rgb = SIMD3(x, 0, c)
        default: rgb = SIMD3(c, 0, x)
        }
        return rgb + SIMD3(m, m, m)
    }

    // MARK: - beat grid

    private struct BeatGrid {
        let bpm: Float
        let beats: [Float]
    }

    /// Onset flux + windowed autocorrelation for local tempo, then forward
    /// beat tracking that snaps each predicted beat to the nearest onset peak.
    nonisolated private static func detectBeats(envelope: [Float], rate: Float) -> BeatGrid? {
        let n = envelope.count
        guard n > Int(rate * 20) else { return nil }

        var onset = [Float](repeating: 0, count: n)
        for i in 1..<n { onset[i] = max(0, envelope[i] - envelope[i - 1]) }

        // local tempo every 8s over 16s windows, 70–190 BPM
        let win = Int(rate * 16)
        let hop = Int(rate * 8)
        let minLag = max(2, Int(rate * 60 / 190))
        let maxLag = Int(rate * 60 / 70)
        guard maxLag < win else { return nil }

        var periods: [(center: Int, lag: Float)] = []
        var start = 0
        while start + win <= n {
            var bestLag = 0
            var bestScore: Float = 0
            var scores = [Float](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag {
                var s: Float = 0
                var i = start
                let end = start + win - lag
                while i < end {
                    s += onset[i] * onset[i + lag]
                    i += 1
                }
                let score = s / Float(win - lag)
                scores[lag] = score
                if score > bestScore { bestScore = score; bestLag = lag }
            }
            if bestLag > minLag && bestLag < maxLag && bestScore > 0 {
                // parabolic refinement for sub-sample tempo accuracy
                let y0 = scores[bestLag - 1], y1 = scores[bestLag], y2 = scores[bestLag + 1]
                let denom = y0 - 2 * y1 + y2
                let offset = denom != 0 ? 0.5 * (y0 - y2) / denom : 0
                periods.append((start + win / 2, Float(bestLag) + offset))
            }
            start += hop
        }
        guard !periods.isEmpty else { return nil }

        let sortedLags = periods.map(\.lag).sorted()
        let medianLag = sortedLags[sortedLags.count / 2]
        let bpm = 60 * rate / medianLag

        func localLag(at index: Int) -> Float {
            var best = periods[0].lag
            var bestDist = Int.max
            for p in periods {
                let d = abs(p.center - index)
                if d < bestDist { bestDist = d; best = p.lag }
            }
            return best
        }

        // anchor on the strongest onset in the first 8 seconds
        let anchorWindow = min(n, Int(rate * 8))
        var cursor = Float((0..<anchorWindow).max(by: { onset[$0] < onset[$1] }) ?? 0)

        var beats: [Float] = []
        beats.reserveCapacity(n / Int(medianLag))
        while cursor < Float(n) {
            beats.append(cursor / rate)
            let lag = localLag(at: Int(cursor))
            var next = cursor + lag
            let radius = Int(lag * 0.12)
            let center = Int(next)
            if radius > 0, center - radius > 0, center + radius < n {
                var bestIdx = center
                var bestVal: Float = -1
                for j in (center - radius)...(center + radius) where onset[j] > bestVal {
                    bestVal = onset[j]
                    bestIdx = j
                }
                next = Float(bestIdx)
            }
            if next <= cursor { break }
            cursor = next
        }
        guard beats.count > 4 else { return nil }
        return BeatGrid(bpm: bpm, beats: beats)
    }
}
