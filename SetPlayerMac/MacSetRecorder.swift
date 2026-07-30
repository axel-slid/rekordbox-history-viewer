import AppKit
import Combine
import Foundation
import SwiftUI

struct MacAudioAppSource: Codable, Hashable, Identifiable {
    let pid: Int32
    let name: String
    let playing: Bool

    var id: Int32 { pid }
}

enum MacRecordingFormat: String, CaseIterable, Identifiable {
    case mp3
    case wav

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

@MainActor
final class MacSetRecorder: ObservableObject {
    static let shared = MacSetRecorder()

    @Published private(set) var sources: [MacAudioAppSource] = []
    @Published var selectedPID: Int32?
    @Published var format: MacRecordingFormat = .mp3
    @Published var bitrate = 320
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStarting = false
    @Published private(set) var isRecording = false
    @Published private(set) var isStopping = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var meterHistory: [Float] = []
    @Published private(set) var status = "Choose an app to record"
    @Published private(set) var errorMessage: String?

    private var pipeline: MacAudioCapturePipeline?
    private var captureTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?

    private init() {}

    var selectedSource: MacAudioAppSource? {
        guard let selectedPID else { return nil }
        return sources.first(where: { $0.pid == selectedPID })
    }

    var elapsedLabel: String {
        let seconds = max(0, Int(elapsed))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    func refreshSources() async {
        guard !isRefreshing, !isRecording, !isStarting else { return }
        isRefreshing = true
        errorMessage = nil

        do {
            let helperURL = try MacAudioCapturePipeline.helperURL()
            let discovered = try await Task.detached(priority: .userInitiated) {
                try MacAudioCapturePipeline.listSources(helperURL: helperURL)
            }.value
            let ownPID = ProcessInfo.processInfo.processIdentifier
            sources = discovered
                .filter { $0.pid != ownPID && $0.name != "Set Player" }
                .sorted {
                    if $0.playing != $1.playing { return $0.playing && !$1.playing }
                    if $0.name.localizedCaseInsensitiveContains("rekordbox") !=
                        $1.name.localizedCaseInsensitiveContains("rekordbox") {
                        return $0.name.localizedCaseInsensitiveContains("rekordbox")
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

            if selectedSource == nil {
                selectedPID = sources.first(where: {
                    $0.name.localizedCaseInsensitiveContains("rekordbox")
                })?.pid ?? sources.first(where: \.playing)?.pid ?? sources.first?.pid
            }
            status = sources.isEmpty
                ? "Open Rekordbox or another audio app, then refresh"
                : "Ready to record app audio"
        } catch {
            sources = []
            errorMessage = error.localizedDescription
            status = "Couldn’t load audio sources"
        }
        isRefreshing = false
    }

    func startRecording(into library: MacLibrary) {
        guard !isRecording, !isStarting, !isStopping else { return }
        guard let source = selectedSource else {
            errorMessage = "Choose an app to record first."
            return
        }

        isStarting = true
        errorMessage = nil
        status = "Connecting to \(source.name)…"
        let startDate = Date()
        let selectedFormat = format
        let selectedBitrate = bitrate
        let outputURL = uniqueRecordingURL(
            in: library.setsURL,
            date: startDate,
            format: selectedFormat)

        Task {
            do {
                let capture = try await Task.detached(priority: .userInitiated) {
                    try MacAudioCapturePipeline(
                        source: source,
                        outputURL: outputURL,
                        format: selectedFormat,
                        bitrate: selectedBitrate)
                }.value

                pipeline = capture
                startedAt = startDate
                elapsed = 0
                level = 0
                meterHistory = []
                isStarting = false
                isRecording = true
                status = "Recording \(source.name)"
                startTimer()
                runCapture(
                    capture,
                    outputURL: outputURL,
                    source: source,
                    startDate: startDate,
                    library: library)
            } catch {
                isStarting = false
                status = "Recording couldn’t start"
                errorMessage = cleanedError(error)
            }
        }
    }

    func stopRecording() {
        guard isRecording, !isStopping else { return }
        isStopping = true
        status = "Finishing \(format.label)…"
        pipeline?.stop()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        captureTask?.cancel()
        captureTask = nil
        pipeline?.cancel()
        pipeline = nil
    }

    private func runCapture(
        _ capture: MacAudioCapturePipeline,
        outputURL: URL,
        source: MacAudioAppSource,
        startDate: Date,
        library: MacLibrary
    ) {
        captureTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Void, Error>
            do {
                try capture.run { nextLevel in
                    Task { @MainActor in
                        let recorder = MacSetRecorder.shared
                        guard recorder.pipeline === capture else { return }
                        recorder.level = nextLevel
                        recorder.meterHistory.append(nextLevel)
                        if recorder.meterHistory.count > 108 {
                            recorder.meterHistory.removeFirst(
                                recorder.meterHistory.count - 108)
                        }
                    }
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                self?.captureFinished(
                    result,
                    capture: capture,
                    outputURL: outputURL,
                    source: source,
                    startDate: startDate,
                    library: library)
            }
        }
    }

    private func captureFinished(
        _ result: Result<Void, Error>,
        capture: MacAudioCapturePipeline,
        outputURL: URL,
        source: MacAudioAppSource,
        startDate: Date,
        library: MacLibrary
    ) {
        guard pipeline === capture else { return }
        let endDate = Date()
        timer?.invalidate()
        timer = nil
        pipeline = nil
        captureTask = nil
        isRecording = false
        isStopping = false
        isStarting = false
        level = 0

        switch result {
        case .success:
            status = "Saved \(outputURL.lastPathComponent)"
            library.registerRecording(
                at: outputURL,
                startedAt: startDate,
                endedAt: endDate,
                sourceName: source.name)
        case .failure(let error):
            try? FileManager.default.removeItem(at: outputURL)
            status = "Recording failed"
            errorMessage = cleanedError(error)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func uniqueRecordingURL(
        in directory: URL,
        date: Date,
        format: MacRecordingFormat
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Set \(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent("\(base).\(format.rawValue)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(suffix).\(format.rawValue)")
            suffix += 1
        }
        return candidate
    }

    private func cleanedError(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("permission") ||
            message.localizedCaseInsensitiveContains("capture process tap") {
            return "Allow Set Player in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        }
        return message
    }
}

private struct MacTapHeader: Decodable {
    let sampleRate: Double
    let channels: Int
}

private enum MacRecorderPipelineError: LocalizedError {
    case helperMissing
    case encoderMissing
    case invalidHeader(String)
    case helperFailed(String)
    case encoderFailed(String)
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The system-audio recorder is missing from Set Player."
        case .encoderMissing:
            return "The MP3 encoder couldn’t be found on this Mac."
        case .invalidHeader(let message):
            return "The audio source returned an invalid format. \(message)"
        case .helperFailed(let message):
            return message.isEmpty ? "The selected app stopped producing audio." : message
        case .encoderFailed(let message):
            return message.isEmpty ? "The MP3 couldn’t be finalized." : message
        case .emptyRecording:
            return "No audio was captured. Play audio in the selected app and try again."
        }
    }
}

private final class MacAudioCapturePipeline: @unchecked Sendable {
    private let source: MacAudioAppSource
    private let outputURL: URL
    private let tapProcess: Process
    private let tapOutput: Pipe
    private let tapError: Pipe
    private let encoderProcess: Process
    private let encoderInput: Pipe
    private let encoderError: Pipe
    private let stateLock = NSLock()
    private var stopRequested = false

    init(
        source: MacAudioAppSource,
        outputURL: URL,
        format: MacRecordingFormat,
        bitrate: Int
    ) throws {
        self.source = source
        self.outputURL = outputURL

        let helper = try Self.helperURL()
        let ffmpeg = try Self.encoderURL()

        tapProcess = Process()
        tapOutput = Pipe()
        tapError = Pipe()
        tapProcess.executableURL = helper
        tapProcess.arguments = ["--record", String(source.pid)]
        tapProcess.standardOutput = tapOutput
        tapProcess.standardError = tapError

        do {
            try tapProcess.run()
        } catch {
            throw MacRecorderPipelineError.helperFailed(error.localizedDescription)
        }

        let header: MacTapHeader
        do {
            header = try Self.readHeader(
                from: tapOutput.fileHandleForReading,
                process: tapProcess,
                errorPipe: tapError)
        } catch {
            if tapProcess.isRunning { tapProcess.terminate() }
            throw error
        }

        guard header.sampleRate > 0, header.channels > 0 else {
            tapProcess.terminate()
            throw MacRecorderPipelineError.invalidHeader("Missing sample rate or channel count.")
        }

        encoderProcess = Process()
        encoderInput = Pipe()
        encoderError = Pipe()
        encoderProcess.executableURL = ffmpeg
        var encoderArguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "f32le",
            "-ar", String(Int(header.sampleRate.rounded())),
            "-ac", String(header.channels),
            "-i", "pipe:0",
            "-map_metadata", "-1",
            "-ac", "2"
        ]
        if format == .mp3 {
            encoderArguments += [
                "-codec:a", "libmp3lame",
                "-b:a", "\(max(128, min(320, bitrate)))k"
            ]
        } else {
            encoderArguments += ["-codec:a", "pcm_s16le"]
        }
        encoderArguments += ["-y", outputURL.path]
        encoderProcess.arguments = encoderArguments
        encoderProcess.standardInput = encoderInput
        encoderProcess.standardOutput = FileHandle.nullDevice
        encoderProcess.standardError = encoderError

        do {
            try encoderProcess.run()
        } catch {
            tapProcess.terminate()
            throw MacRecorderPipelineError.encoderFailed(error.localizedDescription)
        }
    }

    func run(onLevel: @escaping @Sendable (Float) -> Void) throws {
        let input = tapOutput.fileHandleForReading
        let encoder = encoderInput.fileHandleForWriting
        var meterRemainder = Data()
        var lastMeterUpdate = ContinuousClock.now
        var capturedBytes: Int64 = 0

        while true {
            let data = input.readData(ofLength: 64 * 1_024)
            if data.isEmpty { break }
            do {
                try encoder.write(contentsOf: data)
            } catch {
                cancel()
                throw MacRecorderPipelineError.encoderFailed(error.localizedDescription)
            }
            capturedBytes += Int64(data.count)

            meterRemainder.append(data)
            let usable = meterRemainder.count - (meterRemainder.count % MemoryLayout<Float32>.size)
            if usable > 0, lastMeterUpdate.duration(to: .now) >= .milliseconds(75) {
                let meterData = meterRemainder.prefix(usable)
                var peak: Float = 0
                meterData.withUnsafeBytes { raw in
                    for sample in raw.bindMemory(to: Float32.self) {
                        peak = max(peak, abs(sample))
                    }
                }
                onLevel(min(1, sqrt(max(0, peak))))
                lastMeterUpdate = .now
            }
            if usable > 0 {
                meterRemainder.removeFirst(usable)
            }
        }

        try? encoder.close()
        encoderProcess.waitUntilExit()
        if tapProcess.isRunning { tapProcess.waitUntilExit() }

        let encoderMessage = String(
            data: encoderError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard encoderProcess.terminationStatus == 0 else {
            throw MacRecorderPipelineError.encoderFailed(encoderMessage)
        }

        let wasStopped = stateLock.withLock { stopRequested }
        if tapProcess.terminationStatus != 0, !wasStopped {
            let helperMessage = String(
                data: tapError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MacRecorderPipelineError.helperFailed(helperMessage)
        }

        let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard capturedBytes > 0, fileSize > 1_024 else {
            throw MacRecorderPipelineError.emptyRecording
        }
    }

    func stop() {
        stateLock.withLock { stopRequested = true }
        if tapProcess.isRunning { tapProcess.terminate() }
    }

    func cancel() {
        stateLock.withLock { stopRequested = true }
        if tapProcess.isRunning { tapProcess.terminate() }
        try? encoderInput.fileHandleForWriting.close()
        if encoderProcess.isRunning { encoderProcess.terminate() }
        try? FileManager.default.removeItem(at: outputURL)
    }

    static func helperURL() throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: "audiotap", withExtension: nil),
            URL(fileURLWithPath: "/Applications/Set Recorder.app/Contents/Resources/audiotap"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("set-recorder/helper/audiotap")
        ].compactMap { $0 }
        guard let url = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw MacRecorderPipelineError.helperMissing
        }
        return url
    }

    static func encoderURL() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ]
        guard let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw MacRecorderPipelineError.encoderMissing
        }
        return URL(fileURLWithPath: path)
    }

