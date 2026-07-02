import Foundation

struct SetAnnotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: TimeInterval
    var label: String
}

struct DJSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var fileName: String
    var title: String
    var duration: TimeInterval
    var addedAt: Date
    var fileSize: Int64
    var annotations: [SetAnnotation] = []
}
