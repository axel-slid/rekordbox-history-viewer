import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI
import WebKit

struct MacLyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: TimeInterval
    let text: String
}

enum MacLiveLyricsBackdrop: Equatable {
    case albumColor
    case rave
}

private struct MacRavePhrase: Codable, Equatable, Sendable {
    let beat: Int
    let kind: String
    let category: String
}

private struct MacRaveWaveform: Codable, Equatable, Sendable {
    let format: String
    let samplesPerSecond: Double
    let entryCount: Int
    let entriesBase64: String
}

private struct MacRaveBeatGrid: Equatable, Sendable {
    let times: [TimeInterval]
    let beatNumbers: [Int]
}

private struct MacRaveDeckState: Codable, Equatable, Sendable {
    let identity: String
    let position: TimeInterval
    let playbackRate: Double
    let bpm: Double
    let playing: Bool
    let fader: Double
    let bass: Double
    let filter: Double
    let beatTimes: [TimeInterval]
    let beatNumbers: [Int]
    let phrases: [MacRavePhrase]
    let waveform: MacRaveWaveform?

    static let idle = MacRaveDeckState(
        identity: "",
        position: 0,
        playbackRate: 1,
        bpm: 120,
        playing: false,
        fader: 0,
        bass: 0.5,
        filter: 0,
        beatTimes: [],
        beatNumbers: [],
        phrases: [],
        waveform: nil)

    var withoutWaveform: MacRaveDeckState {
        MacRaveDeckState(
            identity: identity,
            position: position,
            playbackRate: playbackRate,
            bpm: bpm,
            playing: playing,
            fader: fader,
            bass: bass,
            filter: filter,
            beatTimes: beatTimes,
            beatNumbers: beatNumbers,
            phrases: phrases,
            waveform: nil)
    }
}

private struct MacRekordboxAnalysis: Equatable, Sendable {
    let beatTimes: [TimeInterval]
    let beatNumbers: [Int]
    let phrases: [MacRavePhrase]
    let waveform: MacRaveWaveform?
}

private enum MacRekordboxAnalysisResult: Sendable {
    case found(MacRekordboxAnalysis)
    case missing
}

private struct MacLiveDeck: Equatable, Sendable {
    let number: Int
    let title: String
    let artist: String
    let position: TimeInterval
    let duration: TimeInterval
    let originalBPM: Double
    let playbackRate: Double
    let channelFader: Double
    let bass: Double
    let filter: Double
    let isPlaying: Bool
    let capturedAt: Date

    var identity: String {
        "\(title.lowercased())::\(artist.lowercased())::\(Int(duration.rounded()))"
    }
}

private struct MacLiveLyricsTheme: Sendable {
    let backgroundRed: Double
    let backgroundGreen: Double
    let backgroundBlue: Double
    let mutedRed: Double
    let mutedGreen: Double
    let mutedBlue: Double

    static let fallback = MacLiveLyricsTheme(
        backgroundRed: 54 / 255,
        backgroundGreen: 42 / 255,
        backgroundBlue: 78 / 255,
        mutedRed: 175 / 255,
        mutedGreen: 145 / 255,
        mutedBlue: 226 / 255)
}

@MainActor
final class MacLiveLyricsStore: ObservableObject {
    static let shared = MacLiveLyricsStore()

    @Published private(set) var lines: [MacLyricLine] = []
    @Published private(set) var lyricsRevision = UUID()
    @Published private(set) var statusMessage = "Open Rekordbox and load a track"
    @Published private(set) var backgroundColor = Color(
        red: MacLiveLyricsTheme.fallback.backgroundRed,
        green: MacLiveLyricsTheme.fallback.backgroundGreen,
        blue: MacLiveLyricsTheme.fallback.backgroundBlue)
    @Published private(set) var mutedColor = Color(
        red: MacLiveLyricsTheme.fallback.mutedRed,
        green: MacLiveLyricsTheme.fallback.mutedGreen,
        blue: MacLiveLyricsTheme.fallback.mutedBlue)
    @Published fileprivate var raveDeckState = MacRaveDeckState.idle

    private var pollingTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var activeDeck: MacLiveDeck?
    private var activeAnalysis: MacRekordboxAnalysis?
    private var activeDeckIndex = -1
    private var deckMotion: [String: (position: TimeInterval, lastMovedAt: Date)] = [:]
    private var lyricsCache: [String: [MacLyricLine]] = [:]
    private var themeCache: [String: MacLiveLyricsTheme] = [:]
    private var analysisCache: [String: MacRekordboxAnalysisResult] = [:]
    private var lyricsPrefetchTasks: [String: Task<Void, Never>] = [:]
    private var bassHeldTargetIdentity: String?
    private var didRequestAccessibility = false

    private init() {}

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollRekordbox()
                let delay: Duration = self?.statusMessage == "Allow Set Player in Accessibility"
                    ? .seconds(2)
                    : .milliseconds(100)
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func activeLineIndex(at date: Date = .now) -> Int {
        guard let deck = activeDeck, !lines.isEmpty else { return -1 }
        let elapsed = deck.isPlaying
            ? max(0, date.timeIntervalSince(deck.capturedAt)) * max(0.1, deck.playbackRate)
            : 0
        let position = min(deck.duration > 0 ? deck.duration : .greatestFiniteMagnitude,
                           deck.position + elapsed)
        return lines.lastIndex(where: { $0.time <= position }) ?? -1
    }

    fileprivate func activeRaveLineIndex(
        at date: Date = .now,
        delay: TimeInterval = 0
    ) -> Int {
        guard let deck = activeDeck, !lines.isEmpty else { return -1 }
        let elapsed = deck.isPlaying
            ? max(0, date.timeIntervalSince(deck.capturedAt)) * max(0.1, deck.playbackRate)
            : 0
        let position = min(
            deck.duration > 0 ? deck.duration : .greatestFiniteMagnitude,
            max(0, deck.position + elapsed - delay))
        guard let index = lines.lastIndex(where: { $0.time <= position }) else {
            return -1
        }

        let line = lines[index]
        let nextTime = lines.indices.contains(index + 1)
            ? lines[index + 1].time
            : .greatestFiniteMagnitude
        let gapToNext = nextTime - line.time

        // LRC lyrics only provide start times. During continuous vocals, keep
        // the line until the next one. Across a real instrumental gap, estimate
        // a natural reading/singing duration and then leave the screen clean.
        let naturalHold = min(
            6.0,
            max(3.2, 2.25 + Double(line.text.count) * 0.055))
        let visibleUntil = gapToNext <= 7.0
            ? nextTime
            : min(nextTime, line.time + naturalHold)
        return position < visibleUntil ? index : -1
    }

