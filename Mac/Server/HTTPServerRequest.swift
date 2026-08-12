import Foundation

struct HTTPServerRequest: Sendable, Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum HTTPServerRequestError: Error, Equatable, Sendable {
    case malformed
    case unsupportedTransferEncoding
    case oversized
}

struct HTTPServerRequestParser: Sendable {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) throws -> HTTPServerRequest? {
        buffer.append(data)
        guard buffer.count <= Self.maximumHeaderBytes + Self.maximumBodyBytes else {
            throw HTTPServerRequestError.oversized
        }
        let bytes = [UInt8](buffer)
        guard bytes.count >= 4 else { return nil }

        var headerEnd: Int?
        for index in 0...(bytes.count - 4) where bytes[index...(index + 3)] == [13, 10, 13, 10] {
            headerEnd = index
            break
        }
        guard let headerEnd else { return nil }
        guard headerEnd <= Self.maximumHeaderBytes else { throw HTTPServerRequestError.oversized }

        let headerData = Data(bytes[0..<headerEnd])
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPServerRequestError.malformed
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPServerRequestError.malformed }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.0" || requestParts[2] == "HTTP/1.1" else {
            throw HTTPServerRequestError.malformed
        }
        let path = String(requestParts[1])
        guard path.hasPrefix("/"), !path.contains("\r"), !path.contains("\n") else {
            throw HTTPServerRequestError.malformed
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { throw HTTPServerRequestError.malformed }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.contains("\r"), !value.contains("\n"), headers[name] == nil else {
                throw HTTPServerRequestError.malformed
            }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { throw HTTPServerRequestError.unsupportedTransferEncoding }
        let bodyLength: Int
        if let contentLength = headers["content-length"] {
            guard let parsed = Int(contentLength), parsed >= 0 else { throw HTTPServerRequestError.malformed }
            bodyLength = parsed
        } else {
            bodyLength = 0
        }
        guard bodyLength <= Self.maximumBodyBytes else { throw HTTPServerRequestError.oversized }
        let totalLength = headerEnd + 4 + bodyLength
        guard bytes.count >= totalLength else { return nil }
        let body = Data(bytes[(headerEnd + 4)..<totalLength])
        buffer = Data(bytes.dropFirst(totalLength))
        return HTTPServerRequest(
            method: String(requestParts[0]).uppercased(),
            path: path,
            headers: headers,
            body: body
        )
    }
}
