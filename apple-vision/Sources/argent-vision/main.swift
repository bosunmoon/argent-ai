import Foundation

private struct CommandLineOptions {
    let imagePath: String?
    let port: UInt16?
    let confidenceThreshold: Float

    static let usage = """
    Usage: argent-vision [--confidence-threshold 0.0...1.0] <image.jpg>
           argent-vision serve [--port 8080] [--confidence-threshold 0.0...1.0]
    """

    static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var imagePath: String?
        var threshold: Float = 0.50
        var index = 0
        let serving = arguments.first == "serve"
        var port: UInt16 = 8080
        if serving { index = 1 }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--port" where serving:
                index += 1
                guard index < arguments.count, let value = UInt16(arguments[index]), value > 0 else {
                    throw CLIError.invalidArguments("Port must be an integer from 1 through 65535.")
                }
                port = value
            case "--confidence-threshold", "-t":
                index += 1
                guard index < arguments.count, let value = Float(arguments[index]), (0...1).contains(value) else {
                    throw CLIError.invalidArguments("Confidence threshold must be a number from 0.0 through 1.0.")
                }
                threshold = value
            case "--help", "-h":
                throw CLIError.helpRequested
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIError.invalidArguments("Unknown option: \(argument)")
                }
                guard imagePath == nil else {
                    throw CLIError.invalidArguments("Only one image path may be supplied.")
                }
                imagePath = argument
            }
            index += 1
        }

        guard serving || imagePath != nil else {
            throw CLIError.invalidArguments("An image path is required.")
        }
        guard !serving || imagePath == nil else {
            throw CLIError.invalidArguments("Serve mode does not accept an image path.")
        }
        return CommandLineOptions(imagePath: imagePath, port: serving ? port : nil, confidenceThreshold: threshold)
    }
}

private enum CLIError: LocalizedError {
    case helpRequested
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .invalidArguments(let message):
            return message
        }
    }
}

private func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

do {
    let options = try CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst()))
    let analyzer = VisionAnalyzer(classificationConfidenceThreshold: options.confidenceThreshold)
    if let port = options.port {
        try DetectionServer(analyzer: analyzer).run(port: port)
        exit(EXIT_SUCCESS)
    }
    let result = try analyzer.analyze(imageAt: options.imagePath!)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch CLIError.helpRequested {
    writeToStandardError(CommandLineOptions.usage)
    exit(EXIT_SUCCESS)
} catch {
    writeToStandardError("Error: \(error.localizedDescription)")
    writeToStandardError(CommandLineOptions.usage)
    exit(EXIT_FAILURE)
}
