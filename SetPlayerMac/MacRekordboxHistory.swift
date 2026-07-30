import AppKit
import Charts
import Combine
import Foundation
import SwiftUI

struct RekordboxHistoryTrack: Identifiable, Hashable {
    let id: String
    let historyID: String
    let historyName: String
    let historyStartedAt: Date
    let contentID: String
    let trackNumber: Int
    let playedAt: Date
    let title: String
    let artist: String
    let album: String
    let genre: String
    let key: String
    let bpm: Double?
    let lengthSeconds: TimeInterval?
    let djPlayCount: Int?
    let source: String
    let path: String
    let artworkURL: URL?

    var canonicalKey: String {
        [title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|||")
    }

    var displayLabel: String {
        artist.isEmpty ? title : "\(title) — \(artist)"
    }
}

struct RekordboxHistorySession: Identifiable, Hashable {
    let id: String
    let name: String
    let startedAt: Date
    var tracks: [RekordboxHistoryTrack]

    var displayName: String {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: startedAt)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: startedAt)
        let year = calendar.component(.year, from: startedAt)
        return "\(month) \(ordinal(day)), \(year) Set"
    }

    /// Rekordbox records when each track was played, so the most reliable set
    /// duration is the elapsed timeline from the first play to the last play.
    var duration: TimeInterval {
        let ordered = tracks.sorted { $0.playedAt < $1.playedAt }
        guard let first = ordered.first else { return 0 }
        guard let last = ordered.last, last.id != first.id else {
            return first.lengthSeconds ?? 0
        }
        return max(0, last.playedAt.timeIntervalSince(first.playedAt))
    }

    private func ordinal(_ value: Int) -> String {
        let mod100 = value % 100
        if (11...13).contains(mod100) { return "\(value)th" }
        switch value % 10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }
}

struct RekordboxUniqueTrack: Identifiable, Hashable {
    let id: String
    var latest: RekordboxHistoryTrack
    var playCount: Int
    var sources: Set<String>

    var sourceLabel: String {
        sources.sorted().joined(separator: " / ")
    }
}

struct RekordboxHistoryCount: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }
}

struct RekordboxRepeatedTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let count: Int
    let artworkURL: URL?
}

struct RekordboxHistoryTransition: Identifiable, Hashable {
    let targetKey: String
    let count: Int
    var id: String { targetKey }
}

struct RekordboxHistoryStats {
    let dayCounts: [String: Int]
    let dayPlaySeconds: [String: TimeInterval]
    let activeDays: Int
    let rangeDays: Int
    let totalPlaySeconds: TimeInterval
    let averageBPM: Double
    let busiestDay: RekordboxHistoryCount?
    let peakHour: RekordboxHistoryCount?
    let sources: [RekordboxHistoryCount]
    let genres: [RekordboxHistoryCount]
    let repeatedTracks: [RekordboxRepeatedTrack]
}

struct RekordboxHistoryData {
    let databaseURL: URL
    let sessions: [RekordboxHistorySession]
    let tracks: [RekordboxHistoryTrack]
    let uniqueTracks: [RekordboxUniqueTrack]
    let uniqueByKey: [String: RekordboxUniqueTrack]
    let transitions: [String: [RekordboxHistoryTransition]]
    let stats: RekordboxHistoryStats

    var sources: [String] {
        Array(Set(tracks.map(\.source))).sorted()
    }
}

@MainActor
final class MacRekordboxHistoryStore: ObservableObject {
    static let shared = MacRekordboxHistoryStore()

    @Published private(set) var data: RekordboxHistoryData?
    @Published private(set) var isLoading = false
    @Published private(set) var status = "Ready to load Rekordbox history"
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var databaseURL: URL

    private let databasePreferenceKey = "rekordboxHistoryDatabasePath"

    private init() {
        if let saved = UserDefaults.standard.string(forKey: databasePreferenceKey),
           !saved.isEmpty {
            databaseURL = URL(fileURLWithPath: saved)
        } else {
            databaseURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Pioneer/rekordbox/master.db")
        }
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if data != nil, !force { return }
        isLoading = true
        errorMessage = nil
        status = "Reading Rekordbox history…"
        let selectedDatabase = databaseURL

        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try RekordboxHistoryLoader.load(databaseURL: selectedDatabase)
            }.value
            data = loaded
            lastLoadedAt = Date()
            status = "\(loaded.sessions.count) sets · \(loaded.tracks.count) played tracks"
        } catch {
            data = nil
            errorMessage = error.localizedDescription
            status = "Rekordbox history unavailable"
        }
        isLoading = false
    }

    func chooseDatabase() async {
        let panel = NSOpenPanel()
        panel.title = "Locate Rekordbox History"
        panel.message = "Choose Rekordbox master.db."
        panel.prompt = "Use Database"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.database]
        panel.directoryURL = databaseURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        databaseURL = url
        UserDefaults.standard.set(url.path, forKey: databasePreferenceKey)
        data = nil
        await load(force: true)
    }

    func useDefaultDatabase() async {
        databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Pioneer/rekordbox/master.db")
        UserDefaults.standard.removeObject(forKey: databasePreferenceKey)
        data = nil
        await load(force: true)
    }
}

private struct RekordboxRawHistoryRow: Decodable {
    let id: String
    let historyID: String
    let historyName: String?
    let historyStartedAt: String?
    let contentID: String?
    let trackNumber: Int?
    let playedAt: String?
    let rawTitle: String?
    let rawArtist: String?
    let rawAlbum: String?
    let rawGenre: String?
    let keyName: String?
    let bpm: Double?
    let lengthSeconds: Double?
    let djPlayCount: Int?
    let source: String?
    let sourcePath: String?
    let spotifyID: String?
    let artworkPath: String?
}

private struct RekordboxSpotifyMetadata: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let genre: String?
    let thumbnailUrl: String?
}

private enum RekordboxHistoryLoadError: LocalizedError {
    case databaseMissing
    case sqlCipherMissing
    case queryFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return "Rekordbox master.db could not be found. Use Locate Database to choose it."
        case .sqlCipherMissing:
            return "SQLCipher is required to read Rekordbox history and was not found."
        case .queryFailed(let message):
            return message.isEmpty ? "Rekordbox history could not be read." : message
        case .invalidResponse:
            return "Rekordbox returned an unreadable history response."
        }
    }
}

private enum RekordboxHistoryLoader {
    private static let databaseKey = "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497"

