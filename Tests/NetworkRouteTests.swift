import Foundation
import Network
import CryptoKit
import Testing

@testable import PRC_PhotoBooth_Mac

private final class RecoveryTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false

    func mark() {
        lock.lock()
        didFire = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFire
    }
}

/// Records the order observed by the MainActor consumer without relying on
/// MainActor progress to synchronize the transport queue with the test.
private final class CoreEventDeliveryObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let eventReceived = DispatchSemaphore(value: 0)
    private var value: [String] = []

    func receive(_ event: BoothNetworkTransportRuntime.ControlCoreEvent) {
        let kind: String
        switch event {
        case .trustedAuthenticated:
            kind = "authenticated"
        case .controlFrames:
            kind = "controlFrames"
        case .directControlFrames:
            kind = "controlFrames"
        default:
            return
        }
        lock.lock()
        value.append(kind)
        lock.unlock()
        eventReceived.signal()
    }

    private func waitForCountBlocking(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while self.count < count {
            guard eventReceived.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    func waitForCount(_ count: Int, timeout: TimeInterval) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForCountBlocking(count, timeout: timeout)
        }.value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value.count
    }

    var order: [String] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ControlCoreOverflowTestObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let listenerReady = DispatchSemaphore(value: 0)
    private let overflowReady = DispatchSemaphore(value: 0)
    private var port: NWEndpoint.Port?
    private var overflowedGeneration: Int?

    func receiveListener(_ value: NWEndpoint.Port?) {
        lock.lock()
        port = value
        lock.unlock()
        listenerReady.signal()
    }

    func waitForListener(timeout: TimeInterval = 3) -> NWEndpoint.Port? {
        guard listenerReady.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    func recordOverflow(generation: Int) {
        lock.lock()
        overflowedGeneration = generation
        lock.unlock()
        overflowReady.signal()
    }

    func waitForOverflow(timeout: TimeInterval = 5) -> Int? {
        guard overflowReady.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return overflowedGeneration
    }
}

/// The test waiter and Network.framework callback share `serviceNames`; the
/// condition guards every access. Browser callbacks stay on the supplied queue.
private final class BonjourRouteObserver: @unchecked Sendable {
    private let changed = NSCondition()
    private let browser: NWBrowser
    private let targetDeviceID: String
    private var serviceNames = Set<String>()

    init(targetDeviceID: String, queue: DispatchQueue) {
        self.targetDeviceID = targetDeviceID
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_prc-control._tcp", domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.record(results)
        }
        browser.start(queue: queue)
    }

    func waitForRoutes(
        containing requiredName: String,
        excluding excludedName: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        changed.lock()
        defer { changed.unlock() }
        while !serviceNames.contains(requiredName) || serviceNames.contains(excludedName) {
            guard changed.wait(until: deadline) else { return false }
        }
        return true
    }

    func cancel() {
        browser.cancel()
    }

    private func record(_ results: Set<NWBrowser.Result>) {
        let names = Set(results.compactMap { result -> String? in
            guard case let .service(name, _, _, _) = result.endpoint,
                  BoothBonjourServiceIdentity.parse(name)?.deviceID == targetDeviceID,
                  case let .bonjour(record) = result.metadata,
                  record["deviceID"] == targetDeviceID else {
                return nil
            }
            return name
        })
        changed.lock()
        serviceNames = names
        changed.broadcast()
        changed.unlock()
    }
}

private enum ControlStressError: Error {
    case connectionCancelled
    case connectionClosed
    case unexpectedFrame
    case unexpectedMessage(Int)
    case sendFailed(sessionID: String, messageIndex: Int, outcome: BoothControlSendOutcome)
    case connectionNotReady(sessionID: String, detail: String?)
    case listenerHasNoPort
    case timedOut
}

private let runMainActorStallTests =
    ProcessInfo.processInfo.environment["PRC_RUN_MAINACTOR_STALL_TESTS"] == "1"
// Hosted runners may not permit local Bonjour publication and browsing.
private let runBonjourRouteRefreshIntegration =
    ProcessInfo.processInfo.environment["PRC_RUN_BONJOUR_ROUTE_REFRESH_TESTS"] == "1"

private final class ControlStressSendWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoothControlSendOutcome, Never>?
    private var timeout: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<BoothControlSendOutcome, Never>) {
        self.continuation = continuation
    }

    func scheduleTimeout(on queue: DispatchQueue) {
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.networkSendFailed)
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        self.timeout = timeout
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .seconds(10), execute: timeout)
    }

    func finish(_ outcome: BoothControlSendOutcome) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeout = self.timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        continuation.resume(returning: outcome)
    }
}

private final class ControlStressConnectionLifetime: @unchecked Sendable {
    private enum ReadinessState: Equatable {
        case ready
        case failed(String)
    }

    private let lock = NSLock()
    private let readinessSemaphore = DispatchSemaphore(value: 0)
    private var isClosed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var readinessState: ReadinessState?
    private var lastWaitingError: String?

    func didBecomeReady() {
        resolveReadiness(.ready)
    }

    func didFail(_ error: Error) {
        resolveReadiness(.failed(error.localizedDescription))
    }

    func didWait(_ error: Error) {
        lock.lock()
        if readinessState == nil { lastWaitingError = error.localizedDescription }
        lock.unlock()
    }

    func waitUntilReady(sessionID: String, timeout: TimeInterval = 10) throws {
        guard readinessSemaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock()
            let detail = lastWaitingError
            lock.unlock()
            throw ControlStressError.connectionNotReady(sessionID: sessionID, detail: detail)
        }
        lock.lock()
        let state = readinessState
        lock.unlock()
        switch state {
        case .ready:
            return
        case .failed(let detail):
            throw ControlStressError.connectionNotReady(sessionID: sessionID, detail: detail)
        case nil:
            throw ControlStressError.connectionNotReady(sessionID: sessionID, detail: nil)
        }
    }

    private func resolveReadiness(_ state: ReadinessState) {
        lock.lock()
        guard readinessState == nil else {
            lock.unlock()
            return
        }
        readinessState = state
        lock.unlock()
        readinessSemaphore.signal()
    }

    func didClose() {
        resolveReadiness(.failed(ControlStressError.connectionCancelled.localizedDescription))
        lock.lock()
        isClosed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func cancel(_ connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
            connection.cancel()
        }
    }

    func cancelIfNeeded(_ connection: NWConnection) {
        lock.lock()
        let shouldCancel = !isClosed
        lock.unlock()
        if shouldCancel { connection.cancel() }
    }
}

private final class ControlStressReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ControlStressReceiver")
    private let expected: [Message]
    private let secureChannel: BoothSecureChannel
    private var decoder = BoothTransportFrameDecoder()
    private var connection: NWConnection?
    private var nextMessageIndex = 0
    private var finalResult: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var waitTimeout: DispatchWorkItem?
    private var isConnectionClosed = false
    private var closeContinuation: CheckedContinuation<Void, Never>?

    init(expected: [Message], secureChannel: BoothSecureChannel) {
        self.expected = expected
        self.secureChannel = secureChannel
    }

    func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connection == nil else {
                connection.cancel()
                return
            }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receive()
                case .failed(let error):
                    self.finish(.failure(error))
                case .cancelled:
                    self.isConnectionClosed = true
                    self.closeContinuation?.resume()
                    self.closeContinuation = nil
                    if self.finalResult == nil {
                        self.finish(.failure(ControlStressError.connectionCancelled))
                    }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { return }
                if let finalResult = self.finalResult {
                    Self.resume(continuation, with: finalResult)
                } else {
                    self.continuation = continuation
                    let timeout = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(ControlStressError.timedOut))
                    }
                    self.waitTimeout = timeout
                    self.queue.asyncAfter(deadline: .now() + .seconds(10), execute: timeout)
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.connection?.cancel()
        }
    }

    func cancelAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.isConnectionClosed else {
                    continuation.resume()
                    return
                }
                self.closeContinuation = continuation
                self.connection?.cancel()
            }
        }
    }

    private func receive() {
        guard let connection, finalResult == nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }

            do {
                if let data {
                    let frames = try self.decoder.decode(data, channel: .control, secureChannel: self.secureChannel)
                    for frame in frames {
                        guard case .control(let message) = frame else {
                            throw ControlStressError.unexpectedFrame
                        }
                        guard self.nextMessageIndex < self.expected.count,
                              message == self.expected[self.nextMessageIndex] else {
                            throw ControlStressError.unexpectedMessage(self.nextMessageIndex)
                        }
                        self.nextMessageIndex += 1
                    }
                }
                guard self.nextMessageIndex < self.expected.count else {
                    self.finish(.success(()))
                    return
                }
                guard !isComplete else {
                    throw ControlStressError.connectionClosed
                }
                self.receive()
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard finalResult == nil else { return }
        finalResult = result
        waitTimeout?.cancel()
        waitTimeout = nil
        if let continuation {
            self.continuation = nil
            Self.resume(continuation, with: result)
        }
        connection?.cancel()
    }

    private static func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) {
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class ControlStressServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ControlStressServer")
    private let listener: NWListener
    private let receiver: ControlStressReceiver
    private var readyContinuation: CheckedContinuation<NWEndpoint.Port, Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var isStopped = false
    private var stopRequested = false

    init(expected: [Message], secureChannel: BoothSecureChannel) throws {
        listener = try NWListener(using: .tcp)
        receiver = ControlStressReceiver(expected: expected, secureChannel: secureChannel)
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            queue.async { [weak self] in
                guard let self else { return }
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else {
                            self.resolveReady(.failure(ControlStressError.listenerHasNoPort))
                            return
                        }
                        self.resolveReady(.success(port))
                    case .failed(let error):
                        self.resolveReady(.failure(error))
                    case .cancelled:
                        self.isStopped = true
                        self.stopContinuation?.resume()
                        self.stopContinuation = nil
                    default:
                        break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.receiver.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func wait() async throws {
        try await receiver.wait()
    }

    func stop() {
        queue.async { [weak self] in
            self?.cancelListenerIfNeeded()
        }
        receiver.cancel()
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.isStopped else {
                    continuation.resume()
                    return
                }
                self.stopContinuation = continuation
                self.cancelListenerIfNeeded()
            }
        }
        await receiver.cancelAndWait()
    }

    private func resolveReady(_ result: Result<NWEndpoint.Port, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        switch result {
        case .success(let port):
            continuation.resume(returning: port)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func cancelListenerIfNeeded() {
        guard !isStopped, !stopRequested else { return }
        stopRequested = true
        listener.cancel()
    }
}

private func startControlStressServer(
    expected: [Message],
    secureChannel: BoothSecureChannel
) async throws -> (ControlStressServer, NWEndpoint.Port) {
    let server = try ControlStressServer(expected: expected, secureChannel: secureChannel)
    return (server, try await server.start())
}

private final class TransportLivenessObserver: @unchecked Sendable {
    struct Snapshot: Sendable {
        var activityCount = 0
        var deliveredFrameCount = 0
        var transportClosedCount = 0
        var closeDeliveredCount = 0
        var timeoutCount = 0
        var reconnectDueCount = 0
        var overflowCount = 0
        var deliveredControlMessages: [Message] = []
    }

    private let lock = NSLock()
    private let overflowEvent = DispatchSemaphore(value: 0)
    private let closeEvent = DispatchSemaphore(value: 0)
    private var value = Snapshot()

    func markActivity() {
        lock.lock()
        value.activityCount += 1
        lock.unlock()
    }

    func markDelivered(_ frames: [BoothDecodedTransportFrame]) {
        lock.lock()
        value.deliveredFrameCount += frames.count
        value.deliveredControlMessages.append(contentsOf: frames.compactMap { frame in
            guard case let .control(message) = frame else { return nil }
            return message
        })
        lock.unlock()
    }

    func markTransportClosed() {
        lock.lock()
        value.transportClosedCount += 1
        lock.unlock()
        closeEvent.signal()
    }

    func markCloseDelivered() {
        lock.lock()
        value.closeDeliveredCount += 1
        lock.unlock()
    }

    func markTimeout() {
        lock.lock()
        value.timeoutCount += 1
        lock.unlock()
    }

    func markReconnectDue() {
        lock.lock()
        value.reconnectDueCount += 1
        lock.unlock()
    }

    func markOverflow() {
        lock.lock()
        value.overflowCount += 1
        lock.unlock()
        overflowEvent.signal()
    }

    func waitForOverflow(timeout: TimeInterval = 5) -> Bool {
        overflowEvent.wait(timeout: .now() + timeout) == .success
    }

    func waitForTransportClose(timeout: TimeInterval = 5) -> Bool {
        closeEvent.wait(timeout: .now() + timeout) == .success
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class TransportLivenessServer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let listener: NWListener
    private let secureChannel: BoothSecureChannel
    private let runtime: BoothNetworkTransportRuntime
    private let writer: BoothControlWritePump
    private let observer = TransportLivenessObserver()
    let controlEvents: BoothNetworkTransportCoreEventStream
    private let scheduleReconnectOnClose: Bool
    private let connectionReady = DispatchSemaphore(value: 0)
    private var readyContinuation: CheckedContinuation<NWEndpoint.Port, Error>?
    private var connection: NWConnection?
    private var receiveToken: BoothTransportReceiveToken?
    private var generation = 0
    private var reconnectWasScheduled = false

    init(
        secureChannel: BoothSecureChannel,
        scheduleReconnectOnClose: Bool = false,
        controlEventBufferLimit: Int = 256
    ) throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TransportLiveness")
        self.queue = queue
        listener = try NWListener(using: .tcp)
        self.secureChannel = secureChannel
        self.scheduleReconnectOnClose = scheduleReconnectOnClose
        runtime = BoothNetworkTransportRuntime(queue: queue)
        writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        controlEvents = BoothNetworkTransportCoreEventStream(bufferLimit: controlEventBufferLimit)
        runtime.onHeartbeatTimeout = { [weak observer] _ in
            observer?.markTimeout()
        }
        runtime.onReconnectDue = { [weak observer] _, _ in
            observer?.markReconnectDue()
        }
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            queue.async { [weak self] in
                guard let self else { return }
                readyContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            resolveReady(.failure(ControlStressError.listenerHasNoPort))
                            return
                        }
                        resolveReady(.success(port))
                    case .failed(let error):
                        resolveReady(.failure(error))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }
    }

    func waitForConnection(timeout: TimeInterval = 5) -> Bool {
        connectionReady.wait(timeout: .now() + timeout) == .success
    }

    func terminateConnection() {
        queue.async { [weak self] in
            self?.connection?.cancel()
        }
    }

    func snapshot() -> TransportLivenessObserver.Snapshot {
        observer.snapshot()
    }

    func recordDelivered(_ frames: [BoothDecodedTransportFrame]) {
        observer.markDelivered(frames)
    }

    func observerWaitForOverflow() -> Bool {
        observer.waitForOverflow()
    }

    func waitForTransportClose() -> Bool {
        observer.waitForTransportClose()
    }

    func waitForActivityToSettle() async {
        var previous = snapshot().activityCount
        var stableIntervals = 0
        while stableIntervals < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            let current = snapshot().activityCount
            if current == previous {
                stableIntervals += 1
            } else {
                previous = current
                stableIntervals = 0
            }
        }
    }

    func stop() {
        receiveToken?.invalidate()
        controlEvents.finish()
        runtime.stopHeartbeat()
        writer.invalidate(generation: 2)
        connection?.cancel()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            guard self.connection == nil else {
                connection.cancel()
                return
            }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    guard self.receiveToken == nil else { return }
                    self.generation += 1
                    let connectionGeneration = self.generation
                    let token = BoothTransportReceiveToken()
                    self.receiveToken = token
                    let decoder = BoothTransportFrameDecoder()
                    decoder.setHandshakeComplete(true, channel: .control)
                    self.runtime.bindControlConnection(connection, generation: connectionGeneration, authenticated: true)
                    self.writer.bind(connection, generation: connectionGeneration)
                    self.runtime.startHeartbeat(
                        connection: connection,
                        generation: connectionGeneration,
                        writer: self.writer,
                        interval: 0.25,
                        timeout: 1
                    )
                    self.connectionReady.signal()
                    NetworkBoothTransport.receive(
                        on: connection,
                        channel: .control,
                        decoder: decoder,
                        token: token,
                        secureChannel: self.secureChannel,
                        activity: { [weak self, runtime] in
                            self?.observer.markActivity()
                            runtime.markControlActivityOnQueue(
                                connection: connection,
                                generation: connectionGeneration
                            )
                        },
                        deliver: { [weak self] frames in
                            self?.observer.markDelivered(frames)
                        },
                        deliverPreview: { _ in },
                        close: { [weak self] _ in
                            self?.observer.markCloseDelivered()
                        },
                        isReceiveCurrent: { [weak self, weak connection] in
                            guard let self, let connection else { return false }
                            return self.runtime.isControlConnectionCurrent(
                                connection: connection,
                                generation: connectionGeneration
                            )
                        },
                        enqueueAuthenticatedControl: { [controlEvents] frames in
                            controlEvents.yield(.directControlFrames(
                                generation: connectionGeneration,
                                frames: frames
                            ))
                        },
                        controlDeliveryOverflow: { [weak self, weak connection] _ in
                            guard let self, let connection else { return }
                            self.observer.markOverflow()
                            self.controlEvents.suppressDirectEvents(through: connectionGeneration)
                            connection.cancel()
                        }
                    )
                case .failed, .cancelled:
                    self.observer.markTransportClosed()
                    self.receiveToken = nil
                    if self.connection === connection { self.connection = nil }
                    self.runtime.stopHeartbeat()
                    if self.scheduleReconnectOnClose && !self.reconnectWasScheduled {
                        self.reconnectWasScheduled = true
                        self.runtime.scheduleReconnect(after: 0.05, attempt: 1)
                    }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    private func resolveReady(_ result: Result<NWEndpoint.Port, Error>) {
        guard let readyContinuation else { return }
        self.readyContinuation = nil
        switch result {
        case .success(let port): readyContinuation.resume(returning: port)
        case .failure(let error): readyContinuation.resume(throwing: error)
        }
    }
}

private final class TransportLivenessMessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Message] = []

    func append(_ message: Message) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [Message] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private func drainConnection(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, isComplete, error in
        guard !isComplete, error == nil else { return }
        drainConnection(connection)
    }
}

