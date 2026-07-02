import AVFoundation
import Foundation

@MainActor
final class Library: ObservableObject {
    @Published private(set) var sets: [DJSet] = []
    @Published var importing = false
    @Published var importError: String?

    let setsDir: URL
    private let indexURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        setsDir = docs.appendingPathComponent("Sets", isDirectory: true)
        indexURL = docs.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: setsDir, withIntermediateDirectories: true)
        load()
        rescan()
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

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([DJSet].self, from: data) else { return }
        sets = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        try? data.write(to: indexURL)
    }

    /// Pick up files dropped in via Finder file sharing, drop entries whose file is gone.
    func rescan() {
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

    func setAnnotations(_ annotations: [SetAnnotation], for id: UUID) {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[idx].annotations = annotations.sorted { $0.time < $1.time }
        save()
        if PlayerManager.shared.current?.id == id {
            PlayerManager.shared.current = sets[idx]
        }
    }
}
