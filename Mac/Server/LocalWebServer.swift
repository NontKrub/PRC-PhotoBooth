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

actor LocalWebServer {
    private var listener: NWListener?
    let port: UInt16
    private var tokenMap: [String: URL] = [:]

    // Kept only while older coordinator code still supplies relative paths.
    var sessionsDirectory: URL?

    private var state: LocalWebServerState = .stopped

    init(port: UInt16 = 8585) {
        self.port = port
    }

    func registerToken(_ token: String, sessionDirectory: URL) {
        guard !token.isEmpty else { return }
        tokenMap[token] = sessionDirectory.standardizedFileURL
    }

    func unregisterToken(_ token: String) {
        tokenMap.removeValue(forKey: token)
    }

    func replaceTokenMap(_ mappings: [String: URL]) {
        tokenMap = mappings.reduce(into: [:]) { result, mapping in
            guard !mapping.key.isEmpty else { return }
            result[mapping.key] = mapping.value.standardizedFileURL
        }
    }

    // Compatibility for completed sessions created before absolute token maps.
    func registerToken(_ token: String, sessionID: String) {
        guard let sessionsDirectory else { return }
        registerToken(token, sessionDirectory: sessionsDirectory.appendingPathComponent(sessionID))
    }

    func statusSnapshot() -> LocalWebServerStatus {
        LocalWebServerStatus(state: state, registeredTokenCount: tokenMap.count)
    }

    func start() throws {
        guard listener == nil else { return }
        state = .starting
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
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
        guard let data = await receive(from: connection),
              let request = parseRequest(data),
              request.method == "GET" else {
            await send(connection, response: LocalDownloadRouter(tokenMap: [:]).response(for: "/missing").httpData)
            return
        }
        let response = LocalDownloadRouter(tokenMap: tokenMap).response(for: request.path)
        await send(connection, response: response.httpData)
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
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

    private struct HTTPRequest {
        var method: String
        var path: String
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return HTTPRequest(method: parts[0], path: parts[1])
    }

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
