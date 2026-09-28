import Foundation
import Network
import Darwin

enum LocalWebServerState: Sendable, Equatable {
    case stopped
    case starting
    case ready(port: UInt16)
    case failed(message: String)
}

enum LocalGuestRouteExposure: Sendable, Equatable {
    case disabled
    case trustedLocalHTTP
}

struct LocalWebServerStatus: Sendable, Equatable {
    var state: LocalWebServerState
    var registeredTokenCount: Int
}

struct OperatorWebHandlers: Sendable {
    var isEnabled: @MainActor @Sendable () -> Bool
    var pair: @MainActor @Sendable (String) -> String?
    var authorize: @MainActor @Sendable (String) -> Bool
    var status: @MainActor @Sendable () async -> BoothHealthSnapshot
    var action: @MainActor @Sendable (RemoteOperatorAction) async -> Bool
    var events: @MainActor @Sendable () async -> Data
}

actor LocalWebServer {
    private struct ActiveGuestConnection {
        let connection: NWConnection
        let sessionRoute: String?
    }

    private static let maximumActiveConnections = 48
    private static let maximumActiveConnectionsPerClient = 8
    private static let fileChunkTimeoutNanoseconds: UInt64 = 15_000_000_000
    private static let securityHeaders = [
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
    ]

    private var listener: NWListener?
    let port: UInt16
    private var sessionRoutes: [String: SessionRouteRegistration] = [:]
    private var hiddenGuestRoutes = Set<String>()
    private var galleryRoutes: [String: EventGalleryRouteRegistration] = [:]
    private var guestRouteExposure: LocalGuestRouteExposure = .disabled
    private var guestRouteGeneration: UInt64 = 0
    private var activeGuestConnections: [UUID: ActiveGuestConnection] = [:]
    private var operatorHandlers: OperatorWebHandlers?
    private var activePort: UInt16?
    private var connectionAdmission = LocalWebServerConnectionAdmission(
        maximumConnections: maximumActiveConnections,
        maximumPerClient: maximumActiveConnectionsPerClient
    )
    private let requestTimeoutNanoseconds: UInt64
#if DEBUG
    private var beforeFileResponseForTesting: (@Sendable () async -> Void)?
#endif
    private let ioQueue = DispatchQueue(label: "PRC-PhotoBooth.LocalWebServer", qos: .utility, attributes: .concurrent)

    private var state: LocalWebServerState = .stopped

    init(port: UInt16 = 8585, requestTimeoutSeconds: TimeInterval = 10) {
        self.port = port
        requestTimeoutNanoseconds = UInt64(max(0.001, requestTimeoutSeconds) * 1_000_000_000)
    }

    func registerToken(_ token: String, sessionDirectory: URL) {
        guard !token.isEmpty else { return }
        registerToken(token, registration: SessionRouteRegistration(
                sessionDirectory: sessionDirectory.standardizedFileURL,
                language: .english,
                eventGalleryPath: nil,
                gifState: .none
        ))
    }

    func registerToken(_ token: String, registration: SessionRouteRegistration) {
        registerGuestRoute(path: "/s/\(token)", registration: registration)
    }

    func registerGuestRoute(path: String, registration: SessionRouteRegistration) {
        guard guestRouteExposure == .trustedLocalHTTP,
              let route = LocalDownloadRouter.canonicalSessionRouteKey(path),
              !hiddenGuestRoutes.contains(route) else { return }
        sessionRoutes[route] = registration
    }

    /// Permanently hides a session route for this server lifetime. This also
    /// prevents an already-running finalization job from restoring it after
    /// cleanup has removed the current registration.
    func hideGuestRoute(path: String) {
        guard let route = LocalDownloadRouter.canonicalSessionRouteKey(path) else { return }
        hiddenGuestRoutes.insert(route)
        sessionRoutes.removeValue(forKey: route)
        for active in activeGuestConnections.values where active.sessionRoute == route {
            active.connection.cancel()
        }
    }

    func unregisterToken(_ token: String) {
        unregisterGuestRoute(path: "/s/\(token)")
    }

    func unregisterGuestRoute(path: String) {
        guard let route = LocalDownloadRouter.canonicalSessionRouteKey(path) else { return }
        sessionRoutes.removeValue(forKey: route)
    }

    func replaceTokenMap(_ mappings: [String: URL]) {
        guard guestRouteExposure == .trustedLocalHTTP else {
            sessionRoutes.removeAll()
            return
        }
        sessionRoutes = mappings.reduce(into: [:]) { result, mapping in
            guard let route = LocalDownloadRouter.canonicalSessionRouteKey(mapping.key),
                  !hiddenGuestRoutes.contains(route) else { return }
            result[route] = SessionRouteRegistration(
                sessionDirectory: mapping.value.standardizedFileURL,
                language: .english,
                eventGalleryPath: nil,
                gifState: .none
            )
        }
    }

    func replaceSessionRoutes(_ mappings: [String: SessionRouteRegistration]) {
        guard guestRouteExposure == .trustedLocalHTTP else {
            sessionRoutes.removeAll()
            return
        }
        sessionRoutes = mappings.reduce(into: [:]) { result, mapping in
            guard let route = LocalDownloadRouter.canonicalSessionRouteKey(mapping.key),
                  !hiddenGuestRoutes.contains(route) else { return }
            result[route] = mapping.value
        }
    }

    func replaceGalleryRoutes(_ mappings: [String: EventGalleryRouteRegistration]) {
        guard guestRouteExposure == .trustedLocalHTTP else {
            galleryRoutes.removeAll()
            return
        }
        galleryRoutes = mappings.reduce(into: [:]) { result, mapping in
            guard !mapping.key.isEmpty else { return }
            result[mapping.key] = mapping.value
        }
    }

    func setGuestRouteExposure(_ exposure: LocalGuestRouteExposure) {
        if guestRouteExposure != exposure {
            guestRouteGeneration &+= 1
        }
        guestRouteExposure = exposure
        guard exposure == .disabled else { return }
        sessionRoutes.removeAll()
        galleryRoutes.removeAll()
        for active in activeGuestConnections.values {
            active.connection.cancel()
        }
        activeGuestConnections.removeAll()
    }

    func configureOperatorHandlers(_ handlers: OperatorWebHandlers) {
        operatorHandlers = handlers
    }

#if DEBUG
    func setBeforeFileResponseForTesting(_ handler: (@Sendable () async -> Void)?) {
        beforeFileResponseForTesting = handler
    }
#endif

    func statusSnapshot() -> LocalWebServerStatus {
        LocalWebServerStatus(state: state, registeredTokenCount: sessionRoutes.count)
    }

    func connectionAdmissionSnapshot() -> LocalWebServerConnectionAdmission.Snapshot {
        connectionAdmission.snapshot
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
            listener.start(queue: ioQueue)
            self.listener = listener
        } catch {
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        state = .stopped
    }

    private func handleListenerState(_ update: NWListener.State) {
        switch update {
        case .ready:
            activePort = listener?.port?.rawValue ?? port
            state = .ready(port: activePort ?? port)
        case .failed(let error), .waiting(let error):
            state = .failed(message: error.localizedDescription)
        case .cancelled:
            activePort = nil
            state = .stopped
        case .setup:
            state = .starting
        @unknown default:
            state = .failed(message: "Local download server entered an unknown state.")
        }
    }

    private func clientHost(for connection: NWConnection) -> String? {
        switch connection.endpoint {
        case .hostPort(let host, _):
            return LocalWebServerClientIdentity.normalizedHost("\(host)")
        default:
            return connection.endpoint.debugDescription
        }
    }

    private func handle(_ connection: NWConnection) async {
        let clientKey = clientHost(for: connection)
        guard let admission = connectionAdmission.acquire(clientKey: clientKey) else {
            connection.start(queue: ioQueue)
            _ = await send(connection, data: secured(busy()).httpData, timeoutNanoseconds: Self.fileChunkTimeoutNanoseconds)
            connection.cancel()
            return
        }
        defer { connectionAdmission.release(admission) }
        defer { connection.cancel() }
        connection.start(queue: ioQueue)
        var parser = HTTPServerRequestParser()
        var request: HTTPServerRequest?
        let deadline = DispatchTime.now().uptimeNanoseconds + requestTimeoutNanoseconds
        do {
            while request == nil, let data = await receive(from: connection, deadline: deadline) {
                request = try parser.append(data)
            }
        } catch {
            _ = await send(connection, data: secured(errorResponse(for: error)).httpData, timeoutNanoseconds: Self.fileChunkTimeoutNanoseconds)
            return
        }
        guard let request else {
            _ = await send(connection, data: secured(errorResponse(for: HTTPServerRequestError.malformed)).httpData, timeoutNanoseconds: Self.fileChunkTimeoutNanoseconds)
            return
        }
        let isGuestRequest = LocalDownloadRouter.isGuestMediaPath(request.path)
        let guestGeneration = guestRouteGeneration
        let guestConnectionID = isGuestRequest ? UUID() : nil
        if let guestConnectionID {
            activeGuestConnections[guestConnectionID] = ActiveGuestConnection(
                connection: connection,
                sessionRoute: LocalDownloadRouter.canonicalSessionRouteKey(forRequestPath: request.path)
            )
        }
        defer {
            if let guestConnectionID {
                activeGuestConnections.removeValue(forKey: guestConnectionID)
            }
        }
        switch await route(for: request) {
        case .response(let response):
            guard !isGuestRequest || guestGeneration == guestRouteGeneration else {
                connection.cancel()
                return
            }
            _ = await send(connection, data: secured(response).httpData, timeoutNanoseconds: Self.fileChunkTimeoutNanoseconds)
        case .file(let response):
#if DEBUG
            await beforeFileResponseForTesting?()
#endif
            guard !isGuestRequest
                    || (guestGeneration == guestRouteGeneration && guestRouteExposure == .trustedLocalHTTP) else {
                connection.cancel()
                return
            }
            await send(connection, file: response)
        }
    }

    private func receive(from connection: NWConnection, deadline: UInt64) async -> Data? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else {
            connection.cancel()
            return nil
        }
        let remaining = deadline - now
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                        guard error == nil, let data, !data.isEmpty else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(returning: data)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: remaining)
                guard !Task.isCancelled else { return nil }
                connection.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func send(
        _ connection: NWConnection,
        data: Data,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        continuation.resume(returning: error == nil)
                    })
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return false }
                connection.cancel()
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func send(_ connection: NWConnection, file response: LocalDownloadFileResponse) async {
        let response = secured(response)
        guard await send(connection, data: response.httpHeaderData, timeoutNanoseconds: Self.fileChunkTimeoutNanoseconds) else { return }
        let chunkSize = 128 * 1024
        var bytesSent: Int64 = 0
        do {
            let handle = try FileHandle(forReadingFrom: response.fileURL)
            defer { try? handle.close() }
            while bytesSent < response.contentLength, !Task.isCancelled {
                let remaining = response.contentLength - bytesSent
                guard let chunk = try handle.read(upToCount: min(chunkSize, Int(remaining))), !chunk.isEmpty else {
                    return
                }
                guard await send(connection, data: chunk, timeoutNanoseconds: Self.fileChunkTimeoutNanoseconds) else { return }
                bytesSent += Int64(chunk.count)
            }
        } catch {
            return
        }
    }

    private func route(for request: HTTPServerRequest) async -> LocalDownloadRoute {
        if request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first == "/operator"
            || request.path.hasPrefix("/operator/") {
            return .response(await operatorResponse(for: request))
        }
        guard request.method == "GET" else { return .response(methodNotAllowed()) }
        return LocalDownloadRouter(
            sessionRoutes: sessionRoutes,
            galleryRoutes: galleryRoutes,
            guestRouteExposure: guestRouteExposure
        ).route(for: request.path)
    }

    private func operatorResponse(for request: HTTPServerRequest) async -> LocalDownloadResponse {
        guard RemoteOperatorAuth.isAvailableInCurrentBuild else { return notFound() }
        guard let handlers = operatorHandlers else { return notFound() }
        guard await handlers.isEnabled() else { return notFound() }
        let path = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? request.path
        if request.method == "GET", (path == "/operator/" || path == "/operator") {
            return operatorLanding()
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

    private func operatorLanding() -> LocalDownloadResponse {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>PRC PhotoBooth Operator</title></head>
        <body style="font-family:-apple-system,sans-serif;background:#101010;color:#fff;padding:2rem;max-width:42rem;margin:auto">
        <h1>PRC PHOTOBOOTH</h1><p>Pairing links are generated explicitly from the Mac Operations screen.</p>
        <p>This page never contains a pairing credential.</p></body></html>
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
        LocalDownloadResponse(statusCode: 200, reason: "OK", contentType: "text/html; charset=utf-8", headers: Self.securityHeaders, body: Data(html.utf8))
    }

    private func errorResponse(for error: Error) -> LocalDownloadResponse {
        switch error {
        case HTTPServerRequestError.oversized: return LocalDownloadResponse(statusCode: 413, reason: "Payload Too Large", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Request too large".utf8))
        default: return badRequest()
        }
    }

    private func busy() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 503, reason: "Service Unavailable", contentType: "text/plain; charset=utf-8", headers: ["Retry-After": "1"], body: Data("Server busy".utf8)) }
    private func secured(_ response: LocalDownloadResponse) -> LocalDownloadResponse {
        var response = response
        for (name, value) in Self.securityHeaders where response.headers[name] == nil {
            response.headers[name] = value
        }
        return response
    }
    private func secured(_ response: LocalDownloadFileResponse) -> LocalDownloadFileResponse {
        var response = response
        for (name, value) in Self.securityHeaders where response.headers[name] == nil {
            response.headers[name] = value
        }
        return response
    }
    private func badRequest() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 400, reason: "Bad Request", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Bad request".utf8)) }
    private func unauthorized() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 401, reason: "Unauthorized", contentType: "text/plain; charset=utf-8", headers: ["WWW-Authenticate": "Bearer"], body: Data("Unauthorized".utf8)) }
    private func methodNotAllowed() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 405, reason: "Method Not Allowed", contentType: "text/plain; charset=utf-8", headers: ["Allow": "GET, POST"], body: Data("Method not allowed".utf8)) }
    private func serverError() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 500, reason: "Internal Server Error", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Internal server error".utf8)) }
    private func notFound() -> LocalDownloadResponse { LocalDownloadResponse(statusCode: 404, reason: "Not Found", contentType: "text/plain; charset=utf-8", headers: [:], body: Data("Not found".utf8)) }

    static func guestDeliveryEndpoint(
        selection: GuestDeliveryInterfaceSelection = .automatic,
        port: UInt16 = 8585
    ) -> GuestDeliveryResolution {
        GuestDeliveryEndpointResolver.resolveSystem(selection: selection, port: port)
    }

    static func lanIPAddress(
        selection: GuestDeliveryInterfaceSelection = .automatic,
        port: UInt16 = 8585
    ) -> String? {
        guestDeliveryEndpoint(selection: selection, port: port).endpoint?.address
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
