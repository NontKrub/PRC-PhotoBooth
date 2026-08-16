import Foundation
import Network

enum LocalWebServerState: Sendable, Equatable {
    case stopped
    case starting
    case ready(port: UInt16)
    case failed(message: String)
}

struct LocalWebServerStatus: Sendable, Equatable {
    var state: LocalWebServerState
    var registeredTokenCount: Int
}

struct OperatorWebHandlers: Sendable {
    var pairingURL: @MainActor @Sendable () -> String
    var pair: @MainActor @Sendable (String) -> String?
    var authorize: @MainActor @Sendable (String) -> Bool
    var status: @MainActor @Sendable () async -> BoothHealthSnapshot
    var action: @MainActor @Sendable (RemoteOperatorAction) async -> Bool
    var events: @MainActor @Sendable () async -> Data
}

actor LocalWebServer {
    private var listener: NWListener?
    let port: UInt16
    private var sessionRoutes: [String: SessionRouteRegistration] = [:]
    private var galleryRoutes: [String: EventGalleryRouteRegistration] = [:]
    private var operatorHandlers: OperatorWebHandlers?

    private var state: LocalWebServerState = .stopped

    init(port: UInt16 = 8585) {
        self.port = port
    }

    func registerToken(_ token: String, sessionDirectory: URL) {
        guard !token.isEmpty else { return }
        registerToken(token, registration: SessionRouteRegistration(
            sessionDirectory: sessionDirectory.standardizedFileURL,
            language: .english,
            eventGalleryPath: nil
        ))
    }

    func registerToken(_ token: String, registration: SessionRouteRegistration) {
        guard !token.isEmpty else { return }
        sessionRoutes[token] = registration
    }

    func unregisterToken(_ token: String) {
        sessionRoutes.removeValue(forKey: token)
    }

    func replaceTokenMap(_ mappings: [String: URL]) {
        sessionRoutes = mappings.reduce(into: [:]) { result, mapping in
            guard !mapping.key.isEmpty else { return }
            result[mapping.key] = SessionRouteRegistration(
                sessionDirectory: mapping.value.standardizedFileURL,
                language: .english,
                eventGalleryPath: nil
            )
        }
    }

    func replaceSessionRoutes(_ mappings: [String: SessionRouteRegistration]) {
        sessionRoutes = mappings.reduce(into: [:]) { result, mapping in
            guard !mapping.key.isEmpty else { return }
            result[mapping.key] = mapping.value
        }
    }

    func replaceGalleryRoutes(_ mappings: [String: EventGalleryRouteRegistration]) {
        galleryRoutes = mappings.reduce(into: [:]) { result, mapping in
            guard !mapping.key.isEmpty else { return }
            result[mapping.key] = mapping.value
        }
    }

    func configureOperatorHandlers(_ handlers: OperatorWebHandlers) {
        operatorHandlers = handlers
    }

    func statusSnapshot() -> LocalWebServerStatus {
        LocalWebServerStatus(state: state, registeredTokenCount: sessionRoutes.count)
    }

    func waitUntilReady(timeout: TimeInterval = 5) async -> LocalWebServerStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .ready, .failed, .stopped:
                return statusSnapshot()
            case .starting:
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if case .starting = state {
            state = .failed(message: "Local download server did not become ready before the startup timeout.")
        }
        return statusSnapshot()
    }

    func start() throws {
        guard listener == nil else { return }
        state = .starting
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                let error = NSError(
                    domain: "PRCPhotoBooth.LocalWebServer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid local download server port \(port)."]
                )
                state = .failed(message: error.localizedDescription)
                throw error
            }
            let listener = try NWListener(using: parameters, on: endpointPort)
            listener.stateUpdateHandler = { [weak self] update in
                Task { await self?.handleListenerState(update) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func handleListenerState(_ update: NWListener.State) {
        switch update {
        case .ready:
            state = .ready(port: port)
        case .failed(let error), .waiting(let error):
            state = .failed(message: error.localizedDescription)
        case .cancelled:
            state = .stopped
        case .setup:
            state = .starting
        @unknown default:
            state = .failed(message: "Local download server entered an unknown state.")
        }
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        var parser = HTTPServerRequestParser()
        var request: HTTPServerRequest?
        do {
            while request == nil, let data = await receive(from: connection) {
                request = try parser.append(data)
            }
        } catch {
            await send(connection, response: errorResponse(for: error).httpData)
            return
        }
        guard let request else {
            await send(connection, response: errorResponse(for: HTTPServerRequestError.malformed).httpData)
            return
        }
        let response = await response(for: request)
        await send(connection, response: response.httpData)
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                guard error == nil, let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func send(_ connection: NWConnection, response: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }

    private func response(for request: HTTPServerRequest) async -> LocalDownloadResponse {
        if request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first == "/operator"
            || request.path.hasPrefix("/operator/") {
            return await operatorResponse(for: request)
        }
        guard request.method == "GET" else { return methodNotAllowed() }
        return LocalDownloadRouter(sessionRoutes: sessionRoutes, galleryRoutes: galleryRoutes).response(for: request.path)
    }

    private func operatorResponse(for request: HTTPServerRequest) async -> LocalDownloadResponse {
        guard let handlers = operatorHandlers else { return notFound() }
        let path = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? request.path
        if request.method == "GET", (path == "/operator/" || path == "/operator") {
            return operatorLanding(pairingURL: await handlers.pairingURL())
        }
        if request.method == "GET", path.hasPrefix("/operator/pair/") {
            let token = String(path.dropFirst("/operator/pair/".count))
            guard !token.isEmpty, let sessionToken = await handlers.pair(token) else {
                return unauthorized()
            }
            return operatorDashboard(sessionToken: sessionToken)
        }
        guard let bearer = bearerToken(from: request), await handlers.authorize(bearer) else {
            return unauthorized()
        }
        switch (request.method, path) {
        case ("GET", "/operator/api/status"):
            return jsonResponse(await handlers.status())
        case ("GET", "/operator/api/events"):
            return jsonDataResponse(await handlers.events())
        case ("POST", "/operator/api/action"):
            guard let actionRequest = try? JSONDecoder().decode(RemoteOperatorActionRequest.self, from: request.body) else {
                return badRequest()
            }
            let accepted = await handlers.action(actionRequest.action)
            return jsonResponse(["accepted": accepted], statusCode: accepted ? 200 : 409)
        default:
            return request.method == "GET" || request.method == "POST" ? notFound() : methodNotAllowed()
        }
    }

    private func bearerToken(from request: HTTPServerRequest) -> String? {
        guard let value = request.header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        return parts[1]
    }

    private func jsonResponse<T: Encodable>(_ value: T, statusCode: Int = 200) -> LocalDownloadResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return serverError() }
        return LocalDownloadResponse(
            statusCode: statusCode,
            reason: statusCode == 200 ? "OK" : "Conflict",
            contentType: "application/json",
            headers: ["Cache-Control": "no-store"],
            body: data
        )
    }

    private func jsonResponse(_ snapshot: BoothHealthSnapshot) -> LocalDownloadResponse {
        jsonResponse(snapshot, statusCode: 200)
    }

    private func jsonDataResponse(_ data: Data) -> LocalDownloadResponse {
        LocalDownloadResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "application/json",
            headers: ["Cache-Control": "no-store"],
            body: data
        )
    }

    private func operatorLanding(pairingURL: String) -> LocalDownloadResponse {
        let escaped = pairingURL.htmlEscaped
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>PRC PhotoBooth Operator</title></head>
        <body style="font-family:-apple-system,sans-serif;background:#101010;color:#fff;padding:2rem;max-width:42rem;margin:auto">
        <h1>PRC PHOTOBOOTH</h1><p>Pairing link is generated on the Mac Operations screen.</p>
        <p><a style="color:#fff" href="\(escaped)">Open pairing link</a></p></body></html>
        """
        return htmlResponse(html)
    }

    private func operatorDashboard(sessionToken: String) -> LocalDownloadResponse {
        let escaped = sessionToken.htmlEscaped
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>PRC PhotoBooth Operator</title>
        <style>body{font-family:-apple-system,sans-serif;background:#101010;color:#f5f5f5;padding:16px;max-width:720px;margin:auto}h1{font-size:24px}.card{background:#1d1d1d;border-radius:14px;padding:16px;margin:12px 0}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}button{padding:12px;border:0;border-radius:10px;font-weight:600}button.danger{background:#e55;color:#fff}pre{white-space:pre-wrap;color:#bdbdbd}</style></head>
        <body><h1>PRC PHOTOBOOTH</h1><div id="status" class="card">Loading…</div><div class="card grid">
        <button onclick="act('pause')">Pause</button><button onclick="act('resume')">Resume</button><button onclick="act('retryReceive')">Retry Receive</button><button onclick="act('retake')">Retake</button><button onclick="act('continueSession')">Continue</button><button onclick="act('usePrevious')">Use Previous</button><button onclick="act('reconnectCamera')">Reconnect Camera</button><button onclick="act('retryFailedJobs')">Retry Jobs</button><button class="danger" onclick="act('cancelSession')">Cancel Session</button></div>
        <script>const token='\(escaped)';const headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'};async function load(){const r=await fetch('/operator/api/status',{headers});if(!r.ok)return;const s=await r.json();const d=s.delivery||{};document.querySelector('#status').textContent='Booth: '+s.status+'\nPhase: '+s.currentPhase+'\nCamera: '+(s.camera.connected?'Connected':'Unavailable')+'\nControl: '+s.controlConnection+'\nQueue: '+s.queuePending+' pending · '+s.queueFailed+' failed\nDelivery: '+(d.local||'Unknown')+' · '+(d.cloud||'No cloud')+' · '+(d.print||'No print')+'\nPrinter: '+s.printerStatus+' ('+s.printSuccessCount+' ok / '+s.printFailureCount+' failed)';}async function act(action){if(action==='cancelSession'&&!confirm('Cancel active session?'))return;await fetch('/operator/api/action',{method:'POST',headers,body:JSON.stringify({action})});load();}load();setInterval(load,2000);</script></body></html>
        """
        return htmlResponse(html)
    }

    private func htmlResponse(_ html: String) -> LocalDownloadResponse {
        LocalDownloadResponse(statusCode: 200, reason: "OK", contentType: "text/html; charset=utf-8", headers: ["Cache-Control": "no-store"], body: Data(html.utf8))
    }

    private func errorResponse(for error: Error) -> LocalDownloadResponse {
        switch error {
        case HTTPServerRequestError.oversized: return LocalDownloadResponse(statusCode: 413, reason: "Payload Too Large", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Request too large".utf8))
        default: return badRequest()
        }
    }

    private func badRequest() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Bad request".utf8)) }
    private func unauthorized() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 401, reason: "Unauthorized", contentType: "text/plain; charset=utf-8", headers: ["WWW-Authenticate": "Bearer"], body: Data("Unauthorized".utf8)) }
    private func methodNotAllowed() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 405, reason: "Method Not Allowed", contentType: "text/plain; charset=utf-8", headers: ["Allow": "GET, POST"], body: Data("Method not allowed".utf8)) }
    private func serverError() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 500, reason: "Internal Server Error", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Internal server error".utf8)) }
    private func notFound() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 404, reason: "Not Found", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Not found".utf8)) }

    static func lanIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer = ifaddr
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback,
               current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    current.pointee.ifa_addr,
                    socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                let ip = hostname.withUnsafeBufferPointer { buffer in
                    String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
                }
                if ip.hasPrefix("192.168") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                    address = ip
                    break
                }
            }
            pointer = current.pointee.ifa_next
        }
        return address
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
