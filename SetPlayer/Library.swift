import AVFoundation
import Foundation

@MainActor
final class Library: ObservableObject {
    @Published private(set) var sets: [DJSet] = []
    @Published var importing = false
    @Published var importError: String?

    let setsDir: URL
    let photosDir: URL
    let videosDir: URL
    private let indexURL: URL
    private var indexModificationDate: Date?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        setsDir = docs.appendingPathComponent("Sets", isDirectory: true)
        photosDir = docs.appendingPathComponent("Photos", isDirectory: true)
        videosDir = docs.appendingPathComponent("Videos", isDirectory: true)
        indexURL = docs.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: setsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        load()
        rescan()
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            save()
        }
        PlayerManager.shared.library = self
    }

    /// Queue background waveform + beat-grid analysis for any set that
    /// doesn't have a saved grid yet.
    func analyzeAll() {
        for set in sets {
            WaveformStore.shared.request(for: set, url: audioURL(for: set))
        }
    }

    nonisolated func audioURL(for set: DJSet) -> URL {
        setsDir.appendingPathComponent(set.fileName)
    }

    nonisolated func photoURL(for photo: SetPhoto) -> URL {
        photosDir.appendingPathComponent(photo.fileName)
    }

    nonisolated func coverPhotoURL(for set: DJSet) -> URL? {
        set.photos.first.map(photoURL(for:))
    }

    nonisolated func videoURL(for video: SetVideo) -> URL {
        videosDir.appendingPathComponent(video.fileName)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([DJSet].self, from: data) else { return }
        sets = decoded
        indexModificationDate = modificationDate(of: indexURL)
        if let current = PlayerManager.shared.current,
           let updated = sets.first(where: { $0.id == current.id }) {
            PlayerManager.shared.current = updated
            PlayerManager.shared.refreshLiveActivity()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        try? data.write(to: indexURL)
        indexModificationDate = modificationDate(of: indexURL)
    }

    /// The Mac companion writes the same library index through the paired
    /// device connection. Refresh active views when that external file changes.
    func reloadIfChanged() {
        let latest = modificationDate(of: indexURL)
        guard latest != indexModificationDate else { return }
        load()
        rescan()
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    /// Pick up files dropped in via Finder file sharing, drop entries whose file is gone.
    func rescan() {
        importSharedDocuments()
        let known = Set(sets.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: setsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files
        where ["mp3", "wav", "aif", "aiff", "m4a"].contains(file.pathExtension.lowercased())
            && !known.contains(file.lastPathComponent) {
            addEntry(for: file)
        }
        let before = sets.count
        sets.removeAll { !FileManager.default.fileExists(atPath: audioURL(for: $0).path) }
        if before != sets.count || !files.isEmpty { save() }
        analyzeAll()
    }

    /// Finder and the Files app place shared files at the root of Documents,
    /// while Set Player keeps its managed library in Documents/Sets.
    private func importSharedDocuments() {
        let documentsDir = setsDir.deletingLastPathComponent()
        let sharedFiles = (try? FileManager.default.contentsOfDirectory(
            at: documentsDir, includingPropertiesForKeys: nil)) ?? []

        for source in sharedFiles where isSupportedAudio(source) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var destination = setsDir.appendingPathComponent(source.lastPathComponent)
            var suffix = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = setsDir.appendingPathComponent("\(base) \(suffix).\(ext)")
                suffix += 1
            }
            try? FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private func isSupportedAudio(_ url: URL) -> Bool {
        ["mp3", "wav", "aif", "aiff", "m4a"].contains(url.pathExtension.lowercased())
    }

    func importFiles(_ urls: [URL]) {
        importing = true
        let destDir = setsDir
        Task.detached(priority: .userInitiated) {
            var added: [URL] = []
            var failure: String?
            for src in urls {
                let scoped = src.startAccessingSecurityScopedResource()
                defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                let base = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                var dest = destDir.appendingPathComponent(src.lastPathComponent)
                var i = 1
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = destDir.appendingPathComponent("\(base) \(i).\(ext)")
                    i += 1
                }
                do {
                    try FileManager.default.copyItem(at: src, to: dest)
                    added.append(dest)
                } catch {
                    failure = "Couldn't import \(src.lastPathComponent): \(error.localizedDescription)"
                }
            }
            await MainActor.run { [added, failure] in
                for url in added { self.addEntry(for: url) }
                self.save()
                self.importing = false
                self.importError = failure
                self.analyzeAll()
            }
        }
    }

    private func addEntry(for url: URL) {
        let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        sets.insert(DJSet(
            fileName: url.lastPathComponent,
            title: url.deletingPathExtension().lastPathComponent,
            duration: duration,
            addedAt: Date(),
            fileSize: size), at: 0)
    }

    func delete(_ set: DJSet) {
        if PlayerManager.shared.current?.id == set.id {
            PlayerManager.shared.unload()
        }
        try? FileManager.default.removeItem(at: audioURL(for: set))
        for photo in set.photos {
            try? FileManager.default.removeItem(at: photoURL(for: photo))
        }
        for video in set.videos {
            try? FileManager.default.removeItem(at: videoURL(for: video))
        }
        WaveformStore.shared.removeCache(for: set.id)
        sets.removeAll { $0.id == set.id }
        save()
    }

    var folderNames: [String] {
        Array(Set(sets.compactMap(\.folder))).sorted()
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[idx].title = trimmed
        save()
        if PlayerManager.shared.current?.id == id {
            PlayerManager.shared.current = sets[idx]
            PlayerManager.shared.refreshLiveActivity()
        }
    }

    func setFolder(_ id: UUID, folder: String?) {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        sets[idx].folder = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    func setDescription(_ description: String?, for id: UUID) {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard sets[idx].description != value else { return }
        sets[idx].description = value
        save()
        if PlayerManager.shared.current?.id == id {
            PlayerManager.shared.current = sets[idx]
            PlayerManager.shared.refreshLiveActivity()
        }
    }

    func setLocation(
        _ location: String?,
        latitude: Double? = nil,
        longitude: Double? = nil,
        for id: UUID
    ) {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        sets[idx].locationName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        sets[idx].locationLatitude = latitude
        sets[idx].locationLongitude = longitude
        save()
    }

    func setAnnotations(_ annotations: [SetAnnotation], for id: UUID) {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[idx].annotations = annotations.sorted { $0.time < $1.time }
        save()
        if PlayerManager.shared.current?.id == id {
            PlayerManager.shared.current = sets[idx]
        }
    }

    func addPhoto(
        data: Data,
        fileExtension: String,
        to id: UUID
    ) throws {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        let photoID = UUID()
        let ext = normalizedImageExtension(fileExtension)
        let fileName = "\(id.uuidString)-\(photoID.uuidString).\(ext)"
        try data.write(
            to: photosDir.appendingPathComponent(fileName),
            options: .atomic)
        sets[idx].photos.insert(SetPhoto(
            id: photoID,
            fileName: fileName,
            addedAt: Date()), at: 0)
        save()
    }

    func deletePhoto(_ photoID: UUID, from id: UUID) {
        guard let idx = sets.firstIndex(where: { $0.id == id }),
              let photo = sets[idx].photos.first(where: { $0.id == photoID }) else { return }
        try? FileManager.default.removeItem(at: photoURL(for: photo))
        sets[idx].photos.removeAll { $0.id == photoID }
        save()
    }

    func addVideo(at source: URL, to id: UUID) throws {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        let videoID = UUID()
        let ext = normalizedVideoExtension(source.pathExtension)
        let fileName = "\(id.uuidString)-\(videoID.uuidString).\(ext)"
        let destination = videosDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        sets[idx].videos.insert(SetVideo(
            id: videoID,
            fileName: fileName,
            addedAt: Date(),
            duration: 0), at: 0)
        save()
    }

    func deleteVideo(_ videoID: UUID, from id: UUID) {
        guard let idx = sets.firstIndex(where: { $0.id == id }),
              let video = sets[idx].videos.first(where: { $0.id == videoID }) else { return }
        try? FileManager.default.removeItem(at: videoURL(for: video))
        sets[idx].videos.removeAll { $0.id == videoID }
        save()
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