private func soakMessages(sessionID: String, photoCount: Int, index: Int) -> [Message] {
    let snapshot = SessionSyncSnapshot(
        config: EventConfig(photoCount: photoCount),
        sessionID: sessionID,
        phase: .review(photoIndex: max(0, photoCount - 1)),
        presentation: nil,
        isMirrored: false,
        authorityEpoch: testAuthorityEpoch
    )
    let firstContext = SessionMessageContext(sessionID: sessionID, sequence: 1, authorityEpoch: testAuthorityEpoch)
    let firstReviewState = ReviewStateToken(sessionID: sessionID, photoIndex: 0, revision: 1, authorityEpoch: testAuthorityEpoch)
    let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var messages: [Message] = [
        .sessionSync(snapshot: snapshot),
        .beginCountdown(
            context: firstContext,
            deliveryID: firstRequestID,
            descriptor: CountdownDescriptor(
                photoIndex: 0,
                captureAt: Date(timeIntervalSince1970: Double(index))
            )
        ),
        .reviewDecision(
            state: firstReviewState,
            requestID: firstRequestID,
            action: index.isMultiple(of: 7) ? .retake : .keep
        )
    ]
    if index.isMultiple(of: 7) {
        let retakeContext = SessionMessageContext(sessionID: sessionID, sequence: 2, authorityEpoch: testAuthorityEpoch)
        let retakeReviewState = ReviewStateToken(sessionID: sessionID, photoIndex: 0, revision: 2, authorityEpoch: testAuthorityEpoch)
        messages.append(.beginCountdown(
            context: retakeContext,
            deliveryID: firstRequestID,
            descriptor: CountdownDescriptor(
                photoIndex: 0,
                captureAt: Date(timeIntervalSince1970: Double(index) + 1)
            )
        ))
        messages.append(.reviewDecision(
            state: retakeReviewState,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            action: .keep
        ))
    }
    return messages
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval = 1
) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    until deadline: DispatchTime
) -> Bool {
    semaphore.wait(timeout: deadline) == .success
}

private final class NetworkTestConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connections = [NWConnection]()

    func store(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let connections = self.connections
        self.connections.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
    }
}

/// Captures only message case names from a loopback socket; payload fields stay
/// in the parser and are never retained for assertions or diagnostic output.
private final class ControlMessageCaseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let closed = DispatchSemaphore(value: 0)
    private var parser = BoothFrameParser()
    private var cases: [String] = []
    private var isClosed = false

    func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty,
               let frames = try? self.parser.append(data) {
                let names = frames.compactMap { frame in
                    try? Message.decoded(from: frame.payload).diagnosticCaseName
                }
                if !names.isEmpty {
                    self.lock.lock()
                    self.cases.append(contentsOf: names)
                    self.lock.unlock()
                    names.forEach { _ in self.changed.signal() }
                }
            }
            if isComplete || error != nil {
                self.lock.lock()
                self.isClosed = true
                self.lock.unlock()
                self.changed.signal()
                self.closed.signal()
            } else {
                self.receive(from: connection)
            }
        }
    }

    func waitForCase(_ expected: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while true {
            lock.lock()
            let found = cases.contains(expected)
            let closed = isClosed
            lock.unlock()
            if found { return true }
            if closed { return false }
            guard changed.wait(timeout: deadline) == .success else { return false }
        }
    }

    func waitUntilClosed(timeout: TimeInterval = 5) -> Bool {
        lock.lock()
        let alreadyClosed = isClosed
        lock.unlock()
        return alreadyClosed || closed.wait(timeout: .now() + timeout) == .success
    }

    func contains(_ expected: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cases.contains(expected)
    }
}

/// Test observer with all shared mutable state protected by `lock`.
private final class TrustedCoreTestObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let listenerReady = DispatchSemaphore(value: 0)
    private let authenticated = DispatchSemaphore(value: 0)
    private let disconnected = DispatchSemaphore(value: 0)
    private let rejected = DispatchSemaphore(value: 0)
    private let controlMessageReceived = DispatchSemaphore(value: 0)
    private let heartbeatReceived = DispatchSemaphore(value: 0)
    private let pairingVerificationRequired = DispatchSemaphore(value: 0)
    private let pairingSessionConsumed = DispatchSemaphore(value: 0)
    private let pairingIntentReceived = DispatchSemaphore(value: 0)
    private var portValue: NWEndpoint.Port?
    private var authenticatedGenerations: [Int] = []
    private var authenticatedInterfaces: [BoothNetworkInterfacePolicy?] = []
    private var authenticatedSessionIDs: [String] = []
    private var disconnectedGenerations: [Int] = []
    private var rejectionReasons: [String] = []
    private var controlFrameFailureSummaries: [String] = []
    private var controlMessages: [Message] = []
    private var heartbeatCountValue = 0
    private var pairingVerificationSnapshot: BoothNetworkTransportRuntime.PairingVerificationSnapshot?
    private var pairingSessionConsumptions: [BoothNetworkTransportRuntime.PairingSessionConsumption] = []
    private var pairingIntentCandidates: [(BoothNetworkTransportRuntime.PairingCandidate, BoothPairingIntent)] = []

    func receive(_ event: BoothNetworkTransportRuntime.ControlCoreEvent) {
        switch event {
        case .listenerReady(_, let port, _):
            lock.lock()
            portValue = port
            lock.unlock()
            listenerReady.signal()
        case .trustedAuthenticated(let generation, _, _, let localHello, _, let interface, _, _):
            lock.lock()
            authenticatedGenerations.append(generation)
            authenticatedInterfaces.append(interface)
            authenticatedSessionIDs.append(localHello.sessionID)
            lock.unlock()
            authenticated.signal()
        case .disconnected(let generation, _):
            lock.lock()
            disconnectedGenerations.append(generation)
            lock.unlock()
            disconnected.signal()
        case .controlFrames(_, let frames):
            let messages = frames.compactMap { frame -> Message? in
                guard case .control(let message) = frame else { return nil }
                return message
            }
            let heartbeats = frames.reduce(into: 0) { count, frame in
                if case .heartbeat = frame { count += 1 }
            }
            guard !messages.isEmpty || heartbeats > 0 else { return }
            lock.lock()
            controlMessages.append(contentsOf: messages)
            heartbeatCountValue += heartbeats
            lock.unlock()
            messages.forEach { _ in controlMessageReceived.signal() }
            (0..<heartbeats).forEach { _ in heartbeatReceived.signal() }
        case .directControlFrames(_, let frames):
            let messages = frames.compactMap { frame -> Message? in
                guard case .control(let message) = frame else { return nil }
                return message
            }
            let heartbeats = frames.reduce(into: 0) { count, frame in
                if case .heartbeat = frame { count += 1 }
            }
            guard !messages.isEmpty || heartbeats > 0 else { return }
            lock.lock()
            controlMessages.append(contentsOf: messages)
            heartbeatCountValue += heartbeats
            lock.unlock()
            messages.forEach { _ in controlMessageReceived.signal() }
            (0..<heartbeats).forEach { _ in heartbeatReceived.signal() }
        case .pairingVerificationRequired(let snapshot):
            lock.lock()
            pairingVerificationSnapshot = snapshot
            lock.unlock()
            pairingVerificationRequired.signal()
        case .pairingSessionConsumed(let consumption):
            lock.lock()
            pairingSessionConsumptions.append(consumption)
            lock.unlock()
            pairingSessionConsumed.signal()
        case .pairingIntentCandidate(let candidate, let intent):
            lock.lock()
            pairingIntentCandidates.append((candidate, intent))
            lock.unlock()
            pairingIntentReceived.signal()
        case .rejected(_, let reason), .listenerFailed(_, let reason):
            lock.lock()
            rejectionReasons.append(reason)
            lock.unlock()
            rejected.signal()
        case .controlFrameDecodeFailed(_, _, _, let summary):
            lock.lock()
            controlFrameFailureSummaries.append(summary)
            lock.unlock()
            rejected.signal()
        default:
            break
        }
    }

    func waitForListener(timeout: TimeInterval = 3) -> NWEndpoint.Port? {
        guard listenerReady.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return portValue
    }

    func waitForAuthenticationCount(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForAuthenticationCountBlocking(count, timeout: timeout)
        }.value
    }

    private func waitForAuthenticationCountBlocking(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while authenticationCount < count {
            guard authenticated.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    func waitForDisconnectedCount(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForDisconnectedCountBlocking(count, timeout: timeout)
        }.value
    }

    private func waitForDisconnectedCountBlocking(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while disconnectedCount < count {
            guard disconnected.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    func waitForPairingVerification(timeout: TimeInterval = 8) -> Bool {
        pairingVerificationRequired.wait(timeout: .now() + timeout) == .success
    }

    func waitForPairingSessionConsumption(timeout: TimeInterval = 5) -> Bool {
        pairingSessionConsumed.wait(timeout: .now() + timeout) == .success
    }

    func waitForPairingIntent(timeout: TimeInterval = 5) -> Bool {
        pairingIntentReceived.wait(timeout: .now() + timeout) == .success
    }

    func waitForPairingIntentCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while pairingIntentCount < count {
            guard pairingIntentReceived.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    var lastPairingVerificationSnapshot: BoothNetworkTransportRuntime.PairingVerificationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return pairingVerificationSnapshot
    }

    var lastPairingSessionConsumption: BoothNetworkTransportRuntime.PairingSessionConsumption? {
        lock.lock()
        defer { lock.unlock() }
        return pairingSessionConsumptions.last
    }

    var lastPairingIntentCandidate: (BoothNetworkTransportRuntime.PairingCandidate, BoothPairingIntent)? {
        lock.lock()
        defer { lock.unlock() }
        return pairingIntentCandidates.last
    }

    private var pairingIntentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pairingIntentCandidates.count
    }

    func waitForRejectionCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while rejectionCount < count {
            guard rejected.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    func waitForRejectionReason(_ reason: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while !hasRejectionReason(reason) {
            guard rejected.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    private func hasRejectionReason(_ reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectionReasons.contains(where: { $0.contains(reason) })
    }

    var authenticationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedGenerations.count
    }

    private var disconnectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnectedGenerations.count
    }

    var controlMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return controlMessages.count
    }

    var heartbeatCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return heartbeatCountValue
    }

    var controlFrameFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return controlFrameFailureSummaries.count
    }

    var secureSessionIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedSessionIDs
    }

    func waitForControlMessageCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while controlMessageCount < count {
            guard controlMessageReceived.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    func waitForHeartbeatCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while heartbeatCount < count {
            guard heartbeatReceived.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    var controlMessagesSnapshot: [Message] {
        lock.lock()
        defer { lock.unlock() }
        return controlMessages
    }

    var lastAuthenticatedGeneration: Int? {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedGenerations.last
    }

    var lastAuthenticatedInterface: BoothNetworkInterfacePolicy? {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedInterfaces.last ?? nil
    }

    func waitForControlMessage(_ message: Message, timeout: TimeInterval = 3) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while !hasControlMessage(message) {
            guard controlMessageReceived.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    private func hasControlMessage(_ message: Message) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlMessages.contains(message)
    }

    var rejectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rejectionReasons.count
    }
}

private final class ListenerLifecycleTestObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let listenerReady = DispatchSemaphore(value: 0)
    private let listenerFailed = DispatchSemaphore(value: 0)
    private var readyEvents: [(generation: Int, port: NWEndpoint.Port?, interface: BoothNetworkInterfacePolicy)] = []
    private var failedGenerations: [Int] = []

    func receive(_ event: BoothNetworkTransportRuntime.ControlCoreEvent) {
        lock.lock()
        switch event {
        case .listenerReady(let generation, let port, let interface):
            readyEvents.append((generation, port, interface))
            lock.unlock()
            listenerReady.signal()
        case .listenerFailed(let generation, _):
            failedGenerations.append(generation)
            lock.unlock()
            listenerFailed.signal()
        default:
            lock.unlock()
        }
    }

    func waitForReadyCount(_ count: Int, timeout: TimeInterval = 3) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForReadyCountBlocking(count, timeout: timeout)
        }.value
    }

    private func waitForReadyCountBlocking(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while readyCount < count {
            guard listenerReady.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    func waitForFailureCount(_ count: Int, timeout: TimeInterval = 3) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForFailureCountBlocking(count, timeout: timeout)
        }.value
    }

    private func waitForFailureCountBlocking(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while failureCount < count {
            guard listenerFailed.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    var readyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readyEvents.count
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedGenerations.count
    }

    var lastReadyEvent: (generation: Int, port: NWEndpoint.Port?, interface: BoothNetworkInterfacePolicy)? {
        lock.lock()
        defer { lock.unlock() }
        return readyEvents.last
    }
}

private final class ListenerFactoryFailureBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int

    init(_ remainingFailures: Int) {
        self.remainingFailures = remainingFailures
    }

    func consumeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else { return false }
        remainingFailures -= 1
        return true
    }
}

private final class ControlListenerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedListeners: [NWListener] = []

    func append(_ listener: NWListener) {
        lock.lock()
        capturedListeners.append(listener)
        lock.unlock()
    }

    var listeners: [NWListener] {
        lock.lock()
        defer { lock.unlock() }
        return capturedListeners
    }
}

private struct ForcedControlListenerFailure: Error, LocalizedError {
    var errorDescription: String? { "Injected control-listener construction failure." }
}

/// A test socket whose callback state is serialized by its queue and lock.
private final class HostileLoopbackClient: @unchecked Sendable {
    private enum SendState: Equatable {
        case connecting
        case sending
        case sent
        case closed
    }

    private let lock = NSLock()
    private let stateChanged = DispatchSemaphore(value: 0)
    private var sendState = SendState.connecting
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let payload: Data

    init(port: NWEndpoint.Port, messages: [Message]) throws {
        connection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port),
            using: .tcp
        )
        queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.Hostile.\(UUID().uuidString)")
        payload = try messages.reduce(into: Data()) { bytes, message in
            bytes.append(try BoothFrameEncoder.encode(channel: .control, payload: message.encoded()))
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                guard self.sendState == .connecting else {
                    self.lock.unlock()
                    return
                }
                self.sendState = .sending
                self.lock.unlock()
                if self.payload.isEmpty {
                    self.finishSend(.sent)
                    return
                }
                self.connection.send(content: self.payload, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.finishSend(error == nil ? .sent : .closed)
                })
            case .failed, .cancelled:
                self.finishSend(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func waitUntilSent(timeout: TimeInterval = 3) -> Bool {
        waitUntilSent(until: .now() + timeout)
    }

    func waitUntilSent(until deadline: DispatchTime) -> Bool {
        while true {
            lock.lock()
            let state = sendState
            lock.unlock()
            switch state {
            case .sent:
                return true
            case .closed:
                return false
            case .connecting, .sending:
                guard stateChanged.wait(timeout: deadline) == .success else { return false }
            }
        }
    }

    func send(_ messages: [Message], timeout: TimeInterval = 3) -> Bool {
        guard let payload = try? messages.reduce(into: Data(), { bytes, message in
            bytes.append(try BoothFrameEncoder.encode(channel: .control, payload: message.encoded()))
        }) else { return false }
        let completion = DispatchSemaphore(value: 0)
        let result = RecoveryTestFlag()
        queue.async { [connection] in
            connection.send(content: payload, completion: .contentProcessed { error in
                if error == nil { result.mark() }
                completion.signal()
            })
        }
        guard completion.wait(timeout: .now() + timeout) == .success else { return false }
        return result.value
    }

    private func finishSend(_ state: SendState) {
        lock.lock()
        guard sendState != .sent, sendState != .closed else {
            lock.unlock()
            return
        }
        sendState = state
        lock.unlock()
        stateChanged.signal()
    }

    func cancel() { connection.cancel() }
}

private func makeAdmissionPairingRequest(
    session: BoothPairingSession,
    macIdentity: BoothDeviceIdentity,
    iPadIdentity: BoothDeviceIdentity,
    method: BoothPairingMethod,
    proofCode: String
) -> BoothPairingRequest {
    let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
    let transcript = BoothPairingCrypto.pairingTranscript(
        sessionID: session.info.sessionID,
        macDeviceID: macIdentity.id,
        iPadDeviceID: iPadIdentity.id,
        method: method,
        macEphemeralPublicKey: session.info.macEphemeralPublicKey,
        iPadEphemeralPublicKey: ephemeralKey.publicKey.rawRepresentation
    )
    return BoothPairingRequest(
        sessionID: session.info.sessionID,
        targetMacDeviceID: macIdentity.id,
        iPadIdentity: iPadIdentity,
        method: method,
        iPadEphemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
        admissionProof: BoothPairingCrypto.makeAdmissionProof(code: proofCode, transcript: transcript)
    )
}

