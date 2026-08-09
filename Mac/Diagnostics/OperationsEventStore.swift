import Foundation

enum OperationsEventKind: String, Codable, Sendable, CaseIterable {
    case sessionStarted, sessionCompleted, sessionCancelled
    case captureStarted, captureSucceeded, captureFailed, captureRecovered
    case captureDeferred, captureRetried, previousPhotoUsed
    case cameraConnected, cameraDisconnected, cameraReconnected
    case ipadConnected, ipadDisconnected, ipadReconnected
    case printSucceeded, printFailed
    case cloudUploadSucceeded, cloudUploadFailed, jobRetried
}

struct OperationsEvent: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: OperationsEventKind
    var timestamp: Date
    var sessionID: String?
    var photoIndex: Int?
    var duration: Double?
    var reason: String?
}

actor OperationsEventStore {
    private let fileURL: URL
    private var events: [OperationsEvent] = []
    private var loaded = false
    private let retention: TimeInterval = 30 * 24 * 60 * 60

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(
        _ kind: OperationsEventKind,
        sessionID: String? = nil,
        photoIndex: Int? = nil,
        duration: Double? = nil,
        reason: String? = nil
    ) {
        loadIfNeeded()
        let now = Date()
        events.append(OperationsEvent(
            id: UUID().uuidString,
            kind: kind,
            timestamp: now,
            sessionID: sessionID,
            photoIndex: photoIndex,
            duration: duration,
            reason: reason
        ))
        trim(now: now)
        save()
    }

    func load(since: Date? = nil) -> [OperationsEvent] {
        loadIfNeeded()
        trim(now: Date())
        return since.map { cutoff in events.filter { $0.timestamp >= cutoff } } ?? events
    }

    func jsonData(since: Date? = nil) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(load(since: since))) ?? Data("[]".utf8)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = (try? decoder.decode([OperationsEvent].self, from: data)) ?? []
        trim(now: Date())
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        events = Array(events.filter { $0.timestamp >= cutoff }.suffix(10_000))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
