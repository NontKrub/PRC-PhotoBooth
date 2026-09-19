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

private enum ControlStressError: Error {
    case connectionCancelled
    case connectionClosed
    case unexpectedFrame
    case unexpectedMessage(Int)
    case listenerHasNoPort
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
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.connection?.cancel()
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
        listener.cancel()
        receiver.cancel()
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
}

private final class TransportLivenessObserver: @unchecked Sendable {
    struct Snapshot: Sendable {
        var activityCount = 0
        var deliveredFrameCount = 0
        var transportClosedCount = 0
        var closeDeliveredCount = 0
        var timeoutCount = 0
        var reconnectDueCount = 0
    }

    private let lock = NSLock()
    private var value = Snapshot()

    func markActivity() {
        lock.lock()
        value.activityCount += 1
        lock.unlock()
    }

    func markDelivered(_ count: Int) {
        lock.lock()
        value.deliveredFrameCount += count
        lock.unlock()
    }

    func markTransportClosed() {
        lock.lock()
        value.transportClosedCount += 1
        lock.unlock()
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
    private let scheduleReconnectOnClose: Bool
    private let connectionReady = DispatchSemaphore(value: 0)
    private var readyContinuation: CheckedContinuation<NWEndpoint.Port, Error>?
    private var connection: NWConnection?
    private var receiveToken: BoothTransportReceiveToken?
    private var generation = 0
    private var reconnectWasScheduled = false

    init(secureChannel: BoothSecureChannel, scheduleReconnectOnClose: Bool = false) throws {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TransportLiveness")
        self.queue = queue
        listener = try NWListener(using: .tcp)
        self.secureChannel = secureChannel
        self.scheduleReconnectOnClose = scheduleReconnectOnClose
        runtime = BoothNetworkTransportRuntime(queue: queue)
        writer = BoothControlWritePump(queue: queue, secureChannel: secureChannel)
        runtime.onHeartbeatTimeout = { [weak observer] connection, _ in
            observer?.markTimeout()
            connection.cancel()
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

    func waitForConnection() -> Bool {
        connectionReady.wait(timeout: .now() + 1) == .success
    }

    func terminateConnection() {
        queue.async { [weak self] in
            self?.connection?.cancel()
        }
    }

    func snapshot() -> TransportLivenessObserver.Snapshot {
        observer.snapshot()
    }

    func stop() {
        receiveToken?.invalidate()
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
                    let token = BoothTransportReceiveToken()
                    self.receiveToken = token
                    self.writer.bind(connection, generation: self.generation)
                    self.runtime.startHeartbeat(
                        connection: connection,
                        generation: self.generation,
                        writer: self.writer,
                        interval: 0.25,
                        timeout: 1
                    )
                    self.connectionReady.signal()
                    NetworkBoothTransport.receive(
                        on: connection,
                        channel: .control,
                        decoder: BoothTransportFrameDecoder(),
                        token: token,
                        secureChannel: self.secureChannel,
                        activity: { [weak self] in
                            self?.observer.markActivity()
                            self?.runtime.markControlActivityOnQueue()
                        },
                        deliver: { [weak self] frames in
                            self?.observer.markDelivered(frames.count)
                        },
                        deliverPreview: { _ in },
                        close: { [weak self] _ in
                            self?.observer.markCloseDelivered()
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
        isMirrored: false
    )
    let firstContext = SessionMessageContext(sessionID: sessionID, sequence: 1)
    let firstReviewState = ReviewStateToken(sessionID: sessionID, photoIndex: 0, revision: 1)
    let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var messages: [Message] = [
        .sessionSync(snapshot: snapshot),
        .beginCountdown(
            context: firstContext,
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
        let retakeContext = SessionMessageContext(sessionID: sessionID, sequence: 2)
        let retakeReviewState = ReviewStateToken(sessionID: sessionID, photoIndex: 0, revision: 2)
        messages.append(.beginCountdown(
            context: retakeContext,
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

@Suite("Network route policy")
struct NetworkRouteTests {
    @Test("reconnect timer fires while MainActor is blocked")
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

    @Test("authenticated control traffic remains live during a real 12-second MainActor stall")
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

        #expect(waitForSemaphore(clientReady))
        clientPump.bind(clientConnection, generation: 1)
        #expect(server.waitForConnection())

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
        defer { traffic.cancel() }

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
        let stalledSnapshot = server.snapshot()
        #expect(stalledSnapshot.activityCount >= 20)
        #expect(stalledSnapshot.timeoutCount == 0)
        #expect(stalledSnapshot.transportClosedCount == 0)

        releaseMain.signal()
        try await Task.sleep(for: .milliseconds(250))
        #expect(server.snapshot().deliveredFrameCount > 0)
    }

    @Test("control closure is observed and reconnect stays single during a MainActor stall")
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

        #expect(waitForSemaphore(clientReady))
        clientPump.bind(clientConnection, generation: 1)
        #expect(server.waitForConnection())

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

            let server = try ControlStressServer(expected: messages, secureChannel: macChannel)
            let port = try await server.start()
            let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TransportSoak.\(index)")
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            let pump = BoothControlWritePump(queue: queue, secureChannel: iPadChannel)
            connection.start(queue: queue)
            pump.bind(connection, generation: index + 1)
            defer {
                pump.invalidate(generation: index + 2)
                connection.cancel()
                server.stop()
            }

            for message in messages {
                let outcome = await withCheckedContinuation { continuation in
                    _ = pump.enqueue(
                        message,
                        connection: connection,
                        generation: index + 1,
                        secure: true,
                        completion: { outcome in continuation.resume(returning: outcome) }
                    )
                }
                #expect(outcome == .sent)
            }
            try await server.wait()
            #expect(pump.pendingMessageCount == 0)
            #expect(pump.pendingByteCount == 0)

            sessionGate.synchronize(sessionID: sessionID, sequence: 0)
            let actionCount = index.isMultiple(of: 7) ? 2 : 1
            for sequence in 1...actionCount {
                let accepted = sessionGate.accept(
                    SessionMessageContext(sessionID: sessionID, sequence: UInt64(sequence))
                )
                #expect(accepted)
            }
            let rejected = sessionGate.accept(SessionMessageContext(
                sessionID: "stale-session",
                sequence: UInt64.max
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
        #expect(previewPeerMatchesControlPeer(
            previewPeerID: "peer",
            controlPeerID: "peer",
            identityRequired: true
        ))
        #expect(!previewPeerMatchesControlPeer(
            previewPeerID: "stale-peer",
            controlPeerID: "peer",
            identityRequired: true
        ))
        #expect(!previewPeerMatchesControlPeer(
            previewPeerID: nil,
            controlPeerID: "peer",
            identityRequired: true
        ))
        #expect(previewPeerMatchesControlPeer(
            previewPeerID: nil,
            controlPeerID: nil,
            identityRequired: false
        ))
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
            isMirrored: false
        )
        let expected: [Message] = (0..<10_000).map { index in
            let context = SessionMessageContext(
                sessionID: "control-stress",
                sequence: UInt64(index + 1)
            )
            switch index % 5 {
            case 0:
                return .heartbeat
            case 1:
                return .sessionSync(snapshot: snapshot)
            case 2:
                return .beginCountdown(
                    context: context,
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
                        revision: context.sequence
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
