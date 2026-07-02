import BackgroundTasks
import Foundation

/// Continues waveform/beat-grid analysis when the app isn't running, via
/// BGProcessingTask. iOS grants these windows when the device is idle
/// (typically locked or charging); each window processes as many sets as
/// it can and reschedules itself if work remains.
enum BackgroundAnalyzer {
    static let taskID = "com.alexdils.setplayer.analyze"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task)
        }
    }

    /// Ask iOS for a processing window if any set still lacks a saved grid.
    static func scheduleIfNeeded() {
        guard !pendingSets().isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Sets from the saved library index whose analysis cache is missing.
    static func pendingSets() -> [(id: UUID, url: URL)] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let indexURL = docs.appendingPathComponent("library.json")
        let setsDir = docs.appendingPathComponent("Sets", isDirectory: true)
        guard let data = try? Data(contentsOf: indexURL),
              let sets = try? JSONDecoder().decode([DJSet].self, from: data) else { return [] }
        return sets.compactMap { set in
            let cache = WaveformStore.diskCacheURL(for: set.id)
            guard !FileManager.default.fileExists(atPath: cache.path) else { return nil }
            let audio = setsDir.appendingPathComponent(set.fileName)
            guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
            return (set.id, audio)
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        let cancelled = Cancelled()
        task.expirationHandler = { cancelled.flag = true }

        DispatchQueue.global(qos: .utility).async {
            for job in pendingSets() {
                if cancelled.flag { break }
                let checkpointURL = WaveformStore.checkpointURL(for: job.id)
                let outcome = WaveformStore.analyze(
                    url: job.url, bins: 2000,
                    resuming: WaveformStore.loadCheckpoint(from: checkpointURL),
                    shouldAbort: { cancelled.flag })
                switch outcome {
                case .finished(let wf):
                    if let data = try? JSONEncoder().encode(wf) {
                        try? data.write(to: WaveformStore.diskCacheURL(for: job.id))
                    }
                    try? FileManager.default.removeItem(at: checkpointURL)
                case .suspended(let checkpoint):
                    // window expired mid-file: save so the next window (or the
                    // app) picks up exactly here
                    WaveformStore.saveCheckpoint(checkpoint, to: checkpointURL)
                case .failed:
                    break
                }
            }
            scheduleIfNeeded()
            task.setTaskCompleted(success: !cancelled.flag)
        }
    }

    private final class Cancelled: @unchecked Sendable {
        var flag = false
    }
}