    static func listSources(helperURL: URL) throws -> [MacAudioAppSource] {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--list"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            throw MacRecorderPipelineError.helperFailed(message)
        }
        return try JSONDecoder().decode([MacAudioAppSource].self, from: data)
    }

    private static func readHeader(
        from handle: FileHandle,
        process: Process,
        errorPipe: Pipe
    ) throws -> MacTapHeader {
        var data = Data()
        while data.count < 4_096 {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { break }
            if byte.first == 10 { break }
            data.append(byte)
        }
        guard !data.isEmpty else {
            if process.isRunning { process.waitUntilExit() }
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MacRecorderPipelineError.helperFailed(message)
        }
        do {
            return try JSONDecoder().decode(MacTapHeader.self, from: data)
        } catch {
            throw MacRecorderPipelineError.invalidHeader(
                String(data: data, encoding: .utf8) ?? error.localizedDescription)
        }
    }
}

struct MacRecorderPanel: View {
    @EnvironmentObject private var library: MacLibrary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recorder = MacSetRecorder.shared
    @ObservedObject private var themes = MacThemeStore.shared

    private var recorderAccent: Color { themes.selectedTheme.warm }

    var body: some View {
        VStack(spacing: 0) {
            recorderTitlebar

            VStack(spacing: 12) {
                statusBanner
                formatToolbar

                Group {
                    if recorder.isRecording || recorder.isStarting || recorder.isStopping {
                        recordingStage
                    } else {
                        recordedSets
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            recorderBottomBar
        }
        .frame(width: 560, height: 665)
        .background(
            LinearGradient(
                colors: [Theme.panel, Theme.background],
                startPoint: .top,
                endPoint: .bottom))
        .task {
            if recorder.sources.isEmpty {
                await recorder.refreshSources()
            }
        }
    }

    private var recorderTitlebar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(recorderAccent)
                Text("Set Recorder")
                    .font(.system(size: 16, weight: .semibold))
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 56)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.white.opacity(0.07))
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(recorder.isRecording ? Color.red : recorderAccent)
                .frame(width: 14, height: 14)
                .shadow(
                    color: recorder.isRecording ? Color.red.opacity(0.75) : .clear,
                    radius: 7)

            Text(recorder.status)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)

