import ActivityKit
import AVFoundation
import MediaPlayer

/// Playback engine: AVAudioPlayer + background audio session + lock-screen controls.
final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    @Published var current: DJSet?
    @Published var isPlaying = false
    @Published var displayTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var loadError: String?

    weak var library: Library?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    // AVAudioPlayer.currentTime quantizes to buffer boundaries, which makes
    // waveform scrolling stutter. Anchor media time to the smooth audio
    // hardware clock and interpolate while playing.
    private var anchorMedia: TimeInterval = 0
    private var anchorDevice: TimeInterval = 0

    private var activity: Activity<SetActivityAttributes>?
    private var activityTicker: Timer?
    private var resumeAfterInterruption = false

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        PlayerIntentBridge.toggle = {
            await MainActor.run { PlayerManager.shared.toggle() }
        }
        PlayerIntentBridge.skip = { delta in
            await MainActor.run { PlayerManager.shared.skip(delta) }
        }
        configureRemoteCommands()
        observeSessionNotifications()
        // clear any Live Activity left over from a previous run
        Task { @MainActor in
            for stale in Activity<SetActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Playback silently stopping "after a while" is usually an unhandled
    /// session interruption (call, Siri, alarm, another app). Resume when
    /// the system says we should.
    private func observeSessionNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.resumeAfterInterruption = self.isPlaying
                self.pause()
            case .ended:
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                if self.resumeAfterInterruption, opts.contains(.shouldResume) {
                    self.play()
                }
                self.resumeAfterInterruption = false
            @unknown default:
                break
            }
        }
        nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            // headphones unplugged / speaker vanished: pause like Music does
            if reason == .oldDeviceUnavailable { self?.pause() }
        }
    }

    func load(_ set: DJSet, autoplay: Bool = true) {
        guard let url = library?.audioURL(for: set) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            current = set
            duration = p.duration
            displayTime = 0
            loadError = nil
            if autoplay {
                play()
            } else {
                startOrUpdateActivity()
            }
        } catch {
            loadError = "Couldn't open \(set.fileName): \(error.localizedDescription)"
        }
    }

    func unload() {
        pause()
        stopActivityTicker()
        player = nil
        current = nil
        duration = 0
        displayTime = 0
        endActivity()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func play() {
        guard let p = player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play()
        isPlaying = true
        reanchor()
        startTicker()
        startActivityTicker()
        startOrUpdateActivity()
    }

    /// Live Activity views are static snapshots — the waveform playhead only
    /// moves when we push a content update, so nudge it every 20s while
    /// playing (the timer text/progress bar animate on their own).
    private func startActivityTicker() {
        activityTicker?.invalidate()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.startOrUpdateActivity()
        }
        RunLoop.main.add(t, forMode: .common)
        activityTicker = t
    }

    private func stopActivityTicker() {
        activityTicker?.invalidate()
        activityTicker = nil
    }

    private func reanchor() {
        guard let p = player else { return }
        anchorMedia = p.currentTime
        anchorDevice = p.deviceCurrentTime
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        stopActivityTicker()
        startOrUpdateActivity()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to t: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, duration - 0.05))
        displayTime = p.currentTime
        reanchor()
        startOrUpdateActivity()
    }

    func skip(_ delta: TimeInterval) { seek(to: liveTime() + delta) }

    /// Smooth time for the waveform's per-frame redraws: interpolated from
    /// the audio hardware clock while playing.
    func liveTime() -> TimeInterval {
        guard let p = player else { return displayTime }
        guard isPlaying else { return p.currentTime }
        return min(anchorMedia + (p.deviceCurrentTime - anchorDevice), duration)
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.displayTime = p.currentTime
            // catch clock drift or route changes; small jitter is expected
            if self.isPlaying, abs(self.liveTime() - p.currentTime) > 0.3 {
                self.reanchor()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - lock screen / control center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(15); return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-15); return .success }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    // Deliberately NOT publishing MPNowPlayingInfo: doing so makes iOS show
    // its own media card on the lock screen and hand the Dynamic Island to the
    // system player while audio plays, which outranks (and hides) our Live
    // Activity. Remote commands still work — they route by audio session.

    func refreshLiveActivity() {
        startOrUpdateActivity()
    }

    // MARK: - Live Activity / Dynamic Island

    private func startOrUpdateActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let set = current else {
            endActivity()
            return
        }

        Task { @MainActor in
            let attributes = self.activityAttributes(for: set)
            let content = ActivityContent(state: self.activityState(for: set), staleDate: nil)
            if let existing = self.activity ?? Activity<SetActivityAttributes>.activities.first {
                if existing.attributes.setID == attributes.setID {
                    self.activity = existing
                    await existing.update(content)
                } else {
                    await existing.end(nil, dismissalPolicy: .immediate)
                    self.activity = nil
                    self.requestActivity(attributes: attributes, content: content)
                }
            } else {
                self.requestActivity(attributes: attributes, content: content)
            }
        }
    }

    private func endActivity() {
        Task { @MainActor in
            let existing = self.activity ?? Activity<SetActivityAttributes>.activities.first
            self.activity = nil
            await existing?.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func requestActivity(
        attributes: SetActivityAttributes,
        content: ActivityContent<SetActivityAttributes.ContentState>
    ) {
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            #if DEBUG
            print("Could not start Live Activity: \(error)")
            #endif
        }
    }

    private func activityAttributes(for set: DJSet) -> SetActivityAttributes {
        SetActivityAttributes(
            setID: set.id.uuidString,
            duration: max(duration, set.duration))
    }

    @MainActor
    private func activityState(for set: DJSet) -> SetActivityAttributes.ContentState {
        let position = max(0, min(liveTime(), max(duration, set.duration)))
        let waveform = Self.compactWaveform(WaveformStore.shared.waveforms[set.id])
        return SetActivityAttributes.ContentState(
            startDate: Date().addingTimeInterval(-position),
            isPlaying: isPlaying,
            position: position,
            title: set.title,
            bpm: waveform.bpm,
            amps: waveform.amps,
            hues: waveform.hues)
    }

    private static func compactWaveform(
        _ waveform: Waveform?,
        sampleCount: Int = 72
    ) -> (bpm: Double, amps: [UInt8], hues: [UInt8]) {
        guard let waveform, waveform.count > 0 else {
            return fallbackActivityWaveform(sampleCount: sampleCount)
        }

        var amps: [UInt8] = []
        var hues: [UInt8] = []
        amps.reserveCapacity(sampleCount)
        hues.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let start = i * waveform.count / sampleCount
            let end = max(start + 1, (i + 1) * waveform.count / sampleCount)
            let boundedEnd = min(end, waveform.count)
            let amp = waveform.amps[start..<boundedEnd].max() ?? 0
            let colorIndex = min(waveform.count - 1, (start + boundedEnd - 1) / 2)
            amps.append(UInt8(max(8, min(255, Int((amp * 255).rounded())))))
            hues.append(hueByte(
                red: waveform.r[colorIndex],
                green: waveform.g[colorIndex],
                blue: waveform.b[colorIndex]))
        }

        return (Double(waveform.bpm), amps, hues)
    }

    private static func fallbackActivityWaveform(
        sampleCount: Int
    ) -> (bpm: Double, amps: [UInt8], hues: [UInt8]) {
        var amps: [UInt8] = []
        var hues: [UInt8] = []
        amps.reserveCapacity(sampleCount)
        hues.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let phase = Double(i) / Double(max(1, sampleCount - 1))
            let wave = 0.45 + 0.35 * sin(phase * .pi * 6)
            amps.append(UInt8(max(18, min(160, Int(wave * 180)))))
            hues.append(UInt8((180 + i) % 255))
        }
        return (0, amps, hues)
    }

    private static func hueByte(red: Float, green: Float, blue: Float) -> UInt8 {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        guard delta > 0.0001 else { return 128 }

        let hue: Float
        if maxValue == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }

        let normalized = hue < 0 ? hue + 360 : hue
        return UInt8(max(0, min(255, Int((normalized / 360 * 255).rounded()))))
    }
}

extension PlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        displayTime = duration
        stopTicker()
        stopActivityTicker()
        endActivity()
    }
}