    fileprivate func activeRavePhrase(at date: Date = .now) -> MacRavePhrase? {
        guard let deck = activeDeck,
              let analysis = activeAnalysis,
              !analysis.phrases.isEmpty else { return nil }
        let elapsed = deck.isPlaying
            ? max(0, date.timeIntervalSince(deck.capturedAt)) * max(0.1, deck.playbackRate)
            : 0
        let position = max(0, deck.position + elapsed)

        let beatNumber: Int
        if !analysis.beatTimes.isEmpty {
            var low = 0
            var high = analysis.beatTimes.count
            while low < high {
                let middle = (low + high) / 2
                if analysis.beatTimes[middle] <= position {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            beatNumber = max(1, low)
        } else {
            beatNumber = max(
                1,
                Int(floor(position * max(30, deck.originalBPM) / 60)) + 1)
        }

        let anticipatedBeatNumber = beatNumber + 1
        var low = 0
        var high = analysis.phrases.count
        while low < high {
            let middle = (low + high) / 2
            if analysis.phrases[middle].beat <= anticipatedBeatNumber {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return analysis.phrases[max(0, low - 1)]
    }

    private func pollRekordbox() async {
        guard AXIsProcessTrusted() else {
            if !didRequestAccessibility {
                didRequestAccessibility = true
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions(
                    [promptKey: true] as CFDictionary)
            }
            setUnavailable("Allow Set Player in Accessibility")
            return
        }
        didRequestAccessibility = false

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            let bundle = $0.bundleIdentifier?.lowercased() ?? ""
            let name = $0.localizedName?.lowercased() ?? ""
            return bundle.contains("rekordbox") || name == "rekordbox"
        }) else {
            setUnavailable("Open Rekordbox and load a track")
            return
        }

        let pid = app.processIdentifier
        let records = await Task.detached(priority: .userInitiated) {
            MacLiveAXReader.collect(pid: pid)
        }.value
        guard !Task.isCancelled else { return }
        consume(records)
    }

    private func setUnavailable(_ message: String) {
        statusMessage = message
        guard activeDeck != nil || !lines.isEmpty else { return }
        activeDeck = nil
        activeDeckIndex = -1
        activeAnalysis = nil
        raveDeckState = .idle
        lines = []
        lyricsRevision = UUID()
        mediaTask?.cancel()
        analysisTask?.cancel()
    }

    private func consume(_ records: [MacLiveAXRecord]) {
        let capturedAt = Date()
        let titleIndexes = records.indices.filter {
            MacLiveDeckParser.isTrackTitle(records, at: $0)
        }.prefix(4)
        let titlePositions = Array(titleIndexes)
        guard !titlePositions.isEmpty else {
            setUnavailable("Load a track in Rekordbox")
            return
        }

        let faders = records.filter { $0.help?.hasPrefix("Channel Fader:") == true }
        let bassControls = records.filter { $0.help?.hasPrefix("EQ/ISO (Low) knob:") == true }
        let filterControls = records.filter {
            $0.help?.hasPrefix("COLOR Knob (Channel):") == true
        }
        let deckBPMs = records.filter { $0.help?.hasPrefix("Deck BPM display:") == true }

        var decks: [MacLiveDeck] = []
        var visibleMotionKeys = Set<String>()

        for (deckIndex, titleIndex) in titlePositions.enumerated() {
            let nextTitle = deckIndex + 1 < titlePositions.count
                ? titlePositions[deckIndex + 1]
                : min(records.count, titleIndex + 48)
            let slice = Array(records[titleIndex..<nextTitle])
            let title = records[titleIndex].value?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
            let artist = MacLiveDeckParser.artist(in: Array(slice.dropFirst()), title: title)
            let position = max(0, MacLiveDeckParser.clock(in: slice, negative: false) ?? 0)
            let remaining = abs(MacLiveDeckParser.clock(in: slice, negative: true) ?? 0)
            let duration = position + remaining
            let originalBPM = MacLiveDeckParser.originalBPM(in: slice)
            let deckBPM = MacLiveDeckParser.numeric(
                deckIndex < deckBPMs.count ? deckBPMs[deckIndex] : nil,
                fallback: originalBPM)
            let motionKey = "\(deckIndex)::\(title)::\(artist)"
            visibleMotionKeys.insert(motionKey)

            let previous = deckMotion[motionKey]
            let changed = previous.map { abs(position - $0.position) > 0.045 } ?? false
            let lastMovedAt = changed
                ? capturedAt
                : (previous?.lastMovedAt ?? capturedAt.addingTimeInterval(-2))
            deckMotion[motionKey] = (position, lastMovedAt)

            decks.append(MacLiveDeck(
                number: deckIndex + 1,
                title: title,
                artist: artist,
                position: position,
                duration: duration,
                originalBPM: originalBPM,
                playbackRate: originalBPM > 0 && deckBPM > 0 ? deckBPM / originalBPM : 1,
                channelFader: MacLiveDeckParser.numeric(
                    deckIndex < faders.count ? faders[deckIndex] : nil),
                bass: MacLiveDeckParser.numeric(
                    deckIndex < bassControls.count ? bassControls[deckIndex] : nil),
                filter: MacLiveDeckParser.numeric(
                    MacLiveDeckParser.filterControl(
                        in: filterControls,
                        deckIndex: deckIndex,
                        visibleDeckCount: titlePositions.count),
                    fallback: 0.5),
                isPlaying: capturedAt.timeIntervalSince(lastMovedAt) < 0.9,
                capturedAt: capturedAt))
        }

        deckMotion = deckMotion.filter { visibleMotionKeys.contains($0.key) }
        let nextIndex = selectDeck(decks)
        guard decks.indices.contains(nextIndex) else {
            setUnavailable("Load a track in Rekordbox")
            return
        }

        let nextDeck = decks[nextIndex]
        let changedTrack = activeDeck?.identity != nextDeck.identity
        activeDeckIndex = nextIndex
        activeDeck = nextDeck
        if changedTrack {
            loadAnalysis(for: nextDeck)
            loadMedia(for: nextDeck)
        }
        publishRaveState(for: nextDeck)
    }

    private func publishRaveState(for deck: MacLiveDeck) {
        let normalizedFader = min(1, max(0, deck.channelFader / 100))
        let normalizedBass = min(1, max(0, (deck.bass + 50) / 50))
        let normalizedFilter = min(1, max(-1, (deck.filter - 0.5) * 2))
        raveDeckState = MacRaveDeckState(
            identity: deck.identity,
            position: deck.position,
            playbackRate: deck.playbackRate,
            bpm: deck.originalBPM > 0 ? deck.originalBPM : 120,
            playing: deck.isPlaying,
            fader: normalizedFader,
            bass: normalizedBass,
            filter: normalizedFilter,
            beatTimes: activeAnalysis?.beatTimes ?? [],
            beatNumbers: activeAnalysis?.beatNumbers ?? [],
            phrases: activeAnalysis?.phrases ?? [],
            waveform: activeAnalysis?.waveform)
    }

    private func loadAnalysis(for deck: MacLiveDeck) {
        analysisTask?.cancel()
        activeAnalysis = nil

        if let cached = analysisCache[deck.identity] {
            if case .found(let analysis) = cached {
                activeAnalysis = analysis
            }
            return
        }

        let identity = deck.identity
        analysisTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                MacRekordboxAnalysisService.load(for: deck)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.analysisCache[identity] = result
            guard self.activeDeck?.identity == identity else { return }
            if case .found(let analysis) = result {
                self.activeAnalysis = analysis
            } else {
                self.activeAnalysis = nil
            }
            if let activeDeck = self.activeDeck {
                self.publishRaveState(for: activeDeck)
            }
        }
    }

    private func selectDeck(_ decks: [MacLiveDeck]) -> Int {
        guard !decks.isEmpty else { return -1 }
        guard decks.indices.contains(activeDeckIndex) else {
            return decks.indices.dropFirst().reduce(0) { bestIndex, index in
                let best = decks[bestIndex]
                let candidate = decks[index]
                if candidate.channelFader > best.channelFader {
                    return index
                }
                let tiedAtTop = candidate.channelFader >= 99.5
                    && best.channelFader >= 99.5
                    && abs(candidate.channelFader - best.channelFader) < 0.001
                if tiedAtTop, candidate.bass > best.bass {
                    return index
                }
                if candidate.channelFader == best.channelFader,
                   candidate.bass == best.bass,
                   candidate.isPlaying,
                   !best.isPlaying {
                    return index
                }
                return bestIndex
            }
        }

        let current = decks[activeDeckIndex]
        for index in decks.indices where index != activeDeckIndex {
            let candidate = decks[index]

            if bassHeldTargetIdentity == candidate.identity {
                if let cached = lyricsCache[candidate.identity], !cached.isEmpty {
                    bassHeldTargetIdentity = nil
                } else if current.channelFader > 0.001 {
                    prefetchLyrics(for: candidate)
                    return activeDeckIndex
                } else {
                    bassHeldTargetIdentity = nil
                }
            }

            if candidate.channelFader > current.channelFader {
                return index
            }
            let tiedAtTop = candidate.channelFader >= 99.5
                && current.channelFader >= 99.5
                && abs(candidate.channelFader - current.channelFader) < 0.001
            if tiedAtTop, candidate.bass > current.bass {
                if lyricsCache[candidate.identity]?.isEmpty != false,
                   current.channelFader > 0.001 {
                    bassHeldTargetIdentity = candidate.identity
                    prefetchLyrics(for: candidate)
                    return activeDeckIndex
                }
                bassHeldTargetIdentity = nil
                return index
            }
        }
        return activeDeckIndex
    }

    private func prefetchLyrics(for deck: MacLiveDeck) {
        let identity = deck.identity
        guard lyricsCache[identity] == nil,
              lyricsPrefetchTasks[identity] == nil else { return }
        lyricsPrefetchTasks[identity] = Task { [weak self] in
            let prefetched = await MacLiveLyricsService.fetch(
                title: deck.title,
                artist: deck.artist,
                duration: deck.duration)
            guard !Task.isCancelled, let self else { return }
            self.lyricsCache[identity] = prefetched
            self.lyricsPrefetchTasks[identity] = nil
        }
    }

    private func loadMedia(for deck: MacLiveDeck) {
        mediaTask?.cancel()
        let identity = deck.identity
        statusMessage = "Finding lyrics…"

        if let cachedLines = lyricsCache[identity] {
            lines = cachedLines
            lyricsRevision = UUID()
            statusMessage = cachedLines.isEmpty ? "Synced lyrics unavailable" : ""
        } else {
            lines = []
            lyricsRevision = UUID()
        }

        if let cachedTheme = themeCache[identity] {
            apply(cachedTheme)
        }

        mediaTask = Task { [weak self] in
            async let fetchedLyrics = MacLiveLyricsService.fetch(
                title: deck.title,
                artist: deck.artist,
                duration: deck.duration)
            async let fetchedTheme = MacLiveArtworkService.fetchTheme(
                title: deck.title,
                artist: deck.artist,
                duration: deck.duration)

            let (newLines, newTheme) = await (fetchedLyrics, fetchedTheme)
            guard !Task.isCancelled,
                  let self,
                  self.activeDeck?.identity == identity else { return }

            self.lyricsCache[identity] = newLines
            self.lines = newLines
            self.lyricsRevision = UUID()
            self.statusMessage = newLines.isEmpty ? "Synced lyrics unavailable" : ""

            if let newTheme {
                self.themeCache[identity] = newTheme
                self.apply(newTheme)
            }
        }
    }

    private func apply(_ theme: MacLiveLyricsTheme) {
        withAnimation(.easeInOut(duration: 0.55)) {
            backgroundColor = Color(
                red: theme.backgroundRed,
                green: theme.backgroundGreen,
                blue: theme.backgroundBlue)
            mutedColor = Color(
                red: theme.mutedRed,
                green: theme.mutedGreen,
                blue: theme.mutedBlue)
        }
    }
}

private enum MacRaveLyricPresentation: Equatable {
    case impact
    case flow
    case bridge
    case ambient

