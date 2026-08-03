import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Gallery router")
struct GalleryRouterTests {
    @Test("approved gallery routes render Thai and hide unapproved entries")
    func routes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumb = root.appendingPathComponent("gallery-thumb.jpg")
        try Data([1, 2, 3]).write(to: thumb)
        let route = EventGalleryRouteRegistration(
            eventID: "event-1",
            eventToken: "event-token",
            title: "งานของเรา <3",
            language: .thai,
            showGIFLinks: true,
            approvedSessions: [
                GalleryRouteSession(
                    sessionID: "session-1",
                    downloadToken: "download-1",
                    startedAt: Date(),
                    thumbnailURL: thumb,
                    gifAvailable: false,
                    templateName: "คลาสสิก",
                    filterID: .warm
                )
            ]
        )
        let router = LocalDownloadRouter(
            sessionRoutes: [
                "download-1": SessionRouteRegistration(
                    sessionDirectory: root,
                    language: .thai,
                    eventGalleryPath: "/e/event-token/"
                )
            ],
            galleryRoutes: ["event-token": route]
        )
        let page = router.response(for: "/e/event-token/")
        #expect(page.statusCode == 200)
        #expect(page.headers["Cache-Control"] == "no-store")
        #expect(String(decoding: page.body, as: UTF8.self).contains("งานของเรา &lt;3"))
        #expect(router.response(for: "/e/event-token/thumb/session-1.jpg").statusCode == 200)
        #expect(router.response(for: "/e/event-token/thumb/pending.jpg").statusCode == 404)
        #expect(router.response(for: "/e/missing/").statusCode == 404)
        #expect(router.response(for: "/e/event-token/thumb/%2e%2e%2fsecret.jpg").statusCode == 404)
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-GalleryRouter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