@Suite("Network route policy", .serialized)
struct NetworkRouteTests {
    @Test("duplicate control-listener start keeps the runtime generation")
    func duplicateControlListenerStartKeepsCanonicalGeneration() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ControlListenerGeneration")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let identity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Listener Mac", role: .mac)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        let events = ListenerLifecycleTestObserver()
        runtime.configureControlCore(
            localIdentity: identity,
            networkPreference: .wifi,
            trustedSecrets: [:],
            selectedPeerID: nil,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        defer {
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }

        let service = NWListener.Service(
            name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: identity.id),
            type: "_prc-control._tcp",
            txtRecord: NWTXTRecord(["deviceID": identity.id])
        )
        let firstGeneration = runtime.startControlListener(using: .tcp, port: nil, service: service)
        #expect(await events.waitForReadyCount(1))

        let duplicateGeneration = runtime.startControlListener(using: .tcp, port: nil, service: service)
        #expect(duplicateGeneration == firstGeneration)
        #expect(events.readyCount == 1)
        #expect(events.lastReadyEvent?.generation == firstGeneration)
    }

    @Test("control-listener retry recovers during MainActor stall")
    func controlListenerRetryRecoversDuringMainActorStall() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ControlListenerRetry")
        let failureBudget = ListenerFactoryFailureBudget(1)
        let runtime = BoothNetworkTransportRuntime(
            queue: queue,
            controlListenerFactory: { parameters, port in
                if failureBudget.consumeFailure() { throw ForcedControlListenerFailure() }
                if let port { return try NWListener(using: parameters, on: port) }
                return try NWListener(using: parameters)
            }
        )
        let identity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Listener Mac", role: .mac)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        let events = ListenerLifecycleTestObserver()
        runtime.configureControlCore(
            localIdentity: identity,
            networkPreference: .wifi,
            trustedSecrets: [:],
            selectedPeerID: nil,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        defer {
            releaseMain.signal()
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }
        #expect(waitForSemaphore(mainEntered))

        let generation = runtime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: identity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": identity.id])
            )
        )
        #expect(await events.waitForFailureCount(1))
        #expect(await events.waitForReadyCount(1))
        #expect(events.lastReadyEvent?.generation == generation)
        #expect(events.lastReadyEvent?.port != nil)
    }

    @Test(
        "Mac control listener falls back to Wi-Fi and authenticates during MainActor stall",
        .disabled(if: !runMainActorStallTests)
    )
    func macControlListenerFallbackAuthenticatesDuringMainActorStall() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ListenerFallback.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ListenerFallback.iPad")
        let failureBudget = ListenerFactoryFailureBudget(1)
        let macRuntime = BoothNetworkTransportRuntime(
            queue: macQueue,
            controlListenerFactory: { parameters, port in
                if failureBudget.consumeFailure() { throw ForcedControlListenerFailure() }
                if let port { return try NWListener(using: parameters, on: port) }
                return try NWListener(using: parameters)
            }
        )
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Fallback Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Fallback iPad", role: .iPad)
        let secret = Data(repeating: 0x8D, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedCoreTestObserver()
        let iPadEvents = TrustedCoreTestObserver()
        let listenerEvents = ListenerLifecycleTestObserver()
        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .lan,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in
            macEvents?.receive(event)
            listenerEvents.receive(event)
        }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .lan,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in iPadEvents?.receive(event) }

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer {
            releaseMain.signal()
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))
        let stallStarted = Date()

        var wiredParameters = NWParameters.tcp
        wiredParameters.requiredInterfaceType = .wiredEthernet
        let generation = macRuntime.startControlListener(
            using: wiredParameters,
            port: NWEndpoint.Port(rawValue: 58_500),
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord([
                    "deviceID": macIdentity.id,
                    "network": BoothNetworkPreference.lan.rawValue,
                    "role": DeviceRole.mac.rawValue,
                    "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
                ])
            ),
            interface: .wiredEthernet,
            fallback: (interface: .wifi, parameters: .tcp, port: nil)
        )

        #expect(await listenerEvents.waitForFailureCount(1, timeout: 3))
        #expect(await listenerEvents.waitForReadyCount(1, timeout: 5))
        let ready = try #require(listenerEvents.lastReadyEvent)
        #expect(ready.generation == generation)
        #expect(ready.interface == .wifi)
        let port = try #require(ready.port)

        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 2002
        )
        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 8))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))
        #expect(iPadEvents.lastAuthenticatedInterface == .wifi)

        let stallDeadline = stallStarted.addingTimeInterval(12)
        while Date() < stallDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Date().timeIntervalSince(stallStarted) >= 11.9)
        #expect(macEvents.authenticationCount == 1)
        #expect(iPadEvents.authenticationCount == 1)
    }

    @Test("a retired control listener cannot admit a late connection after fallback")
    func retiredControlListenerCannotAdmitLateConnectionAfterFallback() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.RetiredListener")
        let capture = ControlListenerCapture()
        let runtime = BoothNetworkTransportRuntime(
            queue: queue,
            controlListenerFactory: { parameters, port in
                let listener: NWListener
                if let port {
                    listener = try NWListener(using: parameters, on: port)
                } else {
                    listener = try NWListener(using: parameters)
                }
                capture.append(listener)
                return listener
            }
        )
        let identity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Retired Listener Mac", role: .mac)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        let events = ListenerLifecycleTestObserver()
        runtime.configureControlCore(
            localIdentity: identity,
            networkPreference: .lan,
            trustedSecrets: [:],
            selectedPeerID: nil,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        defer {
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }

        var wiredParameters = NWParameters.tcp
        wiredParameters.requiredInterfaceType = .wiredEthernet
        let generation = runtime.startControlListener(
            using: wiredParameters,
            port: NWEndpoint.Port(rawValue: 58_500),
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: identity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": identity.id])
            ),
            interface: .wiredEthernet,
            fallback: (interface: .wifi, parameters: .tcp, port: nil)
        )

        #expect(await events.waitForReadyCount(1))
        let retiredListener = try #require(capture.listeners.first)
        let lateConnectionHandler = try #require(retiredListener.newConnectionHandler)
        retiredListener.cancel()
        #expect(await events.waitForFailureCount(1))
        #expect(await events.waitForReadyCount(2))
        #expect(events.lastReadyEvent?.generation == generation)
        #expect(events.lastReadyEvent?.interface == .wifi)

        let staleConnection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 58_501)!),
            using: .tcp
        )
        lateConnectionHandler(staleConnection)

        #expect(runtime.inboundControlConnectionCount() == 0)
        #expect(runtime.admissionLaneSnapshot() == .init(
            normalCandidatePresent: false,
            identityProbePresent: false
        ))
    }

    @Test(
        "trusted iPad rejects secure negotiation before mutual authentication",
        arguments: ["secureChannelHello", "secureChannelReady"]
    )
    func trustedIPadRejectsSecureNegotiationBeforeAuthentication(_ prematureCase: String) async throws {
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PreAuthSecureHello.iPad")
        let serverQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PreAuthSecureHello.Server")
        let runtime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Phase iPad", role: .iPad)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Phase Mac", role: .mac)
        let secret = Data(repeating: 0xA4, count: 32)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: iPadQueue, secureChannel: secureChannel)
        let events = TrustedCoreTestObserver()
        let remoteMessages = ControlMessageCaseCapture()
        let connections = NetworkTestConnectionBox()
        let listenerReady = DispatchSemaphore(value: 0)
        let listener = try NWListener(using: .tcp)
        let fakeMacHello = BoothTransportHello(
            role: .mac,
            deviceID: macIdentity.id,
            deviceName: macIdentity.displayName
        )
        let prematureSecureMessage: Message
        let expectedRejectionReason: String
        switch prematureCase {
        case "secureChannelHello":
            let hello = BoothSecureChannelHello(
                sessionID: UUID().uuidString,
                challenge: Data(repeating: 0x39, count: 32),
                senderRole: .mac,
                senderDeviceID: macIdentity.id,
                receiverDeviceID: iPadIdentity.id
            )
            prematureSecureMessage = .secureChannelHello(hello: hello)
            expectedRejectionReason = "Secure-channel Hello arrived before mutual authentication."
        case "secureChannelReady":
            prematureSecureMessage = .secureChannelReady(
                sessionID: UUID().uuidString,
                proof: Data(repeating: 0x39, count: 32)
            )
            expectedRejectionReason = "Secure-channel confirmation arrived before mutual authentication."
        default:
            Issue.record("Unexpected premature secure-message case: \(prematureCase)")
            return
        }
        let attackPayload = try [
            Message.helloDetails(hello: fakeMacHello),
            prematureSecureMessage
        ].reduce(into: Data()) { bytes, message in
            bytes.append(try BoothFrameEncoder.encode(channel: .control, payload: message.encoded()))
        }

        runtime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            connections.store(connection)
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                remoteMessages.receive(from: connection)
                connection.send(content: attackPayload, completion: .contentProcessed { _ in })
            }
            connection.start(queue: serverQueue)
        }
        listener.start(queue: serverQueue)
        #expect(waitForSemaphore(listenerReady))
        let port = try #require(listener.port)
        defer {
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
            connections.cancel()
            listener.cancel()
        }

        runtime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 1
        )

        #expect(remoteMessages.waitForCase("authChallenge", timeout: 5))
        #expect(events.waitForRejectionReason(expectedRejectionReason, timeout: 5))
        #expect(remoteMessages.waitUntilClosed(timeout: 5))
        #expect(!remoteMessages.contains("secureChannelHello"))
        #expect(!remoteMessages.contains("secureChannelReady"))
        #expect(events.authenticationCount == 0)
        #expect(events.controlFrameFailureCount == 0)
        #expect(!secureChannel.hasPreparedKeys)
    }

    @Test("100 stored-secret runtime reconnects establish fresh secure sessions and deliver encrypted controls")
    func trustedRuntimeCompletesOneHundredSecureReconnectCycles() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedCycle.Mac")
        let macRuntime = BoothNetworkTransportRuntime(queue: macQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Cycle Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Cycle iPad", role: .iPad)
        let secret = Data(repeating: 0xC7, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let macEvents = TrustedCoreTestObserver()

        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in macEvents?.receive(event) }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord([
                    "deviceID": macIdentity.id,
                    "network": BoothNetworkPreference.wifi.rawValue,
                    "role": DeviceRole.mac.rawValue,
                    "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
                ])
            )
        )
        let port = try #require(macEvents.waitForListener())

        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedCycle.iPad")
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let iPadSecureChannel = BoothSecureChannel()
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let iPadEvents = TrustedCoreTestObserver()
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in iPadEvents?.receive(event) }
        defer {
            macRuntime.stopControlCore()
            macWriter.invalidate(generation: Int.max)
            iPadRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
        }

        var iPadSessions: [String] = []
        for index in 0..<100 {
            iPadRuntime.startTrustedControlConnection(
                endpoint: .hostPort(host: "127.0.0.1", port: port),
                parameters: .tcp,
                interface: .wifi,
                provenance: .localNetworkBonjour,
                generation: index + 1
            )
            let expectedCount = index + 1
            try #require(
                await iPadEvents.waitForAuthenticationCount(expectedCount, timeout: 5),
                "iPad did not authenticate reconnect cycle \(expectedCount)"
            )
            try #require(
                await macEvents.waitForAuthenticationCount(expectedCount, timeout: 5),
                "Mac did not authenticate reconnect cycle \(expectedCount)"
            )
            #expect(iPadEvents.controlFrameFailureCount == 0)
            #expect(macEvents.controlFrameFailureCount == 0)
            iPadSessions.append(try #require(iPadEvents.secureSessionIDs.last))

            let generation = try #require(iPadEvents.lastAuthenticatedGeneration)
            #expect(iPadRuntime.enqueueAuthenticatedControl(
                .heartbeat,
                generation: generation,
                secure: true,
                completion: nil
            ) == .sent)
            try #require(
                macEvents.waitForHeartbeatCount(expectedCount, timeout: 5),
                "Mac did not receive the encrypted heartbeat for reconnect cycle \(expectedCount)"
            )

            let message = Message.boothPaused(isPaused: index.isMultiple(of: 2))
            #expect(iPadRuntime.enqueueAuthenticatedControl(
                message,
                generation: generation,
                secure: true,
                completion: nil
            ) == .sent)
            try #require(
                macEvents.waitForControlMessageCount(expectedCount, timeout: 5),
                "Mac did not receive the encrypted control message for reconnect cycle \(expectedCount)"
            )
            #expect(macEvents.controlMessagesSnapshot.last == message)

            iPadRuntime.stopControlCore()
            try #require(
                await macEvents.waitForDisconnectedCount(expectedCount, timeout: 5),
                "Mac did not observe disconnect after reconnect cycle \(expectedCount)"
            )
        }

        let macSessions = macEvents.secureSessionIDs
        let iPadSecureSessions = iPadEvents.secureSessionIDs
        #expect(macSessions.count == 100)
        #expect(Set(macSessions).count == 100)
        #expect(iPadSecureSessions.count == 100)
        #expect(Set(iPadSecureSessions).count == 100)
        #expect(iPadSessions == macSessions)
        #expect(macEvents.heartbeatCount == 100)
        #expect(macEvents.controlMessageCount == 100)
        #expect(macEvents.controlFrameFailureCount == 0)
        #expect(macEvents.rejectionCount == 0)
    }

    @Test(
        "stored-secret Hello and secure reconnect finish during MainActor stall over loopback",
        .disabled(if: !runMainActorStallTests)
    )
    func trustedControlHandshakeAndReconnectSurviveMainActorStall() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedCore.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedCore.iPad")
        let macRuntime = BoothNetworkTransportRuntime(queue: macQueue)
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Core Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Core iPad", role: .iPad)
        let secret = Data(repeating: 0xA7, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedCoreTestObserver()
        let iPadEvents = TrustedCoreTestObserver()

        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in
            macEvents?.receive(event)
        }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in
            iPadEvents?.receive(event)
        }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord([
                    "deviceID": macIdentity.id,
                    "network": BoothNetworkPreference.wifi.rawValue,
                    "role": DeviceRole.mac.rawValue,
                    "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
                ])
            )
        )
        let port = try #require(macEvents.waitForListener())
        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer {
            releaseMain.signal()
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))
        let stallStarted = Date()

        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 771
        )
        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 8))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))
        if let generation = iPadEvents.lastAuthenticatedGeneration {
            #expect(iPadRuntime.enqueueAuthenticatedControl(
                .boothPaused(isPaused: true),
                generation: generation,
                secure: true,
                completion: nil
            ) == .sent)
        }
        #expect(macEvents.waitForControlMessage(.boothPaused(isPaused: true)))
        if let generation = iPadEvents.lastAuthenticatedGeneration {
            iPadRuntime.invalidateControlConnection(generation: generation)
        }
        #expect(await iPadEvents.waitForAuthenticationCount(2, timeout: 5))
        #expect(await macEvents.waitForAuthenticationCount(2, timeout: 3))

        let elapsed = Date().timeIntervalSince(stallStarted)
        if elapsed < 12 {
            try await Task.sleep(for: .seconds(12 - elapsed))
        }
        #expect(Date().timeIntervalSince(stallStarted) >= 11.9)
        #expect(iPadEvents.authenticationCount >= 2)
        #expect(macEvents.authenticationCount >= 2)
    }

    @Test(
        "trusted cached-route exhaustion rediscovers and authenticates during MainActor stall with local Bonjour",
        .disabled(if: !runMainActorStallTests || !runBonjourRouteRefreshIntegration)
    )
    func trustedRouteRefreshAuthenticatesDuringMainActorStall() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.RouteRefresh.MacA")
        let replacementMacQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.RouteRefresh.MacB")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.RouteRefresh.iPad")
        let macRuntime = BoothNetworkTransportRuntime(queue: macQueue)
        let replacementMacRuntime = BoothNetworkTransportRuntime(queue: replacementMacQueue)
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Route Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Route iPad", role: .iPad)
        let secret = Data(repeating: 0x91, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let replacementMacSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let replacementMacWriter = BoothControlWritePump(
            queue: replacementMacQueue,
            secureChannel: replacementMacSecureChannel
        )
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedCoreTestObserver()
        let replacementMacEvents = TrustedCoreTestObserver()
        let iPadEvents = TrustedCoreTestObserver()
        let reconnectEvents = TransportLivenessObserver()

        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in macEvents?.receive(event) }
        replacementMacRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: replacementMacSecureChannel,
            writer: replacementMacWriter
        ) { [weak replacementMacEvents] event in replacementMacEvents?.receive(event) }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in iPadEvents?.receive(event) }
        iPadRuntime.onReconnectDue = { [weak reconnectEvents] _, _ in
            reconnectEvents?.markReconnectDue()
        }
        let staleServiceName = BoothBonjourServiceIdentity.serviceName(
            channel: .control,
            deviceID: macIdentity.id
        )
        let replacementServiceName = "\(staleServiceName) (2)"
        #expect(
            BoothBonjourServiceIdentity.parse(replacementServiceName)
                == BoothBonjourServiceIdentity(channel: .control, deviceID: macIdentity.id)
        )
        let service = NWListener.Service(
            name: staleServiceName,
            type: "_prc-control._tcp",
            txtRecord: NWTXTRecord([
                "deviceID": macIdentity.id,
                "network": BoothNetworkPreference.wifi.rawValue,
                "role": DeviceRole.mac.rawValue,
                "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
            ])
        )
        // The identity parser accepts Bonjour's collision suffix. A distinct
        // instance name lets the replacement register while the old listener
        // is still winding down.
        let replacementService = NWListener.Service(
            name: replacementServiceName,
            type: "_prc-control._tcp",
            txtRecord: NWTXTRecord([
                "deviceID": macIdentity.id,
                "network": BoothNetworkPreference.wifi.rawValue,
                "role": DeviceRole.mac.rawValue,
                "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
            ])
        )
        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer {
            releaseMain.signal()
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            replacementMacRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
            replacementMacWriter.invalidate(generation: Int.max)
        }
        let staleListener = try NWListener(using: .tcp)
        var staleListenerCancelledByTest = false
        defer {
            if !staleListenerCancelledByTest {
                staleListener.cancel()
            }
        }
        let staleListenerReady = DispatchSemaphore(value: 0)
        let staleListenerCancelled = DispatchSemaphore(value: 0)
        let staleServiceRegistered = DispatchSemaphore(value: 0)
        let routeObserver = BonjourRouteObserver(
            targetDeviceID: macIdentity.id,
            queue: DispatchQueue(label: "PRC-PhotoBooth.Tests.RouteRefresh.Bonjour", qos: .userInitiated)
        )
        defer { routeObserver.cancel() }
        let replacementListener = try NWListener(using: .tcp)
        defer { replacementListener.cancel() }
        defer { releaseMain.signal() }
        let replacementListenerReady = DispatchSemaphore(value: 0)
        let replacementServiceRegistered = DispatchSemaphore(value: 0)
        staleListener.service = service
        staleListener.stateUpdateHandler = { state in
            switch state {
            case .ready: staleListenerReady.signal()
            case .cancelled: staleListenerCancelled.signal()
            default: break
            }
        }
        staleListener.serviceRegistrationUpdateHandler = { change in
            if case .add = change { staleServiceRegistered.signal() }
        }
        staleListener.newConnectionHandler = { connection in
            _ = macRuntime.startInboundControlConnection(connection)
        }
        staleListener.start(queue: macQueue)
        #expect(waitForSemaphore(staleListenerReady, timeout: 5))
        #expect(
            waitForSemaphore(staleServiceRegistered, timeout: 5),
            "The initial listener became ready before Bonjour registration completed."
        )
        let stalePort = try #require(staleListener.port)
        #expect(routeObserver.waitForRoutes(
            containing: staleServiceName,
            excluding: replacementServiceName,
            timeout: 5
        ))

        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: stalePort),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 981
        )
        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 5))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))

        replacementListener.service = replacementService
        replacementListener.stateUpdateHandler = { state in
            if case .ready = state { replacementListenerReady.signal() }
        }
        replacementListener.serviceRegistrationUpdateHandler = { change in
            if case .add = change { replacementServiceRegistered.signal() }
        }
        replacementListener.newConnectionHandler = { connection in
            _ = replacementMacRuntime.startInboundControlConnection(connection)
        }
        replacementListener.start(queue: replacementMacQueue)
        #expect(waitForSemaphore(replacementListenerReady, timeout: 5))
        let replacementPort = try #require(replacementListener.port)
        #expect(
            waitForSemaphore(replacementServiceRegistered, timeout: 5),
            "The replacement listener became ready before Bonjour registration completed."
        )
        #expect(stalePort != replacementPort)

        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))
        let stallStarted = Date()
        macRuntime.stopControlCore()
        #expect(await iPadEvents.waitForDisconnectedCount(1, timeout: 5))
        iPadRuntime.cancelReconnect()
        staleListener.cancel()
        staleListenerCancelledByTest = true
        #expect(
            waitForSemaphore(staleListenerCancelled, timeout: 5),
            "The old listener did not stop before cached-route recovery began."
        )
        #expect(routeObserver.waitForRoutes(
            containing: replacementServiceName,
            excluding: staleServiceName,
            timeout: 5
        ), "Bonjour still advertised the stale route when reconnection began.")
        // Enter at the exhausted retry boundary; timer and per-attempt retry
        // behavior have separate tests, while this case covers route refresh.
        #expect(iPadRuntime.scheduleReconnect(after: 0.05, attempt: 6, generation: 981))

        let authenticatedDuringStall = await iPadEvents.waitForAuthenticationCount(2, timeout: 11)
        let authenticatedAt = Date()
        if authenticatedAt.timeIntervalSince(stallStarted) < 12 {
            try await Task.sleep(for: .seconds(12 - authenticatedAt.timeIntervalSince(stallStarted)))
        }
        #expect(authenticatedDuringStall, "Trusted Bonjour rediscovery waited for MainActor after the cached route failed.")
        #expect(await replacementMacEvents.waitForAuthenticationCount(1, timeout: 1))
        #expect(Date().timeIntervalSince(stallStarted) >= 11.9)
        #expect(reconnectEvents.snapshot().reconnectDueCount == 0)
        #expect(iPadEvents.authenticationCount == 2)
        #expect(macEvents.authenticationCount == 1)
        #expect(replacementMacEvents.authenticationCount == 1)
    }

    @Test(
        "control-core events keep authentication before frames through a MainActor stall",
        .disabled(if: !runMainActorStallTests)
    )
    func controlCoreEventStreamPreservesAuthenticationOrderDuringMainActorStall() async throws {
        let stream = BoothNetworkTransportCoreEventStream()
        let observer = CoreEventDeliveryObserver()
        let consumer = Task { @MainActor in
            for await event in stream.stream {
                observer.receive(event)
                if observer.count == 2 { return }
            }
        }
        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer {
            releaseMain.signal()
            stream.finish()
            consumer.cancel()
        }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))

        let macID = UUID().uuidString
        let iPadID = UUID().uuidString
        let sessionID = "ordered-core-events"
        let localSecureHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x2A, count: 32),
            senderRole: .iPad,
            senderDeviceID: iPadID,
            receiverDeviceID: macID
        )
        let peerSecureHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x3B, count: 32),
            senderRole: .mac,
            senderDeviceID: macID,
            receiverDeviceID: iPadID
        )
        let authenticated = BoothNetworkTransportRuntime.ControlCoreEvent.trustedAuthenticated(
            generation: 442,
            endpointDescription: "127.0.0.1",
            hello: BoothTransportHello(role: .mac, deviceID: macID, deviceName: "Mac"),
            localSecureHello: localSecureHello,
            peerSecureHello: peerSecureHello,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            routeGeneration: 19
        )
        let frames = BoothNetworkTransportRuntime.ControlCoreEvent.controlFrames(
            generation: 442,
            frames: [.control(.boothPaused(isPaused: true))]
        )
        let transportQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.CoreEventOrder")
        let yielded = DispatchSemaphore(value: 0)
        transportQueue.async {
            stream.yield(authenticated)
            stream.yield(frames)
            yielded.signal()
        }
        #expect(waitForSemaphore(yielded))
        #expect(observer.count == 0)

        releaseMain.signal()
        #expect(await observer.waitForCount(2, timeout: 2))
        #expect(observer.order == ["authenticated", "controlFrames"])
        await consumer.value
    }

    @Test("control-core event stream bounds its backlog and handles overflow once per generation")
    func controlCoreEventStreamBoundsBacklog() {
        let stream = BoothNetworkTransportCoreEventStream(bufferLimit: 2)
        let first = BoothNetworkTransportRuntime.ControlCoreEvent.listenerReady(
            generation: 1, port: nil, interface: .wifi
        )
        let second = BoothNetworkTransportRuntime.ControlCoreEvent.listenerReady(
            generation: 2, port: nil, interface: .wifi
        )
        let overflow = BoothNetworkTransportRuntime.ControlCoreEvent.listenerReady(
            generation: 3, port: nil, interface: .wifi
        )

        #expect(stream.yield(first))
        #expect(stream.yield(second))
        #expect(!stream.yield(overflow))
        stream.suppressEvents(through: 3)
        #expect(stream.isSuppressed(1))
        #expect(stream.isSuppressed(3))
        #expect(!stream.isSuppressed(4))
        #expect(stream.claimOverflowHandling(for: 3))
        #expect(!stream.claimOverflowHandling(for: 3))
        #expect(stream.claimOverflowHandling(for: 4))
        stream.finish()
    }

    @Test("control-core event overflow invokes production close and listener-failure fallbacks")
    func controlCoreEventStreamUsesProductionOverflowHandling() {
        let stream = BoothNetworkTransportCoreEventStream(bufferLimit: 1)
        let failCalled = RecoveryTestFlag()
        let overflowReported = RecoveryTestFlag()
        let listenerFailureReported = RecoveryTestFlag()
        let buffered = BoothNetworkTransportRuntime.ControlCoreEvent.listenerReady(
            generation: 1, port: nil, interface: .wifi
        )
        #expect(stream.yield(buffered))

        let droppedControl = BoothNetworkTransportRuntime.ControlCoreEvent.rejected(
            generation: 8,
            reason: "test overflow"
        )
        let failedToPublishControl = stream.publish(
            droppedControl,
            failOverflowedGeneration: { _, _ in failCalled.mark() },
            reportOverflow: { _, _ in overflowReported.mark() },
            reportDroppedListenerEvent: { _ in listenerFailureReported.mark() }
        )
        #expect(!failedToPublishControl)
        #expect(failCalled.value)
        #expect(overflowReported.value)
        #expect(stream.isSuppressed(8))
        #expect(!listenerFailureReported.value)

        let listenerFailureStream = BoothNetworkTransportCoreEventStream(bufferLimit: 1)
        #expect(listenerFailureStream.yield(buffered))
        let failedToPublishListener = listenerFailureStream.publish(
            .listenerFailed(generation: 9, reason: "listener failed"),
            failOverflowedGeneration: { _, _ in failCalled.mark() },
            reportOverflow: { _, _ in overflowReported.mark() },
            reportDroppedListenerEvent: { _ in listenerFailureReported.mark() }
        )
        #expect(!failedToPublishListener)
        #expect(listenerFailureReported.value)
        listenerFailureStream.finish()

        let listenerRouteStream = BoothNetworkTransportCoreEventStream(bufferLimit: 1)
        let listenerRouteReported = RecoveryTestFlag()
        #expect(listenerRouteStream.yield(buffered))
        let failedToPublishListenerRoute = listenerRouteStream.publish(
            .listenerReady(
                generation: 2,
                port: NWEndpoint.Port(rawValue: 58_501),
                interface: .wifi
            ),
            failOverflowedGeneration: { _, _ in failCalled.mark() },
            reportOverflow: { _, _ in overflowReported.mark() },
            reportDroppedListenerEvent: { event in
                if case .listenerReady(_, _, .wifi) = event {
                    listenerRouteReported.mark()
                }
            }
        )
        #expect(!failedToPublishListenerRoute)
        #expect(listenerRouteReported.value)
        listenerRouteStream.finish()
        stream.finish()
    }

    @Test("production overflow closes an authenticated socket before UI event consumption")
    func productionControlEventOverflowClosesSocketAndSuppressesGeneration() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.CoreOverflow.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.CoreOverflow.iPad")
        let macRuntime = BoothNetworkTransportRuntime(queue: macQueue)
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Overflow Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Overflow iPad", role: .iPad)
        let secret = Data(repeating: 0xD6, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let iPadEvents = TrustedCoreTestObserver()
        let overflowObserver = ControlCoreOverflowTestObserver()
        let eventStream = BoothNetworkTransportCoreEventStream(bufferLimit: 1)

        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macRuntime] event in
            guard let macRuntime else { return }
            if case .listenerReady(_, let port, _) = event {
                overflowObserver.receiveListener(port)
            }
            eventStream.publish(
                event,
                failOverflowedGeneration: { generation, reason in
                    macRuntime.failControlCoreConnection(generation: generation, reason: reason)
                },
                reportOverflow: { generation, _ in
                    overflowObserver.recordOverflow(generation: generation)
                },
                reportDroppedListenerEvent: { _ in }
            )
        }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in iPadEvents?.receive(event) }
        defer {
            eventStream.finish()
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord([
                    "deviceID": macIdentity.id,
                    "network": BoothNetworkPreference.wifi.rawValue,
                    "role": DeviceRole.mac.rawValue,
                    "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
                ])
            )
        )
        let port = try #require(overflowObserver.waitForListener())

        // ListenerReady occupies the single buffer slot, modeling a stalled
        // MainActor consumer. The real secure handshake event then overflows.
        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 887
        )

        let overflowedGeneration = try #require(overflowObserver.waitForOverflow(timeout: 8))
        #expect(await iPadEvents.waitForDisconnectedCount(1, timeout: 5))
        #expect(eventStream.isSuppressed(overflowedGeneration))
        #expect(macRuntime.isControlSlotAvailable())
    }

    @Test("control-core event stream finishes when its owner is released")
    func controlCoreEventStreamFinishesWhenOwnerIsReleased() async {
        var eventStream: BoothNetworkTransportCoreEventStream? = BoothNetworkTransportCoreEventStream()
        var iterator = eventStream!.stream.makeAsyncIterator()

        eventStream = nil

        #expect(await iterator.next() == nil)
    }

    @Test("persistent Bonjour browser failures back off to a bounded retry interval")
    func trustedRouteBrowserRetryDelayCapsAfterRepeatedFailures() {
        #expect(BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: 0) == 1)
        #expect(BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: 1) == 2)
        #expect(BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: 2) == 4)
        #expect(BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: 3) == 8)
        #expect(BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: 4) == 16)
        #expect(BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: 5) == 30)
        #expect(BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: 100) == 30)
    }

    @Test("Bonjour browser recovery resets retry backoff before the next failure")
    func trustedRouteBrowserRecoveryResetsRetryBackoff() {
        var backoff = BoothNetworkTransportRuntime.RouteBrowserRetryBackoff()

        #expect(backoff.nextDelay() == 1)
        #expect(backoff.nextDelay() == 2)
        #expect(backoff.nextDelay() == 4)

        backoff.browserRecovered()

        #expect(backoff.attempt == 0)
        #expect(backoff.nextDelay() == 1)
    }

    @Test(
        "incoming PIN pairing reaches the operator boundary after a 12-second MainActor stall",
        .disabled(if: !runMainActorStallTests)
    )
    func incomingPairingCandidateSurvivesMainActorStall() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PairingCore.Mac")
        let runtime = BoothNetworkTransportRuntime(queue: macQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Pairing Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Pairing iPad", role: .iPad)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: macQueue, secureChannel: secureChannel)
        let events = TrustedCoreTestObserver()
        let session = try BoothPairingSession.make(macIdentity: macIdentity)
        let iPadEphemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let transcript = BoothPairingCrypto.pairingTranscript(
            sessionID: session.info.sessionID,
            macDeviceID: macIdentity.id,
            iPadDeviceID: iPadIdentity.id,
            method: .pin,
            macEphemeralPublicKey: session.info.macEphemeralPublicKey,
            iPadEphemeralPublicKey: iPadEphemeralKey.publicKey.rawRepresentation
        )
        let request = BoothPairingRequest(
            sessionID: session.info.sessionID,
            targetMacDeviceID: macIdentity.id,
            iPadIdentity: iPadIdentity,
            method: .pin,
            iPadEphemeralPublicKey: iPadEphemeralKey.publicKey.rawRepresentation,
            admissionProof: BoothPairingCrypto.makeAdmissionProof(code: session.pin, transcript: transcript)
        )
        runtime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [:],
            selectedPeerID: nil,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        runtime.installInboundPairingSession(session)
        _ = runtime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": macIdentity.id])
            )
        )
        let port = try #require(events.waitForListener())

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        let mainResumed = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
            mainResumed.signal()
        }
        let client = try HostileLoopbackClient(
            port: port,
            messages: [
                .helloDetails(hello: BoothTransportHello(
                    role: .iPad,
                    deviceID: iPadIdentity.id,
                    deviceName: iPadIdentity.displayName
                )),
                .pairingRequest(request: request)
            ]
        )
        defer {
            releaseMain.signal()
            client.cancel()
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }
        #expect(waitForSemaphore(mainEntered))
        let stallStarted = Date()
        client.start()
        #expect(client.waitUntilSent())
        #expect(events.waitForPairingVerification())

        let snapshot = try #require(events.lastPairingVerificationSnapshot)
        #expect(runtime.isInboundPairingCandidateCurrent(
            token: snapshot.candidate.token,
            generation: snapshot.candidate.generation
        ))
        #expect(snapshot.candidate.hello.deviceID == iPadIdentity.id)
        #expect(snapshot.sessionID == session.info.sessionID)
        #expect(BoothPairingSession.isValidPIN(snapshot.verificationCode))
        while Date().timeIntervalSince(stallStarted) < 12 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Date().timeIntervalSince(stallStarted) >= 12)
        #expect(runtime.admissionLaneSnapshot().normalCandidatePresent)
        #expect(!runtime.confirmPairingVerification(
            token: snapshot.candidate.token,
            generation: snapshot.candidate.generation &+ 1
        ))

        releaseMain.signal()
        #expect(waitForSemaphore(mainResumed))
        runtime.cancelInboundPairingCandidate(
            token: snapshot.candidate.token,
            generation: snapshot.candidate.generation,
            reason: "Test teardown."
        )
        #expect(!runtime.isInboundPairingCandidateCurrent(
            token: snapshot.candidate.token,
            generation: snapshot.candidate.generation
        ))
    }

    @Test("accepted QR pairing consumes the advertised session while retaining its candidate")
    func acceptedQRPairingReportsSessionConsumption() throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PairingConsumption.QR")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "QR Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "QR iPad", role: .iPad)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        let events = TrustedCoreTestObserver()
        let session = try BoothPairingSession.make(macIdentity: macIdentity)
        let request = makeAdmissionPairingRequest(
            session: session,
            macIdentity: macIdentity,
            iPadIdentity: iPadIdentity,
            method: .qrToken,
            proofCode: session.qrToken
        )
        runtime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [:],
            selectedPeerID: nil,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        runtime.installInboundPairingSession(session)
        _ = runtime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": macIdentity.id])
            )
        )
        let port = try #require(events.waitForListener())
        let client = try HostileLoopbackClient(
            port: port,
            messages: [
                .helloDetails(hello: BoothTransportHello(
                    role: .iPad,
                    deviceID: iPadIdentity.id,
                    deviceName: iPadIdentity.displayName
                )),
                .pairingRequest(request: request)
            ]
        )
        defer {
            client.cancel()
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }

        client.start()
        #expect(client.waitUntilSent())
        #expect(events.waitForPairingSessionConsumption())
        let consumption = try #require(events.lastPairingSessionConsumption)
        #expect(consumption.sessionID == session.info.sessionID)
        #expect(consumption.outcome == .proofAccepted(method: .qrToken))
        #expect(runtime.isInboundPairingCandidateCurrent(
            token: consumption.candidate.token,
            generation: consumption.candidate.generation
        ))
        #expect(!runtime.respondToInboundPairingIntent(
            token: consumption.candidate.token,
            generation: consumption.candidate.generation,
            session: session.info
        ))
    }

    @Test("preempted pairing candidate cannot consume the replacement candidate session")
    func preemptedPairingCandidateCannotConsumeReplacementSession() throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PairingPreemption")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Preemption Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Preemption iPad", role: .iPad)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        let events = TrustedCoreTestObserver()
        let session = try BoothPairingSession.make(macIdentity: macIdentity)
        let intent = BoothPairingIntent(iPadIdentity: iPadIdentity, targetMacDeviceID: macIdentity.id)
        let hello = BoothTransportHello(
            role: .iPad,
            deviceID: iPadIdentity.id,
            deviceName: iPadIdentity.displayName
        )
        let request = makeAdmissionPairingRequest(
            session: session,
            macIdentity: macIdentity,
            iPadIdentity: iPadIdentity,
            method: .qrToken,
            proofCode: session.qrToken
        )
        runtime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [:],
            selectedPeerID: nil,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        runtime.installInboundPairingSession(session)
        _ = runtime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": macIdentity.id])
            )
        )
        let port = try #require(events.waitForListener())
        let first = try HostileLoopbackClient(
            port: port,
            messages: [.helloDetails(hello: hello), .pairingIntent(intent: intent)]
        )
        let replacement = try HostileLoopbackClient(
            port: port,
            messages: [.helloDetails(hello: hello), .pairingIntent(intent: intent)]
        )
        defer {
            first.cancel()
            replacement.cancel()
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }

        first.start()
        #expect(first.waitUntilSent())
        #expect(events.waitForPairingIntentCount(1))
        let firstCandidate = try #require(events.lastPairingIntentCandidate?.0)

        // A previously authenticated endpoint hint makes the next connection
        // preferred. This exercises production replacement and cancellation.
        runtime.updateTrustedPeerIDs([iPadIdentity.id])
        runtime.recordAuthenticatedPeer(
            iPadIdentity.id,
            endpoint: .hostPort(host: "127.0.0.1", port: .any)
        )
        replacement.start()
        #expect(replacement.waitUntilSent())
        #expect(events.waitForPairingIntentCount(2))
        let replacementCandidate = try #require(events.lastPairingIntentCandidate?.0)
        #expect(replacementCandidate.generation != firstCandidate.generation)

        // Attempt a valid request from the cancelled socket, then have the
        // replacement candidate consume the same one-use pairing session.
        _ = first.send([.pairingRequest(request: request)])
        _ = replacement.send([.pairingRequest(request: request)])
        #expect(events.waitForPairingSessionConsumption())
        let consumption = try #require(events.lastPairingSessionConsumption)
        #expect(consumption.outcome == .proofAccepted(method: .qrToken))
        #expect(consumption.candidate.generation == replacementCandidate.generation)
    }

    @Test("pairing PIN lockout clears its session and admits a fresh pairing intent")
    func pairingPINLockoutAllowsFreshIntent() throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PairingConsumption.Lockout")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Lockout Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Lockout iPad", role: .iPad)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        let events = TrustedCoreTestObserver()
        let session = try BoothPairingSession.make(macIdentity: macIdentity)
        let wrongPIN = session.pin == "000000" ? "000001" : "000000"
        let invalidRequest = makeAdmissionPairingRequest(
            session: session,
            macIdentity: macIdentity,
            iPadIdentity: iPadIdentity,
            method: .pin,
            proofCode: wrongPIN
        )
        runtime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [:],
            selectedPeerID: nil,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        runtime.installInboundPairingSession(session)
        _ = runtime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": macIdentity.id])
            )
        )
        let port = try #require(events.waitForListener())
        let lockoutClient = try HostileLoopbackClient(
            port: port,
            messages: [.helloDetails(hello: BoothTransportHello(
                role: .iPad,
                deviceID: iPadIdentity.id,
                deviceName: iPadIdentity.displayName
            ))] + Array(repeating: .pairingRequest(request: invalidRequest), count: BoothPairingSession.maximumPINAttempts)
        )
        defer {
            lockoutClient.cancel()
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }

        lockoutClient.start()
        #expect(lockoutClient.waitUntilSent())
        #expect(events.waitForPairingSessionConsumption())
        let consumption = try #require(events.lastPairingSessionConsumption)
        #expect(consumption.sessionID == session.info.sessionID)
        #expect(consumption.outcome == .locked)
        #expect(events.waitForRejectionReason("Too many incorrect pairing PIN attempts"))
        #expect(!runtime.isInboundPairingCandidateCurrent(
            token: consumption.candidate.token,
            generation: consumption.candidate.generation
        ))

        let replacementSession = try BoothPairingSession.make(macIdentity: macIdentity)
        runtime.installInboundPairingSession(replacementSession)
        let replacementClient = try HostileLoopbackClient(
            port: port,
            messages: [
                .helloDetails(hello: BoothTransportHello(
                    role: .iPad,
                    deviceID: iPadIdentity.id,
                    deviceName: iPadIdentity.displayName
                )),
                .pairingIntent(intent: BoothPairingIntent(
                    iPadIdentity: iPadIdentity,
                    targetMacDeviceID: macIdentity.id
                ))
            ]
        )
        defer { replacementClient.cancel() }
        replacementClient.start()
        #expect(replacementClient.waitUntilSent())
        #expect(events.waitForPairingIntent())
        let (candidate, intent) = try #require(events.lastPairingIntentCandidate)
        #expect(intent.iPadIdentity == iPadIdentity)
        #expect(runtime.respondToInboundPairingIntent(
            token: candidate.token,
            generation: candidate.generation,
            session: replacementSession.info
        ))
    }

    @Test(
        "trusted identity probe authenticates after 100 anonymous endpoint failures during MainActor stall",
        .disabled(if: !runMainActorStallTests)
    )
    func trustedIdentityProbeAuthenticatesAfterAnonymousEndpointFlood() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedFlood.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedFlood.iPad")
        let macRuntime = BoothNetworkTransportRuntime(queue: macQueue)
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Flood Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Flood iPad", role: .iPad)
        let secret = Data(repeating: 0xB4, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedCoreTestObserver()
        let iPadEvents = TrustedCoreTestObserver()

        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in
            macEvents?.receive(event)
        }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in
            iPadEvents?.receive(event)
        }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord([
                    "deviceID": macIdentity.id,
                    "network": BoothNetworkPreference.wifi.rawValue,
                    "role": DeviceRole.mac.rawValue,
                    "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
                ])
            )
        )
        let port = try #require(macEvents.waitForListener())
        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer {
            releaseMain.signal()
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))
        let stallStarted = Date()

        for index in 1...100 {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(String(format: "192.0.2.%d", index)),
                port: NWEndpoint.Port(rawValue: 54_321)!
            )
            let candidate = NWConnection(to: endpoint, using: .tcp)
            guard let admission = macRuntime.admitInboundControlConnection(candidate).admission else {
                Issue.record("Anonymous endpoint candidate \(index) was not admitted to the bounded test lane.")
                return
            }
            macRuntime.abandonInboundControlAdmission(admission, connection: candidate)
        }

        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 991
        )
        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 8))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))

        let elapsed = Date().timeIntervalSince(stallStarted)
        if elapsed < 12 {
            try await Task.sleep(for: .seconds(12 - elapsed))
        }
        #expect(Date().timeIntervalSince(stallStarted) >= 11.9)
    }

    @Test(
        "trusted reconnect retries after occupied probe slots during MainActor stall",
        .disabled(if: !runMainActorStallTests)
    )
    func trustedProbeRetriesAfterOccupiedSlotsDuringMainActorStall() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ProbeWaiter.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ProbeWaiter.iPad")
        let macRuntime = BoothNetworkTransportRuntime(queue: macQueue)
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Waiter Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Waiter iPad", role: .iPad)
        let secret = Data(repeating: 0xC3, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedCoreTestObserver()
        let iPadEvents = TrustedCoreTestObserver()
        var hostileClients: [HostileLoopbackClient] = []

        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in macEvents?.receive(event) }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in iPadEvents?.receive(event) }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": macIdentity.id])
            )
        )
        let port = try #require(macEvents.waitForListener())
        defer {
            hostileClients.forEach { $0.cancel() }
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }

        func waitForAdmissionLanes(
            _ expected: BoothNetworkTransportRuntime.AdmissionLaneSnapshot,
            timeout: TimeInterval = 3
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if macRuntime.admissionLaneSnapshot() == expected { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return macRuntime.admissionLaneSnapshot() == expected
        }

        // The first anonymous socket owns the normal pre-auth slot. The
        // second occupies the single identity-probe slot with a slow Hello.
        for index in 0..<2 {
            let client = try HostileLoopbackClient(port: port, messages: [])
            hostileClients.append(client)
            client.start()
            #expect(client.waitUntilSent(), "Probe holder \(index) did not connect.")
        }

        let occupiedSlots = await waitForAdmissionLanes(
            .init(
                normalCandidatePresent: true,
                identityProbePresent: true
            )
        )
        #expect(occupiedSlots, "The listener did not admit both bounded probe holders.")

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer { releaseMain.signal() }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))
        let stallStarted = Date()

        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 1502
        )
        let trustedAttemptDeadline = Date().addingTimeInterval(3)
        while Date() < trustedAttemptDeadline,
              macRuntime.inboundControlConnectionCount() < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            macRuntime.inboundControlConnectionCount() >= 3,
            "The trusted reconnect did not reach the occupied listener."
        )
        #expect(macEvents.authenticationCount == 0)
        hostileClients[0].cancel()
        hostileClients[1].cancel()

        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 8))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))
        let authenticationFinishedAt = Date()
        #expect(authenticationFinishedAt.timeIntervalSince(stallStarted) < 10)
        if authenticationFinishedAt.timeIntervalSince(stallStarted) < 12 {
            try await Task.sleep(for: .seconds(12 - authenticationFinishedAt.timeIntervalSince(stallStarted)))
        }
        #expect(Date().timeIntervalSince(stallStarted) >= 11.9)
        #expect(iPadEvents.authenticationCount == 1)
        #expect(macEvents.authenticationCount == 1)
    }

    @Test("an occupied identity probe rejects extra sockets without retaining them")
    func occupiedIdentityProbeRejectsExtraSocketsWithoutRetainingThem() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ProbeWaiterExpiry")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        defer { runtime.stopControlCore() }
        let port = try #require(NWEndpoint.Port(rawValue: 8585))

        func connection(to address: String) throws -> NWConnection {
            let host = try #require(IPv4Address(address))
            return NWConnection(to: .hostPort(host: .ipv4(host), port: port), using: .tcp)
        }

        let normalConnection = try connection(to: "127.0.0.1")
        let probeConnection = try connection(to: "127.0.0.2")
        let normal = runtime.admitInboundControlConnection(
            normalConnection,
            adoptionTimeout: 10
        )
        let activeProbe = runtime.admitInboundControlConnection(
            probeConnection,
            adoptionTimeout: 10
        )
        let overflowProbe = runtime.admitInboundControlConnection(
            try connection(to: "127.0.0.3"),
            adoptionTimeout: 1
        )
        #expect(normal.admission != nil)
        #expect(activeProbe.admission?.isIdentityProbe == true)
        #expect(overflowProbe.admission == nil)
        #expect(overflowProbe.rejectionReason?.contains("probe slot is occupied") == true)
        #expect(runtime.admissionLaneSnapshot().identityProbePresent)

        runtime.abandonInboundControlAdmission(
            try #require(activeProbe.admission),
            connection: probeConnection
        )
        #expect(!runtime.admissionLaneSnapshot().identityProbePresent)

        let laterProbe = runtime.admitInboundControlConnection(
            try connection(to: "127.0.0.4"),
            adoptionTimeout: 10
        )
        #expect(laterProbe.admission?.isIdentityProbe == true)
        #expect(runtime.admissionLaneSnapshot().normalCandidatePresent)
        #expect(runtime.admissionLaneSnapshot().identityProbePresent)
    }

    @Test("a trusted HMAC proof passes after 100 spoofed claims with anonymous occupancy")
    func trustedPeerProofPassesAfterHundredSpoofClaims() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.SpoofCooldown.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.SpoofCooldown.iPad")
        let macRuntime = BoothNetworkTransportRuntime(queue: macQueue)
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Cooldown Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Cooldown iPad", role: .iPad)
        let storedSecret = Data(repeating: 0x65, count: 32)
        let spoofSecret = Data(repeating: 0x19, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedCoreTestObserver()
        let iPadEvents = TrustedCoreTestObserver()

        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: storedSecret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in macEvents?.receive(event) }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: spoofSecret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in iPadEvents?.receive(event) }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": macIdentity.id])
            )
        )
        let port = try #require(macEvents.waitForListener())
        let anonymousControlHolder = try HostileLoopbackClient(port: port, messages: [])
        defer { anonymousControlHolder.cancel() }
        anonymousControlHolder.start()
        #expect(anonymousControlHolder.waitUntilSent())
        let anonymousCandidateDeadline = Date().addingTimeInterval(3)
        while Date() < anonymousCandidateDeadline,
              !macRuntime.admissionLaneSnapshot().normalCandidatePresent {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(macRuntime.admissionLaneSnapshot().normalCandidatePresent)
        defer {
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }

        func connect(generation: Int) {
            iPadRuntime.startTrustedControlConnection(
                endpoint: .hostPort(host: "127.0.0.1", port: port),
                parameters: .tcp,
                interface: .wifi,
                provenance: .localNetworkBonjour,
                generation: generation
            )
        }

        for attempt in 0..<100 {
            connect(generation: 1410 + attempt)
            #expect(macEvents.waitForRejectionCount(attempt + 1, timeout: 5))
            iPadRuntime.stopControlCore()
        }

        #expect(macRuntime.identityProbeCooldownIsActive())
        iPadRuntime.updateControlCredentials(
            trustedSecrets: [macIdentity.id: storedSecret],
            selectedPeerID: macIdentity.id
        )
        #expect(macRuntime.admissionLaneSnapshot().normalCandidatePresent)
        connect(generation: 1499)
        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 5))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))
        #expect(macEvents.authenticationCount == 1)
    }

    @Test("100 hostile pre-auth loopback connections stay within bounded admission lanes")
    func hostilePreAuthLoopbackFloodStaysWithinAdmissionLanes() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.HostileFlood")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Flood Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Flood iPad", role: .iPad)
        let secureChannel = BoothSecureChannel()
        let writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        let events = TrustedCoreTestObserver()
        let listener = try NWListener(using: .tcp)
        let listenerReady = DispatchSemaphore(value: 0)
        let acceptedConnection = DispatchSemaphore(value: 0)
        var clients: [HostileLoopbackClient] = []

        runtime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: Data(repeating: 0x34, count: 32)],
            selectedPeerID: iPadIdentity.id,
            secureChannel: secureChannel,
            writer: writer
        ) { [weak events] event in events?.receive(event) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            _ = runtime.startInboundControlConnection(connection, adoptionTimeout: 20)
            acceptedConnection.signal()
        }
        listener.start(queue: queue)
        #expect(waitForSemaphore(listenerReady))
        let port = try #require(listener.port)
        defer {
            clients.forEach { $0.cancel() }
            listener.cancel()
            runtime.stopControlCore()
            writer.invalidate(generation: Int.max)
        }

        for _ in 0..<100 {
            let client = try HostileLoopbackClient(port: port, messages: [])
            clients.append(client)
            client.start()
        }

        let acceptDeadline = DispatchTime.now() + .seconds(5)
        var acceptedConnectionCount = 0
        for _ in clients {
            guard waitForSemaphore(acceptedConnection, until: acceptDeadline) else { break }
            acceptedConnectionCount += 1
        }
        guard acceptedConnectionCount == 100 else {
            Issue.record("The listener processed \(acceptedConnectionCount) of 100 hostile connections.")
            return
        }

        let connectDeadline = DispatchTime.now() + .seconds(3)
        let connectedCount = clients.reduce(into: 0) { count, client in
            if client.waitUntilSent(until: connectDeadline) { count += 1 }
        }
        #expect(connectedCount >= 1)

        let admissionDeadline = Date().addingTimeInterval(3)
        var lanes = runtime.admissionLaneSnapshot()
        while Date() < admissionDeadline,
              !(lanes.normalCandidatePresent && lanes.identityProbePresent) {
            try await Task.sleep(for: .milliseconds(10))
            lanes = runtime.admissionLaneSnapshot()
        }
        #expect(lanes.normalCandidatePresent)
        #expect(lanes.identityProbePresent)
        #expect(events.authenticationCount == 0)

        clients.forEach { $0.cancel() }
        let cleanupDeadline = Date().addingTimeInterval(3)
        while Date() < cleanupDeadline, runtime.admissionLaneSnapshot().normalCandidatePresent {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!runtime.admissionLaneSnapshot().normalCandidatePresent)
    }

    @Test(
        "production listener admission releases a stalled control slot while MainActor is blocked",
        .disabled(if: !runMainActorStallTests)
    )
    func productionListenerAdmissionIsQueueOwned() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ProductionAdmission")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let listener = try NWListener(using: .tcp)
        let listenerReady = DispatchSemaphore(value: 0)
        let accepted = DispatchSemaphore(value: 0)
        let preAuthTimeout = DispatchSemaphore(value: 0)
        let serverConnection = NetworkTestConnectionBox()
        let clientQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ProductionAdmissionClient")
        runtime.onPreAuthTimeout = { _, _, _ in preAuthTimeout.signal() }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            let result = runtime.startInboundControlConnection(
                connection,
                adoptionTimeout: 0.2
            )
            if result.admission != nil {
                serverConnection.store(connection)
                accepted.signal()
            }
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            serverConnection.cancel()
            runtime.cancelReconnect()
        }
        #expect(waitForSemaphore(listenerReady))
        let port = try #require(listener.port)

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer { releaseMain.signal() }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(waitForSemaphore(mainEntered))

        let first = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let second = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer {
            first.cancel()
            second.cancel()
        }
        first.start(queue: clientQueue)
        #expect(waitForSemaphore(accepted, timeout: 5))
        #expect(waitForSemaphore(preAuthTimeout, timeout: 3))
        #expect(runtime.isControlSlotAvailable())

        second.start(queue: clientQueue)
        #expect(waitForSemaphore(accepted, timeout: 5))
        #expect(!runtime.isControlSlotAvailable())
    }

    @Test("previously authenticated endpoint bypasses anonymous flood ceiling without bypassing authentication")
    func trustedEndpointAdmissionSurvivesAnonymousFlood() {
        let runtime = BoothNetworkTransportRuntime(
            queue: DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedAdmission")
        )
        runtime.updateTrustedPeerIDs(["paired-ipad"])
        let trustedEndpoint = NWEndpoint.hostPort(
            host: "192.168.1.44",
            port: NWEndpoint.Port(rawValue: 54_321)!
        )
        runtime.recordAuthenticatedPeer("paired-ipad", endpoint: trustedEndpoint)

        for index in 1...BoothPreAuthAdmissionLimiter.defaultGlobalFailureThreshold {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(String(format: "192.0.2.%d", index)),
                port: NWEndpoint.Port(rawValue: 54_321)!
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            let result = runtime.admitInboundControlConnection(connection)
            #expect(result.admission != nil)
            if let admission = result.admission {
                runtime.abandonInboundControlAdmission(admission, connection: connection)
            }
        }

        let anonymous = NWConnection(
            to: .hostPort(host: "198.51.100.7", port: NWEndpoint.Port(rawValue: 54_321)!),
            using: .tcp
        )
        let anonymousResult = runtime.admitInboundControlConnection(anonymous)
        #expect(anonymousResult.admission?.isIdentityProbe == true)
        if let admission = anonymousResult.admission {
            runtime.abandonInboundControlAdmission(admission, connection: anonymous)
        }

        let trusted = NWConnection(to: trustedEndpoint, using: .tcp)
        let trustedResult = runtime.admitInboundControlConnection(trusted)
        #expect(trustedResult.admission?.isIdentityProbe == false)
        #expect(trustedResult.admission?.isPreferredCandidate == true)
        if let admission = trustedResult.admission {
            runtime.abandonInboundControlAdmission(admission, connection: trusted)
        }
    }

    @Test("trusted identity probe works with empty endpoint history and a changed DHCP address")
    func identityProbeWorksWithChangedAddressAndEmptyHistory() {
        let runtime = BoothNetworkTransportRuntime(
            queue: DispatchQueue(label: "PRC-PhotoBooth.Tests.IdentityProbe")
        )
        runtime.updateTrustedPeerIDs(["paired-ipad"])

        for index in 1...100 {
            let connection = NWConnection(
                to: .hostPort(
                    host: NWEndpoint.Host(String(format: "192.0.2.%d", (index % 250) + 1)),
                    port: NWEndpoint.Port(rawValue: 54_321)!
                ),
                using: .tcp
            )
            let result = runtime.admitInboundControlConnection(connection)
            guard let admission = result.admission else {
                #expect(Bool(false), "The bounded probe lane should stay available after anonymous throttling.")
                continue
            }
            runtime.abandonInboundControlAdmission(admission, connection: connection)
        }

        let newDHCPAddress = NWConnection(
            to: .hostPort(host: "192.168.1.99", port: NWEndpoint.Port(rawValue: 54_321)!),
            using: .tcp
        )
        let result = runtime.admitInboundControlConnection(newDHCPAddress)
        #expect(result.admission?.isIdentityProbe == true)
        if let admission = result.admission {
            #expect(runtime.acceptIdentityProbeClaim(
                "paired-ipad",
                connection: newDHCPAddress,
                generation: admission.generation
            ))
            runtime.abandonInboundControlAdmission(admission, connection: newDHCPAddress)
        }
    }

    @Test("spoofed trusted IDs cannot cooldown-veto a claimed ID before HMAC proof")
    func identityProbeThrottlesSpoofedTrustedID() {
        let runtime = BoothNetworkTransportRuntime(
            queue: DispatchQueue(label: "PRC-PhotoBooth.Tests.IdentityProbeSpoof")
        )
        runtime.updateTrustedPeerIDs(["paired-ipad"])

        for index in 1...BoothPreAuthAdmissionLimiter.defaultGlobalFailureThreshold {
            let connection = NWConnection(
                to: .hostPort(
                    host: NWEndpoint.Host(String(format: "192.0.2.%d", index)),
                    port: NWEndpoint.Port(rawValue: 54_321)!
                ),
                using: .tcp
            )
            guard let admission = runtime.admitInboundControlConnection(connection).admission else {
                #expect(Bool(false), "The anonymous ceiling should be reached after this request.")
                continue
            }
            runtime.abandonInboundControlAdmission(admission, connection: connection)
        }

        for attempt in 0..<BoothPreAuthAdmissionLimiter.defaultReservedFailureThreshold {
            let connection = NWConnection(
                to: .hostPort(
                    host: NWEndpoint.Host(String(format: "198.51.100.%d", attempt + 1)),
                    port: NWEndpoint.Port(rawValue: 54_321)!
                ),
                using: .tcp
            )
            guard let admission = runtime.admitInboundControlConnection(connection).admission else {
                #expect(Bool(false), "The single identity-probe lane should admit one candidate at a time.")
                continue
            }
            #expect(admission.isIdentityProbe)
            #expect(runtime.acceptIdentityProbeClaim(
                "paired-ipad",
                connection: connection,
                generation: admission.generation
            ))
            runtime.abandonInboundControlAdmission(admission, connection: connection)
        }

        let spoofed = NWConnection(
            to: .hostPort(host: "203.0.113.99", port: NWEndpoint.Port(rawValue: 54_321)!),
            using: .tcp
        )
        guard let admission = runtime.admitInboundControlConnection(spoofed).admission else {
            #expect(Bool(false), "A bounded probe candidate should be available for the HMAC attempt.")
            return
        }
        #expect(admission.isIdentityProbe)
        #expect(runtime.acceptIdentityProbeClaim(
            "paired-ipad",
            connection: spoofed,
            generation: admission.generation
        ))
        runtime.abandonInboundControlAdmission(admission, connection: spoofed)
    }

    @Test(
        "production cached reconnect starts a replacement socket while MainActor is blocked",
        .disabled(if: !runMainActorStallTests)
    )
    func productionReconnectStartsSocketOffMainActor() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ProductionReconnect")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let listener = try NWListener(using: .tcp)
        let listenerReady = DispatchSemaphore(value: 0)
        let accepted = DispatchSemaphore(value: 0)
        let connectionStarted = DispatchSemaphore(value: 0)
        let serverConnection = NetworkTestConnectionBox()
        let generation = 88
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            serverConnection.store(connection)
            connection.start(queue: queue)
            accepted.signal()
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            serverConnection.cancel()
            runtime.cancelReconnect()
        }
        #expect(waitForSemaphore(listenerReady))
        let port = try #require(listener.port)
        runtime.setControlReconnectRoute(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: .tcp,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: generation
        )
        runtime.onReconnectConnectionStarted = { _, _, _, _, _, _, _ in
            connectionStarted.signal()
        }

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer { releaseMain.signal() }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(waitForSemaphore(mainEntered))

        #expect(runtime.scheduleReconnect(after: 0.05, attempt: 1, generation: generation))
        #expect(waitForSemaphore(connectionStarted))
        #expect(waitForSemaphore(accepted))
        #expect(!waitForSemaphore(accepted, timeout: 0.2))
    }

    @Test("reconnect timer fires while MainActor is blocked", .disabled(if: !runMainActorStallTests))
    func reconnectTimerIsQueueOwned() {
        let queue = DispatchQueue(
            label: "PRC-PhotoBooth.Tests.ReconnectRuntime",
            qos: .userInitiated
        )
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        let reconnectFired = DispatchSemaphore(value: 0)
        runtime.onReconnectDue = { _, _ in reconnectFired.signal() }

        DispatchQueue.main.async(qos: .userInitiated) {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(mainEntered.wait(timeout: .now() + 1) == .success)

        runtime.scheduleReconnect(after: 0.05, attempt: 2)
        #expect(reconnectFired.wait(timeout: .now() + 1) == .success)

        releaseMain.signal()
        runtime.cancelReconnect()
    }

    @Test(
        "pre-auth watchdog timer cancels connection and frees slot while MainActor is blocked",
        .disabled(if: !runMainActorStallTests)
    )
    func preAuthWatchdogCancelsConnectionWhileMainActorBlocked() throws {
        let queue = DispatchQueue(
            label: "PRC-PhotoBooth.Tests.PreAuthWatchdogRuntime",
            qos: .userInitiated
        )
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        let timeoutFired = DispatchSemaphore(value: 0)

        runtime.onPreAuthTimeout = { _, _, _ in
            timeoutFired.signal()
        }

        let connection = NWConnection(host: "127.0.0.1", port: 65432, using: .tcp)
        connection.start(queue: queue)

        runtime.bindControlConnection(connection, generation: 1, authenticated: false)
        #expect(runtime.isControlConnectionActive(generation: 1))
        #expect(!runtime.isControlSlotAvailable())

        let watchdog = BoothPreAuthWatchdog(generation: 1, helloTimeout: 0.05)

        DispatchQueue.main.async(qos: .userInitiated) {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(mainEntered.wait(timeout: .now() + 1) == .success)

        runtime.startPreAuthWatchdog(connection: connection, generation: 1, watchdog: watchdog)

        #expect(timeoutFired.wait(timeout: .now() + 2) == .success)
        #expect(runtime.isControlSlotAvailable())
        #expect(!runtime.isControlConnectionActive(generation: 1))

        releaseMain.signal()
        runtime.stopPreAuthWatchdog()
        connection.cancel()
    }


    @Test("runtime cleanup is safe from its own queue")
    func runtimeCleanupDoesNotDeadlock() {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.RuntimeCleanup")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let completed = DispatchSemaphore(value: 0)

        queue.async {
            runtime.cancelReconnect()
            runtime.stopHeartbeat()
            completed.signal()
        }

        #expect(completed.wait(timeout: .now() + 1) == .success)
        runtime.cancelReconnect()
    }

    @Test("control writer accepts work from its own queue")
    func controlWriterCanEnqueueFromItsOwnQueue() {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ControlWriterReentry")
        let writer = BoothControlWritePump(queue: queue, secureChannel: BoothSecureChannel())
        let completed = DispatchSemaphore(value: 0)

        queue.async {
            writer.enqueue(
                .heartbeat,
                connection: nil,
                generation: 1,
                secure: false,
                completion: nil
            )
            completed.signal()
        }

        #expect(completed.wait(timeout: .now() + 1) == .success)
    }

    @Test("transport timer callbacks hop from their queue to MainActor")
    func transportTimerCallbackUsesMainActor() async {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TransportTimer")
        let ranOnMainThread = await withCheckedContinuation { continuation in
            let callback = BoothTransportTimerDispatch.onMainActor {
                continuation.resume(returning: Thread.isMainThread)
            }
            queue.async(execute: callback)
        }
        #expect(ranOnMainThread)
    }

    @Test("stopping the control core releases its authenticated socket")
    func stoppingControlCoreDisconnectsRuntimeOwnedPeer() {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ForgetControl")
        let runtime = BoothNetworkTransportRuntime(queue: queue)
        let connection = NWConnection(host: "127.0.0.1", port: 58500, using: .tcp)
        runtime.bindControlConnection(connection, generation: 1, authenticated: true)

        #expect(runtime.isControlConnectionActive(generation: 1))
        runtime.stopControlCore()
        #expect(!runtime.isControlConnectionActive(generation: 1))
        #expect(runtime.isControlSlotAvailable())
    }

    @Test(
        "authenticated control traffic remains live during a real 12-second MainActor stall",
        .disabled(if: !runMainActorStallTests)
    )
    func authenticatedControlTrafficSurvivesTwelveSecondMainActorStall() async throws {
        let sessionID = "main-actor-stall"
        let secret = Data(repeating: 0xA5, count: 32)
        let macHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x01, count: 32),
            senderRole: .mac,
            senderDeviceID: "mac",
            receiverDeviceID: "ipad"
        )
        let iPadHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x02, count: 32),
            senderRole: .iPad,
            senderDeviceID: "ipad",
            receiverDeviceID: "mac"
        )
        let macChannel = BoothSecureChannel()
        let iPadChannel = BoothSecureChannel()
        try macChannel.configure(secret: secret, localHello: macHello, peerHello: iPadHello)
        try iPadChannel.configure(secret: secret, localHello: iPadHello, peerHello: macHello)

        let server = try TransportLivenessServer(secureChannel: macChannel)
        let deliveryConsumer = Task { @MainActor in
            for await event in server.controlEvents.stream {
                if case let .directControlFrames(_, frames) = event {
                    server.recordDelivered(frames)
                }
            }
        }
        defer { deliveryConsumer.cancel() }
        let port = try await server.start()
        let clientQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TransportLivenessClient")
        let clientConnection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let clientPump = BoothControlWritePump(queue: clientQueue, secureChannel: iPadChannel)
        let clientReady = DispatchSemaphore(value: 0)
        clientConnection.stateUpdateHandler = { state in
            if case .ready = state { clientReady.signal() }
        }
        clientConnection.start(queue: clientQueue)
        drainConnection(clientConnection)
        defer {
            clientPump.invalidate(generation: 2)
            clientConnection.cancel()
            server.stop()
        }

        #expect(waitForSemaphore(clientReady, timeout: 5))
        clientPump.bind(clientConnection, generation: 1)
        #expect(server.waitForConnection(timeout: 5))

        let traffic = DispatchSource.makeTimerSource(queue: clientQueue)
        let expectedMessages = TransportLivenessMessageRecorder()
        var sequence = 0
        traffic.schedule(deadline: .now() + 0.1, repeating: 0.1)
        traffic.setEventHandler {
            let message: Message
            if sequence % 5 == 0 {
                message = .heartbeat
            } else {
                message = .boothPaused(isPaused: sequence % 2 == 0)
            }
            expectedMessages.append(message)
            sequence += 1
            _ = clientPump.enqueue(
                message,
                connection: clientConnection,
                generation: 1,
                secure: true,
                completion: nil
            )
        }
        traffic.resume()

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer { releaseMain.signal() }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))

        let stallStartedAt = Date()
        try await Task.sleep(for: .seconds(12))
        let stallDuration = Date().timeIntervalSince(stallStartedAt)
        #expect(stallDuration >= 11.5)
        traffic.cancel()
        clientQueue.sync {}
        await server.waitForActivityToSettle()
        let stalledSnapshot = server.snapshot()
        #expect(stalledSnapshot.activityCount >= 20)
        #expect(stalledSnapshot.timeoutCount == 0)
        #expect(stalledSnapshot.transportClosedCount == 0)

        releaseMain.signal()
        try await Task.sleep(for: .milliseconds(350))
        let deliveredSnapshot = server.snapshot()
        #expect(deliveredSnapshot.deliveredFrameCount == stalledSnapshot.activityCount)
        #expect(deliveredSnapshot.deliveredControlMessages == expectedMessages.snapshot())
    }

    @Test("direct authenticated frame overflow closes its socket and suppresses only that generation")
    func directControlEventOverflowClosesSocketAndAllowsReplacementGeneration() async throws {
        let sessionID = "direct-event-overflow"
        let secret = Data(repeating: 0xB6, count: 32)
        let macHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x13, count: 32),
            senderRole: .mac,
            senderDeviceID: "mac",
            receiverDeviceID: "ipad"
        )
        let iPadHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x24, count: 32),
            senderRole: .iPad,
            senderDeviceID: "ipad",
            receiverDeviceID: "mac"
        )
        let macChannel = BoothSecureChannel()
        let iPadChannel = BoothSecureChannel()
        try macChannel.configure(secret: secret, localHello: macHello, peerHello: iPadHello)
        try iPadChannel.configure(secret: secret, localHello: iPadHello, peerHello: macHello)

        let server = try TransportLivenessServer(
            secureChannel: macChannel,
            controlEventBufferLimit: 1
        )
        let port = try await server.start()
        let clientQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.DirectOverflowClient")
        let clientConnection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let clientPump = BoothControlWritePump(queue: clientQueue, secureChannel: iPadChannel)
        let clientReady = DispatchSemaphore(value: 0)
        clientConnection.stateUpdateHandler = { state in
            if case .ready = state { clientReady.signal() }
        }
        clientConnection.start(queue: clientQueue)
        drainConnection(clientConnection)
        defer {
            clientPump.invalidate(generation: 2)
            clientConnection.cancel()
            server.stop()
        }

        #expect(waitForSemaphore(clientReady, timeout: 5))
        clientPump.bind(clientConnection, generation: 1)
        #expect(server.waitForConnection(timeout: 5))
        for isPaused in [true, false, true] {
            _ = clientPump.enqueue(
                .boothPaused(isPaused: isPaused),
                connection: clientConnection,
                generation: 1,
                secure: true,
                completion: nil
            )
        }

        #expect(server.observerWaitForOverflow())
        #expect(server.waitForTransportClose())
        let closedSnapshot = server.snapshot()
        #expect(closedSnapshot.overflowCount == 1)
        #expect(closedSnapshot.transportClosedCount == 1)

        var iterator = server.controlEvents.stream.makeAsyncIterator()
        guard case let .directControlFrames(oldGeneration, oldFrames)? = await iterator.next() else {
            Issue.record("Expected the buffered frame from the failed connection generation")
            return
        }
        #expect(oldGeneration == 1)
        #expect(server.controlEvents.isDirectEventSuppressed(oldGeneration))
        #expect(oldFrames.compactMap { frame -> Message? in
            guard case let .control(message) = frame else { return nil }
            return message
        } == [.boothPaused(isPaused: true)])

        let replacementFrames: [BoothDecodedTransportFrame] = [.control(.boothPaused(isPaused: false))]
        #expect(server.controlEvents.yield(.directControlFrames(generation: 2, frames: replacementFrames)))
        #expect(!server.controlEvents.isDirectEventSuppressed(2))
        guard case let .directControlFrames(newGeneration, newFrames)? = await iterator.next() else {
            Issue.record("Expected the replacement generation event to be delivered")
            return
        }
        server.recordDelivered(newFrames)
        #expect(newGeneration == 2)
        #expect(newFrames.compactMap { frame -> Message? in
            guard case let .control(message) = frame else { return nil }
            return message
        } == [.boothPaused(isPaused: false)])
        #expect(server.snapshot().deliveredControlMessages == [.boothPaused(isPaused: false)])
        server.controlEvents.finish()
    }

    @Test(
        "control closure is observed and reconnect stays single during a MainActor stall",
        .disabled(if: !runMainActorStallTests)
    )
    func controlFailureDuringMainActorStallSchedulesOneReconnect() async throws {
        let sessionID = "main-actor-failure-stall"
        let secret = Data(repeating: 0x5A, count: 32)
        let macHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x03, count: 32),
            senderRole: .mac,
            senderDeviceID: "mac",
            receiverDeviceID: "ipad"
        )
        let iPadHello = BoothSecureChannelHello(
            sessionID: sessionID,
            challenge: Data(repeating: 0x04, count: 32),
            senderRole: .iPad,
            senderDeviceID: "ipad",
            receiverDeviceID: "mac"
        )
        let macChannel = BoothSecureChannel()
        let iPadChannel = BoothSecureChannel()
        try macChannel.configure(secret: secret, localHello: macHello, peerHello: iPadHello)
        try iPadChannel.configure(secret: secret, localHello: iPadHello, peerHello: macHello)

        let server = try TransportLivenessServer(
            secureChannel: macChannel,
            scheduleReconnectOnClose: true
        )
        let port = try await server.start()
        let clientQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TransportFailureClient")
        let clientConnection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let clientPump = BoothControlWritePump(queue: clientQueue, secureChannel: iPadChannel)
        let clientReady = DispatchSemaphore(value: 0)
        clientConnection.stateUpdateHandler = { state in
            if case .ready = state { clientReady.signal() }
        }
        clientConnection.start(queue: clientQueue)
        drainConnection(clientConnection)
        defer {
            clientPump.invalidate(generation: 2)
            clientConnection.cancel()
            server.stop()
        }

        #expect(waitForSemaphore(clientReady, timeout: 5))
        clientPump.bind(clientConnection, generation: 1)
        #expect(server.waitForConnection(timeout: 5))

        let traffic = DispatchSource.makeTimerSource(queue: clientQueue)
        traffic.schedule(deadline: .now() + 0.1, repeating: 0.1)
        traffic.setEventHandler {
            _ = clientPump.enqueue(
                .heartbeat,
                connection: clientConnection,
                generation: 1,
                secure: true,
                completion: nil
            )
        }
        traffic.resume()

        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        defer { releaseMain.signal() }
        DispatchQueue.main.async {
            mainEntered.signal()
            releaseMain.wait()
        }
        #expect(waitForSemaphore(mainEntered))

        try await Task.sleep(for: .seconds(1))
        server.terminateConnection()
        for _ in 0..<20 where server.snapshot().transportClosedCount == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        for _ in 0..<40 where server.snapshot().reconnectDueCount == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let stalledSnapshot = server.snapshot()
        #expect(stalledSnapshot.transportClosedCount >= 1)
        #expect(stalledSnapshot.closeDeliveredCount == 0)
        #expect(stalledSnapshot.reconnectDueCount == 1)

        traffic.cancel()
        try await Task.sleep(for: .seconds(11))
        releaseMain.signal()
        try await Task.sleep(for: .milliseconds(250))
        #expect(server.snapshot().closeDeliveredCount >= 1)
    }

    @Test("release gate: 500 loopback transport sessions")
    @MainActor
    func loopbackTransportFiveHundredSessionSoak() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRC-TransportSoak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jobStore = JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json"))
        var sessionGate = SessionMessageGate()
        var callbackGate = BoothTransportCallbackGate()

        for index in 0..<500 {
            let sessionID = "soak-session-\(index)"
            let photoCount = [1, 4, 8][index % 3]
            let messages = soakMessages(sessionID: sessionID, photoCount: photoCount, index: index)
            let secret = Data(repeating: UInt8((index % 251) + 1), count: 32)
            let macHello = BoothSecureChannelHello(
                sessionID: sessionID,
                challenge: Data(repeating: UInt8((index % 31) + 1), count: 32),
                senderRole: .mac,
                senderDeviceID: "mac",
                receiverDeviceID: "ipad"
            )
            let iPadHello = BoothSecureChannelHello(
                sessionID: sessionID,
                challenge: Data(repeating: UInt8((index % 29) + 2), count: 32),
                senderRole: .iPad,
                senderDeviceID: "ipad",
                receiverDeviceID: "mac"
            )
            let macChannel = BoothSecureChannel()
            let iPadChannel = BoothSecureChannel()
            try macChannel.configure(secret: secret, localHello: macHello, peerHello: iPadHello)
            try iPadChannel.configure(secret: secret, localHello: iPadHello, peerHello: macHello)

            do {
                let (server, port) = try await startControlStressServer(
                    expected: messages,
                    secureChannel: macChannel
                )
                let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TransportSoak.\(index)")
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: .any
                )
                let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
                let pump = BoothControlWritePump(queue: queue, secureChannel: iPadChannel)
                let connectionLifetime = ControlStressConnectionLifetime()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connectionLifetime.didBecomeReady()
                    case .failed(let error):
                        connectionLifetime.didFail(error)
                        pump.invalidate(generation: index + 2)
                    case .waiting(let error):
                        connectionLifetime.didWait(error)
                    case .cancelled:
                        connectionLifetime.didClose()
                    default:
                        break
                    }
                }
                pump.bind(connection, generation: index + 1)
                connection.start(queue: queue)
                defer {
                    pump.invalidate(generation: index + 2)
                    connectionLifetime.cancelIfNeeded(connection)
                    server.stop()
                }
                try connectionLifetime.waitUntilReady(sessionID: sessionID)

                for (messageIndex, message) in messages.enumerated() {
                    let outcome = await withCheckedContinuation { continuation in
                        let waiter = ControlStressSendWaiter(continuation)
                        waiter.scheduleTimeout(on: queue)
                        _ = pump.enqueue(
                            message,
                            connection: connection,
                            generation: index + 1,
                            secure: true,
                            completion: { outcome in waiter.finish(outcome) }
                        )
                    }
                    guard outcome == .sent else {
                        throw ControlStressError.sendFailed(
                            sessionID: sessionID,
                            messageIndex: messageIndex,
                            outcome: outcome
                        )
                    }
                }
                try await server.wait()
                #expect(pump.pendingMessageCount == 0)
                #expect(pump.pendingByteCount == 0)
                await connectionLifetime.cancel(connection)
                await server.stopAndWait()
            }

            sessionGate.synchronize(sessionID: sessionID, sequence: 0, authorityEpoch: testAuthorityEpoch)
            let actionCount = index.isMultiple(of: 7) ? 2 : 1
            for sequence in 1...actionCount {
                let accepted = sessionGate.accept(
                    SessionMessageContext(sessionID: sessionID, sequence: UInt64(sequence), authorityEpoch: testAuthorityEpoch)
                )
                #expect(accepted)
            }
            let rejected = sessionGate.accept(SessionMessageContext(
                sessionID: "stale-session",
                sequence: UInt64.max,
                authorityEpoch: testAuthorityEpoch
            ))
            #expect(!rejected)

            let assetData = Data(repeating: UInt8(index % 239), count: 4096 + photoCount)
            let assetReference = BoothAssetReference(
                assetID: "review-\(sessionID)",
                sessionID: sessionID,
                revision: "1",
                kind: .reviewImage,
                byteCount: assetData.count,
                sha256: Data(SHA256.hash(data: assetData))
            )
            let chunks = try BoothAssetTransfer.chunks(
                data: assetData,
                reference: assetReference,
                chunkSize: 1024
            )
            var assembler = BoothAssetAssembler()
            var assembled: Data?
            for chunk in chunks.reversed() {
                if let result = try assembler.append(chunk) { assembled = result.1 }
            }
            #expect(assembled == assetData)

            if index == 97 {
                var corruptedAssembler = BoothAssetAssembler()
                let corruptedChunks = chunks.enumerated().map { offset, chunk in
                    guard offset == 0 else { return chunk }
                    return BoothAssetChunk(metadata: chunk.metadata, data: Data(repeating: 0xFF, count: chunk.data.count))
                }
                var sawHashMismatch = false
                do {
                    for chunk in corruptedChunks { _ = try corruptedAssembler.append(chunk) }
                } catch let error as BoothAssetTransferError {
                    sawHashMismatch = error == .hashMismatch
                }
                #expect(sawHashMismatch)
            }

            if index == 173 {
                let oldGeneration = callbackGate.generation
                callbackGate.invalidate()
                #expect(!callbackGate.accepts(oldGeneration))
            }

            let job = try await jobStore.enqueue(sessionID: sessionID, kind: .renderStrip)
            var finished = job
            finished.status = .succeeded
            finished.updatedAt = Date()
            try await jobStore.update(finished)
        }

        let persisted = await jobStore.snapshot()
        #expect(persisted.count == 500)
        #expect(persisted.allSatisfy { $0.status == .succeeded })
        #expect(sessionGate.currentSessionID == "soak-session-499")
        #expect(sessionGate.latestAcceptedSequence > 0)
    }

    @Test("Wi-Fi preference never selects LAN")
    func wifiPreferenceWins() {
        var route = BoothNetworkRouteMachine(preference: .wifi)

        let command = route.start(lanAvailable: true, wifiAvailable: true)

        #expect(command == .startWiFi(fallback: false))
        #expect(route.state == .connectingWiFi)
    }

    @Test("LAN preference uses LAN after a valid handshake")
    func lanHandshakeConnects() {
        var route = BoothNetworkRouteMachine(preference: .lan)

        #expect(route.start(lanAvailable: true, wifiAvailable: true) == .startLAN)
        #expect(route.lanHandshakeSucceeded(peer: "iPad") == .none)
        #expect(route.state == .connectedLAN(peer: "iPad"))
        #expect(route.effectiveTransport == .lan)
    }

    @Test("LAN-unavailable falls back to Wi-Fi")
    func unavailableLANFallsBack() {
        var route = BoothNetworkRouteMachine(preference: .lan)

        let command = route.start(lanAvailable: false, wifiAvailable: true)

        #expect(command == .startWiFi(fallback: true))
        #expect(route.state == .connectingWiFi)
    }

    @Test("LAN handshake timeout falls back to Wi-Fi")
    func handshakeTimeoutFallsBack() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)

        let command = route.lanHandshakeTimedOut(wifiAvailable: true)

        #expect(command == .startWiFi(fallback: true))
        #expect(route.state == .connectingWiFi)
    }

    @Test("Initial Ethernet path false does not abort a probing LAN attempt")
    func initialEthernetFalseKeepsLANProbeAlive() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)

        #expect(route.lanPathChanged(isAvailable: false, wifiAvailable: true) == .none)
        #expect(route.state == .connectingLAN)
    }

    @Test("Delayed Ethernet availability can complete the LAN handshake")
    func delayedEthernetAvailabilityCompletesHandshake() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)

        #expect(route.lanPathChanged(isAvailable: false, wifiAvailable: true) == .none)
        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true) == .none)
        _ = route.lanHandshakeSucceeded(peer: "iPad")

        #expect(route.state == .connectedLAN(peer: "iPad"))
    }

    @Test("Established Ethernet loss falls back to Wi-Fi")
    func establishedEthernetLossFallsBack() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)
        _ = route.lanHandshakeSucceeded(peer: "iPad")

        #expect(route.lanPathChanged(isAvailable: false, wifiAvailable: true) == .startWiFi(fallback: true))
        #expect(route.state == .connectingWiFi)
    }

    @Test("No LAN and no Wi-Fi becomes unavailable")
    func noNetworkIsUnavailable() {
        var route = BoothNetworkRouteMachine(preference: .lan)

        let command = route.start(lanAvailable: false, wifiAvailable: false)

        #expect(command == .unavailable)
        #expect(route.state == .disconnected)
        #expect(route.effectiveTransport == .unavailable)
    }

    @Test("LAN return after total loss restarts the preferred route")
    func totalNetworkLossRecoversLAN() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: false)

        let command = route.lanPathChanged(isAvailable: true, wifiAvailable: false)

        #expect(command == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("Wi-Fi return after total loss restarts the preferred route")
    func totalNetworkLossRecoversWiFi() {
        var route = BoothNetworkRouteMachine(preference: .wifi)
        _ = route.start(lanAvailable: false, wifiAvailable: false)

        let command = route.wifiPathChanged(isAvailable: true, lanAvailable: false)

        #expect(command == .startWiFi(fallback: false))
        #expect(route.state == .connectingWiFi)
    }

    @Test("Wi-Fi return after total loss uses fallback for LAN preference")
    func totalNetworkLossRecoversWiFiFallback() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: false)

        let command = route.wifiPathChanged(isAvailable: true, lanAvailable: false)

        #expect(command == .startWiFi(fallback: true))
        #expect(route.state == .connectingWiFi)
    }

    @Test("LAN wins when both paths return")
    func bothPathsReturningPreferLAN() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: false)

        let wifiCommand = route.wifiPathChanged(isAvailable: true, lanAvailable: true)
        let lanCommand = route.lanPathChanged(isAvailable: true, wifiAvailable: true)

        #expect(wifiCommand == .none)
        #expect(lanCommand == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("Rapid LAN availability flaps do not restart an active LAN probe")
    func rapidLANAvailabilityFlapsDoNotStorm() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: false)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: false) == .startLAN)
        #expect(route.lanPathChanged(isAvailable: false, wifiAvailable: false) == .none)
        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: false) == .none)
        #expect(route.state == .connectingLAN)
    }

    @Test("Healthy Wi-Fi fallback recovers LAN while the booth is idle")
    func fallbackRecoversLANWhenIdle() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true, boothIsIdle: true) == .startLAN)
        #expect(route.state == .connectingLAN)
        #expect(route.transportDisconnected(lanAvailable: true, wifiAvailable: true) == .startLAN)
    }

    @Test("LAN return during capture remains on Wi-Fi until idle")
    func fallbackDefersLANRecoveryDuringCapture() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true, boothIsIdle: false) == .none)
        #expect(route.state == .fallbackWiFi(peer: "iPad"))
        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true, boothIsIdle: true) == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("LAN recovery command is emitted once after the route starts")
    func fallbackRecoveryDoesNotFlap() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true) == .startLAN)
        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true) == .none)
    }

    @Test("Wi-Fi loss stays unavailable when Wi-Fi is selected")
    func selectedWiFiLossDoesNotSwitchToLAN() {
        var route = BoothNetworkRouteMachine(preference: .wifi)
        _ = route.start(lanAvailable: true, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: false)

        let command = route.wifiPathChanged(isAvailable: false, lanAvailable: true)

        #expect(command == .unavailable)
        #expect(route.state == .disconnected)
    }

    @Test("Wi-Fi fallback loss retries available LAN")
    func fallbackWiFiLossRetriesLAN() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        let command = route.wifiPathChanged(isAvailable: false, lanAvailable: true)

        #expect(command == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("Wi-Fi fallback loss becomes unavailable without LAN")
    func fallbackWiFiLossWithoutLANIsUnavailable() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        let command = route.wifiPathChanged(isAvailable: false, lanAvailable: false)

        #expect(command == .unavailable)
        #expect(route.state == .disconnected)
    }

    @Test("Manual LAN retry starts from a healthy Wi-Fi fallback")
    func manualLANRetryStartsFromFallback() {
        var route = fallbackLANRoute()

        #expect(route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: true) == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("Manual LAN retry waits until the booth is idle")
    func manualLANRetryIsBlockedDuringCapture() {
        var route = fallbackLANRoute()

        #expect(route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: false) == .none)
        #expect(route.state == .fallbackWiFi(peer: "iPad"))
    }

    @Test("Manual LAN retry ignores a false wired path-monitor sample")
    func manualLANRetryIgnoresFalseMonitorState() {
        var route = fallbackLANRoute()

        #expect(route.manualPreferredLANRetry(lanAvailable: false, wifiAvailable: true, boothIsIdle: true) == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("Manual LAN retry does not override Wi-Fi preference")
    func manualLANRetryRespectsWiFiPreference() {
        var route = BoothNetworkRouteMachine(preference: .wifi)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: false)

        #expect(route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: true) == .none)
        #expect(route.state == .connectedWiFi(peer: "iPad"))
    }

    @Test("Manual LAN retry does not restart an active LAN route")
    func manualLANRetryRequiresFallback() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)
        _ = route.lanHandshakeSucceeded(peer: "iPad")

        #expect(route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: true) == .none)
        #expect(route.state == .connectedLAN(peer: "iPad"))
    }

    @Test("Failed manual LAN handshake returns to Wi-Fi fallback")
    func failedManualLANRetryFallsBack() {
        var route = fallbackLANRoute()
        _ = route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: true)

        #expect(route.lanHandshakeTimedOut(wifiAvailable: true) == .startWiFi(fallback: true))
        #expect(route.state == .connectingWiFi)
        #expect(route.preference == .lan)
    }

    @Test("Successful manual LAN handshake reaches connected LAN")
    func successfulManualLANRetryConnects() {
        var route = fallbackLANRoute()
        _ = route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: true)

        #expect(route.lanHandshakeSucceeded(peer: "iPad") == .none)
        #expect(route.state == .connectedLAN(peer: "iPad"))
        #expect(route.preference == .lan)
    }

    @Test("Repeated manual LAN retry emits one start command")
    func repeatedManualLANRetryDoesNotDuplicateTransport() {
        var route = fallbackLANRoute()

        #expect(route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: true) == .startLAN)
        #expect(route.manualPreferredLANRetry(lanAvailable: true, wifiAvailable: true, boothIsIdle: true) == .none)
    }
}

