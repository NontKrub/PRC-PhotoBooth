import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Cloud public image verification", .serialized)
struct CloudPublicURLVerifierTests {
    @Test("valid PNG is accepted with bounded dimensions and inspected bytes")
    func acceptsPNG() async throws {
        let url = URL(string: "https://photos.example/strip.png")!
        let png = try makeVerifierPNG()
        StubCloudURLProtocol.registry.install([
            url.path: StubCloudResponse(status: 200, mimeType: "image/png", body: png)
        ])
        let session = makeVerifierSession()
        defer { session.invalidateAndCancel() }

        let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
            url: url,
            expectedSHA256: Data(SHA256.hash(data: png)),
            expectedByteCount: png.count,
            timeout: 3
        )

        #expect(result.statusCode == 200)
        #expect(result.verifiedImage)
        #expect(result.imageWidth == 7)
        #expect(result.imageHeight == 5)
        #expect(result.finalURL == url)
        #expect(result.bytesInspected <= URLSessionCloudPublicURLVerifier.maximumInspectionBytes)
    }

    @Test("same-size valid image with the wrong digest is rejected")
    func rejectsDifferentImageAtSameSize() async throws {
        let url = URL(string: "https://photos.example/strip.png")!
        let expected = try makeVerifierPNG()
        let actual = try makeVerifierPNG(fill: CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1))
        #expect(expected.count == actual.count)
        StubCloudURLProtocol.registry.install([
            url.path: StubCloudResponse(status: 200, mimeType: "image/png", body: actual)
        ])
        let session = makeVerifierSession()
        defer { session.invalidateAndCancel() }

        let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
            url: url,
            expectedSHA256: Data(SHA256.hash(data: expected)),
            expectedByteCount: expected.count,
            timeout: 3
        )

        #expect(result.imageWidth == 7)
        #expect(result.imageHeight == 5)
        #expect(!result.verifiedImage)
        #expect(result.bytesInspected == expected.count)
    }

    @Test("truncated recognizable image does not satisfy full-file verification")
    func rejectsTruncatedImage() async throws {
        let url = URL(string: "https://photos.example/truncated.png")!
        let expected = try makeVerifierPNG()
        let truncated = Data(expected.prefix(expected.count / 2))
        StubCloudURLProtocol.registry.install([
            url.path: StubCloudResponse(status: 200, mimeType: "image/png", body: truncated)
        ])
        let session = makeVerifierSession()
        defer { session.invalidateAndCancel() }

        let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
            url: url,
            expectedSHA256: Data(SHA256.hash(data: expected)),
            expectedByteCount: expected.count,
            timeout: 3
        )

        #expect(!result.verifiedImage)
        #expect(result.bytesInspected == truncated.count)
    }

    @Test("incorrect content length and encoded response are rejected before reading")
    func rejectsIncorrectLengthAndEncoding() async throws {
        let png = try makeVerifierPNG()
        for (path, response) in [
            ("wrong-length", StubCloudResponse(
                status: 200,
                mimeType: "image/png",
                body: png,
                contentLength: String(png.count + 1)
            )),
            ("compressed", StubCloudResponse(
                status: 200,
                mimeType: "image/png",
                body: png,
                contentEncoding: "gzip"
            ))
        ] {
            let url = URL(string: "https://photos.example/\(path)")!
            StubCloudURLProtocol.registry.install([url.path: response])
            let session = makeVerifierSession()
            defer { session.invalidateAndCancel() }

            let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
                url: url,
                expectedSHA256: Data(SHA256.hash(data: png)),
                expectedByteCount: png.count,
                timeout: 3
            )

            #expect(!result.verifiedImage)
            #expect(result.bytesInspected == 0)
            // URLProtocol may synchronously hand bytes to URLSession before
            // bytes(for:) returns its response; bytesInspected measures what
            // the verifier itself accepted into its bounded hash/parser.
        }
    }

    @Test("HTML login and HTML sent with an image MIME type are rejected")
    func rejectsHTML() async throws {
        for mimeType in ["text/html", "image/png"] {
            let url = URL(string: "https://photos.example/\(mimeType == "text/html" ? "login" : "fake.png")")!
            StubCloudURLProtocol.registry.install([
                url.path: StubCloudResponse(
                    status: 200,
                    mimeType: mimeType,
                    body: Data("<html><body>login required</body></html>".utf8)
                )
            ])
            let session = makeVerifierSession()
            defer { session.invalidateAndCancel() }

            let body = Data("<html><body>login required</body></html>".utf8)
            let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
                url: url,
                expectedSHA256: Data(SHA256.hash(data: body)),
                expectedByteCount: body.count,
                timeout: 3
            )

            #expect(!result.verifiedImage)
        }
    }

    @Test("redirect is rejected before following a login page")
    func rejectsRedirect() async throws {
        let url = URL(string: "https://photos.example/strip.png")!
        let loginURL = URL(string: "https://photos.example/login")!
        StubCloudURLProtocol.registry.install([
            url.path: StubCloudResponse(status: 302, mimeType: "text/html", redirectPath: loginURL.path),
            loginURL.path: StubCloudResponse(
                status: 200,
                mimeType: "text/html",
                body: Data("<html>sign in</html>".utf8)
            )
        ])
        let session = makeVerifierSession()
        defer { session.invalidateAndCancel() }

        let body = Data("<html>sign in</html>".utf8)
        let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
            url: url,
            expectedSHA256: Data(SHA256.hash(data: body)),
            expectedByteCount: body.count,
            timeout: 3
        )

        #expect(result.statusCode == 302)
        #expect(result.finalURL == url)
        #expect(!result.verifiedImage)
        #expect(StubCloudURLProtocol.registry.bytesDelivered(path: loginURL.path) == 0)
    }

    @Test("redirect delegate declines every redirect request")
    func redirectDelegateRejectsRedirect() {
        let url = URL(string: "https://photos.example/strip.png")!
        let loginURL = URL(string: "https://photos.example/login")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": loginURL.absoluteString]
        )!
        var followedRequest: URLRequest?
        let delegate = RejectCloudVerificationRedirects()
        delegate.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: url),
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: loginURL),
            completionHandler: { followedRequest = $0 }
        )

        #expect(followedRequest == nil)
    }

    @Test("empty and error responses are rejected before image inspection")
    func rejectsEmptyAndErrorResponses() async throws {
        let cases: [(String, Int, Data)] = [
            ("empty", 200, Data()),
            ("missing", 404, Data("missing".utf8)),
            ("server-error", 500, Data("unavailable".utf8))
        ]
        for (path, status, body) in cases {
            let url = URL(string: "https://photos.example/\(path)")!
            StubCloudURLProtocol.registry.install([
                url.path: StubCloudResponse(status: status, mimeType: "image/png", body: body)
            ])
            let session = makeVerifierSession()
            defer { session.invalidateAndCancel() }

            let expected = body.isEmpty ? Data([0]) : body
            let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
                url: url,
                expectedSHA256: Data(SHA256.hash(data: expected)),
                expectedByteCount: expected.count,
                timeout: 3
            )

            #expect(!result.verifiedImage)
            #expect(result.bytesInspected == 0)
        }
    }

    @Test("inspection cap cancels a continuing chunked response")
    func capsAndCancelsOversizedResponse() async throws {
        let url = URL(string: "https://photos.example/large.png")!
        StubCloudURLProtocol.registry.install([
            url.path: StubCloudResponse(
                status: 200,
                mimeType: "image/png",
                body: Data(repeating: 0x41, count: 4 * 1024),
                repeatsBody: true
            )
        ])
        let session = makeVerifierSession()
        defer { session.invalidateAndCancel() }

        let expected = Data(repeating: 0x42, count: 1)
        let result = try await URLSessionCloudPublicURLVerifier(session: session).verify(
            url: url,
            expectedSHA256: Data(SHA256.hash(data: expected)),
            expectedByteCount: URLSessionCloudPublicURLVerifier.maximumInspectionBytes + 4 * 1024,
            timeout: 5
        )
        try await waitForStubCancellation(path: url.path)

        #expect(!result.verifiedImage)
        #expect(result.bytesInspected <= URLSessionCloudPublicURLVerifier.maximumInspectionBytes)
        #expect(StubCloudURLProtocol.registry.wasCancelled(path: url.path))
        #expect(StubCloudURLProtocol.registry.bytesDelivered(path: url.path) < 1024 * 1024)
    }

    @Test("task cancellation propagates while verification is reading")
    func propagatesCancellation() async throws {
        let url = URL(string: "https://photos.example/slow.png")!
        StubCloudURLProtocol.registry.install([
            url.path: StubCloudResponse(
                status: 200,
                mimeType: "image/png",
                body: Data(repeating: 0x41, count: 4 * 1024),
                repeatsBody: true
            )
        ])
        let session = makeVerifierSession()
        defer { session.invalidateAndCancel() }
        let verifier = URLSessionCloudPublicURLVerifier(session: session)
        let task = Task {
            try await verifier.verify(
                url: url,
                expectedSHA256: Data(repeating: 0x51, count: 32),
                expectedByteCount: URLSessionCloudPublicURLVerifier.maximumInspectionBytes * 4,
                timeout: 5
            )
        }
        try await waitForStubBytes(path: url.path)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected verification cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await waitForStubCancellation(path: url.path)
        #expect(StubCloudURLProtocol.registry.wasCancelled(path: url.path))
    }
}

