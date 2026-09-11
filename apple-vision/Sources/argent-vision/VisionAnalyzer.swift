import CoreGraphics
import Foundation
import ImageIO
import Vision

enum VisionAnalyzerError: LocalizedError {
    case fileNotFound(String)
    case notAFile(String)
    case imageCannotBeDecoded(String)
    case requestFailed(String, Error)
    case unexpectedResults(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Image does not exist: \(path)"
        case .notAFile(let path):
            return "Image path is not a regular file: \(path)"
        case .imageCannotBeDecoded(let path):
            return "Image could not be decoded: \(path)"
        case .requestFailed(let request, let error):
            return "Vision \(request) failed: \(error.localizedDescription)"
        case .unexpectedResults(let request):
            return "Vision returned unexpected results for \(request)"
        }
    }
}

final class VisionAnalyzer {
    private let classificationConfidenceThreshold: Float
    private let maximumClassifications: Int

    init(classificationConfidenceThreshold: Float = 0.50, maximumClassifications: Int = 10) {
        self.classificationConfidenceThreshold = classificationConfidenceThreshold
        self.maximumClassifications = maximumClassifications
    }

    func analyze(imageAt path: String, imageName: String? = nil) throws -> AnalysisResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw VisionAnalyzerError.fileNotFound(path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw VisionAnalyzerError.notAFile(path)
        }

        let url = URL(fileURLWithPath: path)
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw VisionAnalyzerError.imageCannotBeDecoded(path)
        }

        let orientation = Self.orientation(for: source)
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false
        let classificationRequest = VNClassifyImageRequest()

        // Future Core ML object detection plugs in here as another VNRequest. Keeping
        // request construction and result mapping in this analyzer isolates the CLI.
        // The URL-backed handler lets Vision choose a compatible pixel-buffer
        // representation. This is more reliable on older Intel macOS releases
        // than asking Vision to convert an arbitrary decoded CGImage.
        let handler = VNImageRequestHandler(url: url, orientation: orientation, options: [:])
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try handler.perform([humanRequest])
        } catch {
            throw VisionAnalyzerError.requestFailed("human detection", error)
        }
        do {
            try handler.perform([classificationRequest])
        } catch {
            throw VisionAnalyzerError.requestFailed("image classification", error)
        }
        let end = DispatchTime.now().uptimeNanoseconds

        guard let humanObservations = humanRequest.results else {
            throw VisionAnalyzerError.unexpectedResults("human detection")
        }
        guard let classificationObservations = classificationRequest.results else {
            throw VisionAnalyzerError.unexpectedResults("image classification")
        }

        let people = humanObservations.map { observation in
            let box = observation.boundingBox
            return DetectedPerson(
                confidence: observation.confidence,
                boundingBox: BoundingBox(
                    x: Double(box.origin.x),
                    y: Double(box.origin.y),
                    width: Double(box.size.width),
                    height: Double(box.size.height)
                )
            )
        }

        let classifications = classificationObservations
            .filter { $0.confidence >= classificationConfidenceThreshold }
            .prefix(maximumClassifications)
            .map { ImageClassification(label: $0.identifier, confidence: $0.confidence) }

        let elapsedMilliseconds = Int((end - start) / 1_000_000)
        return AnalysisResult(
            image: imageName ?? path,
            personDetected: !people.isEmpty,
            personCount: people.count,
            people: people,
            classifications: classifications,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    private static func orientation(for source: CGImageSource) -> CGImagePropertyOrientation {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32,
            let orientation = CGImagePropertyOrientation(rawValue: rawOrientation)
        else {
            return .up
        }
        return orientation
    }
}
