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
    private var workerTask: Task<Void, Never>?
    private var persistentQueueError: String?

    private(set) var jobs: [SessionJob] = []
    private(set) var isRunning = false
    private(set) var lastQueueError: String?
    var onJobsChanged: (() -> Void)?

    init(store: JobQueueStore, executor: any SessionJobExecuting) {
        self.store = store
        self.executor = executor
    }

    func start() {
        guard workerTask == nil else { return }
        isRunning = true
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    func stop() {
        isRunning = false
        workerTask?.cancel()
        workerTask = nil
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

    func cancel(jobID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.cancel(jobID: jobID)
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

    private func runWorker() async {
        do {
            _ = try await store.load()
            try await store.resetInterruptedJobs()
            await reload()
        } catch {
            persistentQueueError = error.localizedDescription
            lastQueueError = persistentQueueError
            await reloadFromSnapshot()
        }

        while !Task.isCancelled {
            if await runNextJob() {
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

    private func runNextJob() async -> Bool {
        guard let selected = nextRunnableJob() else { return false }
        var running = selected
        running.status = .running
        running.attemptCount += 1
        running.lastAttemptAt = Date()
        running.nextAttemptAt = nil
        running.updatedAt = Date()
        do {
            try await store.update(running)
            await reload()
            if await store.snapshot().first(where: { $0.id == running.id })?.status == .cancelled {
                return true
            }
            try await executor.execute(running)
            running.status = .succeeded
            running.lastError = nil
            running.nextAttemptAt = nil
            running.updatedAt = Date()
        } catch let error as JobExecutionError {
            apply(error, to: &running)
        } catch {
            apply(.retryable(error.localizedDescription), to: &running)
        }
        do {
            let persisted = await store.snapshot().first { $0.id == running.id }
            if persisted?.status != .cancelled {
                try await store.update(running)
            }
            await reload()
        } catch {
            lastQueueError = error.localizedDescription
        }
        return true
    }

    private func apply(_ error: JobExecutionError, to job: inout SessionJob) {
        let message = error.localizedDescription
        job.lastError = message
        job.updatedAt = Date()
        switch error {
        case .permanent:
            job.status = message == "Cloud upload disabled in Settings" && job.kind == .cloudUpload
                ? .cancelled
                : .failed
            job.nextAttemptAt = nil
        case .retryable:
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

    private func nextRunnableJob() -> SessionJob? {
        let now = Date()
        for kind in [
            SessionJobKind.renderStrip,
            .registerDownload,
            .updateGallery,
            .renderGIF,
            .autoPrint,
            .cloudUpload
        ] {
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