    init(phrase: MacRavePhrase?, bass: Double) {
        guard let phrase else {
            self = bass >= 0.48 ? .impact : .flow
            return
        }
        let kind = phrase.kind.lowercased()
        if phrase.category == "hype"
            || kind.contains("chorus")
            || kind.contains("up")
            || kind.contains("fill") {
            self = .impact
        } else if kind.contains("bridge") || kind.contains("down") {
            self = .bridge
        } else if kind.contains("intro") || kind.contains("outro") {
            self = .ambient
        } else {
            self = .flow
        }
    }
}

struct MacLiveLyricsView: View {
    @ObservedObject private var store = MacLiveLyricsStore.shared
    @AppStorage("raveLyricsDelay") private var raveLyricsDelay = 0.0
    @State private var activeLineIndex = -1
    @State private var positionedRevision: UUID?
    @State private var isPositioned = false
    @State private var ravePresentation = MacRaveLyricPresentation.flow
    @State private var ravePhraseKey = "fallback"
    @State private var isDelayControlHovered = false

    let backdrop: MacLiveLyricsBackdrop

    init(backdrop: MacLiveLyricsBackdrop = .albumColor) {
        self.backdrop = backdrop
    }

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if backdrop == .rave {
                    MacRaveVisualizerView(state: store.raveDeckState)
                        .ignoresSafeArea()
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                } else {
                    store.backgroundColor
                        .ignoresSafeArea()
                }

