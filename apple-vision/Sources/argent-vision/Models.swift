import Foundation

struct BoundingBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct DetectedPerson: Codable {
    let confidence: Float
    let boundingBox: BoundingBox

    enum CodingKeys: String, CodingKey {
        case confidence
        case boundingBox = "bounding_box"
    }
}

struct ImageClassification: Codable {
    let label: String
    let confidence: Float
}

struct AnalysisResult: Codable {
    let image: String
    let personDetected: Bool
    let personCount: Int
    let people: [DetectedPerson]
    let classifications: [ImageClassification]
    let elapsedMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case image
        case personDetected = "person_detected"
        case personCount = "person_count"
        case people
        case classifications
        case elapsedMilliseconds = "elapsed_ms"
    }
}
