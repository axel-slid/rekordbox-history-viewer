import AppKit
import Foundation
import SwiftUI

struct MacVolumeApp: Decodable, Identifiable, Hashable {
    let key: String
    let pid: Int32
    let name: String
    let playing: Bool
    var gain: Double
    var muted: Bool
    let active: Bool
    var icon: String?

    var id: String { key }

    var image: NSImage? {
        guard let icon,
              let data = Data(base64Encoded: icon) else { return nil }
        return NSImage(data: data)
    }
}

private struct MacVolumeMixerMessage: Decodable {
    let event: String
    let message: String?
    let device: String?
    let sysvol: Double?
    let sysvolSettable: Bool?
    let apps: [MacVolumeApp]?
}

private enum MacVolumeMixerError: LocalizedError {
    case helperMissing

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The volume mixer engine is missing from Set Player."
        }
    }
}

@MainActor
final class MacVolumeMixer: ObservableObject {
    static let shared = MacVolumeMixer()

    @Published private(set) var apps: [MacVolumeApp] = []
    @Published private(set) var deviceName = "System Output"
    @Published private(set) var systemVolume: Double?
    @Published private(set) var isSystemVolumeSettable = false
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Starting volume mixer…"
    @Published private(set) var errorMessage: String?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var iconCache: [String: String] = [:]

    private init() {}

    func start() {
        if process?.isRunning == true {
            refresh()
            return
        }

        shutdown(clearState: false)
        errorMessage = nil
        status = "Starting volume mixer…"

        do {
            let helperURL = try Self.helperURL()
            let nextProcess = Process()
            let nextInput = Pipe()
            let nextOutput = Pipe()
            let nextError = Pipe()

            nextProcess.executableURL = helperURL
            nextProcess.standardInput = nextInput
            nextProcess.standardOutput = nextOutput
            nextProcess.standardError = nextError

            nextProcess.terminationHandler = { [weak self, weak nextProcess] _ in
                let errorData = nextError.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    guard let self, self.process === nextProcess else { return }
                    self.process = nil
                    self.inputPipe = nil
                    self.outputPipe = nil
                    self.errorPipe = nil
                    self.isRunning = false
                    if !self.status.hasPrefix("Stopped") {
                        self.status = "Volume mixer stopped"
                        if let detail, !detail.isEmpty {
                            self.errorMessage = detail
                        }
                    }
                }
            }

            try nextProcess.run()

            process = nextProcess
            inputPipe = nextInput
            outputPipe = nextOutput
            errorPipe = nextError
            isRunning = true
            status = "Listening for audio…"
            startReading(nextOutput.fileHandleForReading)
            refresh()
        } catch {
            isRunning = false
            status = "Volume mixer unavailable"
            errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        guard process?.isRunning == true else {
            start()
            return
        }
        send(["cmd": "refresh"])
    }

    func gain(for key: String) -> Double {
        apps.first(where: { $0.key == key })?.gain ?? 1
    }

    func setGain(_ gain: Double, for key: String) {
        let clamped = min(max(gain, 0), 1)
        if let index = apps.firstIndex(where: { $0.key == key }) {
            apps[index].gain = clamped
        }
        send(["cmd": "gain", "key": key, "value": clamped])
    }

    func toggleMute(for key: String) {
        guard let index = apps.firstIndex(where: { $0.key == key }) else { return }
        apps[index].muted.toggle()
        send(["cmd": "mute", "key": key, "value": apps[index].muted])
    }

