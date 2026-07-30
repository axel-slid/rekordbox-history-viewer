import Foundation

struct SetAnnotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: TimeInterval
    var label: String
    var artworkURL: URL?
}

struct SetPhoto: Codable, Identifiable, Equatable {
    var id = UUID()
    var fileName: String
    var addedAt: Date
    var caption: String?
}

struct SetVideo: Codable, Identifiable, Equatable {
    var id = UUID()
    var fileName: String
    var addedAt: Date
    var duration: TimeInterval
}

struct DJSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var fileName: String
    var title: String
    var duration: TimeInterval
    var addedAt: Date
    var fileSize: Int64
    var annotations: [SetAnnotation] = []
    var folder: String?
    var photos: [SetPhoto] = []
    var videos: [SetVideo] = []
    var description: String?
    var locationName: String?
    var locationLatitude: Double?
    var locationLongitude: Double?
}

extension DJSet {
    private enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case title
        case duration
        case addedAt
        case fileSize
        case annotations
        case folder
        case photos
        case videos
        case description
        case locationName
        case locationLatitude
        case locationLongitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decode(String.self, forKey: .fileName)
        title = try container.decode(String.self, forKey: .title)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        annotations = try container.decodeIfPresent(
            [SetAnnotation].self,
            forKey: .annotations) ?? []
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        photos = try container.decodeIfPresent([SetPhoto].self, forKey: .photos) ?? []
        videos = try container.decodeIfPresent([SetVideo].self, forKey: .videos) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description)
        locationName = try container.decodeIfPresent(String.self, forKey: .locationName)
        locationLatitude = try container.decodeIfPresent(
            Double.self,
            forKey: .locationLatitude)
        locationLongitude = try container.decodeIfPresent(
            Double.self,
            forKey: .locationLongitude)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(title, forKey: .title)
        try container.encode(duration, forKey: .duration)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(annotations, forKey: .annotations)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encode(photos, forKey: .photos)
        try container.encode(videos, forKey: .videos)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(locationName, forKey: .locationName)
        try container.encodeIfPresent(locationLatitude, forKey: .locationLatitude)
        try container.encodeIfPresent(locationLongitude, forKey: .locationLongitude)
    }
}
