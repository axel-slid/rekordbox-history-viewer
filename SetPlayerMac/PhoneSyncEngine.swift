import Foundation

struct PhoneSyncResult {
    var deviceName: String
    var setCount: Int
    var pulledFiles: Int
    var pushedFiles: Int
    var waveformFiles: Int
    var photoFiles: Int
    var videoFiles: Int
}

enum PhoneSyncError: LocalizedError {
    case noPhone
    case commandFailed(String)
    case malformedResponse(String)
    case missingPhoneLibrary

    var errorDescription: String? {
        switch self {
        case .noPhone:
            return "No paired iPhone is currently reachable."
        case .commandFailed(let message):
            return message
        case .malformedResponse(let message):
            return "Couldn’t read the iPhone response: \(message)"
        case .missingPhoneLibrary:
            return "Set Player is installed, but its phone library could not be read."
        }
    }
}

enum PhoneSyncEngine {
    private static let appBundleID = "com.alexdils.setplayer"

    static func sync(localDocumentsURL: URL) throws -> PhoneSyncResult {
        let fileManager = FileManager.default
        let localSetsURL = localDocumentsURL.appendingPathComponent("Sets", isDirectory: true)
        let localWaveformsURL = localDocumentsURL.appendingPathComponent(
            "waveforms",
            isDirectory: true)
        let localPhotosURL = localDocumentsURL.appendingPathComponent(
            "Photos",
            isDirectory: true)
        let localVideosURL = localDocumentsURL.appendingPathComponent(
            "Videos",
            isDirectory: true)
        let localLibraryURL = localDocumentsURL.appendingPathComponent("library.json")

        try fileManager.createDirectory(
            at: localSetsURL,
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: localWaveformsURL,
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: localPhotosURL,
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: localVideosURL,
            withIntermediateDirectories: true)

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("set-player-sync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let device = try discoverPhone(temporaryURL: temporaryURL)
        let remoteFiles = try listPhoneFiles(
            deviceIdentifier: device.identifier,
            temporaryURL: temporaryURL)
        let remoteByPath = Dictionary(
            uniqueKeysWithValues: remoteFiles.map { ($0.relativePath, $0) })

        let phoneLibraryURL = temporaryURL.appendingPathComponent("phone-library.json")
        try copyFromPhone(
            deviceIdentifier: device.identifier,
            source: "Documents/library.json",
            destination: phoneLibraryURL)
        guard fileManager.fileExists(atPath: phoneLibraryURL.path) else {
            throw PhoneSyncError.missingPhoneLibrary
        }

        let phoneSets = try decodeLibrary(at: phoneLibraryURL)
        let localSets = (try? decodeLibrary(at: localLibraryURL)) ?? []
        let localLibraryModified = modificationDate(for: localLibraryURL) ?? .distantPast
        let phoneLibraryModified = remoteByPath["library.json"]?.modifiedAt ?? .distantPast

        let preferLocalMetadata = !localSets.isEmpty
            && localSets != phoneSets
            && localLibraryModified > phoneLibraryModified
        let mergedSets = mergeLibraries(
            primary: preferLocalMetadata ? localSets : phoneSets,
            secondary: preferLocalMetadata ? phoneSets : localSets)

        var pulledFiles = 0
        var pushedFiles = 0

        for set in mergedSets {
            let relativePath = "Sets/\(set.fileName)"
            let localURL = localSetsURL.appendingPathComponent(set.fileName)
            let localExists = fileManager.fileExists(atPath: localURL.path)
            let remote = remoteByPath[relativePath]

            switch (localExists, remote) {
            case (false, .some):
                try copyFromPhone(
                    deviceIdentifier: device.identifier,
                    source: "Documents/\(relativePath)",
                    destination: localURL)
                pulledFiles += 1

            case (true, .none):
                try copyToPhone(
                    deviceIdentifier: device.identifier,
                    source: localURL,
                    destination: "Documents/\(relativePath)")
                pushedFiles += 1

            case (true, .some(let remoteFile)):
                let localSize = fileSize(for: localURL)
                guard localSize != remoteFile.size else { continue }
                let localModified = modificationDate(for: localURL) ?? .distantPast
                if localModified > remoteFile.modifiedAt {
                    try copyToPhone(
                        deviceIdentifier: device.identifier,
                        source: localURL,
                        destination: "Documents/\(relativePath)")
                    pushedFiles += 1
                } else {
                    try copyFromPhone(
                        deviceIdentifier: device.identifier,
                        source: "Documents/\(relativePath)",
                        destination: localURL)
                    pulledFiles += 1
                }

            case (false, .none):
                break
            }
        }

        var waveformFiles = 0
        for remote in remoteFiles
        where remote.relativePath.hasPrefix("waveforms/")
            && remote.relativePath.hasSuffix("-v4.wave") {
            let fileName = URL(fileURLWithPath: remote.relativePath).lastPathComponent
            let localURL = localWaveformsURL.appendingPathComponent(fileName)
            let localSize = fileSize(for: localURL)
            let localModified = modificationDate(for: localURL) ?? .distantPast
            if localSize != remote.size || localModified < remote.modifiedAt {
                try copyFromPhone(
                    deviceIdentifier: device.identifier,
                    source: "Documents/\(remote.relativePath)",
                    destination: localURL)
                waveformFiles += 1
            }
        }

        var photoFiles = 0
        for set in mergedSets {
            for photo in set.photos {
                let relativePath = "Photos/\(photo.fileName)"
                let localURL = localPhotosURL.appendingPathComponent(photo.fileName)
                let localExists = fileManager.fileExists(atPath: localURL.path)
                let remote = remoteByPath[relativePath]

                switch (localExists, remote) {
                case (false, .some):
                    try copyFromPhone(
                        deviceIdentifier: device.identifier,
                        source: "Documents/\(relativePath)",
                        destination: localURL)
                    pulledFiles += 1
                    photoFiles += 1

                case (true, .none):
                    try copyToPhone(
                        deviceIdentifier: device.identifier,
                        source: localURL,
                        destination: "Documents/\(relativePath)")
                    pushedFiles += 1
                    photoFiles += 1

                case (true, .some(let remoteFile)):
                    let localSize = fileSize(for: localURL)
                    guard localSize != remoteFile.size else { continue }
                    let localModified = modificationDate(for: localURL) ?? .distantPast
                    if localModified > remoteFile.modifiedAt {
                        try copyToPhone(
                            deviceIdentifier: device.identifier,
                            source: localURL,
                            destination: "Documents/\(relativePath)")
                        pushedFiles += 1
                    } else {
                        try copyFromPhone(
                            deviceIdentifier: device.identifier,
                            source: "Documents/\(relativePath)",
                            destination: localURL)
                        pulledFiles += 1
                    }
                    photoFiles += 1

                case (false, .none):
                    break
                }
            }
        }

        var videoFiles = 0
        for set in mergedSets {
            for video in set.videos {
                let relativePath = "Videos/\(video.fileName)"
                let localURL = localVideosURL.appendingPathComponent(video.fileName)
                let localExists = fileManager.fileExists(atPath: localURL.path)
                let remote = remoteByPath[relativePath]

                switch (localExists, remote) {
                case (false, .some):
                    try copyFromPhone(
                        deviceIdentifier: device.identifier,
                        source: "Documents/\(relativePath)",
                        destination: localURL)
                    pulledFiles += 1
                    videoFiles += 1

                case (true, .none):
                    try copyToPhone(
                        deviceIdentifier: device.identifier,
                        source: localURL,
                        destination: "Documents/\(relativePath)")
                    pushedFiles += 1
                    videoFiles += 1

                case (true, .some(let remoteFile)):
                    let localSize = fileSize(for: localURL)
                    guard localSize != remoteFile.size else { continue }
                    let localModified = modificationDate(for: localURL) ?? .distantPast
                    if localModified > remoteFile.modifiedAt {
                        try copyToPhone(
                            deviceIdentifier: device.identifier,
                            source: localURL,
                            destination: "Documents/\(relativePath)")
                        pushedFiles += 1
                    } else {
                        try copyFromPhone(
                            deviceIdentifier: device.identifier,
                            source: "Documents/\(relativePath)",
                            destination: localURL)
                        pulledFiles += 1
                    }
                    videoFiles += 1

                case (false, .none):
                    break
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let mergedLibraryData = try encoder.encode(mergedSets)
        if (try? Data(contentsOf: localLibraryURL)) != mergedLibraryData {
            try mergedLibraryData.write(to: localLibraryURL, options: .atomic)
        }

        if mergedSets != phoneSets {
            let outgoingLibraryURL = temporaryURL.appendingPathComponent("merged-library.json")
            try mergedLibraryData.write(to: outgoingLibraryURL, options: .atomic)
            try copyToPhone(
                deviceIdentifier: device.identifier,
                source: outgoingLibraryURL,
                destination: "Documents/library.json")
        }

        return PhoneSyncResult(
            deviceName: device.name,
            setCount: mergedSets.count,
            pulledFiles: pulledFiles,
            pushedFiles: pushedFiles,
            waveformFiles: waveformFiles,
            photoFiles: photoFiles,
            videoFiles: videoFiles)
    }

    private static func mergeLibraries(primary: [DJSet], secondary: [DJSet]) -> [DJSet] {
        var result = primary
        var knownFileNames = Set(primary.map(\.fileName))
        for set in secondary where !knownFileNames.contains(set.fileName) {
            result.append(set)
            knownFileNames.insert(set.fileName)
        }
        return result
    }

    private static func decodeLibrary(at url: URL) throws -> [DJSet] {
        try JSONDecoder().decode([DJSet].self, from: Data(contentsOf: url))
    }

    private static func discoverPhone(temporaryURL: URL) throws -> PhoneDevice {
        let jsonURL = temporaryURL.appendingPathComponent("devices.json")
        _ = try ProcessRunner.run([
            "devicectl", "list", "devices",
            "--json-output", jsonURL.path
        ])
        let envelope: DevicesEnvelope
        do {
            envelope = try JSONDecoder().decode(
                DevicesEnvelope.self,
                from: Data(contentsOf: jsonURL))
        } catch {
            throw PhoneSyncError.malformedResponse(decodingMessage(error))
        }

        guard let device = envelope.result.devices.first(where: {
            $0.hardwareProperties.platform == "iOS"
                && $0.connectionProperties.pairingState == "paired"
                && ($0.deviceProperties.bootState == nil
                    || $0.deviceProperties.bootState == "booted")
        }) else {
            throw PhoneSyncError.noPhone
        }
        return PhoneDevice(identifier: device.identifier, name: device.deviceProperties.name)
    }

    private static func listPhoneFiles(
        deviceIdentifier: String,
        temporaryURL: URL
    ) throws -> [RemoteFile] {
        let jsonURL = temporaryURL.appendingPathComponent("phone-files.json")
        _ = try ProcessRunner.run([
            "devicectl", "device", "info", "files",
            "--device", deviceIdentifier,
            "--domain-type", "appDataContainer",
            "--domain-identifier", appBundleID,
            "--subdirectory", "Documents",
            "--json-output", jsonURL.path
        ])

        do {
            let envelope = try JSONDecoder().decode(
                FilesEnvelope.self,
                from: Data(contentsOf: jsonURL))
            return envelope.result.files.compactMap(RemoteFile.init)
        } catch {
            throw PhoneSyncError.malformedResponse(decodingMessage(error))
        }
    }

    private static func copyFromPhone(
        deviceIdentifier: String,
        source: String,
        destination: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        _ = try ProcessRunner.run([
            "devicectl", "device", "copy", "from",
            "--device", deviceIdentifier,
            "--source", source,
            "--destination", destination.path,
            "--domain-type", "appDataContainer",
            "--domain-identifier", appBundleID
        ])
    }

    private static func copyToPhone(
        deviceIdentifier: String,
        source: URL,
        destination: String
    ) throws {
        _ = try ProcessRunner.run([
            "devicectl", "device", "copy", "to",
            "--device", deviceIdentifier,
            "--source", source.path,
            "--destination", destination,
            "--domain-type", "appDataContainer",
            "--domain-identifier", appBundleID
        ])
    }

    private static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func fileSize(for url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }

    private static func decodingMessage(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return error.localizedDescription
        }
        let path: ([CodingKey]) -> String = { keys in
            keys.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(key.stringValue) at \(path(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "missing \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "invalid data at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

private enum ProcessRunner {
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw PhoneSyncError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        let error = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PhoneSyncError.commandFailed(
                message.isEmpty ? "The iPhone sync command failed." : message)
        }
        return output
    }
}

private struct PhoneDevice {
    var identifier: String
    var name: String
}

private struct RemoteFile {
    var relativePath: String
    var size: Int64
    var modifiedAt: Date

    init?(_ file: FilesEnvelope.ListedFile) {
        guard !file.resources.isDirectory else { return nil }
        relativePath = file.relativePath
        size = file.metadata.size
        modifiedAt = ISO8601DateFormatter.setPlayer.date(from: file.metadata.lastModDate)
            ?? .distantPast
    }
}

private struct DevicesEnvelope: Decodable {
    struct Result: Decodable {
        var devices: [Device]
    }

    struct Device: Decodable {
        struct HardwareProperties: Decodable {
            var platform: String
        }

        struct ConnectionProperties: Decodable {
            var pairingState: String
        }

        struct DeviceProperties: Decodable {
            var bootState: String?
            var name: String
        }

        var identifier: String
        var hardwareProperties: HardwareProperties
        var connectionProperties: ConnectionProperties
        var deviceProperties: DeviceProperties
    }

    var result: Result
}

private struct FilesEnvelope: Decodable {
    struct Result: Decodable {
        var files: [ListedFile]
    }

    struct ListedFile: Decodable {
        struct Metadata: Decodable {
            var size: Int64
            var lastModDate: String
        }

        struct Resources: Decodable {
            var isDirectory: Bool
        }

        var metadata: Metadata
        var resources: Resources
        var relativePath: String
    }

    var result: Result
}

private extension ISO8601DateFormatter {
    static let setPlayer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