private func fallbackLANRoute() -> BoothNetworkRouteMachine {
    var route = BoothNetworkRouteMachine(preference: .lan)
    _ = route.start(lanAvailable: false, wifiAvailable: true)
    _ = route.wifiConnected(peer: "iPad", fallback: true)
    return route
}

@Suite("iPad route discovery policy")
struct RouteDiscoveryPolicyTests {
    @Test("Wi-Fi preference uses one local Bonjour discovery plan")
    func wifiDiscoveryPlanIsSingleBrowser() {
        #expect(
            BoothRouteDiscoveryPlan(preference: .wifi).mechanisms
                == [.wifiBonjour]
        )
    }

    @Test("LAN preference keeps wired Bonjour ahead of Wi-Fi fallback")
    func lanDiscoveryPlanKeepsWiredFirst() {
        #expect(
            BoothRouteDiscoveryPlan(preference: .lan).mechanisms
                == [.wiredEthernetBonjour, .wiredEthernetCompatibilityBonjour, .wifiBonjour]
        )
    }

    @Test("Bonjour service identity survives an optional TXT record")
    func bonjourServiceIdentityParsesStableDeviceID() {
        let deviceID = "D2C8B2B7-2B1C-4A84-A4D5-2F7AABED5E19"

        let control = BoothBonjourServiceIdentity.parse(
            "PRC PhotoBooth Control \(deviceID)"
        )
        let preview = BoothBonjourServiceIdentity.parse(
            "PRC PhotoBooth Preview \(deviceID)"
        )
        let asset = BoothBonjourServiceIdentity.parse(
            "PRC PhotoBooth Asset \(deviceID) (2)"
        )

        #expect(control == BoothBonjourServiceIdentity(channel: .control, deviceID: deviceID))
        #expect(preview?.channel == .preview)
        #expect(asset == BoothBonjourServiceIdentity(channel: .asset, deviceID: deviceID))
        #expect(BoothBonjourServiceIdentity.parse("Unrelated Service") == nil)
        #expect(BoothBonjourServiceIdentity.parse("PRC PhotoBooth Control \(deviceID.prefix(8))") == nil)
        #expect(BoothBonjourServiceIdentity.parse("PRC PhotoBooth Control foo-\(deviceID)-bar") == nil)
    }

    @Test("route discovery gives preferred Ethernet two seconds before fallback")
    @MainActor
    func routeDiscoveryGraceIsTwoSeconds() {
        #expect(NetworkBoothTransport.routeDiscoveryGracePeriod == 2.0)
    }

    @Test("LAN preference waits for LAN when Wi-Fi is discovered first")
    func lanPreferenceWaitsForLAN() {
        var selection = BoothRouteDiscoverySelection()

        let waiting = selection.consider(.wifi, preferredPreference: .lan)
        let accepted = selection.consider(.wiredEthernet, preferredPreference: .lan)

        #expect(waiting == .waitingForPreferredInterface)
        #expect(accepted == .accepted)
        #expect(selection.selectedInterface == .wiredEthernet)
    }

    @Test("LAN preference promotes Wi-Fi only after LAN grace expires")
    func lanPreferenceFallsBackToPendingWiFi() {
        var selection = BoothRouteDiscoverySelection()

        let waiting = selection.consider(.wifi, preferredPreference: .lan)
        let promoted = selection.promotePending()

        #expect(waiting == .waitingForPreferredInterface)
        #expect(promoted == .wifi)
        #expect(selection.selectedInterface == .wifi)
    }

    @Test("Wi-Fi preference wins when both interfaces are discovered")
    func wifiPreferenceWins() {
        var selection = BoothRouteDiscoverySelection()

        let waiting = selection.consider(.wiredEthernet, preferredPreference: .wifi)
        let accepted = selection.consider(.wifi, preferredPreference: .wifi)

        #expect(waiting == .waitingForPreferredInterface)
        #expect(accepted == .accepted)
        #expect(selection.selectedInterface == .wifi)
    }

    @Test("Local preference remains authoritative over a Mac advertisement")
    func advertisedPreferenceDoesNotOverrideLocalChoice() {
        var selection = BoothRouteDiscoverySelection()

        let accepted = selection.consider(
            .wifi,
            preferredPreference: .wifi,
            advertisedPreference: .lan
        )
        let ignored = selection.consider(
            .wiredEthernet,
            preferredPreference: .wifi,
            advertisedPreference: .lan
        )

        #expect(accepted == .accepted)
        #expect(ignored == .ignored)
        #expect(selection.selectedInterface == .wifi)
    }

    @Test("A LAN advertisement does not make Wi-Fi wait for LAN")
    func advertisedLANDoesNotDelayWiFi() {
        var selection = BoothRouteDiscoverySelection()

        #expect(selection.consider(
            .wifi,
            preferredPreference: .wifi,
            advertisedPreference: .lan
        ) == .accepted)
        #expect(selection.promotePending() == nil)
    }

    @Test("Discovery ensure reuses the active browser for a new target")
    func ensureReusesMatchingAttempt() {
        #expect(
            BoothRouteDiscoveryPolicy.decision(
                targetPeerID: "mac-1",
                requestedPreference: .wifi,
                activeTargetPeerID: "mac-1",
                activePreference: .wifi,
                hasActiveDiscovery: true,
                hasActiveControlAttempt: false
            ) == .reuse
        )
        #expect(
            BoothRouteDiscoveryPolicy.decision(
                targetPeerID: "mac-2",
                requestedPreference: .wifi,
                activeTargetPeerID: "mac-1",
                activePreference: .wifi,
                hasActiveDiscovery: true,
                hasActiveControlAttempt: false
            ) == .reuse
        )
        #expect(
            BoothRouteDiscoveryPolicy.decision(
                targetPeerID: "mac-1",
                requestedPreference: .lan,
                activeTargetPeerID: "mac-1",
                activePreference: .wifi,
                hasActiveDiscovery: true,
                hasActiveControlAttempt: false
            ) == .restart
        )
        #expect(
            BoothRouteDiscoveryPolicy.decision(
                targetPeerID: "mac-1",
                requestedPreference: .wifi,
                activeTargetPeerID: "mac-1",
                activePreference: .wifi,
                hasActiveDiscovery: false,
                hasActiveControlAttempt: true
            ) == .reuse
        )
        #expect(
            BoothRouteDiscoveryPolicy.decision(
                targetPeerID: "mac-1",
                requestedPreference: .wifi,
                activeTargetPeerID: "mac-1",
                activePreference: .wifi,
                hasActiveDiscovery: false,
                hasActiveControlAttempt: false
            ) == .restart
        )
    }

    @Test("Route candidate provenance keeps constrained and compatibility paths distinct")
    func routeCandidateProvenanceIsExplicit() {
        #expect(
            BoothRouteCandidatePolicy.discoveryProvenance(
                interface: .wifi,
                isLANCompatibilityFallback: false
            ) == .localNetworkBonjour
        )
        #expect(
            BoothRouteCandidatePolicy.discoveryProvenance(
                interface: .wiredEthernet,
                isLANCompatibilityFallback: false
            ) == .ethernetConstrainedBonjour
        )
        #expect(
            BoothRouteCandidatePolicy.discoveryProvenance(
                interface: .wiredEthernet,
                isLANCompatibilityFallback: true
            ) == .ethernetCompatibilityBonjour
        )
        #expect(
            BoothRouteCandidatePolicy.shouldRejectNonEthernetPath(
                provenance: .ethernetConstrainedBonjour
            )
        )
        #expect(
            BoothRouteCandidatePolicy.shouldRejectNonEthernetPath(
                provenance: .ethernetCompatibilityBonjour
            )
        )
        #expect(
            !BoothRouteCandidatePolicy.shouldRejectNonEthernetPath(
                provenance: .directStaticLAN
            )
        )
        #expect(
            BoothRouteCandidateProvenance.ethernetCompatibilityBonjour.interface
                == .wiredEthernet
        )
    }

    @Test("Reset permits a new discovery cycle")
    func resetPermitsNewSelection() {
        var selection = BoothRouteDiscoverySelection()
        _ = selection.consider(.wifi, preferredPreference: .wifi)

        selection.reset()

        #expect(selection.selectedInterface == nil)
        #expect(selection.pendingInterface == nil)
        let accepted = selection.consider(.wiredEthernet, preferredPreference: .lan)

        #expect(accepted == .accepted)
        #expect(selection.selectedInterface == .wiredEthernet)
    }
}

