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

/// Full analysis state, checkpointed to disk so a suspension (backgrounding,
/// BG-task expiry) never loses progress — analysis resumes mid-file.
struct AnalysisCheckpoint: Codable {
    var totalFrames: Int
    var frameIndex: Int
    var binCount: Int
    var framesPerBin: Int
    var sampleRate: Float
    var amps: [Float]
    var bandE: [[Float]]
    var lp: [Float]
    var envelope: [Float]
    var hopAcc: Float
    var hopFill: Int
}

enum AnalysisOutcome {
    case finished(Waveform)
    case suspended(AnalysisCheckpoint)
    case failed
}

// Waveforms are now time-resolved (one bin per 40ms), so a 2h set has ~180k
// bins. JSON is far too slow at that size — caches and checkpoints are
// binary plists with raw Float32 blobs (memcpy in and out).
private extension Array where Element == Float {
    var rawData: Data { withUnsafeBufferPointer { Data(buffer: $0) } }
}

private extension Data {
    var floatArray: [Float] {
        var out = [Float](repeating: 0, count: count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { copyBytes(to: $0) }
        return out
    }
}

private struct WaveformFile: Codable {
    var bpm: Float
    var amps: Data
    var r: Data
    var g: Data
    var b: Data
    var beats: Data
}

private struct CheckpointFile: Codable {
    var totalFrames: Int
    var frameIndex: Int
    var binCount: Int
    var framesPerBin: Int
    var sampleRate: Float
    var hopAcc: Float
    var hopFill: Int
    var amps: Data
    var bandE: [Data]
    var lp: Data
    var envelope: Data
}

enum WaveIO {
    static func encode(_ wf: Waveform) -> Data? {
        let file = WaveformFile(
            bpm: wf.bpm, amps: wf.amps.rawData,
            r: wf.r.rawData, g: wf.g.rawData, b: wf.b.rawData,
            beats: wf.beats.rawData)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(file)
    }

    static func decodeWaveform(_ data: Data) -> Waveform? {
        guard let f = try? PropertyListDecoder().decode(WaveformFile.self, from: data) else { return nil }
        return Waveform(
            amps: f.amps.floatArray, r: f.r.floatArray,
            g: f.g.floatArray, b: f.b.floatArray,
            beats: f.beats.floatArray, bpm: f.bpm)
    }

    static func encode(_ cp: AnalysisCheckpoint) -> Data? {
        let file = CheckpointFile(
            totalFrames: cp.totalFrames, frameIndex: cp.frameIndex,
            binCount: cp.binCount, framesPerBin: cp.framesPerBin,
            sampleRate: cp.sampleRate, hopAcc: cp.hopAcc, hopFill: cp.hopFill,
            amps: cp.amps.rawData, bandE: cp.bandE.map(\.rawData),
            lp: cp.lp.rawData, envelope: cp.envelope.rawData)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(file)
    }

    static func decodeCheckpoint(_ data: Data) -> AnalysisCheckpoint? {
        guard let f = try? PropertyListDecoder().decode(CheckpointFile.self, from: data) else { return nil }
        return AnalysisCheckpoint(
            totalFrames: f.totalFrames, frameIndex: f.frameIndex,
            binCount: f.binCount, framesPerBin: f.framesPerBin,
            sampleRate: f.sampleRate, amps: f.amps.floatArray,
            bandE: f.bandE.map(\.floatArray), lp: f.lp.floatArray,
            envelope: f.envelope.floatArray, hopAcc: f.hopAcc, hopFill: f.hopFill)
    }
}

@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()

    @Published private(set) var waveforms: [UUID: Waveform] = [:]
    /// grows piece by piece while a set is being analyzed
    @Published private(set) var partials: [UUID: Waveform] = [:]
    @Published private(set) var generating: Set<UUID> = []
    @Published private(set) var progress: [UUID: Double] = [:]

    private init() {
        try? FileManager.default.createDirectory(
            at: Self.cacheDir, withIntermediateDirectories: true)
    }

    /// Finished waveform if available, else the in-progress partial.
    func waveform(for id: UUID) -> Waveform? {
        waveforms[id] ?? partials[id]
    }