                if store.lines.isEmpty,
                   !shouldHideRaveStatus {
                    Text(store.statusMessage)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            backdrop == .rave
                                ? Color.white.opacity(0.78)
                                : store.mutedColor.opacity(0.84))
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.9), radius: 14, y: 7)
                        .padding(48)
                } else if backdrop == .rave {
                    raveLyrics(
                        fontSize: min(94, max(52, geometry.size.width * 0.062)))
                } else {
                    lyrics(
                        availableHeight: geometry.size.height,
                        fontSize: min(86, max(48, geometry.size.width * 0.057)))
                }

                if backdrop == .rave {
                    raveDelayControls
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomLeading)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .background(MacLiveLyricsWindowConfiguration())
        .onAppear {
            store.start()
        }
        .onDisappear {
            store.stop()
        }
    }

    private var shouldHideRaveStatus: Bool {
        guard backdrop == .rave else { return false }
        return store.statusMessage == "Finding lyrics…"
            || store.statusMessage == "Synced lyrics unavailable"
    }

    private var raveDelayControls: some View {
        HStack(spacing: 2) {
            raveDelayButton(
                symbol: "−",
                accessibilityLabel: "Decrease lyric delay",
                help: "Show lyrics 0.1 second earlier",
                amount: -0.1)
            raveDelayButton(
                symbol: "+",
                accessibilityLabel: "Increase lyric delay",
                help: "Show lyrics 0.1 second later",
                amount: 0.1)
        }
        .padding(3)
        .background(.black.opacity(isDelayControlHovered ? 0.48 : 0.18), in: Capsule())
        .opacity(isDelayControlHovered ? 0.95 : 0.42)
        .padding(12)
        .onHover { isDelayControlHovered = $0 }
    }

    private func raveDelayButton(
        symbol: String,
        accessibilityLabel: String,
        help: String,
        amount: Double
    ) -> some View {
        Button {
            let adjusted = ((raveLyricsDelay + amount) * 10).rounded() / 10
            raveLyricsDelay = min(5, max(-5, adjusted))
        } label: {
            Text(symbol)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(String(format: "%+.1f seconds", raveLyricsDelay))
        .help(help)
    }

    private func raveLyrics(fontSize: CGFloat) -> some View {
        ZStack {
            switch ravePresentation {
            case .impact:
                raveImpactLyrics(fontSize: fontSize)
            case .flow:
                raveFlowLyrics(fontSize: fontSize)
            case .bridge:
                raveBridgeLyrics(fontSize: fontSize)
            case .ambient:
                raveAmbientLyrics(fontSize: fontSize)
            }
        }
        .padding(.horizontal, max(60, fontSize * 0.82))
        .frame(maxWidth: 1_440, maxHeight: .infinity)
        .onAppear {
            refreshRaveLyrics(at: .now, animate: false)
        }
        .onChange(of: store.lyricsRevision) { _, _ in
            refreshRaveLyrics(at: .now, animate: false)
        }
        .onChange(of: raveLyricsDelay) { _, _ in
            refreshRaveLyrics(at: .now, animate: false)
        }
        .onReceive(ticker) { date in
            refreshRaveLyrics(at: date, animate: true)
        }
    }

    private func raveImpactLyrics(fontSize: CGFloat) -> some View {
        ZStack {
            if let line = lyric(at: activeLineIndex) {
                raveText(
                    line.text,
                    size: fontSize * 1.13,
                    opacity: 1,
                    weight: .heavy)
                    .id("impact-\(ravePhraseKey)-\(line.id)")
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.68).combined(with: .opacity),
                            removal: .scale(scale: 1.18).combined(with: .opacity)))
            }
        }
        .animation(
            .spring(response: 0.38, dampingFraction: 0.68),
            value: activeLineIndex)
    }

    private func raveFlowLyrics(fontSize: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: fontSize * 0.4) {
                    Color.clear
                        .frame(height: fontSize * 1.9)

                    ForEach(store.lines) { line in
                        let distance = abs(line.id - activeLineIndex)
                        raveText(
                            line.text,
                            size: fontSize * (distance == 0 ? 0.94 : 0.78),
                            opacity: distance == 0
                                ? 1
                                : (distance == 1 ? 0.72 : 0.42),
                            weight: distance == 0 ? .heavy : .bold)
                            .scaleEffect(distance == 0 ? 1 : 0.97)
                            .id(line.id)
                    }

                    Color.clear
                        .frame(height: fontSize * 1.9)
                }
            }
            .frame(maxHeight: fontSize * 4.8)
            .onAppear {
                DispatchQueue.main.async {
                    positionRaveLyrics(
                        proxy,
                        anchor: .center,
                        animated: false)
                }
            }
            .onChange(of: activeLineIndex) { _, _ in
                positionRaveLyrics(
                    proxy,
                    anchor: .center,
                    animated: true)
            }
            .onChange(of: store.lyricsRevision) { _, _ in
                DispatchQueue.main.async {
                    positionRaveLyrics(
                        proxy,
                        anchor: .center,
                        animated: false)
                }
            }
        }
        .animation(.easeInOut(duration: 0.24), value: activeLineIndex)
    }

    private func raveBridgeLyrics(fontSize: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: fontSize * 0.48) {
                    ForEach(store.lines) { line in
                        let isActive = line.id == activeLineIndex
                        raveText(
                            line.text,
                            size: fontSize * (isActive ? 1.02 : 0.78),
                            opacity: isActive ? 1 : 0.5,
                            weight: isActive ? .heavy : .bold)
                            .scaleEffect(isActive ? 1 : 0.97)
                            .id(line.id)
                    }

                    Color.clear
                        .frame(height: fontSize * 2.2)
                }
            }
            .frame(maxHeight: fontSize * 3.15)
            .onAppear {
                DispatchQueue.main.async {
                    positionRaveLyrics(
                        proxy,
                        anchor: .top,
                        animated: false)
                }
            }
            .onChange(of: activeLineIndex) { _, _ in
                positionRaveLyrics(
                    proxy,
                    anchor: .top,
                    animated: true)
            }
            .onChange(of: store.lyricsRevision) { _, _ in
                DispatchQueue.main.async {
                    positionRaveLyrics(
                        proxy,
                        anchor: .top,
                        animated: false)
                }
            }
        }
        .animation(.easeInOut(duration: 0.24), value: activeLineIndex)
    }

    private func raveAmbientLyrics(fontSize: CGFloat) -> some View {
        VStack(spacing: fontSize * 0.55) {
            ForEach(visibleLines(before: 0, after: 1)) { line in
                let isActive = line.id == activeLineIndex
                raveText(
                    line.text,
                    size: fontSize * (isActive ? 0.98 : 0.72),
                    opacity: isActive ? 0.94 : 0.38,
                    weight: isActive ? .bold : .semibold)
                    .scaleEffect(isActive ? 1 : 0.94)
            }
        }
        .id("ambient-\(ravePhraseKey)-\(activeLineIndex)")
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.easeInOut(duration: 0.72), value: activeLineIndex)
    }

    private func raveText(
        _ text: String,
        size: CGFloat,
        opacity: Double,
        weight: Font.Weight
    ) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .rounded))
            .tracking(-size * 0.037)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.white.opacity(opacity))
            .shadow(color: .black.opacity(0.9), radius: 18, y: 10)
            .shadow(color: .black.opacity(0.76), radius: 3)
            .frame(maxWidth: 1_320)
    }

    private func visibleLines(before: Int, after: Int) -> [MacLyricLine] {
        guard activeLineIndex >= 0, !store.lines.isEmpty else { return [] }
        let center = min(max(activeLineIndex, 0), store.lines.count - 1)
        let lower = max(0, center - before)
        let upper = min(store.lines.count - 1, center + after)
        return Array(store.lines[lower...upper])
    }

    private func lyric(at index: Int) -> MacLyricLine? {
        store.lines.indices.contains(index) ? store.lines[index] : nil
    }

    private func positionRaveLyrics(
        _ proxy: ScrollViewProxy,
        anchor: UnitPoint,
        animated: Bool
    ) {
        guard activeLineIndex >= 0,
              store.lines.indices.contains(activeLineIndex) else { return }
        let update = {
            proxy.scrollTo(activeLineIndex, anchor: anchor)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.34), update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
    }

    private func refreshRaveLyrics(at date: Date, animate: Bool) {
        let nextIndex = store.activeRaveLineIndex(
            at: date,
            delay: raveLyricsDelay)
        let phrase = store.activeRavePhrase(at: date)
        let nextPresentation = MacRaveLyricPresentation(
            phrase: phrase,
            bass: store.raveDeckState.bass)
        let nextPhraseKey = phrase.map { "\($0.beat)-\($0.kind)" } ?? "fallback"
        guard nextIndex != activeLineIndex
                || nextPresentation != ravePresentation
                || nextPhraseKey != ravePhraseKey else { return }

        let update = {
            activeLineIndex = nextIndex
            ravePresentation = nextPresentation
            ravePhraseKey = nextPhraseKey
        }
        if animate {
            withAnimation(.easeInOut(duration: 0.34), update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
    }

    private func lyrics(availableHeight: CGFloat, fontSize: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: max(28, fontSize * 0.43)) {
                    Color.clear.frame(height: max(120, availableHeight * 0.46))

                    ForEach(store.lines) { line in
                        lyricLine(line, fontSize: fontSize)
                            .id(line.id)
                    }

                    Color.clear.frame(height: max(120, availableHeight * 0.46))
                }
                .padding(.horizontal, max(56, fontSize))
            }
            .opacity(isPositioned ? 1 : 0)
            .onChange(of: store.lyricsRevision) { _, revision in
                positionImmediately(revision: revision, proxy: proxy)
            }
            .onReceive(ticker) { date in
                let nextIndex = store.activeLineIndex(at: date)
                guard positionedRevision == store.lyricsRevision else {
                    positionImmediately(revision: store.lyricsRevision, proxy: proxy)
                    return
                }
                guard nextIndex != activeLineIndex else { return }
                activeLineIndex = nextIndex
                guard nextIndex >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.38)) {
                    proxy.scrollTo(nextIndex, anchor: .center)
                }
            }
        }
    }

    private func lyricLine(_ line: MacLyricLine, fontSize: CGFloat) -> some View {
        let distance = activeLineIndex < 0 ? Int.max : abs(line.id - activeLineIndex)
        let isActive = distance == 0
        let opacity: Double = {
            switch distance {
            case 0: return 1
            case 1: return 0.86
            case 2: return 0.7
            default: return 0.57
            }
        }()

        let inactiveColor = backdrop == .rave ? Color.white : store.mutedColor

        return Text(line.text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .tracking(-fontSize * 0.035)
            .multilineTextAlignment(.center)
            .foregroundStyle(isActive ? Color.white : inactiveColor.opacity(opacity))
            .shadow(color: .black.opacity(isActive ? 0.82 : 0.58),
                    radius: isActive ? 18 : 10,
                    y: isActive ? 10 : 5)
            .shadow(color: .black.opacity(backdrop == .rave ? 0.68 : 0),
                    radius: 3)
            .scaleEffect(isActive ? 1 : 0.965)
            .frame(maxWidth: 1_300)
            .animation(.easeInOut(duration: 0.28), value: activeLineIndex)
    }

    private func positionImmediately(revision: UUID, proxy: ScrollViewProxy) {
        isPositioned = false
        positionedRevision = revision
        let nextIndex = store.activeLineIndex()
        activeLineIndex = nextIndex
        DispatchQueue.main.async {
            if nextIndex >= 0 {
                proxy.scrollTo(nextIndex, anchor: .center)
            }
            isPositioned = true
        }
    }
}

