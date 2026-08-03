import Foundation
import SwiftData

@MainActor
final class DataStore {
    static let shared = DataStore()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    private init() {
        let schema = Schema([BoothEvent.self, BoothSlot.self, BoothSession.self, CapturedShot.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // Schema changed — wipe the SQLite files and start fresh
            let base = config.url.deletingPathExtension()
            for ext in ["store", "store-shm", "store-wal"] {
                try? FileManager.default.removeItem(at: base.appendingPathExtension(ext))
            }
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("SwiftData init failed after store reset: \(error)")
            }
        }
    }

    // MARK: - Events

    func createEvent(name: String, photoCount: Int = 3, countdownSeconds: Int = 5) -> BoothEvent {
        let event = BoothEvent(name: name, photoCount: photoCount, countdownSeconds: countdownSeconds)
        context.insert(event)
        try? context.save()
        return event
    }

    func fetchEvents() -> [BoothEvent] {
        let desc = FetchDescriptor<BoothEvent>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(desc)) ?? []
    }

    func fetchActiveEvent() -> BoothEvent? {
        var desc = FetchDescriptor<BoothEvent>(predicate: #Predicate { $0.isActive })
        desc.fetchLimit = 1
        return try? context.fetch(desc).first
    }

    func setActiveEvent(_ event: BoothEvent) {
        // Deactivate all, then activate this one
        let all = fetchEvents()
        all.forEach { $0.isActive = false }
        event.isActive = true
        try? context.save()
    }

    // MARK: - Sessions

    func startSession(for event: BoothEvent) -> BoothSession {
        let session = BoothSession(eventID: event.id, photoCount: event.photoCount)
        event.sessions.append(session)
        context.insert(session)
        try? context.save()
        return session
    }

    func finishSession(_ session: BoothSession, stripPath: String?, gifPath: String?) {
        finishSession(sessionID: session.id, stripPath: stripPath, gifPath: gifPath)
    }

    func fetchSession(id: String) -> BoothSession? {
        var descriptor = FetchDescriptor<BoothSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func deleteSession(_ session: BoothSession) {
        context.delete(session)
        try? context.save()
    }

    @discardableResult
    func upsertShot(
        session: BoothSession,
        photoIndex: Int,
        imagePath: String?,
        retakeCount: Int
    ) -> CapturedShot {
        let matches = session.shots.filter { $0.photoIndex == photoIndex }
        let shot = matches.first ?? CapturedShot(sessionID: session.id, photoIndex: photoIndex)
        if matches.isEmpty {
            session.shots.append(shot)
            context.insert(shot)
        } else {
            for duplicate in matches.dropFirst() {
                session.shots.removeAll { $0.id == duplicate.id }
                context.delete(duplicate)
            }
        }
        shot.imagePath = imagePath
        shot.retakeCount = max(0, retakeCount)
        try? context.save()
        return shot
    }

    @discardableResult
    func incrementRetakeCount(session: BoothSession, photoIndex: Int) -> CapturedShot {
        let current = session.shots.first(where: { $0.photoIndex == photoIndex })
        return upsertShot(
            session: session,
            photoIndex: photoIndex,
            imagePath: current?.imagePath,
            retakeCount: (current?.retakeCount ?? 0) + 1
        )
    }

    @discardableResult
    func recordShot(session: BoothSession, photoIndex: Int, imagePath: String?, retakeCount: Int) -> CapturedShot {
        upsertShot(session: session, photoIndex: photoIndex, imagePath: imagePath, retakeCount: retakeCount)
    }

    func updateSessionPaths(sessionID: String, stripPath: String?, gifPath: String?) {
        guard let session = fetchSession(id: sessionID) else { return }
        session.stripPath = stripPath ?? session.stripPath
        session.gifPath = gifPath ?? session.gifPath
        try? context.save()
    }

    func finishSession(sessionID: String, stripPath: String?, gifPath: String?) {
        guard let session = fetchSession(id: sessionID) else { return }
        session.finishedAt = Date()
        session.stripPath = stripPath
        session.gifPath = gifPath
        try? context.save()
    }

    func restoreSessionRecord(from manifest: SessionManifest) -> BoothSession {
        let session: BoothSession
        if let existing = fetchSession(id: manifest.id) {
            session = existing
        } else {
            session = BoothSession(eventID: manifest.eventID, photoCount: manifest.eventConfig.photoCount)
            context.insert(session)
            if let event = fetchEvents().first(where: { $0.id == manifest.eventID }) {
                session.event = event
                if !event.sessions.contains(where: { $0.id == session.id }) { event.sessions.append(session) }
            }
        }

        session.id = manifest.id
        session.eventID = manifest.eventID
        session.startedAt = manifest.startedAt
        session.photoCount = manifest.eventConfig.photoCount
        session.downloadToken = manifest.downloadToken
        for shot in manifest.shots {
            _ = upsertShot(
                session: session,
                photoIndex: shot.photoIndex,
                imagePath: shot.imageFileName,
                retakeCount: shot.retakeCount
            )
        }
        try? context.save()
        return session
    }

    func fetchSessions(finishedBefore date: Date) -> [BoothSession] {
        let pred = #Predicate<BoothSession> { s in s.finishedAt != nil && s.finishedAt! < date }
        return (try? context.fetch(FetchDescriptor<BoothSession>(predicate: pred))) ?? []
    }

}