@Suite("Ethernet diagnostics")
@MainActor
struct EthernetDiagnosticsTests {
    @Test("Ethernet probe does not change the requested route")
    func probeIsNonDestructive() async {
        let status = BoothConnectionStatus(requestedNetwork: .wifi)
        let transport = NetworkBoothTransport(
            role: .mac,
            networkPreference: .wifi,
            connectionStatus: status
        )

        let result = await transport.probeEthernet()

        #expect(transport.requestedNetworkPreference == .wifi)
        #expect(!result.interfaceAvailable)
        #expect(!result.peerDiscovered)
        #expect(!result.controlConnected)
        #expect(!result.handshakeSucceeded)
        #expect(!result.previewConnected)
        #expect(result.error != nil)
    }
}

@Suite("Transport callback policy")
struct TransportCallbackPolicyTests {
    @Test("Callback from previous transport generation is ignored")
    func staleCallbackIsIgnored() {
        var gate = BoothTransportCallbackGate()
        let connectionAGeneration = gate.generation

        gate.invalidate()

        #expect(!gate.accepts(connectionAGeneration))
        #expect(gate.accepts(gate.generation))
    }

    @Test("Discovery callback from a previous generation is ignored")
    func staleDiscoveryCallbackIsIgnored() {
        var gate = BoothRouteDiscoveryGenerationGate()
        let oldGeneration = gate.begin()
        let currentGeneration = gate.begin()

        #expect(!gate.accepts(oldGeneration))
        #expect(gate.accepts(currentGeneration))
    }
}