private struct MacLiveLyricsWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowProbeView {
        WindowProbeView()
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        view.configureWindow()
    }

    final class WindowProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            Self.configure(window)

            // SwiftUI can finish applying its scene defaults after the
            // representable is attached. Re-apply once that pass completes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak window] in
                guard let window else { return }
                Self.configure(window)
            }
        }

        private static func configure(_ window: NSWindow) {
            window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }
}

private struct MacRaveVisualizerView: NSViewRepresentable {
    let state: MacRaveDeckState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassthroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = PassthroughWebView(
            frame: .zero,
            configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.latestState = state

        if let resourceDirectory = Bundle.main.resourceURL,
           let document = Bundle.main.url(
                forResource: "index",
                withExtension: "html") {
            webView.loadFileURL(document, allowingReadAccessTo: resourceDirectory)
        }
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        context.coordinator.latestState = state
        context.coordinator.sendLatestState()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var latestState = MacRaveDeckState.idle
        private var isReady = false
        private var sentWaveformKey = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            sentWaveformKey = ""
            sendLatestState()
        }

        func sendLatestState() {
            guard isReady,
                  let webView else { return }
            let waveformKey = latestState.waveform.map {
                "\(latestState.identity)::\($0.format)::\($0.entryCount)"
            } ?? ""
            let shouldSendWaveform = !waveformKey.isEmpty
                && waveformKey != sentWaveformKey
            let outgoingState = shouldSendWaveform
                ? latestState
                : latestState.withoutWaveform
            guard let data = try? JSONEncoder().encode(outgoingState),
                  let payload = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.setRekordboxState(\(payload));")
            if shouldSendWaveform {
                sentWaveformKey = waveformKey
            }
        }
    }

    final class PassthroughWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private struct MacLiveAXRecord: Sendable {
    let role: String
    let title: String?
    let value: String?
    let help: String?
    let height: Double?
}

private enum MacLiveAXReader {
    static func collect(pid: pid_t) -> [MacLiveAXRecord] {
        let root = AXUIElementCreateApplication(pid)
        var records: [MacLiveAXRecord] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0

        while cursor < queue.count, records.count < 2_500 {
            let (element, depth) = queue[cursor]
            cursor += 1

            records.append(MacLiveAXRecord(
                role: string(element, kAXRoleAttribute as CFString) ?? "",
                title: string(element, kAXTitleAttribute as CFString),
                value: string(element, kAXValueAttribute as CFString),
                help: string(element, kAXHelpAttribute as CFString),
                height: size(element).map { Double($0.height) }))

            if depth < 14 {
                queue.append(contentsOf: children(element).map { ($0, depth + 1) })
            }
        }
        return records
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: CFString) -> String? {
        guard let raw = attribute(element, name) else { return nil }
        if let value = raw as? String { return value }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        guard let raw = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }
}

