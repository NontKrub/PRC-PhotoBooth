import Foundation

enum OperationsEventKind: String, Codable, Sendable, CaseIterable {
    case routeDiscoveryStarted
    case routeDiscoveryRestarted, routeDiscoveryReused, routeCandidateDiscovered
    case routeDiscoveryResult, targetSelected, targetMatched, routeSelected
    case browserReady, browserFailed, browserCancelled
    case controlConnectionCreated, controlConnectionPreparing, controlHelloReceived
    case helloSent, authenticated
    case pairingIntentSent, pairingSessionReceived, pairingRequestSent, pairingResultReceived
    case pairingRequestSubmitted
    case sessionStarted, sessionCompleted, sessionCancelled
    case captureStarted, captureSucceeded, captureFailed, captureRecovered
    case captureDeferred, captureRetried, previousPhotoUsed
    case cameraConnected, cameraDisconnected, cameraReconnected
    case ipadConnected, ipadDisconnected, ipadReconnected
    case printSucceeded, printFailed
    case cloudUploadSucceeded, cloudUploadFailed, jobRetried
    case transportDiscoveryStarted, transportConnecting, transportReady
    case transportWaiting, transportDisconnected, transportReconnectScheduled
    case transportReconnectSucceeded, heartbeatTimedOut, routeChanged
    case controlSendFailed, controlPayloadRejected
    case previewDisconnected, previewReconnected, sessionSyncSent, sessionSyncFailed
    case criticalSendQueued, criticalSendCompleted
    case assetSent, assetRejected, assetChannelConnected, assetChannelVerified, assetChannelDisconnected
    case secureChannelEstablished, secureChannelFailed
    case previewReady, assetReady
    case routeViabilityChanged, pathHintUnavailableIgnored, secondaryCandidateRejected
    case waitingRecoveryScheduled, waitingRecoveryCancelled
    case ipadAppForegrounded, ipadAppBackgrounded
}

struct OperationsEvent: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: OperationsEventKind
    var timestamp: Date
    var sessionID: String?
    var photoIndex: Int?
    var duration: Double?
    var reason: String?
    var channel: String?
    var route: String?
    var attempt: Int?
    var byteCount: Int?
    var targetPeerID: String?
    var routeGeneration: Int?
    var networkPreference: BoothNetworkPreference?
    var candidateSource: String?
}

actor OperationsEventStore {
    private let fileURL: URL
    private var events: [OperationsEvent] = []
    private var loaded = false
    private(set) var lastError: String?
    private let retention: TimeInterval = 30 * 24 * 60 * 60

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(
        _ kind: OperationsEventKind,
        sessionID: String? = nil,
        photoIndex: Int? = nil,
        duration: Double? = nil,
        reason: String? = nil,
        channel: String? = nil,
        route: String? = nil,
        attempt: Int? = nil,
        byteCount: Int? = nil,
        targetPeerID: String? = nil,
        routeGeneration: Int? = nil,
        networkPreference: BoothNetworkPreference? = nil,
        candidateSource: String? = nil
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
            reason: OperationsEventRedactor.text(reason),
            channel: OperationsEventRedactor.text(channel),
            route: OperationsEventRedactor.text(route),
            attempt: attempt,
            byteCount: byteCount,
            targetPeerID: OperationsEventRedactor.text(targetPeerID),
            routeGeneration: routeGeneration,
            networkPreference: networkPreference,
            candidateSource: OperationsEventRedactor.text(candidateSource)
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
        do { return try encoder.encode(load(since: since)) }
        catch {
            recordError(error)
            return Data("[]".utf8)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch where (error as NSError).code == NSFileReadNoSuchFileError { return }
        catch { recordError(error); return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { events = try decoder.decode([OperationsEvent].self, from: data) }
        catch { recordError(error); events = [] }
        trim(now: Date())
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        events = Array(events.filter { $0.timestamp >= cutoff }.suffix(5_000))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(events)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            lastError = nil
        } catch { recordError(error) }
    }

    private func recordError(_ error: Error) {
        lastError = error.localizedDescription
        NSLog("[Operations] Event storage failed: %@", error.localizedDescription)
    }
}

enum OperationsEventRedactor {
    private static let sensitiveWords = [
        "token", "password", "secret", "private key", "credential",
        "authorization", "bearer", "pin", "keychain", "access_token",
        "pairing-v2:"
    ]

    static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let normalized = value.lowercased()
        guard !sensitiveWords.contains(where: normalized.contains) else { return "[redacted]" }
        return value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