    func setSystemVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        systemVolume = clamped
        send(["cmd": "sysvol", "value": clamped])
    }

    func shutdown() {
        shutdown(clearState: true)
    }

    private func shutdown(clearState: Bool) {
        readerTask?.cancel()
        readerTask = nil

        if let inputPipe {
            try? inputPipe.fileHandleForWriting.close()
        }
        if process?.isRunning == true {
            process?.terminate()
        }
        process?.terminationHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        isRunning = false

        if clearState {
            apps = []
            iconCache = [:]
            status = "Stopped volume mixer"
        }
    }

    private func startReading(_ handle: FileHandle) {
        readerTask?.cancel()
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            var pending = Data()

            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)

                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if !line.isEmpty {
                        await self?.consume(line)
                    }
                }
            }
        }
    }

    private func consume(_ data: Data) {
        guard let message = try? JSONDecoder().decode(
            MacVolumeMixerMessage.self,
            from: data) else { return }

        if message.event == "error" {
            errorMessage = message.message ?? "The volume mixer encountered an error."
            return
        }

        guard message.event == "status" else { return }
        errorMessage = nil

        if let device = message.device {
            deviceName = device
        }
        systemVolume = message.sysvol
        isSystemVolumeSettable = message.sysvolSettable ?? false

        var nextApps = message.apps ?? []
        for index in nextApps.indices {
            if let icon = nextApps[index].icon {
                iconCache[nextApps[index].key] = icon
            } else {
                nextApps[index].icon = iconCache[nextApps[index].key]
            }
        }
        apps = nextApps

        let playing = apps.filter(\.playing)
        if playing.isEmpty {
            status = "Nothing is playing right now"
        } else if playing.count == 1 {
            status = "\(playing[0].name) is playing"
        } else {
            status = "\(playing.count) apps are playing"
        }
    }

    private func send(_ object: [String: Any]) {
        guard let inputPipe,
              process?.isRunning == true,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func helperURL() throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: "mixer", withExtension: nil),
            URL(fileURLWithPath: "/Applications/Sound Mixer.app/Contents/Resources/mixer")
        ]

        guard let url = candidates
            .compactMap({ $0 })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MacVolumeMixerError.helperMissing
        }
        return url
    }
}

struct MacVolumeMixerPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mixer = MacVolumeMixer.shared
    @ObservedObject private var themes = MacThemeStore.shared

    private var mixerAccent: Color { themes.selectedTheme.warm }

    var body: some View {
        VStack(spacing: 0) {
            titlebar

            VStack(spacing: 14) {
                statusBanner
                appList
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            outputBar
        }
        .frame(width: 620, height: 680)
        .background(
            LinearGradient(
                colors: [Theme.panel, Theme.background],
                startPoint: .top,
                endPoint: .bottom))
        .task {
            mixer.start()
        }
    }

    private var titlebar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(mixerAccent)
                Text("Volume Mixer")
                    .font(.system(size: 16, weight: .semibold))
            }

            HStack(spacing: 8) {
                Button {
                    mixer.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh audio apps")

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
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Circle()
                    .fill(mixer.isRunning ? mixerAccent : Color.red)
                    .frame(width: 12, height: 12)
                    .shadow(
                        color: mixer.isRunning ? mixerAccent.opacity(0.55) : .clear,
                        radius: 6)

                Text(mixer.status)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text("\(mixer.apps.count) APPS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }

            if let error = mixer.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
    }

    @ViewBuilder
    private var appList: some View {
        if mixer.apps.isEmpty {
            VStack(spacing: 13) {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 58, weight: .thin))
                    .foregroundStyle(Color.white.opacity(0.45))
                Text("No audio apps")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.72))
                Text("Apps appear here after they open an audio stream")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(mixer.apps) { app in
                        MacVolumeAppRow(
                            app: app,
                            mixer: mixer,
                            accent: mixerAccent)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var outputBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(mixerAccent)
                    .frame(width: 32)

                Slider(
                    value: Binding(
                        get: { mixer.systemVolume ?? 0 },
                        set: { mixer.setSystemVolume($0) }),
                    in: 0...1)
                    .tint(mixerAccent)
                    .disabled(!mixer.isSystemVolumeSettable)

                Text("\(Int(((mixer.systemVolume ?? 0) * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 42, alignment: .trailing)
            }

            HStack {
                Text("SYSTEM OUTPUT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Text(mixer.deviceName)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 86)
        .background(Color.black.opacity(0.28))
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.07))
        }
    }
}

private struct MacVolumeAppRow: View {
    @ObservedObject private var themes = MacThemeStore.shared
    let app: MacVolumeApp
    @ObservedObject var mixer: MacVolumeMixer
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = app.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(app.muted ? "Muted" : (app.playing ? "Playing" : "Silent"))
                    .font(.caption)
                    .foregroundStyle(app.playing && !app.muted ? accent : Theme.textDim)
            }
            .frame(width: 125, alignment: .leading)

            Slider(
                value: Binding(
                    get: { mixer.gain(for: app.key) },
                    set: { mixer.setGain($0, for: app.key) }),
                in: 0...1)
                .tint(accent)
                .disabled(app.muted)

            Text("\(Int((mixer.gain(for: app.key) * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 42, alignment: .trailing)

            Button {
                mixer.toggleMute(for: app.key)
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(app.muted ? Color.red : Color.white.opacity(0.72))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .padding(.horizontal, 13)
        .frame(height: 64)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        .opacity(app.playing || app.muted ? 1 : 0.76)
    }
}