@Suite("Preview channel identity")
struct PreviewChannelIdentityTests {
    @Test("preview channel must match the verified control peer")
    func matchesControlPeer() {
        #expect(comparePreviewPeerWithControlPeer(
            previewPeerID: "peer",
            controlPeerID: "peer"
        ) == .matched)
        #expect(comparePreviewPeerWithControlPeer(
            previewPeerID: "stale-peer",
            controlPeerID: "peer"
        ) == .mismatched)
        #expect(comparePreviewPeerWithControlPeer(
            previewPeerID: nil,
            controlPeerID: "peer"
        ) == .awaitingHello)
        #expect(comparePreviewPeerWithControlPeer(
            previewPeerID: "peer",
            controlPeerID: nil
        ) == .mismatched)
    }
}

@Suite("Transport recovery policy")
struct TransportRecoveryPolicyTests {
    private func reference(_ index: Int) -> BoothAssetReference {
        BoothAssetReference(
            assetID: "asset-\(index)",
            sessionID: "session",
            revision: "revision-\(index)",
            kind: .reviewImage,
            byteCount: 1,
            sha256: Data([UInt8(index)])
        )
    }

    @Test("Asset request pump drains ordered references beyond one batch")
    func assetRequestsDrain() {
        let expected = (0..<20).map(reference)
        var pump = BoothAssetRequestPump(maximumInFlight: 8)

        let first = pump.nextBatch(expected: expected, cached: [])
        #expect(first == Array(expected.prefix(8)))
        #expect(pump.nextBatch(expected: expected, cached: []).isEmpty)

        pump.markCompleted(first[0])
        pump.markUnavailable(first[1])
        let second = pump.nextBatch(expected: expected, cached: [expected[0]])
        #expect(second == [expected[8], expected[9]])

        pump.clearInFlight()
        let afterReconnect = pump.nextBatch(
            expected: expected,
            cached: Set([expected[0], expected[8], expected[9]])
        )
        #expect(afterReconnect == Array(expected[2...7]) + [expected[10], expected[11]])
    }

