import Foundation

struct DSLRCaptureAttemptScope: Hashable, Sendable {
    let attemptID: UUID
    let cameraGeneration: UInt64
}

struct DSLRCameraPTPScope: Hashable, Sendable {
    let attemptID: UUID?
    let cameraGeneration: UInt64
}

enum DSLRSonyControlProperty: UInt16, Sendable {
    case autofocus = 0xD2C1
    case shutter = 0xD2C2
}

struct DSLRSonyPhysicalControlState: Sendable, Equatable {
    let cameraGeneration: UInt64
    private(set) var autofocusMayBeEngaged = false
    private(set) var shutterMayBeEngaged = false
    private(set) var autofocusReleaseInFlight = false
    private(set) var shutterReleaseInFlight = false
    private(set) var cleanupInProgress = false

    var needsNeutralization: Bool {
        autofocusMayBeEngaged || shutterMayBeEngaged
            || autofocusReleaseInFlight || shutterReleaseInFlight
    }

    mutating func commandDispatched(property: UInt16, value: UInt16, generation: UInt64) {
        guard generation == cameraGeneration else { return }
        switch (DSLRSonyControlProperty(rawValue: property), value) {
        case (.autofocus, 2): autofocusMayBeEngaged = true
        case (.shutter, 2): shutterMayBeEngaged = true
        case (.autofocus, 1): autofocusReleaseInFlight = true
        case (.shutter, 1): shutterReleaseInFlight = true
        default: break
        }
    }

    mutating func commandCompleted(
        property: UInt16,
        value: UInt16,
        responseCode: UInt16,
        failed: Bool,
        generation: UInt64
    ) {
        guard generation == cameraGeneration else { return }
        let succeeded = !failed && responseCode == 0x2001
        let wasBusy = !failed && responseCode == 0x201D
        switch (DSLRSonyControlProperty(rawValue: property), value) {
        case (.autofocus, 1):
            autofocusReleaseInFlight = false
            if succeeded { autofocusMayBeEngaged = false }
        case (.shutter, 1):
            shutterReleaseInFlight = false
            if succeeded { shutterMayBeEngaged = false }
        case (.autofocus, 2) where wasBusy:
            autofocusMayBeEngaged = false
        case (.shutter, 2) where wasBusy:
            shutterMayBeEngaged = false
        default:
            // An error response does not prove that a press or release had no
            // physical effect. Preserve the conservative state until release or
            // a confirmed camera-session close.
            break
        }
    }

    mutating func beginCleanup(laneQuarantined: Bool, generation: UInt64) -> [UInt16]? {
        guard generation == cameraGeneration,
              needsNeutralization,
              !cleanupInProgress else { return nil }
        guard !laneQuarantined,
              !autofocusReleaseInFlight,
              !shutterReleaseInFlight else { return nil }
        cleanupInProgress = true
        var commands: [UInt16] = []
        if shutterMayBeEngaged { commands.append(DSLRSonyControlProperty.shutter.rawValue) }
        if autofocusMayBeEngaged { commands.append(DSLRSonyControlProperty.autofocus.rawValue) }
        return commands
    }

    mutating func finishCleanup(generation: UInt64) {
        guard generation == cameraGeneration else { return }
        cleanupInProgress = false
    }
}

enum DSLRCameraSessionRecoveryPolicy {
    static func closeIsConfirmed(errorOccurred: Bool) -> Bool {
        !errorOccurred
    }

    static func closeDeadlineCanReportFailure(
        generation: UInt64,
        currentGeneration: UInt64,
        cameraStillConnected: Bool,
        closeIsPending: Bool
    ) -> Bool {
        generation == currentGeneration
            || (!cameraStillConnected && closeIsPending)
    }

    static func mayScheduleCycle(
        requestedGeneration: UInt64,
        currentGeneration: UInt64,
        captureIsActive: Bool,
        closingGeneration: UInt64?,
        openingGeneration: UInt64?
    ) -> Bool {
        requestedGeneration == currentGeneration
            && !captureIsActive
            && closingGeneration == nil
            && openingGeneration == nil
    }
}

enum DSLRCameraRecoveryStatus: Equatable, Sendable {
    case opening
    case initializing
    case recovering
    case manualReconnectRequired
}

final class DSLRCaptureAttemptControl: @unchecked Sendable {
    let scope: DSLRCaptureAttemptScope

    private let lock = NSLock()
    private var cancelled = false
    private var resolved = false
    private var shutterMayHaveBeenIssued = false

    init(scope: DSLRCaptureAttemptScope) {
        self.scope = scope
    }

    func cancel(_ scope: DSLRCaptureAttemptScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.scope == scope, !resolved else { return false }
        cancelled = true
        return true
    }

