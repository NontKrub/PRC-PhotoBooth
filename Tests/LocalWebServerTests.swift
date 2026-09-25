import Foundation
import Network
import Testing
import CryptoKit

@testable import PRC_PhotoBooth_Mac

@Suite("Local download server")
struct LocalWebServerTests {
    @Test("guest media routes are unavailable by default while health remains available")
    func guestRoutesAreDisabledByDefault() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("strip.png"))
        try Data([2]).write(to: directory.appendingPathComponent("booth.gif"))
        let thumbnail = directory.appendingPathComponent("gallery-thumb.jpg")
        try Data([3]).write(to: thumbnail)

        let sessionRegistration = SessionRouteRegistration(
            sessionDirectory: directory,
            language: .english,
            eventGalleryPath: "/e/event-token/",
            gifState: .ready
        )
        let galleryRoute = EventGalleryRouteRegistration(
            eventID: "event-1",
            eventToken: "event-token",
            title: "Event",
            language: .english,
            showGIFLinks: true,
            approvedSessions: [GalleryRouteSession(
                sessionID: "session-1",
                downloadToken: "token",
                startedAt: .now,
                thumbnailURL: thumbnail,
                gifAvailable: true,
                templateName: "Classic",
                filterID: .original
            )]
        )
        let server = LocalWebServer(port: 0)
        await server.registerToken("token", registration: sessionRegistration)
        await server.replaceGalleryRoutes(["event-token": galleryRoute])
        try await server.start()
        defer { Task { await server.stop() } }
        let status = await server.waitUntilReady(timeout: 2)
        guard case .ready(let port) = status.state else {
            Issue.record("Server did not become ready: \(status)")
            return
        }

        func statusCode(_ path: String) async throws -> Int {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
            let (_, response) = try await URLSession.shared.data(from: url)
            return try #require((response as? HTTPURLResponse)?.statusCode)
        }

        for path in [
            "/s/token/",
            "/s/token/strip.png",
            "/s/token/booth.gif",
            "/e/event-token/",
            "/e/event-token/station",
            "/e/event-token/thumb/session-1.jpg"
        ] {
            #expect(try await statusCode(path) == 404, "Expected guest route \(path) to be closed")
        }
        #expect(try await statusCode("/health") == 200)
        #expect(await server.statusSnapshot().registeredTokenCount == 0)

        await server.setGuestRouteExposure(.trustedLocalHTTP)
        await server.registerToken("token", registration: sessionRegistration)
        await server.replaceGalleryRoutes(["event-token": galleryRoute])
        for path in [
            "/s/token/",
            "/s/token/strip.png",
            "/s/token/booth.gif",
            "/e/event-token/",
            "/e/event-token/station",
            "/e/event-token/thumb/session-1.jpg"
        ] {
            #expect(try await statusCode(path) == 200, "Expected guest route \(path) to open")
        }

        await server.setGuestRouteExposure(.disabled)
        #expect(await server.statusSnapshot().registeredTokenCount == 0)
        for path in [
            "/s/token/",
            "/s/token/strip.png",
            "/s/token/booth.gif",
            "/e/event-token/",
            "/e/event-token/station",
            "/e/event-token/thumb/session-1.jpg"
        ] {
            #expect(try await statusCode(path) == 404, "Expected guest route \(path) to be revoked")
        }
        #expect(try await statusCode("/health") == 200)
    }

    @Test("operator routes are closed until explicitly enabled")
    func operatorRoutesAreDisabledByDefault() async throws {
        let server = LocalWebServer(port: 0)
        await server.configureOperatorHandlers(OperatorWebHandlers(
            isEnabled: { false },
            pair: { _ in nil },
            authorize: { _ in false },
            status: { .empty },
            action: { _ in false },
            events: { Data("[]".utf8) }
        ))
        try await server.start()
        defer { Task { await server.stop() } }
        let status = await server.waitUntilReady(timeout: 2)
        guard case .ready(let port) = status.state else {
            Issue.record("Server did not become ready: \(status)")
            return
        }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/operator"))
        let (body, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 404)
        #expect(String(decoding: body, as: UTF8.self).contains("pair") == false)
    }

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
        await server.setGuestRouteExposure(.trustedLocalHTTP)
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
        #expect(httpResponse.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(httpResponse.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer")
        #expect(httpResponse.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        #expect(downloaded.count == original.count)
        #expect(Data(SHA256.hash(data: downloaded)) == Data(SHA256.hash(data: original)))
    }

    @Test("disabling guest routes cancels a selected media response before it is sent")
    func disablingGuestRoutesCancelsSelectedMediaResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = Data("private guest media".utf8)
        try media.write(to: directory.appendingPathComponent("strip.png"))

        let gate = AsyncTestGate()
        let server = LocalWebServer(port: 0)
        await server.setGuestRouteExposure(.trustedLocalHTTP)
        await server.registerToken("token", sessionDirectory: directory)
        await server.setBeforeFileResponseForTesting { await gate.pause() }
        try await server.start()
        defer { Task { await gate.release(); await server.stop() } }
        let status = await server.waitUntilReady(timeout: 2)
        guard case .ready(let port) = status.state else {
            Issue.record("Server did not become ready: \(status)")
            return
        }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/s/token/strip.png"))
        let responseTask = Task { try await URLSession.shared.data(from: url) }
        await gate.waitUntilPaused()
        await server.setGuestRouteExposure(.disabled)
        await gate.release()

        if case .success(let (body, response)) = await responseTask.result {
            let httpResponse = response as? HTTPURLResponse
            #expect(httpResponse?.statusCode != 200 || body != media)
        }
    }

    @Test("per-client connection limit throttles excess concurrent requests from same client")
    func perClientConnectionLimitThrottlesExcessRequests() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = Data("throttle test".utf8)
        try media.write(to: directory.appendingPathComponent("strip.png"))

        let server = LocalWebServer(port: 0)
        await server.setGuestRouteExposure(.trustedLocalHTTP)
        await server.registerToken("token", sessionDirectory: directory)

        let gate = AsyncTestMultiGate(expectedPauseCount: 8)
        await server.setBeforeFileResponseForTesting { await gate.pause() }
        try await server.start()
        defer { Task { await gate.releaseAll(); await server.stop() } }
        let status = await server.waitUntilReady(timeout: 2)
        guard case .ready(let port) = status.state else {
            Issue.record("Server did not become ready: \(status)")
            return
        }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/s/token/strip.png"))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpMaximumConnectionsPerHost = 16
        sessionConfig.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: sessionConfig)

        var tasks: [Task<Int, Error>] = []
        for _ in 0..<8 {
            tasks.append(Task {
                let (_, response) = try await session.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            })
        }

        await gate.waitUntilAllPaused()

        let (_, overflowResponse) = try await session.data(from: url)
        let overflowStatus = (overflowResponse as? HTTPURLResponse)?.statusCode
        #expect(overflowStatus == 503)

        await gate.releaseAll()

        for task in tasks {
            let code = try await task.value
            #expect(code == 200)
        }
    }
}

private enum TestError: Error {
    case missingPort
}

private actor AsyncTestGate {
    private var paused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        pauseContinuation?.resume()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AsyncTestMultiGate {
    private let expectedPauseCount: Int
    private var pausedCount = 0
    private var allPausedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(expectedPauseCount: Int) {
        self.expectedPauseCount = expectedPauseCount
    }

    func pause() async {
        pausedCount += 1
        if pausedCount >= expectedPauseCount {
            allPausedContinuation?.resume()
            allPausedContinuation = nil
        }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func waitUntilAllPaused() async {
        guard pausedCount < expectedPauseCount else { return }
        await withCheckedContinuation { allPausedContinuation = $0 }
    }

    func releaseAll() {
        for cont in releaseContinuations {
            cont.resume()
        }
        releaseContinuations.removeAll()
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-WebServer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
