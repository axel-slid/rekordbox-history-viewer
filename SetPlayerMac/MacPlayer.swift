import AVFoundation
import Combine
import Foundation

@MainActor
final class MacPlayer: NSObject, ObservableObject {
    static let shared = MacPlayer()

    @Published var current: DJSet?
    @Published var isPlaying = false
    @Published var displayTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var loadError: String?
    @Published private(set) var isLoading = false
    @Published var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?
    private var ticker: Timer?
    private var anchorMedia: TimeInterval = 0
    private var anchorDevice: TimeInterval = 0

    private override init() {
        super.init()
    }

    func load(_ set: DJSet, from url: URL, autoplay: Bool = true) {
        if current?.id == set.id {
            if autoplay, !isPlaying, player != nil { play() }
            return
        }

        loadTask?.cancel()
        player?.stop()
        player = nil
        isPlaying = false
        isLoading = true
        stopTicker()
        current = set
        duration = set.duration
        displayTime = 0
        loadError = nil

        let requestedID = set.id
        let requestedVolume = volume
        loadTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let audioPlayer = try AVAudioPlayer(contentsOf: url)
                    audioPlayer.volume = requestedVolume
                    audioPlayer.prepareToPlay()
                    return audioPlayer
                }
            }.value

            guard !Task.isCancelled, current?.id == requestedID else { return }
            isLoading = false
            switch result {
            case .success(let audioPlayer):
                audioPlayer.delegate = self
                player = audioPlayer
                duration = audioPlayer.duration
                if autoplay { play() }
            case .failure(let error):
                loadError = "Couldn’t open \(set.fileName): \(error.localizedDescription)"
            }
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        reanchor()
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        displayTime = player?.currentTime ?? displayTime
    }

    func toggle() {
        guard !isLoading else { return }
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, max(0, duration - 0.02)))
        displayTime = player.currentTime
        reanchor()
    }

    func skip(_ delta: TimeInterval) {
        seek(to: liveTime() + delta)
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        isLoading = false
        displayTime = 0
        duration = 0
        stopTicker()
    }

    func liveTime() -> TimeInterval {
        guard let player else { return displayTime }
        guard isPlaying else { return player.currentTime }
        return min(duration, anchorMedia + (player.deviceCurrentTime - anchorDevice))
    }

    private func reanchor() {
        guard let player else { return }
        anchorMedia = player.currentTime
        anchorDevice = player.deviceCurrentTime
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.displayTime = player.currentTime
                if self.isPlaying, abs(self.liveTime() - player.currentTime) > 0.35 {
                    self.reanchor()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension MacPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTicker()
            self.displayTime = self.duration
        }
    }
}