    func canContinue(_ scope: DSLRCaptureAttemptScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.scope == scope && !cancelled && !resolved
    }

    func markShutterMayHaveBeenIssued(_ scope: DSLRCaptureAttemptScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.scope == scope, !cancelled, !resolved else { return false }
        shutterMayHaveBeenIssued = true
        return true
    }

    // Linearize cancellation against enqueueing the physical shutter command.
    func performIfCurrent(_ scope: DSLRCaptureAttemptScope, action: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.scope == scope, !cancelled, !resolved else { return false }
        action()
        return true
    }

    func confirmShutterRejected(_ scope: DSLRCaptureAttemptScope) {
        lock.lock()
        defer { lock.unlock() }
        guard self.scope == scope, !cancelled, !resolved else { return }
        shutterMayHaveBeenIssued = false
    }

    func confirmShutterWasNotDispatched(_ scope: DSLRCaptureAttemptScope) {
        lock.lock()
        defer { lock.unlock() }
        guard self.scope == scope else { return }
        shutterMayHaveBeenIssued = false
    }

    func shutterMayHaveBeenIssued(for scope: DSLRCaptureAttemptScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.scope == scope && shutterMayHaveBeenIssued
    }

    func resolve(_ scope: DSLRCaptureAttemptScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.scope == scope, !resolved else { return false }
        resolved = true
        return true
    }
}

struct DSLRCameraPTPReply: Sendable {
    let data: Data
    let responseCode: UInt16
    let errorDescription: String?
}

enum DSLRCameraPTPFailure: Error, Equatable, Sendable {
    case cancelled
    case timedOut
    case disconnected
}

@MainActor
final class DSLRCameraPTPCommandLane {
    struct Ticket: Hashable, Sendable {
        let id: UUID
        let scope: DSLRCameraPTPScope
        let priority: Int
    }

    private struct Waiter {
        let ticket: Ticket
        let continuation: CheckedContinuation<Result<Void, DSLRCameraPTPFailure>, Never>
        let timeoutTask: Task<Void, Never>
    }

    private struct InFlight {
        let ticket: Ticket
        let continuation: CheckedContinuation<Result<DSLRCameraPTPReply, DSLRCameraPTPFailure>, Never>
        let timeoutTask: Task<Void, Never>
        var resultWasResolved: Bool
    }

    private(set) var owner: Ticket?
    private var inFlight: InFlight?
    private var waiters: [Waiter] = []
    private var expiredTickets = Set<UUID>()

    var isQuarantined: Bool {
        inFlight?.resultWasResolved == true
    }

    var isIdle: Bool { owner == nil }

    func execute(
        scope: DSLRCameraPTPScope,
        priority: Int,
        timeout: Duration,
        isCurrent: @escaping @MainActor (DSLRCameraPTPScope) -> Bool,
        beforeSend: (@MainActor () -> Bool)? = nil,
        onNotSent: (@MainActor () -> Void)? = nil,
        send: @escaping @MainActor (Ticket, @escaping @Sendable (DSLRCameraPTPReply) -> Void) -> Void
    ) async -> Result<DSLRCameraPTPReply, DSLRCameraPTPFailure> {
        let ticket = Ticket(id: UUID(), scope: scope, priority: priority)
        let timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.deadlineReached(ticket)
        }
        let acquisition = await acquire(ticket, timeoutTask: timeoutTask)
        guard case .success = acquisition else {
            timeoutTask.cancel()
            if case .failure(let failure) = acquisition { return .failure(failure) }
            return .failure(.cancelled)
        }
        if expiredTickets.remove(ticket.id) != nil {
            timeoutTask.cancel()
            return .failure(.timedOut)
        }
        guard owner == ticket, !Task.isCancelled, isCurrent(scope) else {
            timeoutTask.cancel()
            releaseUnsent(ticket)
            if Task.isCancelled { return .failure(.cancelled) }
            return .failure(isCurrent(scope) ? .timedOut : .disconnected)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isCurrent(scope) else {
                    timeoutTask.cancel()
                    continuation.resume(returning: .failure(Task.isCancelled ? .cancelled : .disconnected))
                    releaseUnsent(ticket)
                    return
                }

                inFlight = InFlight(
                    ticket: ticket,
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    resultWasResolved: false
                )
                var sendWasAuthorized = false
                if let beforeSend {
                    guard beforeSend() else {
                        timeoutTask.cancel()
                        inFlight = nil
                        continuation.resume(returning: .failure(.cancelled))
                        releaseUnsent(ticket)
                        return
                    }
                    sendWasAuthorized = true
                }
                guard !Task.isCancelled, isCurrent(scope) else {
                    if sendWasAuthorized { onNotSent?() }
                    timeoutTask.cancel()
                    inFlight = nil
                    continuation.resume(returning: .failure(Task.isCancelled ? .cancelled : .disconnected))
                    releaseUnsent(ticket)
                    return
                }

                send(ticket) { [weak self] reply in
                    Task { @MainActor in
                        self?.receive(reply, for: ticket)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(ticket, reason: .cancelled)
            }
        }
    }