private enum MacLiveDeckParser {
    static func isTrackTitle(_ records: [MacLiveAXRecord], at index: Int) -> Bool {
        let record = records[index]
        guard record.role == "AXStaticText",
              let value = record.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              (record.help ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (record.height ?? 0) >= 15 else { return false }
        let upperBound = min(records.count, index + 3)
        return records[(index + 1)..<upperBound].contains { $0.role == "AXImage" }
    }

    static func artist(in records: [MacLiveAXRecord], title: String) -> String {
        for record in records
            where record.role == "AXStaticText"
                && (record.help ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty {
            let value = record.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty,
                  value != title,
                  value.range(of: #"^-?\d+:\d{2}$"#, options: .regularExpression) == nil,
                  value.range(of: #"^\.\d+$"#, options: .regularExpression) == nil,
                  value.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) == nil,
                  (record.height ?? 0) >= 12 else { continue }
            return value
        }
        return ""
    }

    static func clock(in records: [MacLiveAXRecord], negative: Bool) -> TimeInterval? {
        for index in records.indices {
            let value = records[index].value?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
            guard value.hasPrefix("-") == negative,
                  value.range(of: #"^-?\d+:\d{2}$"#, options: .regularExpression) != nil else {
                continue
            }
            let fraction: String
            if records.indices.contains(index + 1),
               let next = records[index + 1].value,
               next.range(of: #"^\.\d+$"#, options: .regularExpression) != nil {
                fraction = next
            } else {
                fraction = ""
            }
            return parseClock(value, fraction: fraction)
        }
        return nil
    }

    static func originalBPM(in records: [MacLiveAXRecord]) -> Double {
        for record in records
            where record.role == "AXStaticText"
                && (record.help ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty {
            let value = record.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.range(of: #"^\d{2,3}\.\d{2}$"#, options: .regularExpression) != nil {
                return Double(value) ?? 0
            }
        }
        return 0
    }

    static func numeric(_ record: MacLiveAXRecord?, fallback: Double = 0) -> Double {
        guard let value = record?.value, let number = Double(value) else { return fallback }
        return number
    }

    static func filterControl(
        in controls: [MacLiveAXRecord],
        deckIndex: Int,
        visibleDeckCount: Int
    ) -> MacLiveAXRecord? {
        // Rekordbox exposes all four COLOR knobs in 3, 1, 2, 4 order even
        // in its two-deck layout. The two visible decks are therefore the
        // middle pair. Four-deck layouts expose titles in the same order as
        // the controls, so their indices can be used directly.
        let controlIndex = controls.count >= 4 && visibleDeckCount <= 2
            ? deckIndex + 1
            : deckIndex
        return controls.indices.contains(controlIndex)
            ? controls[controlIndex]
            : nil
    }

    private static func parseClock(_ value: String, fraction: String) -> TimeInterval? {
        let sign: Double = value.hasPrefix("-") ? -1 : 1
        let clean = value.replacingOccurrences(of: "-", with: "")
        let parts = clean.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return sign * (minutes * 60 + seconds + (Double("0\(fraction)") ?? 0))
    }
}

private struct MacRekordboxAnalysisCandidate: Decodable {
    let title: String
    let artist: String
    let bpm: Double?
    let duration: Double?
    let analysisPath: String
    let metadataMatch: Int
    let updatedRank: Double
}

private enum MacRekordboxAnalysisService {
    private static let databaseKey =
        "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497"
    private static let phraseMask: [UInt8] = [
        0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2,
        0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1
    ]

    static func load(for deck: MacLiveDeck) -> MacRekordboxAnalysisResult {
        guard let candidate = findCandidate(for: deck),
              let dataURL = analysisURL(for: candidate.analysisPath),
              let beatData = try? Data(contentsOf: dataURL) else {
            return .missing
        }

        let beatGrid = parseBeatGrid(beatData)
        let extendedURL = dataURL.deletingPathExtension().appendingPathExtension("EXT")
        let extendedData = try? Data(contentsOf: extendedURL)
        let phrases = extendedData.map(parsePhrases) ?? []
        let waveform = extendedData.flatMap(parseDetailedWaveform)
        guard !beatGrid.times.isEmpty || !phrases.isEmpty || waveform != nil else {
            return .missing
        }
        return .found(MacRekordboxAnalysis(
            beatTimes: beatGrid.times,
            beatNumbers: beatGrid.beatNumbers,
            phrases: phrases,
            waveform: waveform))
    }

    private static func findCandidate(
        for deck: MacLiveDeck
    ) -> MacRekordboxAnalysisCandidate? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let databaseURL = home.appendingPathComponent(
            "Library/Pioneer/rekordbox/master.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        let sqlCipherCandidates = [
            "/opt/homebrew/bin/sqlcipher",
            "/usr/local/bin/sqlcipher",
            "/opt/local/bin/sqlcipher"
        ]
        guard let sqlCipher = sqlCipherCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let strippedTitle = MacLiveLyricsService.stripFeature(deck.title)
        let needle = (strippedTitle.isEmpty ? deck.title : strippedTitle)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let escapedNeedle = sqlEscape(needle)
        let targetDuration = Int(deck.duration.rounded())
        let targetBPM = Int((deck.originalBPM * 100).rounded())

        let query = """
        SELECT
          COALESCE(NULLIF(c.Title, ''), NULLIF(c.SrcTitle, ''), '') AS title,
          COALESCE(NULLIF(a.Name, ''), NULLIF(c.SrcArtistName, ''), '') AS artist,
          CASE WHEN c.BPM IS NULL OR c.BPM = 0 THEN NULL ELSE c.BPM / 100.0 END AS bpm,
          COALESCE(c.Length, c.SrcLength) AS duration,
          COALESCE(c.AnalysisDataPath, '') AS analysisPath,
          CASE
            WHEN lower(COALESCE(NULLIF(c.Title, ''), NULLIF(c.SrcTitle, ''), ''))
                 LIKE lower('%\(escapedNeedle)%')
            THEN 1 ELSE 0
          END AS metadataMatch,
          COALESCE(julianday(c.updated_at), 0) AS updatedRank
        FROM djmdContent c
          LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
        WHERE COALESCE(c.rb_local_deleted, 0) = 0
          AND COALESCE(c.AnalysisDataPath, '') <> ''
          AND (
            lower(COALESCE(NULLIF(c.Title, ''), NULLIF(c.SrcTitle, ''), ''))
                LIKE lower('%\(escapedNeedle)%')
            OR (
              COALESCE(NULLIF(c.Title, ''), NULLIF(c.SrcTitle, ''), '') = ''
              AND ABS(COALESCE(c.Length, c.SrcLength, 0) - \(targetDuration)) <= 3
              AND ABS(COALESCE(c.BPM, 0) - \(targetBPM)) <= 40
            )
          )
        ORDER BY metadataMatch DESC,
                 CASE WHEN metadataMatch = 0 THEN c.updated_at END DESC,
                 ABS(COALESCE(c.Length, c.SrcLength, 0) - \(targetDuration))
        LIMIT 80;
        """

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: sqlCipher)
        process.arguments = [
            "-readonly",
            "-json",
            "-cmd", "PRAGMA key='\(databaseKey)';",
            databaseURL.path,
            query
        ]
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let candidates = decodeCandidates(data),
              !candidates.isEmpty else { return nil }

        let metadataCandidates = candidates.filter { $0.metadataMatch == 1 }
        if !metadataCandidates.isEmpty {
            return metadataCandidates.max {
                candidateScore($0, deck: deck) < candidateScore($1, deck: deck)
            }
        }

        // Streaming-service rows deliberately omit their title and artist.
        // Rekordbox updates the matching row when it loads the deck, so among
        // the tight BPM/duration matches the newest analysis is the live track.
        return candidates.max {
            if abs($0.updatedRank - $1.updatedRank) > 0.000_001 {
                return $0.updatedRank < $1.updatedRank
            }
            return candidateScore($0, deck: deck) < candidateScore($1, deck: deck)
        }
    }

    private static func decodeCandidates(
        _ data: Data
    ) -> [MacRekordboxAnalysisCandidate]? {
        let decoder = JSONDecoder()
        if let firstNewline = data.firstIndex(of: 10) {
            let payload = Data(data[data.index(after: firstNewline)...])
            if let decoded = try? decoder.decode(
                [MacRekordboxAnalysisCandidate].self,
                from: payload) {
                return decoded
            }
        }
        if let decoded = try? decoder.decode(
            [MacRekordboxAnalysisCandidate].self,
            from: data) {
            return decoded
        }
        for line in data.split(separator: 10).reversed() {
            if let decoded = try? decoder.decode(
                [MacRekordboxAnalysisCandidate].self,
                from: Data(line)) {
                return decoded
            }
        }
        return nil
    }

    private static func candidateScore(
        _ candidate: MacRekordboxAnalysisCandidate,
        deck: MacLiveDeck
    ) -> Double {
        let durationDelta = deck.duration > 0
            ? abs((candidate.duration ?? deck.duration) - deck.duration)
            : 0
        let bpmDelta = deck.originalBPM > 0
            ? abs((candidate.bpm ?? deck.originalBPM) - deck.originalBPM)
            : 0
        return MacLiveLyricsService.similarity(candidate.title, deck.title) * 6
            + MacLiveLyricsService.similarity(candidate.artist, deck.artist) * 3
            + max(0, 3 - durationDelta / 4)
            + max(0, 1 - bpmDelta / 2)
    }

    private static func analysisURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let direct = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }

        let relative = path.drop(while: { $0 == "/" })
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Pioneer/rekordbox/share")
        let local = root.appendingPathComponent(String(relative))
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private static func parseBeatGrid(_ data: Data) -> MacRaveBeatGrid {
        guard let headerLength = data.bigEndianUInt32(at: 4) else {
            return MacRaveBeatGrid(times: [], beatNumbers: [])
        }
        var cursor = Int(headerLength)
        var times: [TimeInterval] = []
        var beatNumbers: [Int] = []

        while cursor + 12 <= data.count {
            guard let tagLengthValue = data.bigEndianUInt32(at: cursor + 8) else { break }
            let tagLength = Int(tagLengthValue)
            guard tagLength >= 12, cursor + tagLength <= data.count else { break }
            let fourCC = String(
                data: data[cursor..<(cursor + 4)],
                encoding: .ascii)

            if fourCC == "PQTZ",
               let countValue = data.bigEndianUInt32(at: cursor + 20) {
                let count = Int(countValue)
                let entriesStart = cursor + 24
                times.reserveCapacity(count)
                beatNumbers.reserveCapacity(count)
                for index in 0..<count {
                    let entry = entriesStart + index * 8
                    guard entry + 8 <= cursor + tagLength,
                          let beatNumber = data.bigEndianUInt16(at: entry),
                          let milliseconds = data.bigEndianUInt32(at: entry + 4) else {
                        break
                    }
                    times.append(Double(milliseconds) / 1_000)
                    beatNumbers.append(Int(beatNumber))
                }
                if !times.isEmpty {
                    return MacRaveBeatGrid(
                        times: times,
                        beatNumbers: beatNumbers)
                }
            }
            cursor += tagLength
        }
        return MacRaveBeatGrid(times: times, beatNumbers: beatNumbers)
    }

    private static func parsePhrases(_ data: Data) -> [MacRavePhrase] {
        guard let headerLength = data.bigEndianUInt32(at: 4) else { return [] }
        var cursor = Int(headerLength)

        while cursor + 12 <= data.count {
            guard let tagLengthValue = data.bigEndianUInt32(at: cursor + 8) else { break }
            let tagLength = Int(tagLengthValue)
            guard tagLength >= 12, cursor + tagLength <= data.count else { break }
            let fourCC = String(
                data: data[cursor..<(cursor + 4)],
                encoding: .ascii)
            if fourCC == "PSSI", tagLength >= 32 {
                return parsePhraseTag(Data(data[cursor..<(cursor + tagLength)]))
            }
            cursor += tagLength
        }
        return []
    }

    private static func parseDetailedWaveform(_ data: Data) -> MacRaveWaveform? {
        guard let headerLength = data.bigEndianUInt32(at: 4) else { return nil }
        var cursor = Int(headerLength)
        var monochromeFallback: MacRaveWaveform?

        while cursor + 12 <= data.count {
            guard let tagLengthValue = data.bigEndianUInt32(at: cursor + 8) else { break }
            let tagLength = Int(tagLengthValue)
            guard tagLength >= 12, cursor + tagLength <= data.count else { break }
            let fourCC = String(
                data: data[cursor..<(cursor + 4)],
                encoding: .ascii)

            if (fourCC == "PWV5" || fourCC == "PWV3"),
               let tagHeaderValue = data.bigEndianUInt32(at: cursor + 4),
               let entrySizeValue = data.bigEndianUInt32(at: cursor + 12),
               let entryCountValue = data.bigEndianUInt32(at: cursor + 16) {
                let tagHeader = Int(tagHeaderValue)
                let entrySize = Int(entrySizeValue)
                let entryCount = Int(entryCountValue)
                let expectedEntrySize = fourCC == "PWV5" ? 2 : 1
                let entriesStart = cursor + tagHeader
                let entriesLength = entrySize * entryCount
                guard tagHeader >= 20,
                      entrySize == expectedEntrySize,
                      entryCount > 0,
                      entriesLength > 0,
                      entriesStart + entriesLength <= cursor + tagLength else {
                    cursor += tagLength
                    continue
                }

                let rawRate = data.bigEndianUInt32(at: cursor + 20) ?? (150 << 16)
                let rate = Double(max(1, rawRate >> 16))
                let entries = Data(
                    data[entriesStart..<(entriesStart + entriesLength)])
                let waveform = MacRaveWaveform(
                    format: fourCC?.lowercased() ?? "",
                    samplesPerSecond: rate,
                    entryCount: entryCount,
                    entriesBase64: entries.base64EncodedString())
                if fourCC == "PWV5" {
                    return waveform
                }
                monochromeFallback = waveform
            }
            cursor += tagLength
        }
        return monochromeFallback
    }

    private static func parsePhraseTag(_ tagData: Data) -> [MacRavePhrase] {
        var bytes = [UInt8](tagData)
        guard bytes.count >= 32,
              let entryCount = bytes.bigEndianUInt16(at: 16) else { return [] }
        let count = Int(entryCount)

        if let rawMood = bytes.bigEndianUInt16(at: 18), rawMood > 20 {
            for index in 18..<bytes.count {
                let mask = UInt8(
                    (Int(phraseMask[(index - 18) % phraseMask.count]) + count) & 0xff)
                bytes[index] ^= mask
            }
        }

        guard let moodValue = bytes.bigEndianUInt16(at: 18) else { return [] }
        let mood = Int(moodValue)
        var phrases: [MacRavePhrase] = []
        phrases.reserveCapacity(count + 4)

        for index in 0..<count {
            let offset = 32 + index * 24
            guard offset + 24 <= bytes.count,
                  let beatValue = bytes.bigEndianUInt16(at: offset + 2),
                  let kindValue = bytes.bigEndianUInt16(at: offset + 4) else { break }
            let beat = Int(beatValue)
            let kind = phraseLabel(
                mood: mood,
                kind: Int(kindValue),
                k1: bytes[offset + 7],
                k2: bytes[offset + 9],
                k3: bytes[offset + 19])
            phrases.append(MacRavePhrase(
                beat: beat,
                kind: kind,
                category: phraseCategory(kind)))

            if bytes[offset + 21] != 0,
               let fillValue = bytes.bigEndianUInt16(at: offset + 22) {
                let fillBeat = Int(fillValue)
                if fillBeat > beat {
                    phrases.append(MacRavePhrase(
                        beat: fillBeat,
                        kind: "Fill",
                        category: "hype"))
                }
            }
        }

        return phrases
            .filter { $0.beat > 0 }
            .sorted { left, right in
                left.beat == right.beat
                    ? left.kind < right.kind
                    : left.beat < right.beat
            }
    }

    private static func phraseLabel(
        mood: Int,
        kind: Int,
        k1: UInt8,
        k2: UInt8,
        k3: UInt8
    ) -> String {
        if mood == 1 {
            switch kind {
            case 1: return k1 == 1 ? "Intro 1" : "Intro 2"
            case 2:
                if k2 == 1 { return "Up 3" }
                return k3 == 1 ? "Up 2" : "Up 1"
            case 3: return "Down"
            case 5: return k1 == 1 ? "Chorus 1" : "Chorus 2"
            case 6: return k1 == 1 ? "Outro 1" : "Outro 2"
            default: return "Phrase \(kind)"
            }
        }

        if mood == 2 {
            switch kind {
            case 1: return "Intro"
            case 2...7: return "Verse \(kind - 1)"
            case 8: return "Bridge"
            case 9: return "Chorus"
            case 10: return "Outro"
            default: return "Phrase \(kind)"
            }
        }

        switch kind {
        case 1: return "Intro"
        case 2...4: return "Verse 1"
        case 5...7: return "Verse 2"
        case 8: return "Bridge"
        case 9: return "Chorus"
        case 10: return "Outro"
        default: return "Phrase \(kind)"
        }
    }

    private static func phraseCategory(_ label: String) -> String {
        let lower = label.lowercased()
        return lower.contains("chorus")
            || lower.contains("up")
            || lower.contains("fill")
            ? "hype"
            : "flow"
    }

    private static func sqlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private extension Data {
    func bigEndianUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { raw -> UInt16 in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
    }

    func bigEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { raw -> UInt32 in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }
}

private extension Array where Element == UInt8 {
    func bigEndianUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
}

private struct MacLRCLIBCandidate: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let syncedLyrics: String?
}

private enum MacLiveLyricsService {
    static func fetch(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> [MacLyricLine] {
        do {
            var candidates = try await search(title: title, artist: artist)
            let stripped = stripFeature(title)
            if candidates.isEmpty, stripped != title {
                candidates = try await search(title: stripped, artist: artist)
            }
            let match = candidates
                .filter { !($0.syncedLyrics ?? "").isEmpty }
                .max { score($0, title: title, artist: artist, duration: duration)
                    < score($1, title: title, artist: artist, duration: duration) }
            return parseLRC(match?.syncedLyrics ?? "")
        } catch {
            return []
        }
    }

    private static func search(title: String, artist: String) async throws
        -> [MacLRCLIBCandidate] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SetPlayerLiveLyrics/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([MacLRCLIBCandidate].self, from: data)
    }

