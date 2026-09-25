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
    private var reconnectGeneration = 0

    // Pre-Auth Watchdog state (Finding A03)
    private var preAuthWatchdog: BoothPreAuthWatchdog?
    private var preAuthSource: DispatchSourceTimer?
    private var preAuthConnection: NWConnection?
    private var preAuthGeneration = 0

    // Control connection slot authority (Finding A03)
    private var activeControlConnection: NWConnection?
    private var activeControlGeneration = 0
    private var activeControlAuthenticated = false

    var onHeartbeatTimeout: (@Sendable (NWConnection, Int) -> Void)?
    var onReconnectDue: (@Sendable (Int, Int) -> Void)?
    var onPreAuthTimeout: (@Sendable (NWConnection, Int, String) -> Void)?

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
                self.stopHeartbeatOnQueue()
                _ = self.scheduleRecoveryReconnectOnQueue(
                    after: 0,
                    generation: generation
                )
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
                self.stopHeartbeatOnQueue()
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

    @discardableResult
    func scheduleReconnect(after delay: TimeInterval, attempt: Int, generation: Int = 0) -> Bool {
        onQueue {
            scheduleReconnectOnQueue(after: delay, attempt: attempt, generation: generation)
        }
    }

    /// Schedules recovery from a Network.framework callback without asking the
    /// MainActor to make the timing decision first.
    @discardableResult
    func scheduleRecoveryReconnect(after delay: TimeInterval, generation: Int) -> Int? {
        onQueue {
            scheduleRecoveryReconnectOnQueue(after: delay, generation: generation)
        }
    }

    func cancelReconnect() {
        onQueue {
            reconnectSource?.cancel()
            reconnectSource = nil
            reconnectAttempt = 0
            reconnectGeneration = 0
        }
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }

    @discardableResult
    private func scheduleRecoveryReconnectOnQueue(
        after delay: TimeInterval,
        generation: Int
    ) -> Int? {
        let attempt = reconnectAttempt + 1
        guard scheduleReconnectOnQueue(
            after: delay,
            attempt: attempt,
            generation: generation
        ) else { return nil }
        return attempt
    }

    @discardableResult
    private func scheduleReconnectOnQueue(
        after delay: TimeInterval,
        attempt: Int,
        generation: Int
    ) -> Bool {
        guard reconnectSource == nil else { return false }
        reconnectAttempt = attempt
        reconnectGeneration = generation
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconnectSource = nil
            self.onReconnectDue?(self.reconnectAttempt, self.reconnectGeneration)
        }
        reconnectSource = source
        source.resume()
        return true
    }

    // MARK: - Control Connection Slot Ownership (Finding A03)

    func bindControlConnection(
        _ connection: NWConnection,
        generation: Int,
        authenticated: Bool = false
    ) {
        onQueue {
            activeControlConnection = connection
            activeControlGeneration = generation
            activeControlAuthenticated = authenticated
        }
    }

    func invalidateControlConnection(generation: Int) {
        onQueue {
            if activeControlGeneration == generation {
                activeControlConnection = nil
                activeControlAuthenticated = false
                stopPreAuthWatchdogOnQueue()
                stopHeartbeatOnQueue()
            }
        }
    }

    func isControlConnectionActive(generation: Int) -> Bool {
        onQueue {
            guard activeControlGeneration == generation,
                  let connection = activeControlConnection else { return false }
            switch connection.state {
            case .cancelled, .failed:
                return false
            default:
                return true
            }
        }
    }

    func isControlSlotAvailable() -> Bool {
        onQueue {
            guard let active = activeControlConnection else { return true }
            switch active.state {
            case .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Pre-Auth Watchdog Ownership (Finding A03)

    func startPreAuthWatchdog(
        connection: NWConnection,
        generation: Int,
        watchdog: BoothPreAuthWatchdog
    ) {
        onQueue {
            startPreAuthWatchdogOnQueue(
                connection: connection,
                generation: generation,
                watchdog: watchdog
            )
        }
    }

    func startPreAuthWatchdogOnQueue(
        connection: NWConnection,
        generation: Int,
        watchdog: BoothPreAuthWatchdog
    ) {
        stopPreAuthWatchdogOnQueue()
        preAuthConnection = connection
        preAuthGeneration = generation
        preAuthWatchdog = watchdog
        schedulePreAuthWatchdogTickOnQueue(connection: connection, generation: generation, watchdog: watchdog)
    }

    func reschedulePreAuthWatchdog() {
        onQueue {
            guard let connection = preAuthConnection,
                  let watchdog = preAuthWatchdog else { return }
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
        }
    }

    private func schedulePreAuthWatchdogTickOnQueue(
        connection: NWConnection,
        generation: Int,
        watchdog: BoothPreAuthWatchdog
    ) {
        preAuthSource?.cancel()
        preAuthSource = nil
        guard preAuthConnection === connection,
              preAuthGeneration == generation,
              let nextDeadline = watchdog.nextDeadline() else { return }

        let delay = max(0.05, nextDeadline.timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.preAuthConnection === connection,
                  self.preAuthGeneration == generation,
                  let watchdog = self.preAuthWatchdog else { return }

            if let reason = watchdog.checkTimeout() {
                // Immediate cancellation directly on transport queue!
                // Does NOT require MainActor progress!
                connection.cancel()
                self.stopPreAuthWatchdogOnQueue()
                if self.activeControlConnection === connection {
                    self.activeControlConnection = nil
                    self.activeControlAuthenticated = false
                }
                self.onPreAuthTimeout?(connection, generation, reason)
            } else {
                self.schedulePreAuthWatchdogTickOnQueue(
                    connection: connection,
                    generation: generation,
                    watchdog: watchdog
                )
            }
        }
        source.resume()
        preAuthSource = source
    }

    func stopPreAuthWatchdog() {
        onQueue {
            stopPreAuthWatchdogOnQueue()
        }
    }

    func stopPreAuthWatchdogOnQueue() {
        preAuthSource?.cancel()
        preAuthSource = nil
        preAuthConnection = nil
        preAuthWatchdog = nil
    }

    @discardableResult
    func advancePreAuthWatchdog(
        after decision: BoothPairingIntentPolicy.Decision,
        now: Date = Date()
    ) -> Bool {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return false }
            guard BoothPreAuthProgressPolicy.advance(watchdog, after: decision, now: now) else {
                return false
            }
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
            return true
        }
    }

    @discardableResult
    func advancePreAuthWatchdog(
        after result: BoothPairingAttemptResult,
        now: Date = Date()
    ) -> Bool {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return false }
            guard BoothPreAuthProgressPolicy.advance(watchdog, after: result, now: now) else {
                return false
            }
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
            return true
        }
    }

    func onPreAuthPairingStarted(absoluteExpiry: Date, now: Date = Date()) -> Bool {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return false }
            let success = watchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
            if success {
                schedulePreAuthWatchdogTickOnQueue(
                    connection: connection,
                    generation: preAuthGeneration,
                    watchdog: watchdog
                )
            }
            return success
        }
    }

    func onPreAuthAuthenticationStarted(now: Date = Date()) {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return }
            watchdog.onAuthenticationStarted(now: now)
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
        }
    }

    func onPreAuthSecureNegotiationStarted(now: Date = Date()) {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return }
            watchdog.onSecureNegotiationStarted(now: now)
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
        }
    }

    func onPreAuthAuthenticated() {
        onQueue {
            preAuthWatchdog?.onAuthenticated()
            stopPreAuthWatchdogOnQueue()
            activeControlAuthenticated = true
        }
    }
}

