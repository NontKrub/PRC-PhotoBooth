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

struct LocalDownloadFileResponse: Sendable, Equatable {
    var statusCode: Int
    var reason: String
    var contentType: String
    var headers: [String: String]
    var fileURL: URL
    var contentLength: Int64

    var httpHeaderData: Data {
        var header = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(contentLength)\r\n"
        for (name, value) in headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8)
    }
}

enum LocalDownloadRoute: Sendable, Equatable {
    case response(LocalDownloadResponse)
    case file(LocalDownloadFileResponse)
}

struct LocalDownloadRouter: Sendable {
    private let sessionRoutes: [String: SessionRouteRegistration]
    private let galleryRoutes: [String: EventGalleryRouteRegistration]

    init(tokenMap: [String: URL]) {
        self.init(
            sessionRoutes: tokenMap.mapValues {
                SessionRouteRegistration(sessionDirectory: $0, language: .english, eventGalleryPath: nil)
            },
            galleryRoutes: [:]
        )
    }

    init(
        sessionRoutes: [String: SessionRouteRegistration],
        galleryRoutes: [String: EventGalleryRouteRegistration]
    ) {
        self.sessionRoutes = sessionRoutes.mapValues {
            SessionRouteRegistration(
                sessionDirectory: $0.sessionDirectory.standardizedFileURL,
                language: $0.language,
                eventGalleryPath: $0.eventGalleryPath,
                gifState: $0.gifState
            )
        }
        self.galleryRoutes = galleryRoutes
    }