private struct StubCloudResponse: Sendable {
    var status: Int
    var mimeType: String
    var body = Data()
    var redirectPath: String?
    var repeatsBody = false
    var contentLength: String?
    var contentEncoding: String?
}

private final class StubCloudURLProtocol: URLProtocol, @unchecked Sendable {
    fileprivate static let registry = StubCloudResponseRegistry()
    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fixture = Self.registry.response(path: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        var headers = ["Content-Type": fixture.mimeType]
        headers["Content-Length"] = fixture.contentLength
        headers["Content-Encoding"] = fixture.contentEncoding
        if let redirectPath = fixture.redirectPath {
            headers["Location"] = URL(string: redirectPath, relativeTo: url)?.absoluteURL.absoluteString
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture.redirectPath != nil {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        deliver(fixture, offset: 0)
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        if let path = request.url?.path { Self.registry.markCancelled(path: path) }
    }

    private func deliver(_ fixture: StubCloudResponse, offset: Int) {
        guard !isStopped else { return }
        guard !fixture.body.isEmpty else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let end = min(offset + 4 * 1024, fixture.body.count)
        let chunk = fixture.body.subdata(in: offset..<end)
        client?.urlProtocol(self, didLoad: chunk)
        if let path = request.url?.path { Self.registry.recordBytes(chunk.count, path: path) }
        if end == fixture.body.count {
            if fixture.repeatsBody {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                    self?.deliver(fixture, offset: 0)
                }
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                self?.deliver(fixture, offset: end)
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }
}

fileprivate final class StubCloudResponseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: StubCloudResponse] = [:]
    private var delivered: [String: Int] = [:]
    private var cancelled = Set<String>()

    func install(_ values: [String: StubCloudResponse]) {
        lock.lock()
        responses = values
        delivered = [:]
        cancelled = []
        lock.unlock()
    }

    func response(path: String) -> StubCloudResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[path]
    }

    func recordBytes(_ count: Int, path: String) {
        lock.lock()
        delivered[path, default: 0] += count
        lock.unlock()
    }

    func bytesDelivered(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered[path, default: 0]
    }

    func markCancelled(path: String) {
        lock.lock()
        cancelled.insert(path)
        lock.unlock()
    }

    func wasCancelled(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(path)
    }
}

private func makeVerifierSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubCloudURLProtocol.self]
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 10
    return URLSession(configuration: configuration)
}

private func makeVerifierPNG() throws -> Data {
    try makeVerifierPNG(fill: CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
}

private func makeVerifierPNG(fill: CGColor) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: 7,
        height: 5,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(fill)
    context.fill(CGRect(x: 0, y: 0, width: 7, height: 5))
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

private func waitForStubBytes(path: String) async throws {
    for _ in 0..<100 {
        if StubCloudURLProtocol.registry.bytesDelivered(path: path) > 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw URLError(.timedOut)
}

private func waitForStubCancellation(path: String) async throws {
    for _ in 0..<100 {
        if StubCloudURLProtocol.registry.wasCancelled(path: path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw URLError(.timedOut)
}