            if recorder.isRefreshing || recorder.isStarting || recorder.isStopping {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 45)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
    }

    private var formatToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(MacRecordingFormat.allCases) { format in
                    recorderSegment(
                        format.label,
                        isActive: recorder.format == format,
                        isEnabled: canChangeFormat) {
                            recorder.format = format
                        }
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 22)

            HStack(spacing: 4) {
                ForEach([128, 192, 320], id: \.self) { bitrate in
                    recorderSegment(
                        "\(bitrate)k",
                        isActive: recorder.bitrate == bitrate,
                        isEnabled: canChangeFormat && recorder.format == .mp3) {
                            recorder.bitrate = bitrate
                        }
                }
            }

            Spacer()

            Label("App audio", systemImage: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 14)
        .frame(height: 51)
        .background(Color(hex: 0x263B55).opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
    }

    private func recorderSegment(
        _ label: String,
        isActive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? Color.white.opacity(isActive ? 0.94 : 0.55) : Color.white.opacity(0.25))
                .padding(.horizontal, 11)
                .frame(height: 29)
                .background(
                    isActive ? Color.white.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var recordedSets: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text("RECORDED SETS")
                Text("\(library.sets.count)")
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 4)

            if library.sets.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 64, weight: .thin))
                        .foregroundStyle(Color.white.opacity(0.5))
                    Text("No sets yet")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.72))
                    Text("Choose a source below and hit the power button")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(library.sets.prefix(6))) { set in
                            let fileExtension = URL(
                                fileURLWithPath: set.fileName).pathExtension.lowercased()
                            HStack(spacing: 12) {
                                Text(fileExtension.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(
                                        fileExtension == "wav"
                                            ? themes.selectedTheme.accent
                                            : recorderAccent)
                                    .padding(.horizontal, 7)
                                    .frame(height: 24)
                                    .background(
                                        (fileExtension == "wav"
                                            ? themes.selectedTheme.accent
                                            : recorderAccent).opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: 7))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(set.title)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(formatTime(set.duration))  ·  \(formatSize(set.fileSize))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textDim)
                                }
                                Spacer()
                                Image(systemName: "waveform")
                                    .foregroundStyle(Color.white.opacity(0.28))
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 56)
                            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
                        }
                    }
                }
            }

            if let error = recorder.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 4)
    }

    private var recordingStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)

            Text(recorder.elapsedLabel.count > 5 ? recorder.elapsedLabel : "00:\(recorder.elapsedLabel)")
                .font(.system(size: 52, weight: .ultraLight, design: .monospaced))
                .tracking(2)
                .contentTransition(.numericText())

            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("RECORDING")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.red)
            }
            .padding(.top, 4)

            Text(recorder.selectedSource?.name ?? "App audio")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .padding(.top, 10)

            MacRecorderLiveWaveform(
                levels: recorder.meterHistory,
                color: recorderAccent)
                .frame(height: 132)
                .padding(.top, 18)

            Spacer(minLength: 8)

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
    }

    private var recorderBottomBar: some View {
        HStack(spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule()
                            .fill(recorderAccent)
                            .frame(width: proxy.size.width * CGFloat(recorder.level))
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)

            Picker("App audio", selection: $recorder.selectedPID) {
                if recorder.sources.isEmpty {
                    Text("No audio apps").tag(Int32?.none)
                }
                ForEach(recorder.sources) { source in
                    Text(source.playing ? "\(source.name) ♪" : source.name)
                    .tag(Optional(source.pid))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 175)
            .disabled(recorder.isRecording || recorder.isStarting || recorder.isStopping)

            Button {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    recorder.startRecording(into: library)
                }
            } label: {
                ZStack {
                    if recorder.isStarting || recorder.isStopping {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "power")
                            .font(.system(size: 20, weight: .semibold))
                    }
                }
                .foregroundStyle(recorder.isRecording ? Color.white : recorderAccent)
                .frame(width: 40, height: 40)
                .background(
                    recorder.isRecording ? Color.red : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(
                recorder.isStarting || recorder.isStopping ||
                (!recorder.isRecording && recorder.selectedSource == nil))
            .help(recorder.isRecording ? "Stop and save set" : "Start recording")

            Button {
                Task { await recorder.refreshSources() }
            } label: {
                if recorder.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
            .disabled(recorder.isRefreshing || recorder.isRecording || recorder.isStarting)
            .help("Refresh audio apps")
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.07))
        }
    }

    private var canChangeFormat: Bool {
        !recorder.isRecording && !recorder.isStarting && !recorder.isStopping
    }
}

private struct MacRecorderLiveWaveform: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let count = max(48, levels.count)
            let spacing = size.width / CGFloat(count)
            let centerY = size.height / 2
            var path = Path()

            for index in 0..<count {
                let historyIndex = index - (count - levels.count)
                let level = historyIndex >= 0 && historyIndex < levels.count
                    ? CGFloat(levels[historyIndex])
                    : 0.025
                let x = CGFloat(index) * spacing + spacing / 2
                let height = max(3, level * size.height * 0.86)
                path.move(to: CGPoint(x: x, y: centerY - height / 2))
                path.addLine(to: CGPoint(x: x, y: centerY + height / 2))
            }

            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: max(1.5, spacing * 0.46),
                    lineCap: .round))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