    @Test("Asset request pump has no hidden total limit")
    func assetRequestsDrainThirtyReferences() {
        let expected = (0..<30).map(reference)
        var pump = BoothAssetRequestPump(maximumInFlight: 8)
        var requested: [BoothAssetReference] = []
        var cached = Set<BoothAssetReference>()

        while requested.count < expected.count {
            let batch = pump.nextBatch(expected: expected, cached: cached)
            requested.append(contentsOf: batch)
            for reference in batch {
                pump.markCompleted(reference)
                cached.insert(reference)
            }
        }

        #expect(requested == expected)
    }

    @Test("Asset request pump respects byte budget")
    func assetRequestsRespectByteBudget() {
        let expected = (0..<4).map { index in
            BoothAssetReference(
                assetID: "large-\(index)",
                sessionID: "session",
                revision: "1",
                kind: .reviewImage,
                byteCount: 8,
                sha256: Data(repeating: UInt8(index), count: 32)
            )
        }
        var pump = BoothAssetRequestPump(maximumInFlight: 8, maximumInFlightBytes: 16)

        let first = pump.nextBatch(expected: expected, cached: [])
        #expect(first == Array(expected.prefix(2)))
        #expect(pump.inFlightBytes == 16)

        pump.markCompleted(first[0])
        let second = pump.nextBatch(expected: expected, cached: [first[0]])
        #expect(second == [expected[2]])
        #expect(pump.inFlightBytes == 16)
    }