    private static func score(
        _ candidate: MacLRCLIBCandidate,
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> Double {
        let titleScore = similarity(candidate.trackName ?? "", title) * 5
        let artistScore = similarity(candidate.artistName ?? "", artist) * 3
        let durationDelta = duration > 0
            ? abs((candidate.duration ?? duration) - duration)
            : 0
        return titleScore + artistScore + max(0, 2 - durationDelta / 5) + 2
    }

    private static func parseLRC(_ source: String) -> [MacLyricLine] {
        guard !source.isEmpty else { return [] }
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        let offsetExpression = try! NSRegularExpression(
            pattern: #"(?im)^\[offset:([+-]?\d+)\]"#)
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var offset: Double = 0
        if let match = offsetExpression.firstMatch(in: source, range: sourceRange),
           let range = Range(match.range(at: 1), in: source) {
            offset = (Double(source[range]) ?? 0) / 1_000
        }

        var timed: [(TimeInterval, String)] = []
        for rawLine in source.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = timestamp.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }
            let text = timestamp.stringByReplacingMatches(
                in: rawLine,
                range: range,
                withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(rawLine[minuteRange]),
                      let seconds = Double(rawLine[secondRange]) else { continue }
                timed.append((minutes * 60 + seconds + offset, text))
            }
        }

        return timed.sorted { $0.0 < $1.0 }.enumerated().map {
            MacLyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1)
        }
    }

