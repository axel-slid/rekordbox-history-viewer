import AVFoundation
import Foundation

/// Downsampled waveform with per-bin color, rekordbox RGB style:
/// low frequencies pull blue, mids amber, highs white.
struct Waveform: Codable {
    var amps: [Float]
    var r: [Float]
    var g: [Float]
    var b: [Float]

    var count: Int { amps.count }
}

@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()

    @Published private(set) var waveforms: [UUID: Waveform] = [:]
    @Published private(set) var generating: Set<UUID> = []

    private let cacheDir: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDir = docs.appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func cacheURL(for id: UUID) -> URL {
        cacheDir.appendingPathComponent("\(id.uuidString).json")
    }

    func removeCache(for id: UUID) {
        waveforms[id] = nil
        try? FileManager.default.removeItem(at: cacheURL(for: id))
    }

    func request(for set: DJSet, url: URL) {
        let id = set.id
        if waveforms[id] != nil || generating.contains(id) { return }

        if let data = try? Data(contentsOf: cacheURL(for: id)),
           let cached = try? JSONDecoder().decode(Waveform.self, from: data) {
            waveforms[id] = cached
            return
        }

        generating.insert(id)
        let cacheURL = cacheURL(for: id)
        Task.detached(priority: .utility) {
            let wf = Self.generate(url: url, bins: 1600)
            if let wf, let data = try? JSONEncoder().encode(wf) {
                try? data.write(to: cacheURL)
            }
            await MainActor.run {
                self.generating.remove(id)
                if let wf { self.waveforms[id] = wf }
            }
        }
    }

    /// Streams the file once. Per display bin: peak amplitude plus rough
    /// low/mid/high energy split from one-pole filters (cheap but convincing).
    nonisolated static func generate(url: URL, bins: Int) -> Waveform? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return nil }

        let format = file.processingFormat
        let sampleRate = Float(format.sampleRate)
        let framesPerBin = max(1, totalFrames / bins)
        let binCount = min(bins, totalFrames / framesPerBin)

        var amps = [Float](repeating: 0, count: binCount)
        var lowE = [Float](repeating: 0, count: binCount)
        var midE = [Float](repeating: 0, count: binCount)
        var highE = [Float](repeating: 0, count: binCount)

        // one-pole coefficients: low < ~200 Hz, high > ~4 kHz
        let aLow = 1 - exp(-2 * Float.pi * 200 / sampleRate)
        let aHigh = 1 - exp(-2 * Float.pi * 4000 / sampleRate)
        var lp: Float = 0
        var lp4k: Float = 0

        let chunkFrames: AVAudioFrameCount = 1 << 17
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }

        var frameIndex = 0
        while frameIndex < totalFrames {
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let ch = buffer.floatChannelData?[0] else { break }

            for i in 0..<n {
                let x = ch[i]
                lp += aLow * (x - lp)
                lp4k += aHigh * (x - lp4k)
                let high = x - lp4k
                let mid = lp4k - lp

                let bin = min(binCount - 1, (frameIndex + i) / framesPerBin)
                let ax = abs(x)
                if ax > amps[bin] { amps[bin] = ax }
                lowE[bin] += lp * lp
                midE[bin] += mid * mid
                highE[bin] += high * high
            }
            frameIndex += n
        }

        // normalize amplitude to the set's own peak
        let peak = max(amps.max() ?? 1, 0.0001)
        for i in 0..<binCount { amps[i] = min(1, amps[i] / peak) }

        var r = [Float](repeating: 0, count: binCount)
        var g = [Float](repeating: 0, count: binCount)
        var b = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            // high band gets a boost so hats/air read as white like rekordbox
            let e = (low: lowE[i], mid: midE[i], high: highE[i] * 3)
            let total = max(e.low + e.mid + e.high, 1e-9)
            let wl = e.low / total, wm = e.mid / total, wh = e.high / total
            let color = Theme.waveLow * wl + Theme.waveMid * wm + Theme.waveHigh * wh
            r[i] = color.x; g[i] = color.y; b[i] = color.z
        }

        return Waveform(amps: amps, r: r, g: g, b: b)
    }
}
