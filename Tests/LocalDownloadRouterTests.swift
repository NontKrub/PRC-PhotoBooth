import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("LocalDownloadRouter")
struct LocalDownloadRouterTests {
    @Test("serves health, HTML, and strip routes")
    func servesKnownRoutes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let strip = directory.appendingPathComponent("strip.png")
        try Data([1, 2, 3]).write(to: strip)

        let router = LocalDownloadRouter(tokenMap: ["token": directory])
        let health = router.response(for: "/health")
        let page = router.response(for: "/s/token/")
        let image = router.response(for: "/s/token/strip.png")

        #expect(health.statusCode == 200)
        #expect(health.contentType == "application/json")
        #expect(String(decoding: health.body, as: UTF8.self).contains("\"registeredTokens\":1"))
        #expect(page.statusCode == 200)
        #expect(page.headers["Cache-Control"] == "no-store")
        #expect(image.statusCode == 200)
        #expect(image.contentType == "image/png")
        #expect(image.body == Data([1, 2, 3]))
    }

    @Test("shows GIF only when file exists and returns 404 for unknown files")
    func handlesOptionalGIF() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = LocalDownloadRouter(tokenMap: ["token": directory])

        let withoutGIF = router.response(for: "/s/token/")
        #expect(!String(decoding: withoutGIF.body, as: UTF8.self).contains("booth.gif"))
        #expect(router.response(for: "/s/token/booth.gif").statusCode == 404)

        try Data([4, 5]).write(to: directory.appendingPathComponent("booth.gif"))
        let withGIF = router.response(for: "/s/token/")
        #expect(String(decoding: withGIF.body, as: UTF8.self).contains("booth.gif"))
        #expect(router.response(for: "/s/token/booth.gif").statusCode == 200)
    }

    @Test("rejects traversal and unknown tokens")
    func rejectsUnsafePaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("strip.png"))
        let router = LocalDownloadRouter(tokenMap: ["token": directory])

        for path in [
            "/s/token/../strip.png",
            "/s/token/%2e%2e/strip.png",
            "/s/token/%2E%2E%2Fstrip.png",
            "/s/token/index.html"
        ] {
            #expect(router.response(for: path).statusCode == 404)
        }
        #expect(router.response(for: "/s/missing/strip.png").statusCode == 404)
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-Router-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
