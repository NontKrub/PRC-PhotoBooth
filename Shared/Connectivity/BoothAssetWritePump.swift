import Foundation
import Network

/// Serializes asset frames independently from control traffic. A missing or
/// saturated asset route never consumes the control writer or closes control.
final class BoothAssetWritePump: @unchecked Sendable {
    static let maximumPendingChunks = 256
    static let maximumPendingBytes = 32 * 1024 * 1024

    private final class Item: @unchecked Sendable {
        let encodedChunk: Data
        let generation: Int
        let completion: (@MainActor (BoothControlSendOutcome) -> Void)?
        let estimatedBytes: Int
        var completed = false

        init(
            encodedChunk: Data,
            generation: Int,
            estimatedBytes: Int,
            completion: (@MainActor (BoothControlSendOutcome) -> Void)?
        ) {
            self.encodedChunk = encodedChunk
            self.generation = generation
            self.estimatedBytes = estimatedBytes
            self.completion = completion
        }
    }

    private let queue: DispatchQueue
    private let secureChannel: BoothSecureChannel
    private var connection: NWConnection?
    private var connectionGeneration = 0
    private var pending: [Item] = []
    private var pendingBytes = 0
    private var inFlight: Item?

    var onFailure: (@Sendable (BoothControlSendOutcome, String, Int) -> Void)?

    init(queue: DispatchQueue, secureChannel: BoothSecureChannel) {
        self.queue = queue
        self.secureChannel = secureChannel
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
        queue.sync { [weak self] in
            guard let self else { return }
            self.connection = nil
            self.connectionGeneration = generation
            self.failAll(.networkSendFailed)
        }
    }

    @discardableResult
    func enqueue(
        _ chunk: BoothAssetChunk,
        connection expectedConnection: NWConnection?,
        generation: Int,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)?
    ) -> BoothControlSendOutcome {
        var outcome: BoothControlSendOutcome = .sent
        queue.sync {
            outcome = self.enqueueOnQueue(
                chunk,
                connection: expectedConnection,
                generation: generation,
                completion: completion
            )
        }
        return outcome
    }

    @discardableResult
    func enqueueBinding(
        _ binding: BoothChannelBindingHello,
        connection expectedConnection: NWConnection?,
        generation: Int,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)?
    ) -> BoothControlSendOutcome {
        var outcome: BoothControlSendOutcome = .sent
        queue.sync {
            do {
                outcome = self.enqueueEncodedOnQueue(
                    try BoothAssetTransfer.encodeBinding(binding),
                    connection: expectedConnection,
                    generation: generation,
                    completion: completion
                )
            } catch let error as BoothAssetTransferError {
                let result: BoothControlSendOutcome
                switch error {
                case .metadataTooLarge, .chunkTooLarge, .assetTooLarge:
                    result = .rejectedOversize
                default:
                    result = .encodingFailed
                }
                finish(completion, with: result)
                outcome = result
            } catch {
                finish(completion, with: .encodingFailed)
                outcome = .encodingFailed
            }
        }
        return outcome
    }

    private func enqueueOnQueue(
        _ chunk: BoothAssetChunk,
        connection expectedConnection: NWConnection?,
        generation: Int,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)?
    ) -> BoothControlSendOutcome {
        let encoded: Data
        do {
            encoded = try BoothAssetTransfer.encode(chunk)
        } catch let error as BoothAssetTransferError {
            let outcome: BoothControlSendOutcome
            switch error {
            case .chunkTooLarge, .assetTooLarge, .metadataTooLarge:
                outcome = .rejectedOversize
            default:
                outcome = .encodingFailed
            }
            finish(completion, with: outcome)
            return outcome
        } catch {
            finish(completion, with: .encodingFailed)
            return .encodingFailed
        }
        return enqueueEncodedOnQueue(
            encoded,
            connection: expectedConnection,
            generation: generation,
            completion: completion
        )
    }

    private func enqueueEncodedOnQueue(
        _ encoded: Data,
        connection expectedConnection: NWConnection?,
        generation: Int,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)?
    ) -> BoothControlSendOutcome {
        guard let expectedConnection,
              let connection = self.connection,
              connection === expectedConnection,
              self.connectionGeneration == generation else {
            finish(completion, with: .noConnection)
            return .noConnection
        }
        let estimatedBytes = encoded.count + 64
        guard pending.count + (inFlight == nil ? 0 : 1) < Self.maximumPendingChunks,
              pendingBytes + (inFlight?.estimatedBytes ?? 0) + estimatedBytes <= Self.maximumPendingBytes else {
            let outcome: BoothControlSendOutcome = .networkSendFailed
            finish(completion, with: outcome)
            onFailure?(outcome, "Asset writer queue limit exceeded.", generation)
            return outcome
        }
        pending.append(Item(
            encodedChunk: encoded,
            generation: generation,
            estimatedBytes: estimatedBytes,
            completion: completion
        ))
        pendingBytes += estimatedBytes
        flush()
        return .sent
    }

    private func flush() {
        guard inFlight == nil, !pending.isEmpty, let connection else { return }
        let item = pending.removeFirst()
        pendingBytes -= item.estimatedBytes
        inFlight = item
        do {
            let payload = try secureChannel.protect(item.encodedChunk, channel: .asset)
            let frame = try BoothFrameEncoder.encode(channel: .asset, payload: payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                self.queue.async {
                    self.complete(item, connection: connection, error: error)
                }
            })
        } catch let error as BoothAssetTransferError {
            complete(item, connection: connection, error: error, outcome: .encodingFailed)
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

    private func failAll(_ outcome: BoothControlSendOutcome) {
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
    }

    private func finish(
        _ completion: (@MainActor (BoothControlSendOutcome) -> Void)?,
        with outcome: BoothControlSendOutcome
    ) {
        guard let completion else { return }
        Task { @MainActor in completion(outcome) }
    }
}
