import Foundation
import Network

// Minimal HTTP/1.1 server for offline guest downloads.
// Routes: GET /s/<token>        → HTML download page
//         GET /s/<token>/strip.png → strip PNG file
//         GET /s/<token>/booth.gif → animated GIF file
actor LocalWebServer {
    private var listener: NWListener?
    let port: UInt16
    var sessionsDirectory: URL?

    // token → sessionID mapping
    private var tokenMap: [String: String] = [:]

    init(port: UInt16 = 8585) {
        self.port = port
    }

    func registerToken(_ token: String, sessionID: String) {
        tokenMap[token] = sessionID
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            Task { [weak self] in
                await self?.handle(conn)
            }
        }
        l.start(queue: .global(qos: .utility))
        self.listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handler

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        guard let data = await receive(from: connection),
              let request = parseRequest(data) else {
            await send(connection, response: http404())
            return
        }
        let response = await buildResponse(for: request)
        await send(connection, response: response)
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
    }

    private func send(_ connection: NWConnection, response: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
                cont.resume()
            })
        }
    }

    // MARK: - Request parsing

    private struct HTTPRequest {
        let method: String
        let path: String
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        return HTTPRequest(method: parts[0], path: parts[1])
    }

    // MARK: - Response builder

    private func buildResponse(for request: HTTPRequest) async -> Data {
        let path = request.path
        let components = path.split(separator: "/").map(String.init)

        // Expect /s/<token> or /s/<token>/strip.png or /s/<token>/booth.gif
        guard components.count >= 2, components[0] == "s" else { return http404() }
        let token = components[1]
        guard let sessionID = tokenMap[token] else { return http404() }

        if components.count == 2 {
            // Download page
            let html = downloadPageHTML(token: token, sessionID: sessionID)
            return httpResponse(body: Data(html.utf8), contentType: "text/html; charset=utf-8")
        } else if components.count == 3 {
            let file = components[2]
            guard let sessDir = sessionsDirectory else { return http404() }
            let fileURL = sessDir.appendingPathComponent(sessionID).appendingPathComponent(file)
            guard let fileData = try? Data(contentsOf: fileURL) else { return http404() }
            let ct = file.hasSuffix(".png") ? "image/png" : "image/gif"
            return httpResponse(body: fileData, contentType: ct)
        }
        return http404()
    }

    // MARK: - HTML download page

    private func downloadPageHTML(token: String, sessionID: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>PRC Photo Booth — Your Photos</title>
        <style>
        body { font-family: -apple-system, sans-serif; background: #111; color: #eee; text-align: center; padding: 2rem; margin: 0; }
        h1 { font-size: 1.5rem; margin-bottom: 0.25rem; }
        p { color: #aaa; font-size: 0.9rem; margin-bottom: 2rem; }
        img { max-width: 90vw; max-height: 70vh; border-radius: 8px; display: block; margin: 0 auto 1.5rem; }
        a.btn { display: inline-block; background: #fff; color: #111; padding: 0.75rem 2rem; border-radius: 8px; text-decoration: none; font-weight: 600; margin: 0.5rem; }
        a.btn.secondary { background: #333; color: #eee; }
        </style>
        </head>
        <body>
        <h1>✨ Your Photo Strip</h1>
        <p>Tap a button to save your memories!</p>
        <img src="/s/\(token)/strip.png" alt="Photo Strip">
        <br>
        <a class="btn" href="/s/\(token)/strip.png" download="photobooth-strip.png">⬇ Save Strip</a>
        <a class="btn secondary" href="/s/\(token)/booth.gif" download="photobooth.gif">⬇ Save GIF</a>
        </body>
        </html>
        """
    }

    // MARK: - HTTP helpers

    private func httpResponse(body: Data, contentType: String, status: String = "200 OK") -> Data {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private func http404() -> Data {
        httpResponse(body: Data("Not found".utf8), contentType: "text/plain", status: "404 Not Found")
    }

    // MARK: - LAN IP helper

    static func lanIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback && current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = hostname.withUnsafeBufferPointer { ptr in
                    String(decoding: ptr.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                if ip.hasPrefix("192.168") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                    address = ip; break
                }
            }
            ptr = current.pointee.ifa_next
        }
        return address
    }
}