    nonisolated static var cacheDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("waveforms", isDirectory: true)
    }

    // v4: time-resolved bins (40ms), binary format; older caches regenerate
    nonisolated static func diskCacheURL(for id: UUID) -> URL {
        cacheDir.appendingPathComponent("\(id.uuidString)-v4.wave")
    }

    nonisolated static func checkpointURL(for id: UUID) -> URL {
        cacheDir.appendingPathComponent("\(id.uuidString)-v4.partial")
    }

    nonisolated static func loadCheckpoint(from url: URL) -> AnalysisCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return WaveIO.decodeCheckpoint(data)
    }

    nonisolated static func saveCheckpoint(_ checkpoint: AnalysisCheckpoint, to url: URL) {
        if let data = WaveIO.encode(checkpoint) {
            try? data.write(to: url)
        }
    }

    func removeCache(for id: UUID) {
        waveforms[id] = nil
        partials[id] = nil
        try? FileManager.default.removeItem(at: Self.diskCacheURL(for: id))
        try? FileManager.default.removeItem(at: Self.checkpointURL(for: id))
        try? FileManager.default.removeItem(
            at: Self.cacheDir.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(
            at: Self.cacheDir.appendingPathComponent("\(id.uuidString)-v2.json"))
        try? FileManager.default.removeItem(
            at: Self.cacheDir.appendingPathComponent("\(id.uuidString)-v3.json"))
        try? FileManager.default.removeItem(
            at: Self.cacheDir.appendingPathComponent("\(id.uuidString)-partial.json"))
    }

    private var pendingQueue: [(id: UUID, url: URL)] = []
    private var workerRunning = false
    private var suspended = false
    private var currentAbort: AbortFlag?

    final class AbortFlag: @unchecked Sendable {
        var isSet = false
    }

    /// iOS kills background-audio apps that sustain heavy CPU while
    /// backgrounded. Analysis therefore pauses on backgrounding — but the
    /// engine checkpoints, so it resumes mid-file in the foreground or in
    /// BGProcessingTask windows. Nothing is lost.
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

        if let data = try? Data(contentsOf: Self.diskCacheURL(for: id)),
           let cached = WaveIO.decodeWaveform(data) {
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
        let cacheURL = Self.diskCacheURL(for: job.id)
        let checkpointURL = Self.checkpointURL(for: job.id)
        if progress[job.id] == nil { progress[job.id] = 0 }

        let abort = AbortFlag()
        currentAbort = abort

        Task.detached(priority: .utility) {
            let resume = Self.loadCheckpoint(from: checkpointURL)
            let outcome = Self.analyze(
                url: job.url, resuming: resume,
                onPiece: { partial, pct in
                    Task { @MainActor in
                        self.partials[job.id] = partial
                        self.progress[job.id] = pct
                    }
                },
                shouldAbort: { abort.isSet })

            if case .finished(let wf) = outcome {
                if let data = WaveIO.encode(wf) { try? data.write(to: cacheURL) }
                try? FileManager.default.removeItem(at: checkpointURL)
            } else if case .suspended(let checkpoint) = outcome {
                Self.saveCheckpoint(checkpoint, to: checkpointURL)
            }

            await MainActor.run {
                self.currentAbort = nil
                self.workerRunning = false
                switch outcome {
                case .finished(let wf):
                    self.generating.remove(job.id)
                    self.partials[job.id] = nil
                    self.progress[job.id] = nil
                    self.waveforms[job.id] = wf
                    if PlayerManager.shared.current?.id == job.id {
                        PlayerManager.shared.refreshLiveActivity()
                    }
                case .suspended:
                    // keep the partial visible; resume from the checkpoint later
                    self.pendingQueue.insert(job, at: 0)
                case .failed:
                    self.generating.remove(job.id)
                    self.partials[job.id] = nil
                    self.progress[job.id] = nil
                }
                self.processNext()
            }
        }
    }

    // MARK: - analysis engine

    /// Streams the file in ~2.7s-of-audio chunks. Every few chunks it emits a
    /// partial waveform (so the UI shows the analysis growing) and can stop at
    /// any chunk boundary, returning a checkpoint that resumes mid-file.
    /// one waveform bin per 40ms of audio, so every set has the same detail
    nonisolated static let binDuration = 0.040

    nonisolated static func analyze(
        url: URL,
        resuming: AnalysisCheckpoint?,
        onPiece: @escaping (Waveform, Double) -> Void = { _, _ in },
        shouldAbort: @escaping () -> Bool = { false }
    ) -> AnalysisOutcome {
        guard let file = try? AVAudioFile(forReading: url) else { return .failed }
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return .failed }

        let format = file.processingFormat
        let sampleRate = Float(format.sampleRate)

        var frameIndex: Int
        var amps: [Float]
        var bandE: [[Float]]
        var lp: [Float]
        var envelope: [Float]
        var hopAcc: Float
        var hopFill: Int
        let binCount: Int
        let framesPerBin: Int

        if let r = resuming,
           r.totalFrames == totalFrames, r.sampleRate == sampleRate,
           r.bandE.count == 6, r.amps.count == r.binCount {
            frameIndex = r.frameIndex
            amps = r.amps
            bandE = r.bandE
            lp = r.lp
            envelope = r.envelope
            hopAcc = r.hopAcc
            hopFill = r.hopFill
            binCount = r.binCount
            framesPerBin = r.framesPerBin
            file.framePosition = AVAudioFramePosition(frameIndex)
        } else {
            framesPerBin = max(1, Int(Double(sampleRate) * Self.binDuration))
            binCount = max(1, totalFrames / framesPerBin)
            frameIndex = 0
            amps = [Float](repeating: 0, count: binCount)
            bandE = [[Float]](repeating: [Float](repeating: 0, count: binCount), count: 6)
            lp = [Float](repeating: 0, count: 5)
            envelope = []
            envelope.reserveCapacity(totalFrames / 512 + 1)
            hopAcc = 0
            hopFill = 0
        }

        // 6 bands: <80, 80-200, 200-500, 500-1500, 1500-4000, >4000 Hz
        let cutoffs: [Float] = [80, 200, 500, 1500, 4000]
        let alphas = cutoffs.map { 1 - exp(-2 * Float.pi * $0 / sampleRate) }
        let hopSize = 512

        let chunkFrames: AVAudioFrameCount = 1 << 17
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return .failed
        }

        func checkpoint() -> AnalysisCheckpoint {
            AnalysisCheckpoint(
                totalFrames: totalFrames, frameIndex: frameIndex,
                binCount: binCount, framesPerBin: framesPerBin,
                sampleRate: sampleRate, amps: amps, bandE: bandE, lp: lp,
                envelope: envelope, hopAcc: hopAcc, hopFill: hopFill)
        }

        func partialWaveform() -> Waveform {
            let completedBins = min(binCount, frameIndex / framesPerBin)
            var normalized = amps
            let peak = max(normalized.max() ?? 1, 0.0001)
            for i in 0..<binCount { normalized[i] = min(1, normalized[i] / peak) }
            let (r, g, b) = makeColors(bandE: bandE, binCount: binCount, upTo: completedBins)
            return Waveform(amps: normalized, r: r, g: g, b: b)
        }

        var chunksSincePiece = 0
        while frameIndex < totalFrames {
            if shouldAbort() { return .suspended(checkpoint()) }
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

            chunksSincePiece += 1
            if chunksSincePiece >= 8 || frameIndex >= totalFrames {
                chunksSincePiece = 0
                onPiece(partialWaveform(), 0.9 * Double(frameIndex) / Double(totalFrames))
            }
        }

        // finish: normalize, color all bins, detect beats
        let peak = max(amps.max() ?? 1, 0.0001)
        for i in 0..<binCount { amps[i] = min(1, amps[i] / peak) }
        let (r, g, b) = makeColors(bandE: bandE, binCount: binCount, upTo: binCount)

        onPiece(Waveform(amps: amps, r: r, g: g, b: b), 0.95)
        let bpm = estimateBPM(envelope: envelope, rate: sampleRate / Float(hopSize))

        return .finished(Waveform(
            amps: amps, r: r, g: g, b: b,
            beats: [], bpm: bpm))
    }

    /// Rainbow hues from the 6-band energy split; bins past `upTo` stay dim gray.
    nonisolated private static func makeColors(
        bandE: [[Float]], binCount: Int, upTo: Int
    ) -> ([Float], [Float], [Float]) {
        let hues: [Float] = [0, 30, 55, 120, 200, 275]
        let boost: [Float] = [1.0, 1.0, 1.6, 2.2, 3.2, 4.5]
        var r = [Float](repeating: 0.3, count: binCount)
        var g = [Float](repeating: 0.3, count: binCount)
        var b = [Float](repeating: 0.35, count: binCount)
        for i in 0..<min(upTo, binCount) {
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
        return (r, g, b)
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

    // MARK: - BPM estimate
    // Beat tracking is intentionally gone (it was slow and unreliable on long
    // sets). BPM comes from autocorrelating onset energy in a handful of
    // sampled 16s windows — near-free compared to the old full-set pass.
    nonisolated private static func estimateBPM(envelope: [Float], rate: Float) -> Float {
        let n = envelope.count
        let win = Int(rate * 16)
        let minLag = max(2, Int(rate * 60 / 190))
        let maxLag = Int(rate * 60 / 70)
        guard maxLag < win, n > win + 2 else { return 0 }

        var onset = [Float](repeating: 0, count: n)
        for i in 1..<n { onset[i] = max(0, envelope[i] - envelope[i - 1]) }

        let windowCount = min(8, max(1, n / (win * 2)))
        var lags: [Float] = []
        for w in 0..<windowCount {
            let start = windowCount == 1
                ? (n - win) / 2
                : (n - win) * w / (windowCount - 1)
            var bestLag = 0
            var bestScore: Float = 0
            var scores = [Float](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag {
                var sum: Float = 0
                var i = start
                let end = start + win - lag
                while i < end {
                    sum += onset[i] * onset[i + lag]
                    i += 1
                }
                let score = sum / Float(win - lag)
                scores[lag] = score
                if score > bestScore { bestScore = score; bestLag = lag }
            }
            if bestLag > minLag && bestLag < maxLag && bestScore > 0 {
                let y0 = scores[bestLag - 1], y1 = scores[bestLag], y2 = scores[bestLag + 1]
                let denom = y0 - 2 * y1 + y2
                let offset = denom != 0 ? 0.5 * (y0 - y2) / denom : 0
                lags.append(Float(bestLag) + offset)
            }
        }
        guard !lags.isEmpty else { return 0 }
        let median = lags.sorted()[lags.count / 2]
        return 60 * rate / median
    }
}
