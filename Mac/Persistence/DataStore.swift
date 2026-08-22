import Foundation
import SwiftData

@MainActor
final class DataStore {
    static let shared = DataStore()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    private(set) var lastPersistenceError: String?
    private(set) var persistentStorageAvailable = true

    private init() {
        let schema = Schema([BoothEvent.self, BoothSlot.self, BoothSession.self, CapturedShot.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // Schema changed — preserve the old store before starting fresh.
            let base = config.url.deletingPathExtension()
            let backup = base.deletingLastPathComponent()
                .appendingPathComponent("SwiftData-corrupt-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            } catch {
                NSLog("[Persistence] Could not create corruption backup directory: %@", error.localizedDescription)
            }
            for ext in ["store", "store-shm", "store-wal"] {
                let source = base.appendingPathExtension(ext)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                do {
                    try FileManager.default.moveItem(at: source, to: backup.appendingPathComponent(source.lastPathComponent))
                } catch {
                    NSLog("[Persistence] Could not preserve %@: %@", source.path, error.localizedDescription)
                }
            }
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                let persistenceError = error.localizedDescription
                persistentStorageAvailable = false
                lastPersistenceError = "Persistent SwiftData storage is unavailable: \(persistenceError)"
                NSLog("[Persistence] Falling back to in-memory SwiftData: %@", persistenceError)
                let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                do {
                    container = try ModelContainer(for: schema, configurations: memoryConfig)
                } catch {
                    fatalError("SwiftData in-memory fallback failed: \(error)")
                }
            }
        }
    }

    // MARK: - Events

    func createEvent(name: String, photoCount: Int = 3, countdownSeconds: Int = 5) -> BoothEvent {
        let event = BoothEvent(name: name, photoCount: photoCount, countdownSeconds: countdownSeconds)
        context.insert(event)
        save()
        return event
    }

    func fetchEvents() -> [BoothEvent] {
        let desc = FetchDescriptor<BoothEvent>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        do { return try context.fetch(desc) }
        catch { record(error); return [] }
    }

    func fetchActiveEvent() -> BoothEvent? {
        var desc = FetchDescriptor<BoothEvent>(predicate: #Predicate { $0.isActive })
        desc.fetchLimit = 1
        do { return try context.fetch(desc).first }
        catch { record(error); return nil }
    }

    @discardableResult
    func setActiveEvent(_ event: BoothEvent?) -> Bool {
        let all = fetchEvents()
        if let event, !all.contains(where: { $0.id == event.id }) { return false }
        let previousStates = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.isActive) })
        let activeIDs = EventSelectionLogic.activeIDs(
            eventIDs: all.map(\.id),
            selectedID: event?.id
        )
        all.forEach { $0.isActive = activeIDs.contains($0.id) }
        guard saveChanges() else {
            all.forEach { $0.isActive = previousStates[$0.id] ?? false }
            return false
        }
        return true
    }

    // MARK: - Sessions

    func startSession(for event: BoothEvent) -> BoothSession {
        let session = BoothSession(eventID: event.id, photoCount: event.photoCount)
        event.sessions.append(session)
        context.insert(session)
        save()
        return session
    }

    func finishSession(_ session: BoothSession, stripPath: String?, gifPath: String?) {
        finishSession(sessionID: session.id, stripPath: stripPath, gifPath: gifPath)
    }

    func fetchSession(id: String) -> BoothSession? {
        var descriptor = FetchDescriptor<BoothSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do { return try context.fetch(descriptor).first }
        catch { record(error); return nil }
    }

    func deleteSession(_ session: BoothSession) {
        context.delete(session)
        save()
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
        save()
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
        save()
    }

    func finishSession(sessionID: String, stripPath: String?, gifPath: String?) {
        guard let session = fetchSession(id: sessionID) else { return }
        session.finishedAt = Date()
        session.stripPath = stripPath
        session.gifPath = gifPath
        save()
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
        save()
        return session
    }

    func fetchSessions(finishedBefore date: Date) -> [BoothSession] {
        let pred = #Predicate<BoothSession> { s in s.finishedAt != nil && s.finishedAt! < date }
        do { return try context.fetch(FetchDescriptor<BoothSession>(predicate: pred)) }
        catch { record(error); return [] }
    }

    private func save() {
        _ = saveChanges()
    }

    @discardableResult
    func saveChanges() -> Bool {
        do {
            try context.save()
            if persistentStorageAvailable {
                lastPersistenceError = nil
            }
            return true
        } catch {
            record(error)
            return false
        }
    }

    private func record(_ error: Error) {
        lastPersistenceError = error.localizedDescription
        NSLog("[Persistence] SwiftData operation failed: %@", error.localizedDescription)
    }

}
