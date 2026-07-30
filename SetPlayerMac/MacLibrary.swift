import AppKit
import AVFoundation
import Combine
import Foundation
import ImageIO

func macImageIsLandscape(at url: URL) -> Bool? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil) as? [CFString: Any],
          let pixelWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let pixelHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
        return nil
    }

    var width = pixelWidth.doubleValue
    var height = pixelHeight.doubleValue
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    if [5, 6, 7, 8].contains(orientation) {
        swap(&width, &height)
    }
    return width > height
}

@MainActor
final class MacLibrary: ObservableObject {
    @Published private(set) var sets: [DJSet] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var phoneName: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncMessage = "Ready to sync"
    @Published private(set) var syncError: String?
    @Published var isImporting = false
    @Published var importError: String?
    @Published private(set) var latestAddedSetID: UUID?

    let documentsURL: URL
    let setsURL: URL
    let waveformsURL: URL
    let photosURL: URL
    let videosURL: URL

    private let libraryURL: URL
    private var autoSyncTask: Task<Void, Never>?
    private var hasStarted = false

    init() {
        let musicURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        documentsURL = musicURL.appendingPathComponent("Set Player", isDirectory: true)
        setsURL = documentsURL.appendingPathComponent("Sets", isDirectory: true)
        waveformsURL = documentsURL.appendingPathComponent("waveforms", isDirectory: true)
        photosURL = documentsURL.appendingPathComponent("Photos", isDirectory: true)
        videosURL = documentsURL.appendingPathComponent("Videos", isDirectory: true)
        libraryURL = documentsURL.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: setsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: waveformsURL,
            withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: photosURL,
            withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: videosURL,
            withIntermediateDirectories: true)
        reloadLibrary()
        MacWaveformStore.shared.refresh(
            sets,
            audioDirectory: setsURL,
            waveformsDirectory: waveformsURL)
    }

    var folderNames: [String] {
        Array(Set(sets.compactMap(\.folder))).sorted()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await syncNow()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                await self?.syncNow()
            }
        }
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncError = nil
        syncMessage = "Connecting to iPhone…"
        let localDocumentsURL = documentsURL

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PhoneSyncEngine.sync(localDocumentsURL: localDocumentsURL)
            }.value
            phoneName = result.deviceName
            lastSync = Date()
            reloadLibrary()
            MacWaveformStore.shared.refresh(
                sets,
                audioDirectory: setsURL,
                waveformsDirectory: waveformsURL)

            let changes = [
                result.pulledFiles > 0 ? "\(result.pulledFiles) downloaded" : nil,
                result.pushedFiles > 0 ? "\(result.pushedFiles) uploaded" : nil,
                result.waveformFiles > 0 ? "\(result.waveformFiles) waveforms" : nil,
                result.photoFiles > 0 ? "\(result.photoFiles) photos" : nil,
                result.videoFiles > 0 ? "\(result.videoFiles) videos" : nil
            ].compactMap { $0 }
            syncMessage = changes.isEmpty
                ? "\(result.setCount) sets are up to date"
                : changes.joined(separator: " · ")
        } catch {
            phoneName = nil
            syncError = nil
            syncMessage = "Connect iPhone to sync"
        }
        isSyncing = false
    }

    func audioURL(for set: DJSet) -> URL {
        setsURL.appendingPathComponent(set.fileName)
    }

    func photoURL(for photo: SetPhoto) -> URL {
        photosURL.appendingPathComponent(photo.fileName)
    }

    func coverPhotoURL(for set: DJSet) -> URL? {
        set.photos.first.map(photoURL(for:))
    }

    func videoURL(for video: SetVideo) -> URL {
        videosURL.appendingPathComponent(video.fileName)
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importError = nil
        let destinationDirectory = setsURL

        Task.detached(priority: .userInitiated) {
            var imported: [(URL, TimeInterval, Int64)] = []
            var failure: String?

            for source in urls {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let base = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension
                var destination = destinationDirectory.appendingPathComponent(
                    source.lastPathComponent)
                var suffix = 1
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = destinationDirectory.appendingPathComponent(
                        "\(base) \(suffix).\(ext)")
                    suffix += 1
                }

                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    let duration = (try? AVAudioPlayer(contentsOf: destination))?.duration ?? 0
                    let size = Int64(
                        (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    imported.append((destination, duration, size))
                } catch {
                    failure = "Couldn’t import \(source.lastPathComponent): \(error.localizedDescription)"
                }
            }

            let completedImports = imported
            let completedFailure = failure

            await MainActor.run { [completedImports, completedFailure] in
                for item in completedImports {
                    self.sets.insert(DJSet(
                        fileName: item.0.lastPathComponent,
                        title: item.0.deletingPathExtension().lastPathComponent,
                        duration: item.1,
                        addedAt: Date(),
                        fileSize: item.2), at: 0)
                }
                self.saveLibrary()
                self.isImporting = false
                self.importError = completedFailure
                MacWaveformStore.shared.refresh(
                    self.sets,
                    audioDirectory: self.setsURL,
                    waveformsDirectory: self.waveformsURL)
                Task { await self.syncNow() }
            }
        }
    }

    func registerRecording(
        at url: URL,
        startedAt: Date,
        endedAt: Date,
        sourceName _: String
    ) {
        let recordingURL = url
        Task.detached(priority: .userInitiated) {
            let duration = (try? AVAudioPlayer(contentsOf: recordingURL))?.duration
                ?? max(0, endedAt.timeIntervalSince(startedAt))
            let size = Int64(
                (try? recordingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

            await MainActor.run {
                guard FileManager.default.fileExists(atPath: recordingURL.path) else {
                    self.importError = "The completed recording could not be found."
                    return
                }

                let formatter = DateFormatter()
                formatter.locale = .current
                formatter.timeStyle = .short
                formatter.dateStyle = .none
                let title = "Set \(formatter.string(from: startedAt)) to \(formatter.string(from: endedAt))"
                let set = DJSet(
                    fileName: recordingURL.lastPathComponent,
                    title: title,
                    duration: duration,
                    addedAt: endedAt,
                    fileSize: size)
                self.sets.insert(set, at: 0)
                self.latestAddedSetID = set.id
                self.saveLibrary()
                MacWaveformStore.shared.refresh(
                    self.sets,
                    audioDirectory: self.setsURL,
                    waveformsDirectory: self.waveformsURL)
                Task { await self.syncNow() }
            }
        }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].title = trimmed
        if MacPlayer.shared.current?.id == id {
            MacPlayer.shared.current = sets[index]
        }
        saveLibrary()
        Task { await syncNow() }
    }

    func setFolder(_ id: UUID, folder: String?) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        sets[index].folder = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveLibrary()
        Task { await syncNow() }
    }

    func setDescription(_ description: String?, for id: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard sets[index].description != value else { return }
        sets[index].description = value
        if MacPlayer.shared.current?.id == id {
            MacPlayer.shared.current = sets[index]
        }
        saveLibrary()
        Task { await syncNow() }
    }

    func setLocation(
        _ location: String?,
        latitude: Double? = nil,
        longitude: Double? = nil,
        for id: UUID
    ) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        sets[index].locationName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        sets[index].locationLatitude = latitude
        sets[index].locationLongitude = longitude
        saveLibrary()
        Task { await syncNow() }
    }

    func addCue(to id: UUID, at time: TimeInterval) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        let trackNumber = sets[index].annotations.count + 1
        sets[index].annotations.append(SetAnnotation(
            time: max(0, time),
            label: "Track \(trackNumber)"))
        sets[index].annotations.sort { $0.time < $1.time }
        saveLibrary()
        Task { await syncNow() }
    }

    func replaceTracks(_ tracks: [SetAnnotation], in id: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].annotations = tracks.sorted { $0.time < $1.time }
        saveLibrary()
        Task { await syncNow() }
    }

    func importPhotos(_ urls: [URL], to id: UUID) {
        guard !urls.isEmpty,
              let setIndex = sets.firstIndex(where: { $0.id == id }) else { return }
        var imported: [SetPhoto] = []
        var skippedPortraits = 0

        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard macImageIsLandscape(at: source) == true else {
                skippedPortraits += 1
                continue
            }
            let photoID = UUID()
            let ext = normalizedImageExtension(source.pathExtension)
            let fileName = "\(id.uuidString)-\(photoID.uuidString).\(ext)"
            let destination = photosURL.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                imported.append(SetPhoto(
                    id: photoID,
                    fileName: fileName,
                    addedAt: Date()))
            } catch {
                importError = "Couldn’t add \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if skippedPortraits > 0 {
            let noun = skippedPortraits == 1 ? "photo" : "photos"
            importError = "Skipped \(skippedPortraits) portrait \(noun). Moments accepts landscape photos only."
        }

        guard !imported.isEmpty else { return }
        sets[setIndex].photos.insert(contentsOf: imported.reversed(), at: 0)
        saveLibrary()
        Task { await syncNow() }
    }

    func deletePhoto(_ photoID: UUID, from id: UUID) {
        guard let setIndex = sets.firstIndex(where: { $0.id == id }),
              let photo = sets[setIndex].photos.first(where: { $0.id == photoID }) else { return }
        try? FileManager.default.removeItem(at: photoURL(for: photo))
        sets[setIndex].photos.removeAll { $0.id == photoID }
        saveLibrary()
        Task { await syncNow() }
    }

    func importVideos(_ urls: [URL], to id: UUID) {
        guard !urls.isEmpty,
              let setIndex = sets.firstIndex(where: { $0.id == id }) else { return }
        var imported: [SetVideo] = []

        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let videoID = UUID()
            let ext = normalizedVideoExtension(source.pathExtension)
            let fileName = "\(id.uuidString)-\(videoID.uuidString).\(ext)"
            let destination = videosURL.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                imported.append(SetVideo(
                    id: videoID,
                    fileName: fileName,
                    addedAt: Date(),
                    duration: 0))
            } catch {
                importError = "Couldn’t add \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }

        guard !imported.isEmpty else { return }
        sets[setIndex].videos.insert(contentsOf: imported.reversed(), at: 0)
        saveLibrary()
        Task { await syncNow() }
    }

    func deleteVideo(_ videoID: UUID, from id: UUID) {
        guard let setIndex = sets.firstIndex(where: { $0.id == id }),
              let video = sets[setIndex].videos.first(where: { $0.id == videoID }) else { return }
        try? FileManager.default.removeItem(at: videoURL(for: video))
        sets[setIndex].videos.removeAll { $0.id == videoID }
        saveLibrary()
        Task { await syncNow() }
    }

    func delete(_ set: DJSet) {
        if MacPlayer.shared.current?.id == set.id {
            MacPlayer.shared.unload()
        }
        try? FileManager.default.removeItem(at: audioURL(for: set))
        for photo in set.photos {
            try? FileManager.default.removeItem(at: photoURL(for: photo))
        }
        for video in set.videos {
            try? FileManager.default.removeItem(at: videoURL(for: video))
        }
        sets.removeAll { $0.id == set.id }
        saveLibrary()
        MacWaveformStore.shared.refresh(
            sets,
            audioDirectory: setsURL,
            waveformsDirectory: waveformsURL)
        Task { await syncNow() }
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([documentsURL])
    }

    private func reloadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              let decoded = try? JSONDecoder().decode([DJSet].self, from: data) else {
            sets = []
            return
        }
        sets = decoded
    }

    private func saveLibrary() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sets) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    private func normalizedImageExtension(_ value: String) -> String {
        let ext = value.lowercased().trimmingCharacters(in: .alphanumerics.inverted)
        return ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(ext) ? ext : "jpg"
    }

    private func normalizedVideoExtension(_ value: String) -> String {
        let ext = value.lowercased().trimmingCharacters(in: .alphanumerics.inverted)
        return ["mov", "mp4", "m4v"].contains(ext) ? ext : "mov"
    }
}
