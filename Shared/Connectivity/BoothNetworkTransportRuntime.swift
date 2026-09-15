import Foundation
import Network

/// Owns transport-timer decisions on the Network.framework queue. The
/// MainActor facade remains responsible for user-facing state and route
/// policy; socket cancellation and timer expiry do not depend on it.
final class BoothNetworkTransportRuntime: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let heartbeatState = BoothTransportHeartbeatState()
    private var heartbeatSource: DispatchSourceTimer?
    private var heartbeatConnection: NWConnection?
    private var heartbeatGeneration = 0
    private var controlTrafficAdmitted = false
    private var reconnectSource: DispatchSourceTimer?
    private var reconnectAttempt = 0

    var onHeartbeatTimeout: (@Sendable (NWConnection, Int) -> Void)?
    var onReconnectDue: (@Sendable (Int) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: queueKey, value: ())
    }

    func startHeartbeat(
        connection: NWConnection,
        generation: Int,
        writer: BoothControlWritePump,
        interval: TimeInterval,
        timeout: TimeInterval
    ) {
        onQueue {
            startHeartbeatOnQueue(
                connection: connection,
                generation: generation,
                writer: writer,
                interval: interval,
                timeout: timeout
            )
        }
    }

    func startHeartbeatOnQueue(
        connection: NWConnection,
        generation: Int,
        writer: BoothControlWritePump,
        interval: TimeInterval,
        timeout: TimeInterval
    ) {
        heartbeatSource?.cancel()
        heartbeatConnection = connection
        heartbeatGeneration = generation
        controlTrafficAdmitted = true
        heartbeatState.markActivity()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.heartbeatConnection === connection,
                  self.heartbeatGeneration == generation else { return }
            if self.heartbeatState.shouldReportTimeout(after: timeout) {
                connection.cancel()
                self.onHeartbeatTimeout?(connection, generation)
                return
            }
            if writer.enqueueOnQueue(
                .heartbeat,
                connection: connection,
                generation: generation,
                secure: true,
                completion: nil
            ) != .sent {
                connection.cancel()
            }
        }
        source.resume()
        heartbeatSource = source
    }

    func markControlActivityOnQueue() {
        guard controlTrafficAdmitted, heartbeatConnection != nil else { return }
        heartbeatState.markActivity()
    }

    func stopHeartbeat() {
        onQueue {
            stopHeartbeatOnQueue()
        }
    }

    func stopHeartbeatOnQueue() {
        heartbeatSource?.cancel()
        heartbeatSource = nil
        heartbeatConnection = nil
        controlTrafficAdmitted = false
        heartbeatState.reset()
    }

    func scheduleReconnect(after delay: TimeInterval, attempt: Int) {
        queue.async { [weak self] in
            guard let self, self.reconnectSource == nil else { return }
            self.reconnectAttempt = attempt
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now() + delay)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.reconnectSource = nil
                self.onReconnectDue?(self.reconnectAttempt)
            }
            self.reconnectSource = source
            source.resume()
        }
    }

    func cancelReconnect() {
        onQueue {
            reconnectSource?.cancel()
            reconnectSource = nil
            reconnectAttempt = 0
        }
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }
}