    @Test("Failed asset sends release references for bounded retry")
    func failedAssetSendsReleaseReferences() {
        let expected = (0..<2).map(reference)
        var pump = BoothAssetRequestPump(maximumInFlight: 8)
        let batch = pump.nextBatch(expected: expected, cached: [])

        pump.markSendFailed(batch)

        #expect(pump.inFlight.isEmpty)
        #expect(pump.nextBatch(expected: expected, cached: []) == batch)
    }

    @Test("Healthy authenticated control outranks a wired Ethernet path hint")
    func healthyControlIgnoresWiredEthernetPathHint() {
        #expect(
            BoothPathAuthorityPolicy.action(hasAuthenticatedControl: true)
                == .observeOnly
        )
        #expect(
            BoothPathAuthorityPolicy.action(hasAuthenticatedControl: false)
                == .evaluateRoute
        )
    }

    @Test("Verified secondary channels reject unverified candidates")
    func verifiedSecondaryChannelIsProtected() {
        #expect(
            BoothSecondaryChannelAdmissionPolicy.decision(existingVerified: true)
                == .rejectCandidate
        )
        #expect(
            BoothSecondaryChannelAdmissionPolicy.decision(existingVerified: false)
                == .acceptCandidate
        )
    }

    @Test("preview admission protects an active handshake and releases failed or timed-out slots")
    func previewAdmissionCoversHandshakeLifecycle() {
        let deadline = BoothSecondaryChannelAdmissionPolicy.handshakeTimedOut(
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 111.9),
            timeout: 12
        )
        let expired = BoothSecondaryChannelAdmissionPolicy.handshakeTimedOut(
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 112),
            timeout: 12
        )

        #expect(!deadline)
        #expect(expired)
        #expect(BoothSecondaryChannelAdmissionPolicy.decision(existingState: .handshaking) == .rejectCandidate)
        #expect(BoothSecondaryChannelAdmissionPolicy.decision(existingState: .verified) == .rejectCandidate)
        #expect(BoothSecondaryChannelAdmissionPolicy.decision(existingState: .failed) == .acceptCandidate)
        #expect(BoothSecondaryChannelAdmissionPolicy.decision(existingState: .none) == .acceptCandidate)
        #expect(!BoothSecondaryChannelAdmissionPolicy.shouldAdmitPreviewCandidate(
            existingState: .none,
            controlIsAuthenticated: false
        ))
        #expect(BoothSecondaryChannelAdmissionPolicy.shouldAdmitPreviewCandidate(
            existingState: .none,
            controlIsAuthenticated: true
        ))

        for _ in 0..<10_000 {
            #expect(!BoothSecondaryChannelAdmissionPolicy.shouldAdmitPreviewCandidate(
                existingState: .handshaking,
                controlIsAuthenticated: true
            ))
        }
    }

    @Test("preview admission cooldown is bounded and expires for legitimate recovery")
    func previewAdmissionCooldownAllowsRecovery() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: 0) == 0)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: 1) == 1)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: 2) == 2)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: 3) == 4)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: 4) == 8)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: 5) == 16)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: 1_000) == 30)

        let cooldown = now.addingTimeInterval(4)
        #expect(!BoothSecondaryChannelAdmissionPolicy.cooldownExpired(until: cooldown, now: now))
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownExpired(until: cooldown, now: cooldown))
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownExpired(until: nil, now: now))
        #expect(BoothSecondaryChannelAdmissionPolicy.failureCount(
            afterFailureCount: 6,
            lastFailureAt: now.addingTimeInterval(-61),
            now: now
        ) == 0)
        #expect(BoothSecondaryChannelAdmissionPolicy.failureCount(
            afterFailureCount: 6,
            lastFailureAt: now.addingTimeInterval(-59),
            now: now
        ) == 6)

        var failureCount = 0
        var availableAt = now
        for _ in 0..<100 {
            failureCount += 1
            availableAt = availableAt.addingTimeInterval(
                12 + BoothSecondaryChannelAdmissionPolicy.cooldownDuration(afterFailureCount: failureCount)
            )
        }
        let legitimateReconnect = availableAt.addingTimeInterval(0.001)
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownExpired(
            until: availableAt,
            now: legitimateReconnect
        ))

        for candidate in 0..<10_000 {
            #expect(
                !BoothSecondaryChannelAdmissionPolicy.cooldownExpired(
                    until: cooldown,
                    now: now.addingTimeInterval(Double(candidate % 4))
                )
            )
        }
        #expect(BoothSecondaryChannelAdmissionPolicy.cooldownExpired(
            until: cooldown,
            now: now.addingTimeInterval(4)
        ))
    }

    @Test("Waiting recovery deadline remains tied to its connection generation")
    func recoveryDeadlineUsesExactConnectionGeneration() async throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.Recovery")
        let scheduler = BoothConnectionRecoveryScheduler(queue: queue)
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let flag = RecoveryTestFlag()

        scheduler.schedule(
            connection: connection,
            channel: .control,
            generation: 4,
            after: 0.02,
            onDeadline: flag.mark
        )
        scheduler.cancel(connection: connection, channel: .control, generation: 5)
        try await Task.sleep(for: .milliseconds(100))

        #expect(flag.value)
        scheduler.cancelAll()
    }

    @Test("Replaced receive connections cannot reuse a parser or receive loop")
    func receiveConnectionStateIsInvalidated() throws {
        let token = BoothTransportReceiveToken()
        #expect(token.begin())
        #expect(!token.begin())
        token.invalidate()
        #expect(!token.isValid)
        #expect(!token.begin())

        let frame = try BoothFrameEncoder.encode(channel: .heartbeat, payload: Data())
        let oldDecoder = BoothTransportFrameDecoder()
        #expect(try oldDecoder.decode(Data(frame.prefix(4)), channel: .control).isEmpty)

        #expect(throws: BoothFrameError.invalidMessage) {
            try BoothTransportFrameDecoder().decode(frame, channel: .control)
        }
    }

    @Test("Control writer delivers 10,000 ordered secure messages")
    @MainActor
    func controlWritePumpStress() async throws {
        let snapshot = SessionSyncSnapshot(
            config: EventConfig(photoCount: 8),
            sessionID: "control-stress",
            phase: .review(photoIndex: 0),
            presentation: nil,
            isMirrored: false,
            authorityEpoch: testAuthorityEpoch
        )
        let expected: [Message] = (0..<10_000).map { index in
            let context = SessionMessageContext(
                sessionID: "control-stress",
                sequence: UInt64(index + 1),
                authorityEpoch: testAuthorityEpoch
            )
            switch index % 5 {
            case 0:
                return .heartbeat
            case 1:
                return .sessionSync(snapshot: snapshot)
            case 2:
                return .beginCountdown(
                    context: context,
                    deliveryID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", UInt64(index + 10_000)))!,
                    descriptor: CountdownDescriptor(
                        photoIndex: index % 8,
                        captureAt: Date(timeIntervalSince1970: Double(index))
                    )
                )
            case 3:
                return .reviewDecision(
                    state: ReviewStateToken(
                        sessionID: context.sessionID,
                        photoIndex: index % 8,
                        revision: context.sequence,
                        authorityEpoch: testAuthorityEpoch
                    ),
                    requestID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", UInt64(index + 1)))!,
                    action: index.isMultiple(of: 2) ? .keep : .retake
                )
            default:
                return .operatorOverride(context: context, action: .skip)
            }
        }

        let secret = Data(repeating: 0xA5, count: 32)
        let macHello = BoothSecureChannelHello(
            sessionID: "control-stress",
            challenge: Data(repeating: 0x01, count: 32),
            senderRole: .mac,
            senderDeviceID: "mac",
            receiverDeviceID: "ipad"
        )
        let iPadHello = BoothSecureChannelHello(
            sessionID: "control-stress",
            challenge: Data(repeating: 0x02, count: 32),
            senderRole: .iPad,
            senderDeviceID: "ipad",
            receiverDeviceID: "mac"
        )
        let macChannel = BoothSecureChannel()
        let iPadChannel = BoothSecureChannel()
        try macChannel.configure(secret: secret, localHello: macHello, peerHello: iPadHello)
        try iPadChannel.configure(secret: secret, localHello: iPadHello, peerHello: macHello)

        let server = try ControlStressServer(expected: expected, secureChannel: iPadChannel)
        let port = try await server.start()
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.ControlStressWriter")
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let pump = BoothControlWritePump(queue: queue, secureChannel: macChannel)
        connection.start(queue: queue)
        pump.bind(connection, generation: 1)
        defer {
            pump.invalidate(generation: 2)
            connection.cancel()
            server.stop()
        }

        for message in expected {
            let outcome = await withCheckedContinuation { continuation in
                _ = pump.enqueue(
                    message,
                    connection: connection,
                    generation: 1,
                    secure: true
                ) { outcome in
                    continuation.resume(returning: outcome)
                }
            }
            #expect(outcome == .sent)
        }

        try await server.wait()
        #expect(pump.pendingMessageCount == 0)
        #expect(pump.pendingByteCount == 0)
    }
}