    static func load(databaseURL: URL) throws -> RekordboxHistoryData {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw RekordboxHistoryLoadError.databaseMissing
        }
        let rows = try query(databaseURL: databaseURL)
        let spotify = loadSpotifyCache()
        let tracks = rows.compactMap { makeTrack($0, spotify: spotify) }
        let sessions = makeSessions(tracks)
        let uniqueTracks = makeUniqueTracks(tracks)
        let uniqueByKey = Dictionary(uniqueKeysWithValues: uniqueTracks.map { ($0.id, $0) })
        let transitions = makeTransitions(sessions)
        let stats = makeStats(tracks: tracks, uniqueTracks: uniqueTracks)
        return RekordboxHistoryData(
            databaseURL: databaseURL,
            sessions: sessions,
            tracks: tracks,
            uniqueTracks: uniqueTracks,
            uniqueByKey: uniqueByKey,
            transitions: transitions,
            stats: stats)
    }

    private static func query(databaseURL: URL) throws -> [RekordboxRawHistoryRow] {
        let candidates = [
            "/opt/homebrew/bin/sqlcipher",
            "/usr/local/bin/sqlcipher",
            "/opt/local/bin/sqlcipher"
        ]
        guard let sqlCipher = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw RekordboxHistoryLoadError.sqlCipherMissing
        }

        let sql = """
        SELECT
          sh.ID AS id,
          sh.HistoryID AS historyID,
          COALESCE(NULLIF(h.Name, ''), 'Unnamed history') AS historyName,
          COALESCE(h.created_at, h.DateCreated) AS historyStartedAt,
          COALESCE(sh.ContentID, '') AS contentID,
          COALESCE(sh.TrackNo, 0) AS trackNumber,
          COALESCE(sh.created_at, sh.updated_at, h.created_at) AS playedAt,
          COALESCE(NULLIF(c.Title, ''), NULLIF(c.SrcTitle, ''), '') AS rawTitle,
          COALESCE(NULLIF(ar.Name, ''), NULLIF(c.SrcArtistName, ''), '') AS rawArtist,
          COALESCE(NULLIF(al.Name, ''), NULLIF(c.SrcAlbumName, ''), '') AS rawAlbum,
          COALESCE(NULLIF(g.Name, ''), '') AS rawGenre,
          COALESCE(NULLIF(k.ScaleName, ''), '') AS keyName,
          CASE WHEN c.BPM IS NULL OR c.BPM = 0 THEN NULL ELSE c.BPM / 100.0 END AS bpm,
          c.Length AS lengthSeconds,
          c.DJPlayCount AS djPlayCount,
          CASE
            WHEN c.FolderPath LIKE 'spotify:track:%' THEN 'Spotify'
            WHEN c.FolderPath LIKE '/%' THEN 'Local file'
            WHEN c.FileType = 25 THEN 'Streaming'
            ELSE 'Unknown'
          END AS source,
          COALESCE(c.FolderPath, '') AS sourcePath,
          CASE
            WHEN c.FolderPath LIKE 'spotify:track:%'
            THEN substr(c.FolderPath, length('spotify:track:') + 1)
            ELSE ''
          END AS spotifyID,
          COALESCE(c.ImagePath, '') AS artworkPath
        FROM djmdSongHistory sh
          JOIN djmdHistory h ON h.ID = sh.HistoryID
          LEFT JOIN djmdContent c ON c.ID = sh.ContentID
          LEFT JOIN djmdArtist ar ON ar.ID = c.ArtistID
          LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
          LEFT JOIN djmdGenre g ON g.ID = c.GenreID
          LEFT JOIN djmdKey k ON k.ID = c.KeyID
        WHERE COALESCE(sh.rb_local_deleted, 0) = 0
          AND COALESCE(h.rb_local_deleted, 0) = 0
        ORDER BY h.created_at DESC, h.Seq DESC, sh.TrackNo ASC;
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
            sql
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RekordboxHistoryLoadError.queryFailed(message)
        }

        let decoder = JSONDecoder()
        if let firstNewline = data.firstIndex(of: 10) {
            let payloadStart = data.index(after: firstNewline)
            let payload = Data(data[payloadStart...])
            if let decoded = try? decoder.decode(
                [RekordboxRawHistoryRow].self,
                from: payload) {
                return decoded
            }
        }
        if let decoded = try? decoder.decode(
            [RekordboxRawHistoryRow].self,
            from: data) {
            return decoded
        }
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            if let decoded = try? decoder.decode([RekordboxRawHistoryRow].self, from: Data(line)) {
                return decoded
            }
        }
        throw RekordboxHistoryLoadError.invalidResponse
    }

    private static func loadSpotifyCache() -> [String: RekordboxSpotifyMetadata] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let destination = home
            .appendingPathComponent("Music/Set Player/rekordbox-spotify-cache.json")
        let legacy = home.appendingPathComponent(
            "Library/Application Support/rekordbox-history-viewer/spotify-track-cache.json")

        if !FileManager.default.fileExists(atPath: destination.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: legacy, to: destination)
        }

        let source = FileManager.default.fileExists(atPath: destination.path)
            ? destination
            : legacy
        guard let data = try? Data(contentsOf: source),
              let cache = try? JSONDecoder().decode(
                [String: RekordboxSpotifyMetadata].self,
                from: data) else { return [:] }
        return cache
    }

    private static func makeTrack(
        _ row: RekordboxRawHistoryRow,
        spotify: [String: RekordboxSpotifyMetadata]
    ) -> RekordboxHistoryTrack? {
        let spotifyMetadata = spotify[row.spotifyID ?? ""]
        let path = clean(row.sourcePath)
        let source = clean(row.source).isEmpty ? "Unknown" : clean(row.source)
        var title = clean(row.rawTitle)
        if title.isEmpty { title = clean(spotifyMetadata?.title) }
        if title.isEmpty, source != "Spotify", !path.isEmpty {
            title = URL(fileURLWithPath: path)
                .deletingPathExtension().lastPathComponent
        }
        guard !title.isEmpty else { return nil }

        let historyStart = parseDate(row.historyStartedAt) ?? .distantPast
        let playedAt = parseDate(row.playedAt) ?? historyStart
        let localArtwork = rekordboxArtworkURL(clean(row.artworkPath))
        let remoteArtwork = clean(spotifyMetadata?.thumbnailUrl)
        return RekordboxHistoryTrack(
            id: row.id,
            historyID: row.historyID,
            historyName: clean(row.historyName),
            historyStartedAt: historyStart,
            contentID: clean(row.contentID),
            trackNumber: row.trackNumber ?? 0,
            playedAt: playedAt,
            title: title,
            artist: firstNonempty(clean(row.rawArtist), clean(spotifyMetadata?.artist)),
            album: firstNonempty(clean(row.rawAlbum), clean(spotifyMetadata?.album)),
            genre: firstNonempty(clean(row.rawGenre), clean(spotifyMetadata?.genre)),
            key: clean(row.keyName),
            bpm: row.bpm,
            lengthSeconds: row.lengthSeconds,
            djPlayCount: row.djPlayCount,
            source: source,
            path: path,
            artworkURL: localArtwork ?? (remoteArtwork.isEmpty ? nil : URL(string: remoteArtwork)))
    }

    private static func makeSessions(
        _ tracks: [RekordboxHistoryTrack]
    ) -> [RekordboxHistorySession] {
        var sessions: [RekordboxHistorySession] = []
        var indices: [String: Int] = [:]
        for track in tracks {
            if let index = indices[track.historyID] {
                sessions[index].tracks.append(track)
            } else {
                indices[track.historyID] = sessions.count
                sessions.append(RekordboxHistorySession(
                    id: track.historyID,
                    name: track.historyName,
                    startedAt: track.historyStartedAt,
                    tracks: [track]))
            }
        }
        return sessions
    }

    private static func makeUniqueTracks(
        _ tracks: [RekordboxHistoryTrack]
    ) -> [RekordboxUniqueTrack] {
        var grouped: [String: RekordboxUniqueTrack] = [:]
        for track in tracks {
            let key = track.canonicalKey
            if var existing = grouped[key] {
                existing.playCount += 1
                existing.sources.insert(track.source)
                if track.playedAt >= existing.latest.playedAt {
                    existing.latest = track
                }
                grouped[key] = existing
            } else {
                grouped[key] = RekordboxUniqueTrack(
                    id: key,
                    latest: track,
                    playCount: 1,
                    sources: [track.source])
            }
        }
        return grouped.values.sorted { $0.latest.playedAt > $1.latest.playedAt }
    }

    private static func makeTransitions(
        _ sessions: [RekordboxHistorySession]
    ) -> [String: [RekordboxHistoryTransition]] {
        var counts: [String: [String: Int]] = [:]
        for session in sessions {
            let tracks = session.tracks.sorted { $0.trackNumber < $1.trackNumber }
            for index in tracks.indices.dropLast() {
                let from = tracks[index].canonicalKey
                let to = tracks[index + 1].canonicalKey
                guard from != to else { continue }
                counts[from, default: [:]][to, default: 0] += 1
            }
        }
        return counts.mapValues { targets in
            targets.map {
                RekordboxHistoryTransition(targetKey: $0.key, count: $0.value)
            }
            .sorted { $0.count > $1.count }
        }
    }

    private static func makeStats(
        tracks: [RekordboxHistoryTrack],
        uniqueTracks: [RekordboxUniqueTrack]
    ) -> RekordboxHistoryStats {
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var dayCounts: [String: Int] = [:]
        var dayPlaySeconds: [String: TimeInterval] = [:]
        var hourCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        var genreCounts: [String: Int] = [:]
        var totalSeconds: TimeInterval = 0
        var bpmTotal = 0.0
        var bpmCount = 0

        for track in tracks {
            let dayKey = dayFormatter.string(from: track.playedAt)
            dayCounts[dayKey, default: 0] += 1
            dayPlaySeconds[dayKey, default: 0] += track.lengthSeconds ?? 0
            let hour = String(format: "%02d:00", calendar.component(.hour, from: track.playedAt))
            hourCounts[hour, default: 0] += 1
            sourceCounts[track.source, default: 0] += 1
            if !track.genre.isEmpty {
                genreCounts[track.genre, default: 0] += 1
            }
            if let length = track.lengthSeconds { totalSeconds += length }
            if let bpm = track.bpm {
                bpmTotal += bpm
                bpmCount += 1
            }
        }

        let sortedDates = tracks.map(\.playedAt).sorted()
        let rangeDays: Int
        if let first = sortedDates.first, let last = sortedDates.last {
            let start = calendar.startOfDay(for: first)
            let end = calendar.startOfDay(for: last)
            rangeDays = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        } else {
            rangeDays = 0
        }

        let repeated = uniqueTracks
            .sorted { $0.playCount > $1.playCount }
            .map {
                RekordboxRepeatedTrack(
                    id: $0.id,
                    title: $0.latest.title,
                    artist: $0.latest.artist,
                    count: $0.playCount,
                    artworkURL: $0.latest.artworkURL)
            }

        return RekordboxHistoryStats(
            dayCounts: dayCounts,
            dayPlaySeconds: dayPlaySeconds,
            activeDays: dayCounts.count,
            rangeDays: rangeDays,
            totalPlaySeconds: totalSeconds,
            averageBPM: bpmCount > 0 ? bpmTotal / Double(bpmCount) : 0,
            busiestDay: sortedCounts(dayCounts).first,
            peakHour: sortedCounts(hourCounts).first,
            sources: sortedCounts(sourceCounts),
            genres: sortedCounts(genreCounts),
            repeatedTracks: repeated)
    }

    private static func sortedCounts(_ values: [String: Int]) -> [RekordboxHistoryCount] {
        values.map { RekordboxHistoryCount(name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
            }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSS XXX",
            "yyyy-MM-dd HH:mm:ss XXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func firstNonempty(_ values: String...) -> String {
        values.first(where: { !$0.isEmpty }) ?? ""
    }

    private static func rekordboxArtworkURL(_ imagePath: String) -> URL? {
        guard !imagePath.isEmpty else { return nil }
        let relative = imagePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Pioneer/rekordbox/share")
            .appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

private enum MacHistoryTab: String, CaseIterable, Identifiable {
    case sets = "Sets"
    case stats = "Stats"
    case tracks = "Tracks"
    case paths = "Paths"

    var id: String { rawValue }
}

private enum MacHistoryTrackSort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case mostPlayed = "Most plays"
    case leastPlayed = "Least plays"

    var id: String { rawValue }
}

struct MacRekordboxHistoryPanel: View {
    @EnvironmentObject private var library: MacLibrary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MacRekordboxHistoryStore.shared
    @ObservedObject private var themes = MacThemeStore.shared

    @State private var activeTab: MacHistoryTab = .sets
    @State private var searchText = ""
    @State private var sourceFilter = "All sources"
    @State private var selectedSessionID: String?
    @State private var trackSort: MacHistoryTrackSort = .newest
    @State private var importSession: RekordboxHistorySession?
    @State private var pathKeys: [String] = []
    @State private var pathSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            historyHeader

            if let data = store.data {
                historySummary(data)
                Divider().overlay(Theme.panelBorder)
                historyContent(data)
            } else if store.isLoading {
                loadingView
            } else {
                errorView
            }
        }
        .frame(width: 1_260, height: 790)
        .background(Theme.background)
        .tint(themes.selectedTheme.accent)
        .task {
            await store.load()
            selectInitialContent()
        }
        .onChange(of: store.lastLoadedAt) { _, _ in
            selectInitialContent()
        }
        .sheet(item: $importSession) { session in
            MacHistoryImportTracksSheet(session: session)
                .environmentObject(library)
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                Text("REKORDBOX")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Text("Played Track History")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
            }

            Picker("View", selection: $activeTab) {
                ForEach(MacHistoryTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 310)

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textDim)
                TextField("Search sets, tracks, artists", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(width: 250, height: 34)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.panelBorder))

            Picker("Source", selection: $sourceFilter) {
                Text("All sources").tag("All sources")
                ForEach(store.data?.sources ?? [], id: \.self) { source in
                    Text(source).tag(source)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Menu {
                Button("Locate Database…") {
                    Task { await store.chooseDatabase() }
                }
                Button("Use Default Location") {
                    Task { await store.useDefaultDatabase() }
                }
                Divider()
                Text(store.databaseURL.path)
            } label: {
                Image(systemName: "externaldrive")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Rekordbox database")

            Button {
                Task { await store.load(force: true) }
            } label: {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoading)
            .help("Refresh history")

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.panelBorder)
        }
    }

    private func historySummary(_ data: RekordboxHistoryData) -> some View {
        HStack(spacing: 0) {
            historySummaryItem("SETS", "\(data.sessions.count)")
            historySummaryItem("PLAYED ROWS", data.tracks.count.formatted())
            historySummaryItem("UNIQUE TRACKS", data.uniqueTracks.count.formatted())
            historySummaryItem("RANGE", historyRange(data))
        }
        .frame(height: 66)
        .background(Theme.panel.opacity(0.72))
    }

    private func historySummaryItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .tracking(0.8)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func historyContent(_ data: RekordboxHistoryData) -> some View {
        switch activeTab {
        case .sets:
            setsView(data)
        case .stats:
            MacHistoryStatsView(data: data)
        case .tracks:
            tracksView(data)
        case .paths:
            pathsView(data)
        }
    }

    private func setsView(_ data: RekordboxHistoryData) -> some View {
        let sessions = filteredSessions(data)
        let selected = sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SETS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                        Text("\(sessions.count) sessions")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Spacer()
                }
                .padding(14)

                Divider().overlay(Theme.panelBorder)

                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(sessions) { session in
                            Button {
                                selectedSessionID = session.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(historyDateTime(session.startedAt)) · \(historyTimestamp(session.duration)) · \(session.tracks.count) tracks")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                    Text(session.tracks.first?.title ?? "Empty session")
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.42))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                                .background(
                                    selected?.id == session.id
                                        ? Theme.accent.opacity(0.17)
                                        : Theme.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selected?.id == session.id
                                            ? Theme.accent.opacity(0.6)
                                            : Theme.panelBorder))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
            }
            .frame(width: 304)
            .background(Theme.background)

            Divider().overlay(Theme.panelBorder)

            if let selected {
                sessionDetail(selected)
            } else {
                ContentUnavailableView(
                    "No matching sets",
                    systemImage: "music.note.list",
                    description: Text("Try a different search or source filter."))
            }
        }
    }

    private func sessionDetail(_ session: RekordboxHistorySession) -> some View {
        let tracks = filteredHistoryTracks(session.tracks)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(historyDateTime(session.startedAt).uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text(session.displayName)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("Duration \(historyTimestamp(session.duration)) · \(historySourceSummary(session.tracks))")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Text("\(tracks.count) / \(session.tracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                Button("Copy Set") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        timedSetlist(session),
                        forType: .string)
                }
                .buttonStyle(.bordered)
                Button("Export…") {
                    exportSetlist(session)
                }
                .buttonStyle(.bordered)
                Button("Add Tracks to Set Player") {
                    importSession = session
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(18)

            Divider().overlay(Theme.panelBorder)
            historyTrackHeader(unique: false)
            Divider().overlay(Theme.panelBorder)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        historyTrackRow(
                            track,
                            number: track.trackNumber > 0 ? track.trackNumber : index + 1,
                            playCount: track.djPlayCount,
                            sourceLabel: track.source)
                        if index < tracks.count - 1 {
                            Divider().overlay(Theme.panelBorder.opacity(0.7))
                        }
                    }
                }
            }
        }
        .background(Theme.background)
    }

    private func tracksView(_ data: RekordboxHistoryData) -> some View {
        let tracks = filteredUniqueTracks(data)
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TRACKS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text("Track Library")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                }
                Spacer()
                Text("\(tracks.count.formatted()) visible")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                Picker("Sort", selection: $trackSort) {
                    ForEach(MacHistoryTrackSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(18)

            Divider().overlay(Theme.panelBorder)
            historyTrackHeader(unique: true)
            Divider().overlay(Theme.panelBorder)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, unique in
                        historyTrackRow(
                            unique.latest,
                            number: index + 1,
                            playCount: unique.playCount,
                            sourceLabel: unique.sourceLabel)
                        if index < tracks.count - 1 {
                            Divider().overlay(Theme.panelBorder.opacity(0.7))
                        }
                    }
                }
            }
        }
    }

    private func historyTrackHeader(unique: Bool) -> some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 34, alignment: .trailing)
            Text("TRACK").frame(maxWidth: .infinity, alignment: .leading)
            Text(unique ? "LAST PLAYED" : "TIME").frame(width: 95, alignment: .leading)
            Text("KEY").frame(width: 52, alignment: .center)
            Text("BPM").frame(width: 52, alignment: .trailing)
            Text("LENGTH").frame(width: 58, alignment: .trailing)
            Text("PLAYS").frame(width: 46, alignment: .trailing)
            Text("SOURCE").frame(width: 88, alignment: .leading)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Theme.panel.opacity(0.55))
    }

    private func historyTrackRow(
        _ track: RekordboxHistoryTrack,
        number: Int,
        playCount: Int?,
        sourceLabel: String
    ) -> some View {
        let camelot = historyCamelotKey(track.key)
        let keyColor = historyCamelotColor(camelot)
        return HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 34, alignment: .trailing)

            HStack(spacing: 10) {
                HistoryArtwork(url: track.artworkURL, title: track.title)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(historyRowTime(track.playedAt))
                .frame(width: 95, alignment: .leading)

            Text(camelot)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(keyColor)
                .padding(.horizontal, camelot.isEmpty ? 0 : 6)
                .frame(width: 52, height: 22)
                .background(
                    camelot.isEmpty ? Color.clear : keyColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(camelot.isEmpty ? Color.clear : keyColor.opacity(0.38)))

            Text(track.bpm.map { String(format: "%.1f", $0) } ?? "")
                .frame(width: 52, alignment: .trailing)
            Text(track.lengthSeconds.map(historyDuration) ?? "")
                .frame(width: 58, alignment: .trailing)
            Text(playCount.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
            Text(sourceLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 16)
        .frame(height: 54)
        .contentShape(Rectangle())
        .background(Color.white.opacity(0.001))
    }

    private func pathsView(_ data: RekordboxHistoryData) -> some View {
        let roots = pathRootTracks(data)
        let currentKey = pathKeys.last
        let current = currentKey.flatMap { data.uniqueByKey[$0] }
        let next = currentKey.flatMap { data.transitions[$0] } ?? []
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PATHS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text("Start Track")
                        .font(.system(size: 17, weight: .bold))
                    Text("Choose a song to explore what historically followed it.")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)

                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.textDim)
                        TextField("Search start tracks", text: $pathSearchText)
                            .textFieldStyle(.plain)
                        if !pathSearchText.isEmpty {
                            Button {
                                pathSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.textDim)
                            }
                            .buttonStyle(.plain)
                            .help("Clear search")
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 31)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.panelBorder))
                    .padding(.top, 8)
                }
                .padding(16)

                Divider().overlay(Theme.panelBorder)

                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(roots.prefix(180)) { root in
                            Button {
                                pathKeys = [root.id]
                            } label: {
                                HStack(spacing: 9) {
                                    HistoryArtwork(
                                        url: root.latest.artworkURL,
                                        title: root.latest.title)
                                        .frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(root.latest.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Text("\(root.playCount) plays")
                                            .font(.caption)
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    Spacer()
                                }
                                .padding(9)
                                .background(
                                    pathKeys.first == root.id
                                        ? Theme.accent.opacity(0.16)
                                        : Theme.panel,
                                    in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
            }
            .frame(width: 330)

            Divider().overlay(Theme.panelBorder)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HISTORICAL NEXT-TRACK CHOICES")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                        Text(current?.latest.title ?? "Choose a start track")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    if pathKeys.count > 1 {
                        Button("Back") { pathKeys.removeLast() }
                            .buttonStyle(.bordered)
                    }
                    if !pathKeys.isEmpty {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                pathText(data),
                                forType: .string)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(18)

                if !pathKeys.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(Array(pathKeys.enumerated()), id: \.offset) { index, key in
                                if let track = data.uniqueByKey[key] {
                                    Button {
                                        pathKeys = Array(pathKeys.prefix(index + 1))
                                    } label: {
                                        Text("\(index + 1). \(track.latest.title)")
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                            .padding(.horizontal, 10)
                                            .frame(height: 30)
                                            .background(
                                                index == pathKeys.count - 1
                                                    ? Theme.accent.opacity(0.23)
                                                    : Theme.panel,
                                                in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    if index < pathKeys.count - 1 {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.textDim)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    .frame(height: 45)
                }

                Divider().overlay(Theme.panelBorder)

                if current == nil {
                    ContentUnavailableView(
                        "Choose a start track",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Historical transitions will appear here."))
                } else if next.isEmpty {
                    ContentUnavailableView(
                        "End of this path",
                        systemImage: "checkmark.circle",
                        description: Text("No later track was recorded after this song."))
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)
                            ],
                            spacing: 10
                        ) {
                            ForEach(next.prefix(40)) { transition in
                                if let target = data.uniqueByKey[transition.targetKey] {
                                    Button {
                                        pathKeys.append(transition.targetKey)
                                    } label: {
                                        HStack(spacing: 11) {
                                            HistoryArtwork(
                                                url: target.latest.artworkURL,
                                                title: target.latest.title)
                                                .frame(width: 44, height: 44)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(target.latest.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .lineLimit(1)
                                                Text(target.latest.artist)
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.textDim)
                                                    .lineLimit(1)
                                                Text("followed \(transition.count)×")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(Theme.accent.opacity(0.68))
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(Theme.textDim)
                                        }
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 15) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Rekordbox History")
                .font(.title2.weight(.semibold))
            Text("Reading sets and resolving saved Spotify metadata…")
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.accent)
            Text(store.status)
                .font(.title2.weight(.semibold))
            Text(store.errorMessage ?? "No Rekordbox history is available.")
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack {
                Button("Locate Database…") {
                    Task { await store.chooseDatabase() }
                }
                .buttonStyle(.borderedProminent)
                Button("Try Default") {
                    Task { await store.useDefaultDatabase() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filteredSessions(_ data: RekordboxHistoryData) -> [RekordboxHistorySession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return data.sessions.filter { session in
            let sourceMatches = sourceFilter == "All sources"
                || session.tracks.contains(where: { $0.source == sourceFilter })
            guard sourceMatches else { return false }
            guard !query.isEmpty else { return true }
            return session.displayName.lowercased().contains(query)
                || session.name.lowercased().contains(query)
                || session.tracks.contains(where: { historyTrackMatches($0, query: query) })
        }
    }

    private func filteredHistoryTracks(
        _ tracks: [RekordboxHistoryTrack]
    ) -> [RekordboxHistoryTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tracks.filter { track in
            (sourceFilter == "All sources" || track.source == sourceFilter)
                && (query.isEmpty || historyTrackMatches(track, query: query))
        }
    }

    private func filteredUniqueTracks(
        _ data: RekordboxHistoryData
    ) -> [RekordboxUniqueTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var tracks = data.uniqueTracks.filter { unique in
            (sourceFilter == "All sources" || unique.sources.contains(sourceFilter))
                && (query.isEmpty || historyTrackMatches(unique.latest, query: query))
        }
        tracks.sort {
            switch trackSort {
            case .newest: return $0.latest.playedAt > $1.latest.playedAt
            case .oldest: return $0.latest.playedAt < $1.latest.playedAt
            case .mostPlayed:
                return $0.playCount == $1.playCount
                    ? $0.latest.title < $1.latest.title
                    : $0.playCount > $1.playCount
            case .leastPlayed:
                return $0.playCount == $1.playCount
                    ? $0.latest.title < $1.latest.title
                    : $0.playCount < $1.playCount
            }
        }
        return tracks
    }

    private func pathRootTracks(_ data: RekordboxHistoryData) -> [RekordboxUniqueTrack] {
        let globalQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathQuery = pathSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return data.uniqueTracks
            .filter { data.transitions[$0.id] != nil }
            .filter { sourceFilter == "All sources" || $0.sources.contains(sourceFilter) }
            .filter { globalQuery.isEmpty || historyTrackMatches($0.latest, query: globalQuery) }
            .filter { pathQuery.isEmpty || historyTrackMatches($0.latest, query: pathQuery) }
            .sorted { $0.playCount > $1.playCount }
    }

    private func historyTrackMatches(
        _ track: RekordboxHistoryTrack,
        query: String
    ) -> Bool {
        [track.title, track.artist, track.album, track.genre, track.key, track.source, track.path]
            .contains { $0.lowercased().contains(query) }
    }

    private func historyRange(_ data: RekordboxHistoryData) -> String {
        guard let oldest = data.tracks.map(\.playedAt).min(),
              let newest = data.tracks.map(\.playedAt).max() else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: oldest)) – \(formatter.string(from: newest))"
    }

    private func historySourceSummary(_ tracks: [RekordboxHistoryTrack]) -> String {
        var counts: [String: Int] = [:]
        tracks.forEach { counts[$0.source, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }

    private func timedSetlist(_ session: RekordboxHistorySession) -> String {
        let tracks = session.tracks.sorted { $0.trackNumber < $1.trackNumber }
        guard let first = tracks.first?.playedAt else { return "" }
        return tracks.map { track in
            let elapsed = max(0, track.playedAt.timeIntervalSince(first))
            return "\(historyTimestamp(elapsed)) - \(track.displayLabel)"
        }
        .joined(separator: "\n")
    }

    private func exportSetlist(_ session: RekordboxHistorySession) {
        let panel = NSSavePanel()
        panel.title = "Export Rekordbox Setlist"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.displayName).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = "\(session.displayName)\n\(historyDateTime(session.startedAt))\n\n"
        try? (header + timedSetlist(session)).data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func pathText(_ data: RekordboxHistoryData) -> String {
        pathKeys.enumerated().compactMap { index, key in
            data.uniqueByKey[key].map { "\(index + 1). \($0.latest.displayLabel)" }
        }
        .joined(separator: "\n")
    }

    private func selectInitialContent() {
        guard let data = store.data else { return }
        if selectedSessionID == nil {
            selectedSessionID = data.sessions.first?.id
        }
        if pathKeys.isEmpty,
           let root = data.uniqueTracks
            .filter({ data.transitions[$0.id] != nil })
            .max(by: { $0.playCount < $1.playCount }) {
            pathKeys = [root.id]
        }
    }
}

private struct MacHistoryStatsView: View {
    @ObservedObject private var themes = MacThemeStore.shared
    let data: RekordboxHistoryData

    private var accent: Color { Theme.accent }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ],
                    spacing: 16
                ) {
                    activityCard
                    genreCard
                }

                listeningStatsCard
            }
            .padding(18)
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            historySectionHeading("STATS", "Play Activity", trailing: "\(data.stats.activeDays) active days")
            MacHistoryActivityHeatmap(
                dayCounts: data.stats.dayCounts,
                dayPlaySeconds: data.stats.dayPlaySeconds)
                .frame(height: 166)
        }
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
    }

    private var genreCard: some View {
        let genres = Array(data.stats.genres.prefix(7))
        return VStack(alignment: .leading, spacing: 10) {
            historySectionHeading("GENRES", "Genre Mix")
            if genres.isEmpty {
                ContentUnavailableView("No genre metadata", systemImage: "chart.pie")
                    .frame(height: 170)
            } else {
                Chart(genres) { item in
                    SectorMark(
                        angle: .value("Tracks", item.count),
                        innerRadius: .ratio(0.58),
                        angularInset: 2)
                        .foregroundStyle(by: .value("Genre", item.name))
                        .cornerRadius(3)
                }
                .chartLegend(position: .trailing, alignment: .center, spacing: 8)
                .frame(height: 180)
            }
        }
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
    }

    private var listeningStatsCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            historySectionHeading("LIBRARY", "Listening Stats")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                stat("TOTAL PLAY TIME", historyLongDuration(data.stats.totalPlaySeconds))
                stat(
                    "AVG TIME / DAY",
                    historyLongDuration(data.stats.rangeDays > 0
                        ? data.stats.totalPlaySeconds / Double(data.stats.rangeDays)
                        : 0),
                    "\(data.stats.rangeDays) days")
                stat(
                    "AVG PLAYS / DAY",
                    data.stats.rangeDays > 0
                        ? String(format: "%.1f", Double(data.tracks.count) / Double(data.stats.rangeDays))
                        : "0")
                stat(
                    "BUSIEST DAY",
                    data.stats.busiestDay.map { historyDayName($0.name) } ?? "—",
                    data.stats.busiestDay.map { "\($0.count) plays" } ?? "")
                stat("PEAK HOUR", data.stats.peakHour?.name ?? "—")
                stat(
                    "TOP SOURCE",
                    data.stats.sources.first.map { "\($0.name) (\($0.count.formatted()))" } ?? "—")
                stat(
                    "AVG BPM",
                    data.stats.averageBPM > 0
                        ? String(format: "%.1f", data.stats.averageBPM)
                        : "—")
                stat("UNIQUE TRACKS", data.uniqueTracks.count.formatted())
            }

            Divider().overlay(Theme.panelBorder)

            HStack {
                Text("Most repeated")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("PLAYS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }

            ForEach(data.stats.repeatedTracks.prefix(10)) { track in
                HStack(spacing: 10) {
                    HistoryArtwork(url: track.artworkURL, title: track.title)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(track.count.formatted())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
        }
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
    }

    private func historySectionHeading(
        _ eyebrow: String,
        _ title: String,
        trailing: String = ""
    ) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
            }
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ sub: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MacHistoryActivityHeatmap: View {
    @ObservedObject private var themes = MacThemeStore.shared
    let dayCounts: [String: Int]
    let dayPlaySeconds: [String: TimeInterval]

    private let calendar = Calendar.current

    var body: some View {
        let days = heatmapDays()
        let maximum = max(1, dayCounts.values.max() ?? 1)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(stride(from: 0, to: days.count, by: 7)), id: \.self) { start in
                    VStack(spacing: 3) {
                        ForEach(start..<min(start + 7, days.count), id: \.self) { index in
                            let day = days[index]
                            let count = dayCounts[day.key] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(heatColor(count: count, maximum: maximum))
                                .frame(width: 13, height: 13)
                                .help(heatmapHelp(day: day.key, count: count))
                        }
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 3) {
                Text("Less")
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(heatColor(count: level, maximum: 4))
                        .frame(width: 10, height: 10)
                }
                Text("More")
            }
            .font(.caption2)
            .foregroundStyle(Theme.textDim)
        }
    }

    private func heatmapDays() -> [(key: String, date: Date)] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let parsed = dayCounts.keys.compactMap { key in
            formatter.date(from: key).map { (key, $0) }
        }
        guard let firstDate = parsed.map(\.1).min(),
              let lastDate = parsed.map(\.1).max() else { return [] }
        let start = calendar.dateInterval(of: .weekOfYear, for: firstDate)?.start ?? firstDate
        let endWeek = calendar.dateInterval(of: .weekOfYear, for: lastDate)?.end ?? lastDate
        var values: [(String, Date)] = []
        var cursor = start
        while cursor < endWeek {
            values.append((formatter.string(from: cursor), cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? endWeek
        }
        return values
    }

    private func heatColor(count: Int, maximum: Int) -> Color {
        guard count > 0 else { return Color.white.opacity(0.055) }
        let ratio = Double(count) / Double(maximum)
        if ratio > 0.75 { return Color(hex: 0x526DFF) }
        if ratio > 0.45 { return Color(hex: 0x4157D7) }
        if ratio > 0.2 { return Color(hex: 0x3345AD) }
        return Color(hex: 0x293989)
    }

    private func heatmapHelp(day: String, count: Int) -> String {
        let playTime = historyLongDuration(dayPlaySeconds[day] ?? 0)
        return "\(historyDayName(day)) · \(playTime) played · \(count) \(count == 1 ? "track" : "tracks")"
    }
}

private struct MacHistoryImportTracksSheet: View {
    @EnvironmentObject private var library: MacLibrary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themes = MacThemeStore.shared
    let session: RekordboxHistorySession

    @State private var selectedSetID: UUID?

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add History Tracks")
                        .font(.title2.weight(.semibold))
                    Text(session.displayName)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SET PLAYER SET")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Picker("Set", selection: $selectedSetID) {
                    Text("Choose a set").tag(UUID?.none)
                    ForEach(library.sets) { set in
                        Text("\(set.title) · \(formatTime(set.duration))")
                            .tag(Optional(set.id))
                    }
                }
                .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder))

            if let selected = library.sets.first(where: { $0.id == selectedSetID }),
               !selected.annotations.isEmpty {
                Label(
                    "This replaces \(selected.annotations.count) existing tracks in \(selected.title).",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                guard let selectedSetID else { return }
                library.replaceTracks(
                    historyAnnotations(),
                    in: selectedSetID)
                dismiss()
            } label: {
                Label(
                    "Import \(session.tracks.count) Tracks",
                    systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedSetID == nil)
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.background)
        .onAppear {
            selectedSetID = bestMatchingSetID()
        }
    }

    private func historyAnnotations() -> [SetAnnotation] {
        let tracks = session.tracks.sorted { $0.trackNumber < $1.trackNumber }
        guard let first = tracks.first?.playedAt else { return [] }
        return tracks.map { track in
            SetAnnotation(
                time: max(0, track.playedAt.timeIntervalSince(first)),
                label: track.displayLabel,
                artworkURL: track.artworkURL)
        }
    }

    private func bestMatchingSetID() -> UUID? {
        let sessionDuration = session.tracks.last.map {
            $0.playedAt.timeIntervalSince(session.tracks.first?.playedAt ?? $0.playedAt)
        } ?? 0
        return library.sets.min { lhs, rhs in
            abs(lhs.duration - sessionDuration) < abs(rhs.duration - sessionDuration)
        }?.id
    }
}

private struct RekordboxRecordedSetMatch {
    let session: RekordboxHistorySession
    let tracks: [RekordboxHistoryTrack]
    let annotations: [SetAnnotation]
    let score: Double
    let method: String
    let recordingStart: Date?

    var confidence: String {
        if score <= 0.18 { return "High confidence" }
        if score <= 0.38 { return "Good match" }
        return "Possible match"
    }

    var matchedSpan: TimeInterval {
        guard let first = tracks.first?.playedAt,
              let last = tracks.last?.playedAt else { return 0 }
        return max(0, last.timeIntervalSince(first))
    }
}

private enum RekordboxRecordedSetMatcher {
    private struct Candidate {
        let session: RekordboxHistorySession
        let tracks: [RekordboxHistoryTrack]
        let score: Double
        let method: String
        let recordingStart: Date?
    }

    static func match(
        set: DJSet,
        data: RekordboxHistoryData,
        overrideWindow: DateInterval? = nil
    ) -> RekordboxRecordedSetMatch? {
        guard set.duration >= 30 else { return nil }
        let markers = set.annotations.sorted { $0.time < $1.time }
        let inferredWindow = inferredWindow(for: set)
        let recordingStart = overrideWindow?.start ?? inferredWindow?.start

        let candidate: Candidate?
        if let overrideWindow {
            candidate = manualWindowCandidate(
                window: overrideWindow,
                sessions: data.sessions)
        } else if markers.count >= 2 {
            candidate = markerCandidate(
                markers: markers,
                recordingStart: recordingStart,
                sessions: data.sessions)
        } else {
            candidate = clockCandidate(
                duration: set.duration,
                recordingStart: recordingStart,
                sessions: data.sessions)
        }

        guard let candidate, candidate.score <= 0.72 else { return nil }
        let annotations = makeAnnotations(
            set: set,
            markers: markers,
            candidate: candidate)
        guard !annotations.isEmpty else { return nil }
        return RekordboxRecordedSetMatch(
            session: candidate.session,
            tracks: candidate.tracks,
            annotations: annotations,
            score: candidate.score,
            method: candidate.method,
            recordingStart: candidate.recordingStart)
    }

    static func inferredWindow(for set: DJSet) -> DateInterval? {
        guard let end = recordingEndDate(fileName: set.fileName) else { return nil }
        return DateInterval(
            start: end.addingTimeInterval(-set.duration),
            end: end)
    }

    private static func markerCandidate(
        markers: [SetAnnotation],
        recordingStart: Date?,
        sessions: [RekordboxHistorySession]
    ) -> Candidate? {
        let markerSpan = max(1, (markers.last?.time ?? 0) - (markers.first?.time ?? 0))
        var best: Candidate?

        for session in sessions {
            let history = session.tracks.sorted { $0.playedAt < $1.playedAt }
            guard history.count >= markers.count else { continue }
            if let recordingStart,
               let sessionFirst = history.first?.playedAt,
               let sessionLast = history.last?.playedAt {
                let expectedFirst = recordingStart.addingTimeInterval(markers.first?.time ?? 0)
                let expectedLast = recordingStart.addingTimeInterval(markers.last?.time ?? 0)
                let distance: TimeInterval
                if sessionLast < expectedFirst {
                    distance = expectedFirst.timeIntervalSince(sessionLast)
                } else if sessionFirst > expectedLast {
                    distance = sessionFirst.timeIntervalSince(expectedLast)
                } else {
                    distance = 0
                }
                guard distance <= 12 * 3_600 else { continue }
            }
            for startIndex in 0...(history.count - markers.count) {
                let tracks = Array(history[startIndex..<(startIndex + markers.count)])
                guard let first = tracks.first?.playedAt,
                      let last = tracks.last?.playedAt else { continue }
                let historySpan = max(1, last.timeIntervalSince(first))
                let durationPenalty = min(
                    2,
                    abs(historySpan - markerSpan) / max(markerSpan, 60))
                guard durationPenalty < 0.85 else { continue }

                let shapePenalty = normalizedShapePenalty(
                    markers: markers,
                    tracks: tracks,
                    markerSpan: markerSpan,
                    historySpan: historySpan)
                let clockPenalty: Double
                let clockError: TimeInterval?
                if let recordingStart {
                    let expectedFirst = recordingStart.addingTimeInterval(markers.first?.time ?? 0)
                    let expectedLast = recordingStart.addingTimeInterval(markers.last?.time ?? 0)
                    let error = (
                        abs(first.timeIntervalSince(expectedFirst))
                        + abs(last.timeIntervalSince(expectedLast))) / 2
                    clockError = error
                    // Keep date proximity meaningful across the full history.
                    // A recording can have a few hours of imperfect metadata,
                    // but a lookalike sequence from weeks earlier should lose.
                    clockPenalty = min(1, error / (48 * 3_600))
                } else {
                    clockError = nil
                    clockPenalty = 0.5
                }

                let score = durationPenalty * 0.42
                    + shapePenalty * 0.28
                    + clockPenalty * 0.30
                let usesClock = (clockError ?? .greatestFiniteMagnitude) <= 15 * 60
                let method = usesClock
                    ? "Recording time and marker timing agree"
                    : "Matched by set duration and marker timing"
                let candidate = Candidate(
                    session: session,
                    tracks: tracks,
                    score: score,
                    method: method,
                    recordingStart: recordingStart)
                if best == nil || candidate.score < best!.score {
                    best = candidate
                }
            }
        }
        return best
    }

    private static func normalizedShapePenalty(
        markers: [SetAnnotation],
        tracks: [RekordboxHistoryTrack],
        markerSpan: TimeInterval,
        historySpan: TimeInterval
    ) -> Double {
        guard let firstMarker = markers.first?.time,
              let firstTrack = tracks.first?.playedAt,
              markers.count == tracks.count else { return 1 }
        let total = zip(markers, tracks).reduce(0.0) { partial, pair in
            let markerPosition = (pair.0.time - firstMarker) / markerSpan
            let historyPosition = pair.1.playedAt.timeIntervalSince(firstTrack) / historySpan
            return partial + abs(markerPosition - historyPosition)
        }
        return min(1, (total / Double(markers.count)) * 3.2)
    }

    private static func clockCandidate(
        duration: TimeInterval,
        recordingStart: Date?,
        sessions: [RekordboxHistorySession]
    ) -> Candidate? {
        guard let recordingStart else { return nil }
        let recordingEnd = recordingStart.addingTimeInterval(duration)
        var best: Candidate?

        for session in sessions {
            let ordered = session.tracks.sorted { $0.playedAt < $1.playedAt }
            let inside = ordered.filter {
                $0.playedAt >= recordingStart.addingTimeInterval(-5 * 60)
                    && $0.playedAt <= recordingEnd.addingTimeInterval(90)
            }
            guard !inside.isEmpty else { continue }
            let actual = inside.filter { $0.playedAt >= recordingStart }
            guard !actual.isEmpty else { continue }
            let startError = abs((inside.first?.playedAt ?? recordingStart)
                .timeIntervalSince(recordingStart))
            let endError = abs((inside.last?.playedAt ?? recordingEnd)
                .timeIntervalSince(recordingEnd))
            let boundaryPenalty = min(1, (startError + endError) / max(duration * 2, 60))
            let densityReward = min(0.18, Double(inside.count) * 0.008)
            let score = max(0.02, boundaryPenalty * 0.62 + 0.16 - densityReward)
            let candidate = Candidate(
                session: session,
                tracks: inside,
                score: score,
                method: "Matched by the recording start and end time",
                recordingStart: recordingStart)
            if best == nil || candidate.score < best!.score {
                best = candidate
            }
        }
        return best
    }

    private static func manualWindowCandidate(
        window: DateInterval,
        sessions: [RekordboxHistorySession]
    ) -> Candidate? {
        guard window.duration >= 10 else { return nil }
        var best: Candidate?
        for session in sessions {
            let ordered = session.tracks.sorted { $0.playedAt < $1.playedAt }
            let inside = ordered.filter {
                $0.playedAt >= window.start.addingTimeInterval(-5 * 60)
                    && $0.playedAt <= window.end
            }
            guard !inside.isEmpty else { continue }
            let actualCount = inside.lazy.filter { $0.playedAt >= window.start }.count
            guard actualCount > 0 else { continue }
            let score = max(0.03, 0.14 - min(0.1, Double(actualCount) * 0.004))
            let candidate = Candidate(
                session: session,
                tracks: inside,
                score: score,
                method: "Matched from your selected Rekordbox time window",
                recordingStart: window.start)
            if best == nil
                || candidate.tracks.count > best!.tracks.count
                || (candidate.tracks.count == best!.tracks.count
                    && candidate.score < best!.score) {
                best = candidate
            }
        }
        return best
    }

    private static func makeAnnotations(
        set: DJSet,
        markers: [SetAnnotation],
        candidate: Candidate
    ) -> [SetAnnotation] {
        if markers.count == candidate.tracks.count {
            return zip(markers, candidate.tracks).map { marker, track in
                SetAnnotation(
                    id: marker.id,
                    time: marker.time,
                    label: track.displayLabel,
                    artworkURL: track.artworkURL)
            }
        }

        let firstTrack = candidate.tracks.first?.playedAt
        return candidate.tracks.compactMap { track in
            let rawTime: TimeInterval
            if let recordingStart = candidate.recordingStart {
                rawTime = track.playedAt.timeIntervalSince(recordingStart)
            } else if let firstTrack {
                rawTime = track.playedAt.timeIntervalSince(firstTrack)
            } else {
                return nil
            }
            return SetAnnotation(
                time: min(set.duration, max(0, rawTime)),
                label: track.displayLabel,
                artworkURL: track.artworkURL)
        }
    }

    private static func recordingEndDate(fileName: String) -> Date? {
        let name = URL(fileURLWithPath: fileName)
            .deletingPathExtension().lastPathComponent
        let pattern = #"Set (\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.date(from: String(name[range]))
    }
}

struct MacRekordboxSetMatcherSheet: View {
    @EnvironmentObject private var library: MacLibrary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MacRekordboxHistoryStore.shared
    @ObservedObject private var themes = MacThemeStore.shared

    let set: DJSet

    @State private var match: RekordboxRecordedSetMatch?
    @State private var isMatching = true
    @State private var didFinishAttempt = false
    @State private var didInitializeWindow = false
    @State private var manualStart = Date()
    @State private var manualEnd = Date()
    @State private var selectedTrackIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.accent.opacity(0.18))
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.accent.opacity(0.82))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Match Rekordbox Tracks")
                        .font(.title2.weight(.semibold))
                    Text(set.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(20)

            Divider().overlay(Theme.panelBorder)

            recordingWindowEditor

            Divider().overlay(Theme.panelBorder)

            Group {
                if isMatching {
                    matchingView
                } else if let match {
                    preview(match)
                } else {
                    noMatchView
                }
            }
        }
        .frame(width: 790, height: 740)
        .background(Theme.background)
        .task {
            initializeRecordingWindow()
            await tryMatch(forceReload: false)
        }
    }

    private var recordingWindowEditor: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("RECORDED WINDOW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent.opacity(0.82))
                Text("Adjust this if the songs do not line up.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            DatePicker(
                "Start",
                selection: $manualStart,
                displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)

            Image(systemName: "arrow.right")
                .foregroundStyle(Theme.textDim)

            DatePicker(
                "End",
                selection: $manualEnd,
                displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)

            Text(historyLongDuration(max(0, manualEnd.timeIntervalSince(manualStart))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textDim)
                .frame(width: 55, alignment: .trailing)

            Button {
                guard manualEnd > manualStart else { return }
                let window = DateInterval(start: manualStart, end: manualEnd)
                Task { await tryMatch(forceReload: false, overrideWindow: window) }
            } label: {
                Label("Try This Window", systemImage: "clock.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isMatching || manualEnd.timeIntervalSince(manualStart) < 10)
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
    }

    private var matchingView: some View {
        VStack(spacing: 15) {
            ProgressView()
                .controlSize(.large)
            Text("Matching recording time, duration, and track markers…")
                .font(.headline)
            Text("Nothing changes until you review and apply the result.")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchView: some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.accent.opacity(0.82))
            Text("No reliable history match")
                .font(.title2.weight(.semibold))
            Text(noMatchMessage)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button {
                Task { await tryMatch(forceReload: true) }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchMessage: String {
        if set.duration < 30 {
            return "This recording is too short to identify safely from played-track history."
        }
        if let error = store.errorMessage { return error }
        if didFinishAttempt {
            return "No Rekordbox sequence lined up closely enough with this set’s time, duration, and current markers."
        }
        return "Rekordbox history is still loading."
    }

    private func preview(_ match: RekordboxRecordedSetMatch) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                matchStat("MATCH", match.confidence, detail: match.method)
                matchStat(
                    "HISTORY SET",
                    historyDateTime(match.session.startedAt),
                    detail: "\(historyTimestamp(match.matchedSpan)) span")
                matchStat(
                    "TRACKS",
                    "\(selectedTrackIDs.count) of \(match.tracks.count)",
                    detail: set.annotations.count == match.tracks.count
                        ? "marker positions preserved"
                        : "timed from history")
            }
            .padding(16)

            if !set.annotations.isEmpty {
                Label(
                    "Applying replaces the current track list. Selected matches keep their marker times; deselected songs are left out. The audio never changes.",
                    systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            Divider().overlay(Theme.panelBorder)

            HStack {
                Text("\(selectedTrackIDs.count) of \(match.tracks.count) songs selected")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Select All") {
                    selectedTrackIDs = Set(match.tracks.map(\.id))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                Button("Clear") {
                    selectedTrackIDs.removeAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 18)
            .frame(height: 34)

            Divider().overlay(Theme.panelBorder)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(match.tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            toggleTrack(track.id)
                        } label: {
                            matchedTrackRow(
                                track,
                                index: index,
                                time: match.annotations[index].time,
                                isSelected: selectedTrackIDs.contains(track.id))
                        }
                        .buttonStyle(.plain)
                        if index < match.tracks.count - 1 {
                            Divider()
                                .overlay(Theme.panelBorder)
                                .padding(.leading, 76)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            Divider().overlay(Theme.panelBorder)

            HStack {
                Button {
                    Task { await tryMatch(forceReload: true) }
                } label: {
                    Label("Auto Match", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("Review the songs before applying.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                Button {
                    library.replaceTracks(selectedAnnotations(from: match), in: set.id)
                    dismiss()
                } label: {
                    Label(
                        "Apply \(selectedTrackIDs.count) Matched Tracks",
                        systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTrackIDs.isEmpty)
            }
            .padding(16)
        }
    }

    private func matchStat(_ label: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.82))
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelBorder))
    }

    private func matchedTrackRow(
        _ track: RekordboxHistoryTrack,
        index: Int,
        time: TimeInterval,
        isSelected: Bool
    ) -> some View {
        let camelot = historyCamelotKey(track.key)
        let keyColor = historyCamelotColor(camelot)
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textDim)
                .frame(width: 18)
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 28, alignment: .trailing)
            HistoryArtwork(url: track.artworkURL, title: track.title)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist.isEmpty ? track.album : track.artist)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer()
            if !camelot.isEmpty {
                Text(camelot)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(keyColor)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(keyColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(historyTimestamp(time))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 62, alignment: .trailing)
        }
        .frame(height: 56)
        .contentShape(Rectangle())
    }

    @MainActor
    private func tryMatch(
        forceReload: Bool,
        overrideWindow: DateInterval? = nil
    ) async {
        isMatching = true
        didFinishAttempt = false
        await store.load(force: forceReload)
        if let data = store.data {
            match = RekordboxRecordedSetMatcher.match(
                set: set,
                data: data,
                overrideWindow: overrideWindow)
        } else {
            match = nil
        }
        selectedTrackIDs = Set(match?.tracks.map(\.id) ?? [])
        didFinishAttempt = true
        isMatching = false
    }

    private func initializeRecordingWindow() {
        guard !didInitializeWindow else { return }
        let window = RekordboxRecordedSetMatcher.inferredWindow(for: set)
            ?? DateInterval(
                start: set.addedAt.addingTimeInterval(-set.duration),
                end: set.addedAt)
        manualStart = window.start
        manualEnd = window.end
        didInitializeWindow = true
    }

    private func toggleTrack(_ id: String) {
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func selectedAnnotations(
        from match: RekordboxRecordedSetMatch
    ) -> [SetAnnotation] {
        zip(match.tracks, match.annotations).compactMap { track, annotation in
            selectedTrackIDs.contains(track.id) ? annotation : nil
        }
    }
}

private struct HistoryArtwork: View {
    @ObservedObject private var themes = MacThemeStore.shared
    let url: URL?
    let title: String

    @State private var localImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.accent.opacity(0.14))
            if let url, url.isFileURL {
                if let localImage {
                    Image(nsImage: localImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallback
                }
            } else if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            guard let url, url.isFileURL else {
                localImage = nil
                return
            }
            localImage = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
        }
    }

    private var fallback: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.accent.opacity(0.68))
    }
}

private func historyDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func historyRowTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter.string(from: date)
}

private func historyDuration(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", value / 60, value % 60)
}

private func historyTimestamp(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3_600 {
        return String(format: "%d:%02d:%02d", value / 3_600, (value % 3_600) / 60, value % 60)
    }
    return String(format: "%02d:%02d", value / 60, value % 60)
}

private func historyLongDuration(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded()))
    let hours = value / 3_600
    let minutes = (value % 3_600) / 60
    if hours == 0 { return "\(minutes)m" }
    if minutes == 0 { return "\(hours)h" }
    return "\(hours)h \(minutes)m"
}

private func historyDayName(_ key: String) -> String {
    let input = DateFormatter()
    input.locale = Locale(identifier: "en_US_POSIX")
    input.dateFormat = "yyyy-MM-dd"
    guard let date = input.date(from: key) else { return key }
    let output = DateFormatter()
    output.locale = .current
    output.dateStyle = .medium
    output.timeStyle = .none
    return output.string(from: date)
}

private func historyCamelotKey(_ raw: String) -> String {
    let cleaned = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
    if let match = cleaned.range(
        of: #"^(?:[1-9]|1[0-2])[AaBb]$"#,
        options: .regularExpression) {
        return String(cleaned[match]).uppercased()
    }

    let normalized = cleaned
        .replacingOccurrences(of: "minor", with: "m", options: .caseInsensitive)
        .replacingOccurrences(of: "major", with: "", options: .caseInsensitive)
    let standard: [String: String] = [
        "Abm": "1A", "G#m": "1A", "B": "1B",
        "Ebm": "2A", "D#m": "2A", "F#": "2B", "Gb": "2B",
        "Bbm": "3A", "A#m": "3A", "Db": "3B", "C#": "3B",
        "Fm": "4A", "Ab": "4B", "G#": "4B",
        "Cm": "5A", "Eb": "5B", "D#": "5B",
        "Gm": "6A", "Bb": "6B", "A#": "6B",
        "Dm": "7A", "F": "7B",
        "Am": "8A", "C": "8B",
        "Em": "9A", "G": "9B",
        "Bm": "10A", "D": "10B",
        "F#m": "11A", "Gbm": "11A", "A": "11B",
        "Dbm": "12A", "C#m": "12A", "E": "12B"
    ]
    return standard[normalized] ?? (cleaned == "0" ? "" : cleaned)
}

private func historyCamelotColor(_ key: String) -> Color {
    let digits = key.prefix { $0.isNumber }
    guard let number = Double(digits), (1...12).contains(number) else {
        return Theme.accent.opacity(0.68)
    }
    return Color(
        hue: (number - 1) / 12,
        saturation: 0.76,
        brightness: 0.96)
}
