import CoreGraphics
import Foundation
import ImageIO
import Vision

private struct DiagnosticResult: Codable {
    let request: String
    let revision: Int?
    let succeeded: Bool
    let observationCount: Int?
    let elapsedMilliseconds: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case request, revision, succeeded, error
        case observationCount = "observation_count"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

private struct DiagnosticReport: Codable {
    let image: String
    let operatingSystem: String
    let supportedHumanRevisions: [Int]
    let results: [DiagnosticResult]

    enum CodingKeys: String, CodingKey {
        case image, results
        case operatingSystem = "operating_system"
        case supportedHumanRevisions = "supported_human_revisions"
    }
}

private enum DiagnosticError: LocalizedError {
    case usage
    case cannotDecode(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: argent-vision-diagnostics <image>"
        case .cannotDecode(let path):
            return "Image could not be decoded: \(path)"
        }
    }
}

private func orientation(for source: CGImageSource) -> CGImagePropertyOrientation {
    guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
        let orientation = CGImagePropertyOrientation(rawValue: rawValue)
    else {
        return .up
    }
    return orientation
}

private func run(
    name: String,
    revision: Int? = nil,
    request: VNRequest,
    imageURL: URL,
    orientation: CGImagePropertyOrientation
) -> DiagnosticResult {
    let handler = VNImageRequestHandler(url: imageURL, orientation: orientation, options: [:])
    let start = DispatchTime.now().uptimeNanoseconds

    do {
        try handler.perform([request])
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return DiagnosticResult(
            request: name,
            revision: revision,
            succeeded: true,
            observationCount: request.results?.count,
            elapsedMilliseconds: elapsed,
            error: nil
        )
    } catch {
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return DiagnosticResult(
            request: name,
            revision: revision,
            succeeded: false,
            observationCount: nil,
            elapsedMilliseconds: elapsed,
            error: error.localizedDescription
        )
    }
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw DiagnosticError.usage
    }

    let path = CommandLine.arguments[1]
    let url = URL(fileURLWithPath: path)
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    else {
        throw DiagnosticError.cannotDecode(path)
    }

    let imageOrientation = orientation(for: source)
    let supportedRevisions = Array(VNDetectHumanRectanglesRequest.supportedRevisions).sorted()
    var results: [DiagnosticResult] = []

    results.append(run(
        name: "VNDetectFaceRectanglesRequest",
        request: VNDetectFaceRectanglesRequest(),
        imageURL: url,
        orientation: imageOrientation
    ))
    results.append(run(
        name: "VNDetectRectanglesRequest",
        request: VNDetectRectanglesRequest(),
        imageURL: url,
        orientation: imageOrientation
    ))

    for revision in [1, 2] where supportedRevisions.contains(revision) {
        let request = VNDetectHumanRectanglesRequest()
        request.revision = revision
        results.append(run(
            name: "VNDetectHumanRectanglesRequest",
            revision: revision,
            request: request,
            imageURL: url,
            orientation: imageOrientation
        ))
    }

    results.append(run(
        name: "VNClassifyImageRequest",
        request: VNClassifyImageRequest(),
        imageURL: url,
        orientation: imageOrientation
    ))

    let report = DiagnosticReport(
        image: path,
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        supportedHumanRevisions: supportedRevisions,
        results: results
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    writeError("Error: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
