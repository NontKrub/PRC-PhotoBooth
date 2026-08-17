import Foundation
import Network
import Testing
import CryptoKit

@testable import PRC_PhotoBooth_Mac

@Suite("Local download server")
struct LocalWebServerTests {
    @Test("bind failure is reported without crashing")
    @MainActor
    func bindFailureIsReported() async throws {
        let holder = try NWListener(using: .tcp)
        let port = try await withCheckedThrowingContinuation { continuation in
            holder.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = holder.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: TestError.missingPort)
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            holder.newConnectionHandler = { connection in
                connection.cancel()
            }
            holder.start(queue: .global(qos: .utility))
        }
        defer { holder.cancel() }

        let server = LocalWebServer(port: port)
        try await server.start()
        let status = await server.waitUntilReady(timeout: 2)
        guard case .failed = status.state else {
            Issue.record("Expected a failed status for an occupied port: \(status)")
            return
        }
    }

    @Test("streams a media file without changing its bytes")
    func streamsMediaIntegrity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data((0..<512_000).map { UInt8($0 % 251) })
        try original.write(to: directory.appendingPathComponent("booth.gif"))

        let server = LocalWebServer(port: 0)
        await server.registerToken("token", registration: SessionRouteRegistration(
            sessionDirectory: directory,
            language: .english,
            eventGalleryPath: nil,
            gifState: .ready
        ))
        try await server.start()
        defer { Task { await server.stop() } }
        let status = await server.waitUntilReady(timeout: 2)
        guard case .ready(let port) = status.state else {
            Issue.record("Server did not become ready: \(status)")
            return
        }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/s/token/booth.gif"))
        let (downloaded, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Length") == String(original.count))
        #expect(downloaded.count == original.count)
        #expect(Data(SHA256.hash(data: downloaded)) == Data(SHA256.hash(data: original)))
    }
}

private enum TestError: Error {
    case missingPort
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-WebServer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