    fileprivate static func stripFeature(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\s*[\[(](?:feat(?:uring)?|ft)\.?\s+.*?[\])]\s*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func similarity(_ left: String, _ right: String) -> Double {
        let leftTokens = Set(normalize(left).split(separator: " ").map(String.init))
        let rightTokens = Set(normalize(right).split(separator: " ").map(String.init))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        return Double(leftTokens.intersection(rightTokens).count)
            / Double(leftTokens.union(rightTokens).count)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(
                of: #"\b(feat|featuring|ft)\.?\b"#,
                with: " ",
                options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MacDeezerSearch: Decodable {
    let data: [MacDeezerTrack]
}

private struct MacDeezerTrack: Decodable {
    let title: String
    let duration: Double?
    let artist: MacDeezerArtist
    let album: MacDeezerAlbum
}

private struct MacDeezerArtist: Decodable {
    let name: String
}

private struct MacDeezerAlbum: Decodable {
    let coverMedium: URL?

    enum CodingKeys: String, CodingKey {
        case coverMedium = "cover_medium"
    }
}

private enum MacLiveArtworkService {
    static func fetchTheme(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> MacLiveLyricsTheme? {
        let primaryArtist = artist.split(whereSeparator: { ",/&".contains($0) })
            .first.map(String.init) ?? artist
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: #"track:"\#(title)" artist:"\#(primaryArtist)""#),
            URLQueryItem(name: "limit", value: "12")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SetPlayerLiveLyrics/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let candidates = try JSONDecoder().decode(MacDeezerSearch.self, from: data).data
            let match = candidates
                .filter { $0.album.coverMedium != nil }
                .max {
                    score($0, title: title, artist: artist, duration: duration)
                        < score($1, title: title, artist: artist, duration: duration)
                }
            guard let artworkURL = match?.album.coverMedium else { return nil }
            var artworkRequest = URLRequest(url: artworkURL)
            artworkRequest.timeoutInterval = 8
            artworkRequest.setValue(
                "SetPlayerLiveLyrics/1.0",
                forHTTPHeaderField: "User-Agent")
            let (artworkData, artworkResponse) = try await URLSession.shared.data(
                for: artworkRequest)
            guard (artworkResponse as? HTTPURLResponse)?.statusCode == 200,
                  artworkData.count < 2_000_000 else { return nil }
            return await Task.detached(priority: .utility) {
                theme(from: artworkData)
            }.value
        } catch {
            return nil
        }
    }

    private static func score(
        _ candidate: MacDeezerTrack,
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> Double {
        let durationDelta = duration > 0
            ? abs((candidate.duration ?? duration) - duration)
            : 0
        return MacLiveLyricsService.similarity(candidate.title, title) * 5
            + MacLiveLyricsService.similarity(candidate.artist.name, artist) * 4
            + max(0, 4 - durationDelta / 2)
    }

    private static func theme(from data: Data) -> MacLiveLyricsTheme? {
        guard let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else { return nil }

        var buckets: [Int: Double] = [:]
        let xStep = max(1, bitmap.pixelsWide / 40)
        let yStep = max(1, bitmap.pixelsHigh / 40)

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStep) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let lightness = (max(red, green, blue) + min(red, green, blue)) / 2
                let saturation = max(red, green, blue) - min(red, green, blue)
                guard lightness > 0.08, lightness < 0.92 else { continue }

                let r = min(255, Int(red * 255) / 16 * 16 + 8)
                let g = min(255, Int(green * 255) / 16 * 16 + 8)
                let b = min(255, Int(blue * 255) / 16 * 16 + 8)
                let key = (r << 16) | (g << 8) | b
                let weight = 0.35 + saturation * 2.5 + (1 - abs(lightness - 0.5)) * 0.4
                buckets[key, default: 0] += weight
            }
        }

        guard let key = buckets.max(by: { $0.value < $1.value })?.key else { return nil }
        let raw = NSColor(
            calibratedRed: CGFloat((key >> 16) & 0xff) / 255,
            green: CGFloat((key >> 8) & 0xff) / 255,
            blue: CGFloat(key & 0xff) / 255,
            alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        raw.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha)

        let background = NSColor(
            calibratedHue: hue,
            saturation: min(0.82, max(0.36, saturation)),
            brightness: min(0.34, max(0.15, brightness * 0.62)),
            alpha: 1)
        let muted = NSColor(
            calibratedHue: (hue + 0.105).truncatingRemainder(dividingBy: 1),
            saturation: min(0.78, max(0.5, saturation + 0.12)),
            brightness: 0.82,
            alpha: 1)

        return MacLiveLyricsTheme(
            backgroundRed: background.redComponent,
            backgroundGreen: background.greenComponent,
            backgroundBlue: background.blueComponent,
            mutedRed: muted.redComponent,
            mutedGreen: muted.greenComponent,
            mutedBlue: muted.blueComponent)
    }
}
