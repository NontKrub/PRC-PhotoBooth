import Foundation
import Observation

@MainActor
protocol SessionJobExecuting: AnyObject {
    var isAutoPrintLaneAvailable: Bool { get }
    func execute(_ job: SessionJob) async throws
}

@MainActor
extension SessionJobExecuting {
    var isAutoPrintLaneAvailable: Bool { true }
}

enum SessionJobCancellationResult: Sendable, Equatable {
    case quiesced
    case cleanupPending
}

@MainActor
@Observable
final class SessionJobQueue {
    private let store: JobQueueStore
    private let executor: any SessionJobExecuting
    private var startupTask: Task<Void, Never>?
    private var finalizationWorkerTask: Task<Void, Never>?
    private var printWorkerTask: Task<Void, Never>?
    private var cloudWorkerTask: Task<Void, Never>?
    private var activeCloudJobID: String?
    private var activeCloudExecutionTask: Task<Void, Error>?
    private var activeFinalizationJobID: String?
    private var activeFinalizationExecutionTask: Task<Void, Error>?
    private var activePrintJobID: String?
    private var activePrintExecutionTask: Task<Void, Error>?
    private var activeReservations: [String: String] = [:]
    private var quiescenceWaiters: [UUID: (sessionID: String, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var persistentQueueError: String?

    private let finalizationKinds: [SessionJobKind] = [
        .renderStrip,
        .registerDownload,
        .updateGallery,
        .renderGIF
    ]

    private(set) var jobs: [SessionJob] = []
    private(set) var isRunning = false
    private(set) var lastQueueError: String?
    var onJobsChanged: (() -> Void)?

    init(store: JobQueueStore, executor: any SessionJobExecuting) {
        self.store = store
        self.executor = executor
    }

    func start() {
        guard startupTask == nil,
              finalizationWorkerTask == nil,
              printWorkerTask == nil,
              cloudWorkerTask == nil else { return }
        isRunning = true
        startupTask = Task { [weak self] in
            await self?.prepareWorkers()
        }
    }

    func stop() {
        isRunning = false
        startupTask?.cancel()
        finalizationWorkerTask?.cancel()
        printWorkerTask?.cancel()
        cloudWorkerTask?.cancel()
        activeCloudExecutionTask?.cancel()
        activeFinalizationExecutionTask?.cancel()
        activePrintExecutionTask?.cancel()
        startupTask = nil
        finalizationWorkerTask = nil
        printWorkerTask = nil
        cloudWorkerTask = nil
        activeCloudJobID = nil
        activeCloudExecutionTask = nil
        activeFinalizationJobID = nil
        activeFinalizationExecutionTask = nil
        activePrintJobID = nil
        activePrintExecutionTask = nil
        let waiters = quiescenceWaiters.values
        quiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
    }

    func refresh() {
        Task { [weak self] in
            await self?.reload()
        }
    }

    func enqueueFinalizationJobs(for manifest: SessionManifest) async throws {
        var kinds: [SessionJobKind] = [.renderStrip, .registerDownload, .updateGallery]
        if manifest.shots.contains(where: { !$0.gifFrameFileNames.isEmpty }) {
            kinds.append(.renderGIF)
        }
        try await enqueue(kinds: kinds, sessionID: manifest.id)
    }

    func enqueueAutoPrint(for manifest: SessionManifest) async throws {
        try await enqueue(kinds: [.autoPrint], sessionID: manifest.id)
    }

    func enqueueCloudUpload(for manifest: SessionManifest) async throws {
        try await enqueue(kinds: [.cloudUpload], sessionID: manifest.id)
    }

    func retry(jobID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.retry(jobID: jobID)
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func resolveUnknownPrint(jobID: String, resolution: UnknownPrintResolution) async throws {
        do {
            _ = try await store.resolveUnknownPrint(jobID: jobID, resolution: resolution)
            await reload()
        } catch {
            lastQueueError = error.localizedDescription
            throw error
        }
    }

    func forceRequeueCloudUpload(
        sessionID: String,
        completion: ((CloudUploadRequeueResult) -> Void)? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await store.forceRequeueCloudUpload(sessionID: sessionID)
                await reload()
                completion?(result)
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func retryFailedCloudUploads() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await store.requeueFailedCloudUploads()
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func cancel(jobID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.cancel(jobID: jobID)
                if activeCloudJobID == jobID {
                    activeCloudExecutionTask?.cancel()
                }
                if activeFinalizationJobID == jobID {
                    activeFinalizationExecutionTask?.cancel()
                }
                if activePrintJobID == jobID {
                    activePrintExecutionTask?.cancel()
                }
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func cancelAndQuiesceJobs(sessionID: String) async throws -> SessionJobCancellationResult {
        try await store.cancelJobs(sessionID: sessionID)
        let snapshot = await store.snapshot()
        if let activeCloudJobID,
           snapshot.contains(where: { $0.id == activeCloudJobID && $0.sessionID == sessionID }) {
            activeCloudExecutionTask?.cancel()
        }
        if let activeFinalizationJobID,
           snapshot.contains(where: { $0.id == activeFinalizationJobID && $0.sessionID == sessionID }) {
            activeFinalizationExecutionTask?.cancel()
        }
        if let activePrintJobID,
           snapshot.contains(where: { $0.id == activePrintJobID && $0.sessionID == sessionID }) {
            activePrintExecutionTask?.cancel()
        }
        // A non-cooperative executor must not keep cancellation suspended
        // forever. The durable barrier makes later enqueue/claim attempts safe
        // while this bounded wait decides whether cleanup can delete files.
        let quiesced = await waitForQuiescence(
            sessionID: sessionID,
            timeout: .seconds(10)
        )
        await reload()
        let remaining = await store.snapshot().contains {
            $0.sessionID == sessionID && $0.status == .running
        }
        return !quiesced || remaining || activeReservations.values.contains(sessionID)
            ? .cleanupPending
            : .quiesced
    }

    func retryAllFailed() {
        Task { [weak self] in
            guard let self else { return }
            let failed = jobs.filter { $0.status == .failed }
            do {
                for job in failed where job.lastFailureDisposition == .retryable {
                    try await store.retry(jobID: job.id)
                }
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func purgeOldSucceededJobs(olderThan date: Date) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.purgeOldSucceededJobs(olderThan: date)
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func deleteJobs(sessionID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.deleteJobs(sessionID: sessionID)
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    private func enqueue(kinds: [SessionJobKind], sessionID: String) async throws {
        do {
            for kind in kinds {
                _ = try await store.enqueue(sessionID: sessionID, kind: kind)
            }
            await reload()
        } catch {
            lastQueueError = error.localizedDescription
            throw error
        }
    }

    private func prepareWorkers() async {
        do {
            _ = try await store.load()
            try await store.resetInterruptedJobs()
            await reload()
        } catch {
            persistentQueueError = error.localizedDescription
            lastQueueError = persistentQueueError
            // Do not run workers against an in-memory snapshot after durable
            // queue recovery failed. Required results must remain visible as
            // unavailable until persistence is repaired.
            jobs = []
            onJobsChanged?()
            isRunning = false
            startupTask = nil
            return
        }

        guard !Task.isCancelled else {
            startupTask = nil
            return
        }

        let workerKinds = finalizationKinds
        finalizationWorkerTask = Task { [weak self] in
            await self?.runWorker(kinds: workerKinds)
        }
        printWorkerTask = Task { [weak self] in
            await self?.runWorker(kinds: [.autoPrint])
        }
        cloudWorkerTask = Task { [weak self] in
            await self?.runWorker(kinds: [.cloudUpload])
        }
        startupTask = nil
    }

    private func runWorker(kinds: [SessionJobKind]) async {
        while !Task.isCancelled {
            if await runNextJob(kinds: kinds) {
                continue
            }
            guard !Task.isCancelled else { break }
            await waitForWakeOrPoll()
        }
    }

    private func waitForWakeOrPoll() async {
        // ponytail: bounded 100ms poll; replace with a cancellable wake primitive if queue volume grows.
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func runNextJob(kinds: [SessionJobKind]) async -> Bool {
        guard let selected = nextRunnableJob(in: kinds) else { return false }
        let running: SessionJob
        do {
            guard let claimed = try await store.claim(jobID: selected.id) else {
                await reload()
                return true
            }
            running = claimed
            reserve(running)
        } catch {
            lastQueueError = error.localizedDescription
            await reload()
            return true
        }
        await reload()
        do {
            try await execute(running)
        } catch is CancellationError {
            await reload()
            return true
        } catch let error as JobExecutionError {
            var updated = running
            apply(error, to: &updated)
            await finish(updated)
            return true
        } catch {
            var updated = running
            apply(.retryable(error.localizedDescription), to: &updated)
            await finish(updated)
            return true
        }
        var succeeded = running
        succeeded.status = .succeeded
        succeeded.lastError = nil
        succeeded.lastFailureDisposition = nil
        succeeded.nextAttemptAt = nil
        succeeded.updatedAt = Date()
        await finish(succeeded)
        return true
    }

    private func execute(_ job: SessionJob) async throws {
        guard await store.snapshot().first(where: { $0.id == job.id })?.status == .running else {
            clearReservation(for: job)
            throw CancellationError()
        }
        let task: Task<Void, Error> = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()
            try await self.executor.execute(job)
            try Task.checkCancellation()
        }
        if job.kind == .cloudUpload { activeCloudExecutionTask = task }
        else if job.kind == .autoPrint { activePrintExecutionTask = task }
        else { activeFinalizationExecutionTask = task }
        defer {
            if activeCloudJobID == job.id {
                activeCloudJobID = nil
                activeCloudExecutionTask = nil
            }
            if activeFinalizationJobID == job.id {
                activeFinalizationJobID = nil
                activeFinalizationExecutionTask = nil
            }
            if activePrintJobID == job.id {
                activePrintJobID = nil
                activePrintExecutionTask = nil
            }
            clearReservation(for: job)
        }
        try await task.value
    }

    private func finish(_ job: SessionJob) async {
        do {
            let persisted = await store.snapshot().first { $0.id == job.id }
            if persisted?.status != .cancelled {
                try await store.update(job)
            }
            await reload()
        } catch {
            lastQueueError = error.localizedDescription
        }
    }

    private func apply(_ error: JobExecutionError, to job: inout SessionJob) {
        let message = error.localizedDescription
        job.lastError = message
        job.updatedAt = Date()
        switch error {
        case .permanent:
            job.lastFailureDisposition = .permanent
            job.status = message == "Cloud upload disabled in Settings" && job.kind == .cloudUpload
                ? .cancelled
                : .failed
            job.nextAttemptAt = nil
        case .retryable:
            job.lastFailureDisposition = .retryable
            if job.attemptCount >= SessionJobRetryPolicy.maximumAutomaticAttempts(for: job.kind) {
                job.status = .failed
                job.nextAttemptAt = nil
            } else {
                job.status = .waitingRetry
                job.nextAttemptAt = Date().addingTimeInterval(
                    SessionJobRetryPolicy.delay(afterAttempt: job.attemptCount)
                )
            }
        case .sideEffectUnknown:
            job.lastFailureDisposition = .sideEffectUnknown
            job.status = .failed
            job.nextAttemptAt = nil
        }
    }

    private func nextRunnableJob(in kinds: [SessionJobKind]) -> SessionJob? {
        let now = Date()
        let runnable = jobs.filter {
            kinds.contains($0.kind)
                && isRunnable($0, now: now)
                && dependenciesSatisfied(for: $0)
                && ($0.kind != .autoPrint || executor.isAutoPrintLaneAvailable)
        }
        // Required work is globally oldest-first. Optional GIF work only runs
        // when no required job is runnable, so heavy rendering cannot delay a
        // later session's strip/download/gallery/print path.
        let candidates = runnable.contains(where: { !$0.kind.isOptional })
            ? runnable.filter { !$0.kind.isOptional }
            : runnable
        return candidates.min {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
            return $0.id < $1.id
        }
    }

    private func isRunnable(_ job: SessionJob, now: Date) -> Bool {
        switch job.status {
        case .pending:
            return true
        case .waitingRetry:
            return job.nextAttemptAt.map { $0 <= now } ?? true
        case .running, .succeeded, .failed, .cancelled:
            return false
        }
    }

    private func dependenciesSatisfied(for currentJob: SessionJob) -> Bool {
        func job(for kind: SessionJobKind) -> SessionJob? {
            jobs
                .filter {
                    $0.sessionID == currentJob.sessionID
                        && $0.kind == kind
                        && $0.status != .cancelled
                }
                .max {
                    $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
                }
        }

        func succeeded(_ kind: SessionJobKind) -> Bool {
            job(for: kind)?.status == .succeeded
        }

        switch currentJob.kind {
        case .renderStrip:
            return true
        case .registerDownload, .autoPrint:
            return succeeded(.renderStrip)
        case .updateGallery:
            return succeeded(.renderStrip)
        case .renderGIF:
            guard let download = job(for: .registerDownload) else { return true }
            return download.status == .succeeded || download.status == .failed || download.status == .cancelled
        case .cloudUpload:
            guard succeeded(.renderStrip) else { return false }
            guard let gif = job(for: .renderGIF) else { return true }
            return gif.status == .succeeded || gif.status == .failed || gif.status == .cancelled
        }
    }

    private func reload() async {
        do {
            jobs = try await store.load()
            lastQueueError = persistentQueueError
            onJobsChanged?()
        } catch {
            persistentQueueError = error.localizedDescription
            lastQueueError = persistentQueueError
            await reloadFromSnapshot()
        }
    }

    private func reloadFromSnapshot() async {
        jobs = await store.snapshot()
        onJobsChanged?()
    }

    private func reserve(_ job: SessionJob) {
        activeReservations[job.id] = job.sessionID
        switch job.kind {
        case .cloudUpload:
            activeCloudJobID = job.id
        case .autoPrint:
            activePrintJobID = job.id
        default:
            activeFinalizationJobID = job.id
        }
    }

    private func clearReservation(for job: SessionJob) {
        activeReservations.removeValue(forKey: job.id)
        if activeCloudJobID == job.id {
            activeCloudJobID = nil
            activeCloudExecutionTask = nil
        }
        if activeFinalizationJobID == job.id {
            activeFinalizationJobID = nil
            activeFinalizationExecutionTask = nil
        }
        if activePrintJobID == job.id {
            activePrintJobID = nil
            activePrintExecutionTask = nil
        }
        resumeReadyQuiescenceWaiters()
    }

    private func waitForQuiescence(sessionID: String, timeout: Duration) async -> Bool {
        guard activeReservations.values.contains(sessionID) else { return true }
        let waiterID = UUID()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        return await withCheckedContinuation { continuation in
            quiescenceWaiters[waiterID] = (sessionID, continuation)
            Task { [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.timeoutQuiescenceWaiter(waiterID)
            }
            resumeReadyQuiescenceWaiters()
        }
    }

    private func resumeReadyQuiescenceWaiters() {
        let ready = quiescenceWaiters.filter { !activeReservations.values.contains($0.value.sessionID) }
        for (id, waiter) in ready {
            quiescenceWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: true)
        }
    }

    private func timeoutQuiescenceWaiter(_ id: UUID) {
        guard let waiter = quiescenceWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: false)
    }
}
