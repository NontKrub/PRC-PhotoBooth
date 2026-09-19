import Foundation
import Network

/// The only writer for operational control frames. The supplied queue owns
/// encoding, counter allocation, framing, and NWConnection.send submission.
final class BoothControlWritePump: @unchecked Sendable {
    static let maximumPendingMessages = 256
    static let maximumPendingBytes = 4 * 1024 * 1024

    private final class Item: @unchecked Sendable {
        let message: Message
        let secure: Bool
        let generation: Int
        let completion: (@MainActor (BoothControlSendOutcome) -> Void)?
        let estimatedBytes: Int
        var completed = false

        init(
            message: Message,
            secure: Bool,
            generation: Int,
            estimatedBytes: Int,
            completion: (@MainActor (BoothControlSendOutcome) -> Void)?
        ) {
            self.message = message
            self.secure = secure
            self.generation = generation
            self.estimatedBytes = estimatedBytes
            self.completion = completion
        }
    }

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let secureChannel: BoothSecureChannel
    private var connection: NWConnection?
    private var connectionGeneration = 0
    private var pending: [Item] = []
    private var pendingBytes = 0
    private var inFlight: Item?

    /// Called on the transport queue after a contentProcessed failure.
    var onFailure: (@Sendable (BoothControlSendOutcome, String, Int) -> Void)?

    init(queue: DispatchQueue, secureChannel: BoothSecureChannel) {
        self.queue = queue
        self.secureChannel = secureChannel
        queue.setSpecific(key: queueKey, value: ())
    }

    func bind(_ connection: NWConnection, generation: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection = connection
            self.connectionGeneration = generation
            self.flush()
        }
    }

    func invalidate(generation: Int) {
        onQueue { [weak self] in
            guard let self else { return }
            self.connection = nil
            self.connectionGeneration = generation
            self.failAll(
                .networkSendFailed,
                reason: "Control connection was replaced.",
                notifyFailure: false
            )
        }
    }

    @discardableResult
    func enqueue(
        _ message: Message,
        connection expectedConnection: NWConnection?,
        generation: Int,
        secure: Bool,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)?
    ) -> BoothControlSendOutcome {
        onQueue {
            enqueueOnQueue(
                message,
                connection: expectedConnection,
                generation: generation,
                secure: secure,
                completion: completion
            )
        }
    }

    @discardableResult
    func enqueueOnQueue(
        _ message: Message,
        connection expectedConnection: NWConnection?,
        generation: Int,
        secure: Bool,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)?
    ) -> BoothControlSendOutcome {
        guard let expectedConnection,
              let connection = self.connection,
              connection === expectedConnection,
              self.connectionGeneration == generation else {
            let outcome: BoothControlSendOutcome = .noConnection
            finish(completion, with: outcome)
            return outcome
        }
        if case .heartbeat = message,
           pending.contains(where: { if case .heartbeat = $0.message { return true }; return false }) {
            return .sent
        }
        guard let encoded = try? message.encoded() else {
            let outcome: BoothControlSendOutcome = .encodingFailed
            finish(completion, with: outcome)
            return outcome
        }
        let estimatedBytes = encoded.count + (secure ? 64 : 0) + 8
        guard pending.count + (inFlight == nil ? 0 : 1) < Self.maximumPendingMessages,
              pendingBytes + (inFlight?.estimatedBytes ?? 0) + estimatedBytes <= Self.maximumPendingBytes else {
            let outcome: BoothControlSendOutcome = .networkSendFailed
            finish(completion, with: outcome)
            onFailure?(.networkSendFailed, "Control writer queue limit exceeded.", generation)
            return outcome
        }
        pending.append(Item(
            message: message,
            secure: secure,
            generation: generation,
            estimatedBytes: estimatedBytes,
            completion: completion
        ))
        pendingBytes += estimatedBytes
        flush()
        return .sent
    }

    var pendingMessageCount: Int {
        onQueue { pending.count + (inFlight == nil ? 0 : 1) }
    }

    var pendingByteCount: Int {
        onQueue { pendingBytes + (inFlight?.estimatedBytes ?? 0) }
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }

    private func flush() {
        guard inFlight == nil, !pending.isEmpty else { return }
        guard let connection else {
            failAll(.noConnection, reason: "No active control connection.")
            return
        }
        let item = pending.removeFirst()
        pendingBytes -= item.estimatedBytes
        inFlight = item

        do {
            let encoded = try item.message.encoded()
            let payload = item.secure
                ? try secureChannel.protect(encoded, channel: .control)
                : encoded
            let frame = try BoothFrameEncoder.encode(channel: .control, payload: payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                self.queue.async {
                    self.complete(item, connection: connection, error: error)
                }
            })
        } catch let error as BoothFrameError {
            let outcome: BoothControlSendOutcome
            if case .oversizedPayload = error {
                outcome = .rejectedOversize
            } else {
                outcome = .encodingFailed
            }
            complete(item, connection: connection, error: error, outcome: outcome)
        } catch {
            complete(item, connection: connection, error: error, outcome: .networkSendFailed)
        }
    }

    private func complete(
        _ item: Item,
        connection: NWConnection,
        error: Error?,
        outcome explicitOutcome: BoothControlSendOutcome? = nil
    ) {
        guard !item.completed else { return }
        item.completed = true
        inFlight = nil
        let outcome = explicitOutcome ?? (error == nil ? .sent : .networkSendFailed)
        finish(item.completion, with: outcome)
        if let error {
            onFailure?(outcome, error.localizedDescription, item.generation)
        }
        flush()
    }

    private func failAll(
        _ outcome: BoothControlSendOutcome,
        reason: String,
        notifyFailure: Bool = true
    ) {
        if let inFlight {
            inFlight.completed = true
            finish(inFlight.completion, with: outcome)
            self.inFlight = nil
        }
        let queued = pending
        pending.removeAll()
        pendingBytes = 0
        for item in queued {
            finish(item.completion, with: outcome)
        }
        if notifyFailure, outcome != .noConnection {
            onFailure?(outcome, reason, connectionGeneration)
        }
    }

    private func finish(
        _ completion: (@MainActor (BoothControlSendOutcome) -> Void)?,
        with outcome: BoothControlSendOutcome
    ) {
        guard let completion else { return }
        Task { @MainActor in completion(outcome) }
    }
}
