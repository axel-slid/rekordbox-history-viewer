import AVFoundation
import Combine
import Foundation

struct MacWaveform {
    var amps: [Float]
    /// Normalized spectral center: 0 is bass, 1 is high frequency.
    var frequency: [Float]
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var beats: [Float]
    var bpm: Float

    var count: Int { amps.count }
}

private extension Data {
    var floatArray: [Float] {
        var output = [Float](repeating: 0, count: count / MemoryLayout<Float>.size)
        _ = output.withUnsafeMutableBytes { copyBytes(to: $0) }
        return output
    }
}

private struct SyncedWaveformFile: Codable {
    var bpm: Float
    var amps: Data
    var r: Data
    var g: Data
    var b: Data
    var beats: Data
}

enum MacWaveformIO {
    static func decode(_ data: Data) -> MacWaveform? {
        guard let file = try? PropertyListDecoder().decode(
            SyncedWaveformFile.self,
            from: data
        ) else { return nil }
        let amps = file.amps.floatArray
        let rawRed = file.r.floatArray
        let rawGreen = file.g.floatArray
        let rawBlue = file.b.floatArray
        let frequency = smoothedFrequencyProfile(
            red: rawRed,
            green: rawGreen,
            blue: rawBlue,
            count: amps.count)
        let colors = MacFrequencyPalette.colors(for: frequency)
        return MacWaveform(
            amps: amps,
            frequency: frequency,
            red: colors.red,
            green: colors.green,
            blue: colors.blue,
            beats: file.beats.floatArray,
            bpm: file.bpm)
    }

    static func quickPreview(for url: URL, bins: Int = 2400) -> MacWaveform? {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: 65_536) else { return nil }

        let totalFrames = Int(file.length)
        let channelCount = Int(file.processingFormat.channelCount)
        let sampleStride = max(1, totalFrames / bins / 24)
        let framesPerBin = max(1, totalFrames / bins)
        let frequencyWindow = min(framesPerBin, 2_048)
        let frequencyStride = 4
        var amps = [Float](repeating: 0, count: bins)
        var zeroCrossings = [Int](repeating: 0, count: bins)
        var frequencySamples = [Int](repeating: 0, count: bins)
        var previousSamples = [Float](repeating: 0, count: bins)
        var globalFrame = 0

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                return nil
            }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channels = buffer.floatChannelData else { break }

            var frame = 0
            while frame < frameLength {
                let absoluteFrame = globalFrame + frame
                let bin = min(bins - 1, absoluteFrame * bins / totalFrames)
                var amplitude: Float = 0
                for channel in 0..<channelCount {
                    amplitude = max(amplitude, abs(channels[channel][frame]))
                }
                amps[bin] = max(amps[bin], amplitude)
                frame += sampleStride
            }

            let firstBin = max(0, globalFrame / framesPerBin)
            let lastBin = min(
                bins - 1,
                (globalFrame + frameLength - 1) / framesPerBin)
            if firstBin <= lastBin {
                for bin in firstBin...lastBin {
                    let windowStart = bin * framesPerBin
                    let windowEnd = min(totalFrames, windowStart + frequencyWindow)
                    var absoluteFrame = max(globalFrame, windowStart)
                    let remainder = (absoluteFrame - windowStart) % frequencyStride
                    if remainder != 0 {
                        absoluteFrame += frequencyStride - remainder
                    }
                    let overlapEnd = min(globalFrame + frameLength, windowEnd)

                    while absoluteFrame < overlapEnd {
                        let localFrame = absoluteFrame - globalFrame
                        var sample: Float = 0
                        for channel in 0..<channelCount {
                            sample += channels[channel][localFrame]
                        }
                        sample /= Float(max(1, channelCount))
                        if frequencySamples[bin] > 0,
                           (sample >= 0) != (previousSamples[bin] >= 0) {
                            zeroCrossings[bin] += 1
                        }
                        previousSamples[bin] = sample
                        frequencySamples[bin] += 1
                        absoluteFrame += frequencyStride
                    }
                }
            }
            globalFrame += frameLength
        }

        let peak = max(0.001, amps.max() ?? 1)
        amps = amps.map { min(1, pow($0 / peak, 0.62)) }
        let effectiveSampleRate = Float(file.processingFormat.sampleRate)
            / Float(frequencyStride)
        var frequency = [Float](repeating: 0.45, count: bins)
        let minFrequency: Float = 70
        let maxFrequency: Float = 6_000
        let logRange = log2(maxFrequency / minFrequency)
        for index in 0..<bins where frequencySamples[index] > 1 {
            let crossingRate = Float(zeroCrossings[index])
                / Float(frequencySamples[index] - 1)
            let estimatedFrequency = max(
                minFrequency,
                min(maxFrequency, crossingRate * effectiveSampleRate * 0.5))
            frequency[index] = log2(estimatedFrequency / minFrequency) / logRange
        }
        frequency = smooth(frequency, alpha: 0.16)
        let colors = MacFrequencyPalette.colors(for: frequency)

        return MacWaveform(
            amps: amps,
            frequency: frequency,
            red: colors.red,
            green: colors.green,
            blue: colors.blue,
            beats: [],
            bpm: 0)
    }

    private static func smoothedFrequencyProfile(
        red: [Float],
        green: [Float],
        blue: [Float],
        count: Int
    ) -> [Float] {
        guard count > 0 else { return [] }
        var profile = [Float](repeating: 0.45, count: count)
        var lastFrequency: Float = 0.45

        for index in 0..<count {
            guard index < red.count, index < green.count, index < blue.count else {
                profile[index] = lastFrequency
                continue
            }
            let r = red[index]
            let g = green[index]
            let b = blue[index]
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            let delta = maximum - minimum
            guard delta > 0.06 else {
                profile[index] = lastFrequency
                continue
            }

            var hue: Float
            if maximum == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == g {
                hue = 60 * (((b - r) / delta) + 2)
            } else {
                hue = 60 * (((r - g) / delta) + 4)
            }
            if hue < 0 { hue += 360 }
            lastFrequency = max(0, min(1, hue / 275))
            profile[index] = lastFrequency
        }

        return smooth(profile, alpha: 0.12)
    }

    private static func smooth(_ input: [Float], alpha: Float) -> [Float] {
        guard input.count > 1 else { return input }
        var forward = input
        for index in 1..<forward.count {
            forward[index] = forward[index - 1]
                + alpha * (input[index] - forward[index - 1])
        }

        var backward = input
        for index in stride(from: backward.count - 2, through: 0, by: -1) {
            backward[index] = backward[index + 1]
                + alpha * (input[index] - backward[index + 1])
        }
        return zip(forward, backward).map { ($0 + $1) * 0.5 }
    }
}

