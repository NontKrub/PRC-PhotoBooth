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
        session.finishedAt = Date()
        session.stripPath = stripPath
        session.gifPath = gifPath
        try? context.save()
    }

    func recordShot(session: BoothSession, photoIndex: Int, imagePath: String?, retakeCount: Int) -> CapturedShot {
        let shot = CapturedShot(sessionID: session.id, photoIndex: photoIndex)
        shot.imagePath = imagePath
        shot.retakeCount = retakeCount
        session.shots.append(shot)
        try? context.save()
        return shot
    }

    func fetchSessions(finishedBefore date: Date) -> [BoothSession] {
        let pred = #Predicate<BoothSession> { s in s.finishedAt != nil && s.finishedAt! < date }
        return (try? context.fetch(FetchDescriptor<BoothSession>(predicate: pred))) ?? []
    }

}
