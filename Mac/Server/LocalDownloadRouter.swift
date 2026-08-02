import Foundation

struct LocalDownloadResponse: Sendable, Equatable {
    var statusCode: Int
    var reason: String
    var contentType: String
    var headers: [String: String]
    var body: Data

    var httpData: Data {
        var header = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        for (name, value) in headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

struct LocalDownloadRouter: Sendable {
    private let tokenMap: [String: URL]

    init(tokenMap: [String: URL]) {
        self.tokenMap = tokenMap.mapValues { $0.standardizedFileURL }
    }

    func response(for requestPath: String) -> LocalDownloadResponse {
        let path = decodePath(requestPath)
        guard !path.contains("\0"),
              !path.split(separator: "/").contains(".."),
              path.hasPrefix("/") else {
            return notFound()
        }

        if path == "/health" {
            let body = Data(#"{"status":"ok","registeredTokens":\#(tokenMap.count)}"#.utf8)
            return LocalDownloadResponse(
                statusCode: 200,
                reason: "OK",
                contentType: "application/json",
                headers: [:],
                body: body
            )
        }

        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2 || components.count == 3,
              components[0] == "s",
              !components[1].isEmpty,
              components.last != "" || components.count == 3,
              let sessionDirectory = tokenMap[components[1]] else {
            return notFound()
        }

        if components.count == 2 || components[2].isEmpty {
            return page(token: components[1], sessionDirectory: sessionDirectory)
        }

        guard components[2] == "strip.png" || components[2] == "booth.gif" else {
            return notFound()
        }
        let fileURL = sessionDirectory.appendingPathComponent(components[2]).standardizedFileURL
        guard fileURL.path.hasPrefix(sessionDirectory.path + "/"),
              let body = try? Data(contentsOf: fileURL) else {
            return notFound()
        }
        return LocalDownloadResponse(
            statusCode: 200,
            reason: "OK",
            contentType: components[2] == "strip.png" ? "image/png" : "image/gif",
            headers: [:],
            body: body
        )
    }

    private func page(token: String, sessionDirectory: URL) -> LocalDownloadResponse {
        let gifURL = sessionDirectory.appendingPathComponent("booth.gif")
        let gifButton = FileManager.default.fileExists(atPath: gifURL.path)
            ? #"<a class="btn secondary" href="/s/\#(token)/booth.gif" download="photobooth.gif">⬇ Save GIF</a>"#
            : ""
        let escapedToken = token.htmlEscaped
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>PRC Photo Booth — Your Photos</title>
        <style>
        body{font-family:-apple-system,sans-serif;background:#111;color:#eee;text-align:center;padding:2rem;margin:0}
        h1{font-size:1.5rem;margin-bottom:.25rem}p{color:#aaa;font-size:.9rem;margin-bottom:2rem}
        img{max-width:90vw;max-height:70vh;border-radius:8px;display:block;margin:0 auto 1.5rem}
        a.btn{display:inline-block;background:#fff;color:#111;padding:.75rem 2rem;border-radius:8px;text-decoration:none;font-weight:600;margin:.5rem}
        a.btn.secondary{background:#333;color:#eee}
        </style>
        </head>
        <body>
        <h1>✨ Your Photo Strip</h1>
        <p>Tap a button to save your memories!</p>
        <img src="/s/\(escapedToken)/strip.png" alt="Photo Strip">
        <br>
        <a class="btn" href="/s/\(escapedToken)/strip.png" download="photobooth-strip.png">⬇ Save Strip</a>
        \(gifButton)
        </body>
        </html>
        """
        return LocalDownloadResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "text/html; charset=utf-8",
            headers: ["Cache-Control": "no-store"],
            body: Data(html.utf8)
        )
    }

    private func decodePath(_ requestPath: String) -> String {
        let withoutQuery = requestPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? requestPath
        var decoded = withoutQuery
        for _ in 0..<2 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
        }
        return decoded
    }

    private func notFound() -> LocalDownloadResponse {
        LocalDownloadResponse(
            statusCode: 404,
            reason: "Not Found",
            contentType: "text/plain; charset=utf-8",
            headers: [:],
            body: Data("Not found".utf8)
        )
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
