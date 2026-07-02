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

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureRemoteCommands()
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
            pushStaticNowPlaying()
            if autoplay { play() }
        } catch {
            loadError = "Couldn't open \(set.fileName): \(error.localizedDescription)"
        }
    }

    func unload() {
        pause()
        player = nil
        current = nil
        duration = 0
        displayTime = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func play() {
        guard let p = player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play()
        isPlaying = true
        startTicker()
        pushDynamicNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        pushDynamicNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to t: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, duration - 0.05))
        displayTime = p.currentTime
        pushDynamicNowPlaying()
    }

    func skip(_ delta: TimeInterval) { seek(to: liveTime() + delta) }

    /// Sample-accurate time for the waveform's 60fps redraws.
    func liveTime() -> TimeInterval { player?.currentTime ?? displayTime }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.displayTime = p.currentTime
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

    private func pushStaticNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current?.title ?? "Set",
            MPMediaItemPropertyArtist: "Set Player",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0
        ]
    }

    private func pushDynamicNowPlaying() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = liveTime()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension PlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        displayTime = duration
        stopTicker()
        pushDynamicNowPlaying()
    }
}
