import Foundation
import Observation

@MainActor
protocol SessionJobExecuting: AnyObject {
    func execute(_ job: SessionJob) async throws
}

@MainActor
@Observable
final class SessionJobQueue {
    private let store: JobQueueStore
    private let executor: any SessionJobExecuting
    private var startupTask: Task<Void, Never>?
    private var finalizationWorkerTask: Task<Void, Never>?
    private var cloudWorkerTask: Task<Void, Never>?
    private var activeCloudJobID: String?
    private var activeCloudExecutionTask: Task<Void, Error>?
    private var persistentQueueError: String?

    private let finalizationKinds: [SessionJobKind] = [
        .renderStrip,
        .registerDownload,
        .updateGallery,
        .renderGIF,
        .autoPrint
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
        guard startupTask == nil, finalizationWorkerTask == nil, cloudWorkerTask == nil else { return }
        isRunning = true
        startupTask = Task { [weak self] in
            await self?.prepareWorkers()
        }
    }

    func stop() {
        isRunning = false
        startupTask?.cancel()
        finalizationWorkerTask?.cancel()
        cloudWorkerTask?.cancel()
        activeCloudExecutionTask?.cancel()
        startupTask = nil
        finalizationWorkerTask = nil
        cloudWorkerTask = nil
        activeCloudJobID = nil
        activeCloudExecutionTask = nil
    }

    func refresh() {
        Task { [weak self] in
            await self?.reload()
        }
    }

    func enqueueFinalizationJobs(for manifest: SessionManifest) {
        var kinds: [SessionJobKind] = [.renderStrip, .registerDownload, .updateGallery]
        if manifest.shots.contains(where: { !$0.gifFrameFileNames.isEmpty }) {
            kinds.append(.renderGIF)
        }
        enqueue(kinds: kinds, sessionID: manifest.id)
    }

    func enqueueAutoPrint(for manifest: SessionManifest) {
        enqueue(kinds: [.autoPrint], sessionID: manifest.id)
    }

    func enqueueCloudUpload(for manifest: SessionManifest) {
        enqueue(kinds: [.cloudUpload], sessionID: manifest.id)
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
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func cancelJobs(sessionID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.cancelJobs(sessionID: sessionID)
                if let activeCloudJobID,
                   await store.snapshot().contains(where: { $0.id == activeCloudJobID && $0.sessionID == sessionID }) {
                    activeCloudExecutionTask?.cancel()
                }
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
        }
    }

    func retryAllFailed() {
        Task { [weak self] in
            guard let self else { return }
            let failed = jobs.filter { $0.status == .failed }
            do {
                for job in failed { try await store.retry(jobID: job.id) }
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

    private func enqueue(kinds: [SessionJobKind], sessionID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                for kind in kinds {
                    _ = try await store.enqueue(sessionID: sessionID, kind: kind)
                }
                await reload()
            } catch {
                lastQueueError = error.localizedDescription
            }
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
        guard job.kind == .cloudUpload else {
            try await executor.execute(job)
            return
        }

        let task: Task<Void, Error> = Task { @MainActor in
            try await executor.execute(job)
        }
        activeCloudJobID = job.id
        activeCloudExecutionTask = task
        defer {
            if activeCloudJobID == job.id {
                activeCloudJobID = nil
                activeCloudExecutionTask = nil
            }
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
        }
    }

    private func nextRunnableJob(in kinds: [SessionJobKind]) -> SessionJob? {
        let now = Date()
        for kind in kinds {
            let candidates = jobs
                .filter { $0.kind == kind && isRunnable($0, now: now) }
                .sorted { $0.createdAt < $1.createdAt }
            if let job = candidates.first, dependenciesSatisfied(for: job) {
                return job
            }
        }
        return nil
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
            jobs.first { $0.sessionID == currentJob.sessionID && $0.kind == kind }
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
            return succeeded(.renderStrip) && succeeded(.registerDownload)
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
}