    func response(for requestPath: String) -> LocalDownloadResponse {
        let path = decodePath(requestPath)
        guard !path.contains("\0"),
              !path.split(separator: "/").contains(".."),
              path.hasPrefix("/") else {
            return notFound()
        }

        if path == "/health" {
            let body = Data(#"{"status":"ok","registeredTokens":\#(sessionRoutes.count)}"#.utf8)
            return LocalDownloadResponse(
                statusCode: 200,
                reason: "OK",
                contentType: "application/json",
                headers: [:],
                body: body
            )
        }

        if let galleryResponse = galleryResponse(for: path) {
            return galleryResponse
        }
        return sessionResponse(for: path)
    }

    func route(for requestPath: String) -> LocalDownloadRoute {
        let path = decodePath(requestPath)
        guard !path.contains("\0"),
              !path.split(separator: "/").contains(".."),
              path.hasPrefix("/") else {
            return .response(notFound())
        }
        if let file = sessionFileResponse(for: path) {
            return .file(file)
        }
        return .response(response(for: path))
    }

    private func sessionResponse(for path: String) -> LocalDownloadResponse {
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard (components.count == 2 || components.count == 3),
              components[0] == "s",
              let registration = sessionRoutes[components[1]] else {
            return notFound()
        }

        if components.count == 2 {
            return page(token: components[1], registration: registration)
        }
        guard components[2] == "strip.png" || components[2] == "booth.gif" else { return notFound() }
        let directory = registration.sessionDirectory.resolvingSymlinksInPath().standardizedFileURL
        let fileURL = registration.sessionDirectory.appendingPathComponent(components[2])
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileURL.path.hasPrefix(directory.path + "/"),
              components[2] != "booth.gif" || registration.gifState == .ready,
              let body = try? Data(contentsOf: fileURL) else {
            return notFound()
        }
        return LocalDownloadResponse(
            statusCode: 200,
            reason: "OK",
            contentType: components[2] == "strip.png" ? "image/png" : "image/gif",
            headers: ["Cache-Control": "no-store"],
            body: body
        )
    }

    private func sessionFileResponse(for path: String) -> LocalDownloadFileResponse? {
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count == 3,
              components[0] == "s",
              components[2] == "strip.png" || components[2] == "booth.gif",
              let registration = sessionRoutes[components[1]] else {
            return nil
        }
        guard components[2] != "booth.gif" || registration.gifState == .ready else { return nil }
        let directory = registration.sessionDirectory.resolvingSymlinksInPath().standardizedFileURL
        let fileURL = registration.sessionDirectory.appendingPathComponent(components[2])
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileURL.path.hasPrefix(directory.path + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return LocalDownloadFileResponse(
            statusCode: 200,
            reason: "OK",
            contentType: components[2] == "strip.png" ? "image/png" : "image/gif",
            headers: ["Cache-Control": "no-store"],
            fileURL: fileURL,
            contentLength: size.int64Value
        )
    }

    private func galleryResponse(for path: String) -> LocalDownloadResponse? {
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.first == "e", components.count >= 2,
              let route = galleryRoutes[components[1]] else { return nil }
        if components.count == 2 {
            return galleryPage(route)
        }
        if components.count == 3, components[2] == "station" {
            return sharingStationPage(route)
        }
        guard components.count == 4, components[2] == "thumb", components[3].hasSuffix(".jpg"),
              let sessionID = String(components[3].dropLast(4)).removingPercentEncoding,
              let session = route.approvedSessions.first(where: { $0.sessionID == sessionID }),
              let data = try? Data(contentsOf: session.thumbnailURL) else {
            return notFound()
        }
        return LocalDownloadResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "image/jpeg",
            headers: ["Cache-Control": "no-store"],
            body: data
        )
    }

    private func page(token: String, registration: SessionRouteRegistration) -> LocalDownloadResponse {
        let directory = registration.sessionDirectory
        let gifURL = directory.appendingPathComponent("booth.gif")
        let isThai = registration.language == .thai
        let gifLabel = isThai ? "ดาวน์โหลด GIF" : "Download GIF"
        let gifByteCount = (try? FileManager.default.attributesOfItem(atPath: gifURL.path)[.size] as? NSNumber)?.int64Value
        let gifReady = registration.gifState == .ready && gifByteCount != nil
        let gifSize = gifByteCount.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        let gifWarning = gifReady && (gifByteCount ?? 0) > 10 * 1024 * 1024
            ? "<p id=\"gif-warning\">\(isThai ? "GIF มีขนาดใหญ่ — อาจใช้เวลาดาวน์โหลดนานขึ้น" : "Large GIF — download may take longer.")</p>"
            : ""
        let gifButton: String
        switch registration.gifState {
        case .none:
            gifButton = ""
        case .preparing:
            gifButton = "<p id=\"gif-status\">\(isThai ? "กำลังเตรียม GIF…" : "Preparing GIF…")</p><meta http-equiv=\"refresh\" content=\"2\">"
        case .ready:
            gifButton = gifReady
                ? #"<a class="btn secondary" href="/s/\#(token)/booth.gif" download="photobooth.gif">⬇ \#(gifLabel) · \#(gifSize ?? "")</a>\#(gifWarning)"#
                : "<p id=\"gif-status\">\(isThai ? "GIF ไม่พร้อมใช้งาน รูปภาพของคุณยังดาวน์โหลดได้" : "GIF unavailable. Your photo strip is still ready.")</p>"
        case .failed:
            gifButton = "<p id=\"gif-status\">\(isThai ? "GIF ไม่พร้อมใช้งาน รูปภาพของคุณยังดาวน์โหลดได้" : "GIF unavailable. Your photo strip is still ready.")</p>"
        }
        let galleryButton: String = {
            guard let path = registration.eventGalleryPath else { return "" }
            let label = isThai ? "ดูแกลเลอรีของงาน" : "View event gallery"
            return #"<a class="btn secondary" href="\#(path.htmlEscaped)">\#(label)</a>"#
        }()
        let title = isThai ? "รูปภาพของคุณ" : "Your photos"
        let stripLabel = isThai ? "ดาวน์โหลดโฟโต้สตริป" : "Download photo strip"
        let escapedToken = token.htmlEscaped
        let html = """
        <!DOCTYPE html>
        <html lang="\(isThai ? "th" : "en")">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title.htmlEscaped)</title>
        <style>
        body{font-family:-apple-system,sans-serif;background:#111;color:#eee;text-align:center;padding:2rem;margin:0}
        h1{font-size:1.5rem;margin-bottom:.25rem}p{color:#aaa;font-size:.9rem;margin-bottom:2rem}
        img{max-width:90vw;max-height:70vh;border-radius:8px;display:block;margin:0 auto 1.5rem}
        a.btn{display:inline-block;background:#fff;color:#111;padding:.75rem 2rem;border-radius:8px;text-decoration:none;font-weight:600;margin:.5rem}
        a.btn.secondary{background:#333;color:#eee}
        </style>
        </head>
        <body>
        <h1>✨ \(title.htmlEscaped)</h1>
        <p>\(isThai ? "ดาวน์โหลดความทรงจำของคุณ" : "Download your memories")</p>
        <img src="/s/\(escapedToken)/strip.png" alt="\(title.htmlEscaped)">
        <br>
        <a class="btn" href="/s/\(escapedToken)/strip.png" download="photobooth-strip.png">⬇ \(stripLabel)</a>
        \(gifButton)
        \(galleryButton)
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

    private func galleryPage(_ route: EventGalleryRouteRegistration) -> LocalDownloadResponse {
        let isThai = route.language == .thai
        let countText = isThai ? "รูปภาพที่อนุมัติแล้ว" : "approved sessions"
        let viewLabel = isThai ? "ดูรูปภาพ" : "View photos"
        let cards = route.approvedSessions.map { session in
            let date = formattedDate(session.startedAt, language: route.language)
            let template = session.templateName.htmlEscaped
            let filter = filterName(session.filterID, language: route.language).htmlEscaped
            let gif = route.showGIFLinks && session.gifAvailable
                ? (isThai ? " · GIF" : " · GIF")
                : ""
            return """
            <article class="card">
              <img src="/e/\(route.eventToken.htmlEscaped)/thumb/\(session.sessionID.htmlEscaped).jpg" alt="\(template)">
              <div class="meta">\(date.htmlEscaped)<br>\(template) · \(filter)\(gif)</div>
              <a class="btn" href="/s/\(session.downloadToken.htmlEscaped)/">\(viewLabel)</a>
            </article>
            """
        }.joined(separator: "\n")
        let title = route.title.htmlEscaped
        let empty = isThai ? "ยังไม่มีรูปภาพที่อนุมัติ" : "No approved sessions yet"
        let html = """
        <!DOCTYPE html>
        <html lang="\(isThai ? "th" : "en")">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="15">
        <title>\(title)</title>
        <style>
        body{font-family:-apple-system,sans-serif;background:#111;color:#eee;padding:1.5rem;margin:0}
        h1{text-align:center;margin:.5rem 0}.count{text-align:center;color:#aaa}
        .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:1rem;max-width:1200px;margin:2rem auto}
        .card{background:#1d1d1d;border-radius:14px;padding:12px;text-align:center}
        .card img{width:100%;aspect-ratio:1/1;object-fit:contain;background:#080808;border-radius:10px}
        .meta{color:#aaa;font-size:.85rem;line-height:1.45;margin:.75rem 0}
        a.btn{display:inline-block;background:#fff;color:#111;padding:.65rem 1.2rem;border-radius:8px;text-decoration:none;font-weight:600}
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        <div class="count">\(route.approvedSessions.count) \(countText)</div>
        <main class="grid">\(cards.isEmpty ? "<p>\(empty.htmlEscaped)</p>" : cards)</main>
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

    private func sharingStationPage(_ route: EventGalleryRouteRegistration) -> LocalDownloadResponse {
        let title = route.title.htmlEscaped
        let cards = route.approvedSessions.map { session in
            let label = session.templateName.htmlEscaped
            return """
            <a class="card" href="/s/\(session.downloadToken.htmlEscaped)/">
              <img src="/e/\(route.eventToken.htmlEscaped)/thumb/\(session.sessionID.htmlEscaped).jpg" alt="\(label)">
              <span>Tap to view</span>
            </a>
            """
        }.joined(separator: "\n")
        let empty = route.language == .thai ? "ยังไม่มีรูปภาพที่อนุมัติ" : "No approved sessions yet"
        let html = """
        <!DOCTYPE html><html lang="\(route.language == .thai ? "th" : "en")"><head>
        <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="refresh" content="3"><title>\(title) · Sharing Station</title>
        <style>body{font-family:-apple-system,sans-serif;background:#111;color:#eee;padding:16px;margin:0}h1{text-align:center;font-size:clamp(1.3rem,4vw,2.2rem)}p{text-align:center;color:#aaa}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;max-width:1100px;margin:24px auto}.card{background:#202020;color:#fff;border-radius:12px;padding:8px;text-decoration:none;text-align:center;font-weight:600}.card img{width:100%;aspect-ratio:1;object-fit:contain;background:#080808;border-radius:8px;display:block;margin-bottom:8px}@media(max-width:600px){.grid{grid-template-columns:repeat(2,1fr)}}</style>
        </head><body><h1>\(title)</h1><p>Recent Photos · Tap your photo</p><main class="grid">\(cards.isEmpty ? "<p>\(empty.htmlEscaped)</p>" : cards)</main></body></html>
        """
        return LocalDownloadResponse(statusCode: 200, reason: "OK", contentType: "text/html; charset=utf-8", headers: ["Cache-Control": "no-store"], body: Data(html.utf8))
    }

    private func formattedDate(_ date: Date, language: CustomerLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func filterName(_ filter: PhotoFilterID, language: CustomerLanguage) -> String {
        if language == .thai {
            switch filter {
            case .original: return "ต้นฉบับ"
            case .monochrome: return "ขาวดำ"
            case .warm: return "โทนอุ่น"
            case .cool: return "โทนเย็น"
            case .highContrast: return "คอนทราสต์สูง"
            case .soft: return "นุ่มนวล"
            case .vintage: return "วินเทจ"
            }
        }
        switch filter {
        case .original: return "Original"
        case .monochrome: return "Monochrome"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .highContrast: return "High Contrast"
        case .soft: return "Soft"
        case .vintage: return "Vintage"
        }
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
