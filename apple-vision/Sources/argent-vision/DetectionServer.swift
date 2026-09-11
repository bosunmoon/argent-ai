import Darwin
import Foundation

/// A deliberately small, serial HTTP/1.1 server for local inference.
/// One request per connection; bodies must have a Content-Length.
final class DetectionServer {
    private let analyzer: VisionAnalyzer
    private let maximumBody = 20 * 1024 * 1024

    init(analyzer: VisionAnalyzer) { self.analyzer = analyzer }

    func run(port: UInt16) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        defer { close(listener) }
        var enabled: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        FileHandle.standardError.write(Data("Listening on http://127.0.0.1:\(port) (POST /detect)\n".utf8))
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            autoreleasepool {
                defer { close(client) }
                var timeout = timeval(tv_sec: 15, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
                handle(client)
            }
        }
    }

    private struct HTTPError: Error {
        let status: Int
        let message: String
    }

    private func handle(_ client: Int32) {
        do {
            var bytes = Data()
            let separator = Data("\r\n\r\n".utf8)
            while bytes.range(of: separator) == nil {
                guard bytes.count < 16 * 1024 else {
                    throw HTTPError(status: 431, message: "Request headers are too large.")
                }
                try receive(client, into: &bytes)
            }
            let boundary = bytes.range(of: separator)!
            guard boundary.upperBound <= 16 * 1024,
                  let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else {
                throw HTTPError(status: 400, message: "Invalid request headers.")
            }
            let lines = header.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])) else {
                throw HTTPError(status: 400, message: "Invalid HTTP request.")
            }
            guard request[1] == "/detect" else { throw HTTPError(status: 404, message: "Route not found.") }
            guard request[0] == "POST" else { throw HTTPError(status: 405, message: "Use POST /detect.") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else {
                    throw HTTPError(status: 400, message: "Invalid header.")
                }
                let name = line[..<colon].lowercased()
                guard headers[name] == nil else { throw HTTPError(status: 400, message: "Duplicate header.") }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else {
                throw HTTPError(status: 400, message: "Transfer-Encoding is unsupported; send Content-Length.")
            }
            guard let rawLength = headers["content-length"] else {
                throw HTTPError(status: 411, message: "Content-Length is required.")
            }
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(rawLength), length > 0 else {
                throw HTTPError(status: 400, message: "Content-Length must be a positive integer.")
            }
            guard length <= maximumBody else { throw HTTPError(status: 413, message: "Image exceeds 20 MiB.") }
            let contentType = headers["content-type"]?.split(separator: ";").first?.lowercased() ?? "application/octet-stream"
            guard contentType.hasPrefix("image/") || contentType == "application/octet-stream" else {
                throw HTTPError(status: 415, message: "Send raw image bytes, not multipart or JSON.")
            }
            if let expectation = headers["expect"] {
                guard expectation.lowercased() == "100-continue" else {
                    throw HTTPError(status: 417, message: "Unsupported expectation.")
                }
                sendAll(client, data: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
            var body = Data(bytes[boundary.upperBound...].prefix(length))
            while body.count < length { try receive(client, into: &body, limit: length - body.count) }
            // Keep the URL-backed Vision path used by the CLI for Intel compatibility.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("upload")
            try body.write(to: file)
            let result = try analyzer.analyze(imageAt: file.path, imageName: "upload")
            respond(client, status: 200, body: try JSONEncoder().encode(result))
        } catch let error as HTTPError {
            respondError(client, status: error.status, message: error.message)
        } catch VisionAnalyzerError.imageCannotBeDecoded {
            respondError(client, status: 422, message: "Image could not be decoded.")
        } catch {
            FileHandle.standardError.write(Data("Detection failed: \(error.localizedDescription)\n".utf8))
            respondError(client, status: 500, message: "Image analysis failed.")
        }
    }

    private func receive(_ client: Int32, into data: inout Data, limit: Int = 8192) throws {
        var buffer = [UInt8](repeating: 0, count: min(limit, 8192))
        let count = recv(client, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw HTTPError(status: count < 0 ? 408 : 400, message: "Request body or headers are incomplete.")
        }
        data.append(contentsOf: buffer.prefix(count))
    }

    private func respondError(_ client: Int32, status: Int, message: String) {
        respond(client, status: status, body: try! JSONEncoder().encode(["error": message]))
    }

    private func respond(_ client: Int32, status: Int, body: Data) {
        let reasons = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed",
                       408: "Request Timeout", 411: "Length Required", 413: "Content Too Large",
                       415: "Unsupported Media Type", 417: "Expectation Failed", 422: "Unprocessable Content",
                       431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        let allow = status == 405 ? "Allow: POST\r\n" : ""
        let header = "HTTP/1.1 \(status) \(reasons[status]!)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(allow)\r\n"
        sendAll(client, data: Data(header.utf8) + body)
    }

    private func sendAll(_ client: Int32, data: Data) {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = send(client, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}