    func cancel(scope: DSLRCameraPTPScope, reason: DSLRCameraPTPFailure = .cancelled) {
        let cancelledWaiters = waiters.filter { $0.ticket.scope == scope }
        waiters.removeAll { $0.ticket.scope == scope }
        for waiter in cancelledWaiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: .failure(reason))
        }

        guard let owner, owner.scope == scope else { return }
        cancel(owner, reason: reason)
    }

    func cancel(cameraGeneration: UInt64, reason: DSLRCameraPTPFailure = .cancelled) {
        let cancelledWaiters = waiters.filter { $0.ticket.scope.cameraGeneration == cameraGeneration }
        waiters.removeAll { $0.ticket.scope.cameraGeneration == cameraGeneration }
        for waiter in cancelledWaiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: .failure(reason))
        }

        guard let owner, owner.scope.cameraGeneration == cameraGeneration else { return }
        cancel(owner, reason: reason)
    }

    func retire(cameraGeneration: UInt64) {
        let retiredWaiters = waiters.filter { $0.ticket.scope.cameraGeneration == cameraGeneration }
        waiters.removeAll { $0.ticket.scope.cameraGeneration == cameraGeneration }
        for waiter in retiredWaiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: .failure(.disconnected))
        }

        guard let owner, owner.scope.cameraGeneration == cameraGeneration else { return }
        if let current = inFlight, current.ticket == owner {
            current.timeoutTask.cancel()
            if !current.resultWasResolved {
                current.continuation.resume(returning: .failure(.disconnected))
            }
            inFlight = nil
        }
        self.owner = nil
        grantNextWaiter()
    }

    func deadlineReached(_ ticket: Ticket) {
        if let index = waiters.firstIndex(where: { $0.ticket == ticket }) {
            let waiter = waiters.remove(at: index)
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: .failure(.timedOut))
            return
        }
        if owner == ticket, inFlight == nil {
            owner = nil
            expiredTickets.insert(ticket.id)
            grantNextWaiter()
            return
        }
        resolveCaller(for: ticket, with: .failure(.timedOut))
    }

    private func acquire(
        _ ticket: Ticket,
        timeoutTask: Task<Void, Never>
    ) async -> Result<Void, DSLRCameraPTPFailure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        if owner == nil {
            owner = ticket
            return .success(())
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(
                    ticket: ticket,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                ))
                if Task.isCancelled {
                    cancelQueued(ticket, reason: .cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQueued(ticket, reason: .cancelled)
            }
        }
    }

    private func cancel(_ ticket: Ticket, reason: DSLRCameraPTPFailure) {
        cancelQueued(ticket, reason: reason)
        guard owner == ticket else { return }
        if inFlight?.ticket == ticket {
            resolveCaller(for: ticket, with: .failure(reason))
        } else {
            owner = nil
            grantNextWaiter()
        }
    }

    private func cancelQueued(_ ticket: Ticket, reason: DSLRCameraPTPFailure) {
        guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: .failure(reason))
    }

    private func receive(_ reply: DSLRCameraPTPReply, for ticket: Ticket) {
        guard owner == ticket, let current = inFlight, current.ticket == ticket else { return }
        current.timeoutTask.cancel()
        if !current.resultWasResolved {
            current.continuation.resume(returning: .success(reply))
        }
        inFlight = nil
        owner = nil
        grantNextWaiter()
    }

    private func resolveCaller(
        for ticket: Ticket,
        with result: Result<DSLRCameraPTPReply, DSLRCameraPTPFailure>
    ) {
        guard let current = inFlight,
              current.ticket == ticket,
              !current.resultWasResolved else { return }
        var resolved = current
        resolved.resultWasResolved = true
        resolved.timeoutTask.cancel()
        inFlight = resolved
        resolved.continuation.resume(returning: result)
    }

    private func releaseUnsent(_ ticket: Ticket) {
        guard owner == ticket else { return }
        owner = nil
        grantNextWaiter()
    }

    private func grantNextWaiter() {
        while !waiters.isEmpty {
            var nextIndex = 0
            for index in waiters.indices.dropFirst()
            where waiters[index].ticket.priority > waiters[nextIndex].ticket.priority {
                nextIndex = index
            }
            let waiter = waiters.remove(at: nextIndex)
            owner = waiter.ticket
            waiter.continuation.resume(returning: .success(()))
            return
        }
    }
}