enum MacFrequencyPalette {
    static let bands: [(red: Float, green: Float, blue: Float)] = [
        (0.96, 0.20, 0.12),  // sub / bass
        (1.00, 0.52, 0.08),  // low mids
        (0.22, 0.82, 0.38),  // mids
        (0.00, 0.66, 0.95),  // upper mids
        (0.50, 0.32, 1.00)   // highs
    ]

    static func band(for frequency: Float) -> Int {
        min(bands.count - 1, max(0, Int(frequency * Float(bands.count))))
    }

    static func colors(
        for frequency: [Float]
    ) -> (red: [Float], green: [Float], blue: [Float]) {
        var red = [Float]()
        var green = [Float]()
        var blue = [Float]()
        red.reserveCapacity(frequency.count)
        green.reserveCapacity(frequency.count)
        blue.reserveCapacity(frequency.count)
        for value in frequency {
            let color = bands[band(for: value)]
            red.append(color.red)
            green.append(color.green)
            blue.append(color.blue)
        }
        return (red, green, blue)
    }
}

@MainActor
final class MacWaveformStore: ObservableObject {
    static let shared = MacWaveformStore()

    @Published private(set) var waveforms: [UUID: MacWaveform] = [:]
    @Published private(set) var loading: Set<UUID> = []

    private init() {}

    func waveform(for id: UUID) -> MacWaveform? {
        waveforms[id]
    }

    func request(for set: DJSet, audioURL: URL, waveformsDir: URL) {
        guard waveforms[set.id] == nil, !loading.contains(set.id) else { return }
        loading.insert(set.id)
        let cacheURL = waveformsDir.appendingPathComponent("\(set.id.uuidString)-v4.wave")

        Task.detached(priority: .utility) {
            let synced = (try? Data(contentsOf: cacheURL)).flatMap(MacWaveformIO.decode)
            let waveform = synced ?? MacWaveformIO.quickPreview(for: audioURL)
            await MainActor.run {
                self.loading.remove(set.id)
                if let waveform {
                    self.waveforms[set.id] = waveform
                }
            }
        }
    }

    func refresh(_ sets: [DJSet], audioDirectory: URL, waveformsDirectory: URL) {
        for set in sets where waveforms[set.id] == nil {
            request(
                for: set,
                audioURL: audioDirectory.appendingPathComponent(set.fileName),
                waveformsDir: waveformsDirectory)
        }
    }
}
