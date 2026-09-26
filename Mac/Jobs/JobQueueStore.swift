import Foundation

enum JobQueueStoreError: LocalizedError, Equatable {
    case corrupt(URL, String, URL?)
    case persistenceFailed(URL, String)
    case missingJob(String)
    case invalidJob(String)
    case sessionCancelled(String)
    case manualRetryRejected(String, ManualJobRetryEligibility)

    var errorDescription: String? {
        switch self {
        case .corrupt(let url, let message, let backup):
            let preserved = backup.map { " Preserved as \($0.lastPathComponent)." } ?? ""
            return "Corrupt job queue \(url.path): \(message).\(preserved)"
        case .persistenceFailed(let url, let message):
            return "Job queue persistence failed at \(url.path): \(message)"
        case .missingJob(let id): return "Job not found: \(id)"
        case .invalidJob(let id): return "Invalid job identifier: \(id)"
        case .sessionCancelled(let id): return "Session is durably cancelled: \(id)"
        case .manualRetryRejected(let id, let reason):
            return "Job \(id) is not eligible for manual retry (\(reason.description))."
        }
    }
}

enum ManualJobRetryEligibility: Sendable, Equatable {
    case eligible
    case notFailed
    case missingDisposition
    case permanent
    case sideEffectUnknown
    case cancelled
    case sessionCancelled

    static func evaluate(
        _ job: SessionJob,
        sessionIsCancelled: Bool = false,
        manifestIsCancelled: Bool = false
    ) -> Self {
        guard !sessionIsCancelled, !manifestIsCancelled else { return .sessionCancelled }
        switch job.status {
        case .failed:
            switch job.lastFailureDisposition {
            case .retryable: return .eligible
            case .permanent: return .permanent
            case .sideEffectUnknown: return .sideEffectUnknown
            case nil: return .missingDisposition
            }
        case .cancelled:
            return .cancelled
        case .pending, .running, .waitingRetry, .succeeded:
            return .notFailed
        }
    }
}

extension ManualJobRetryEligibility {
    var description: String {
        switch self {
        case .eligible: return "eligible"
        case .notFailed: return "not failed"
        case .missingDisposition: return "failure disposition is missing"
        case .permanent: return "permanent failure"
        case .sideEffectUnknown: return "side effect requires resolution"
        case .cancelled: return "job is cancelled"
        case .sessionCancelled: return "session is cancelled"
        }
    }
}

enum ManualRetrySkippedReason: Sendable, Equatable {
    case missing
    case ineligible(ManualJobRetryEligibility)
}

struct ManualRetrySkippedJob: Sendable, Equatable {
    var jobID: String
    var reason: ManualRetrySkippedReason
}

struct ManualRetryBatchResult: Sendable, Equatable {
    var retried: [SessionJob]
    var skipped: [ManualRetrySkippedJob]
}

enum JobQueueLoadState: Sendable, Equatable {
    case notLoaded
    case loaded
    case persistenceUnavailable
    case corrupt
}

actor JobQueueStore {
    private let fileURL: URL
    private var cancellationFileURL: URL { fileURL.deletingPathExtension().appendingPathExtension("cancelled-sessions.json") }
    private var jobs: [SessionJob] = []
    private var persistedJobs: [SessionJob] = []
    private var cancelledSessionIDs: Set<String> = []
    private var loadState: JobQueueLoadState = .notLoaded
    private var loadError: JobQueueStoreError?
    private(set) var lastPersistenceError: String?
#if DEBUG
    private var failNextPersistence = false
#endif

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

#if DEBUG
    func failNextPersistenceForTesting() {
        failNextPersistence = true
    }
#endif

    func load() throws -> [SessionJob] {
        switch loadState {
        case .loaded:
            return jobs
        case .persistenceUnavailable, .corrupt:
            throw loadError ?? JobQueueStoreError.persistenceFailed(fileURL, "Queue is unavailable")
        case .notLoaded:
            break
        }
        return try recoverDurableState()
    }

    func durabilityState() -> JobQueueLoadState {
        loadState
    }

    func recoverDurableState() throws -> [SessionJob] {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let durableCancelled = try readCancellationBarrier()
            let decodedJobs: [SessionJob]
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    decodedJobs = try decoder.decode(
                        [SessionJob].self,
                        from: Data(contentsOf: fileURL)
                    )
                } catch {
                    let backup = try? preserveCorruptFile()
                    let failure = JobQueueStoreError.corrupt(
                        fileURL,
                        error.localizedDescription,
                        backup
                    )
                    markUnavailable(failure, state: .corrupt)
                    throw failure
                }
            } else {
                decodedJobs = []
            }

            let normalized = normalize(decodedJobs, cancelledSessionIDs: durableCancelled)
            try persistDurableJobs(normalized.jobs)
            jobs = normalized.jobs
            persistedJobs = normalized.jobs
            cancelledSessionIDs = durableCancelled
            loadError = nil
            lastPersistenceError = nil
            loadState = .loaded
            return jobs
        } catch let error as JobQueueStoreError {
            throw error
        } catch {
            let failure = JobQueueStoreError.persistenceFailed(fileURL, error.localizedDescription)
            markUnavailable(failure, state: .persistenceUnavailable)
            throw failure
        }
    }

    func snapshot() -> [SessionJob] {
        jobs
    }

    func enqueue(
        sessionID: String,
        kind: SessionJobKind,
        finalizationTransactionID: String? = nil,
        requiresCloudPublicationBeforePrint: Bool = false
    ) throws -> SessionJob {
        try enqueueBatch(
            sessionID: sessionID,
            kinds: [kind],
            finalizationTransactionID: finalizationTransactionID,
            requiresCloudPublicationBeforePrint: requiresCloudPublicationBeforePrint
        ).first!
    }

    func enqueueBatch(
        sessionID: String,
        kinds: [SessionJobKind],
        finalizationTransactionID: String? = nil,
        requiresCloudPublicationBeforePrint: Bool = false
    ) throws -> [SessionJob] {
        try ensureLoaded()
        guard !cancelledSessionIDs.contains(sessionID) else {
            throw JobQueueStoreError.sessionCancelled(sessionID)
        }
        var result: [SessionJob] = []
        var missingKinds = Set<SessionJobKind>()
        for kind in kinds where missingKinds.insert(kind).inserted {
            if let existingIndex = jobs.firstIndex(where: {
                $0.sessionID == sessionID
                    && $0.kind == kind
                    && $0.finalizationTransactionID == finalizationTransactionID
            }) {
                if kind == .autoPrint,
                   requiresCloudPublicationBeforePrint,
                   jobs[existingIndex].status != .succeeded,
                   jobs[existingIndex].status != .running {
                    jobs[existingIndex].requiresCloudPublicationBeforePrint = true
                }
                result.append(jobs[existingIndex])
                continue
            }
            let now = Date()
            let job = SessionJob(
                id: UUID().uuidString,
                sessionID: sessionID,
                kind: kind,
                status: .pending,
                createdAt: now,
                updatedAt: now,
                lastAttemptAt: nil,
                nextAttemptAt: now,
                attemptCount: 0,
                lastError: nil,
                lastFailureDisposition: nil,
                finalizationTransactionID: finalizationTransactionID,
                requiresCloudPublicationBeforePrint: kind == .autoPrint && requiresCloudPublicationBeforePrint
            )
            jobs.append(job)
            result.append(job)
        }
        reconcileCloudDependentPrints(sessionID: sessionID, transactionID: finalizationTransactionID)
        try persist()
        return result
    }

    func update(_ job: SessionJob) throws {
        try ensureLoaded()
        if cancelledSessionIDs.contains(job.sessionID), job.status != .cancelled {
            throw JobQueueStoreError.sessionCancelled(job.sessionID)
        }
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
            throw JobQueueStoreError.missingJob(job.id)
        }
        jobs[index] = job
        try persist()
    }

    func finish(_ job: SessionJob) throws -> Bool {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
            throw JobQueueStoreError.missingJob(job.id)
        }
        guard jobs[index].status == .running,
              (!cancelledSessionIDs.contains(job.sessionID) || job.kind == .autoPrint) else {
            return false
        }
        jobs[index] = job
        if job.kind == .cloudUpload {
            reconcileCloudDependentPrints(sessionID: job.sessionID, transactionID: job.finalizationTransactionID)
        }
        try persist()
        return true
    }

    func claim(jobID: String, now: Date = Date()) throws -> SessionJob? {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            throw JobQueueStoreError.missingJob(jobID)
        }
        guard !cancelledSessionIDs.contains(jobs[index].sessionID) else {
            if jobs[index].status != .cancelled {
                jobs[index].status = .cancelled
                jobs[index].nextAttemptAt = nil
                jobs[index].updatedAt = now
                try persist()
            }
            return nil
        }
        guard jobs[index].status == .pending
                || (jobs[index].status == .waitingRetry
                    && (jobs[index].nextAttemptAt.map { $0 <= now } ?? true)) else {
            return nil
        }
        guard SessionJobDependencyPolicy.prerequisitesSatisfied(for: jobs[index], in: jobs) else {
            return nil
        }

        jobs[index].status = .running
        jobs[index].attemptCount += 1
        jobs[index].lastAttemptAt = now
        jobs[index].nextAttemptAt = nil
        jobs[index].updatedAt = now
        try persist()
        return jobs[index]
    }

    func retry(jobID: String) throws {
        let result = try retryJobs(jobIDs: [jobID])
        guard result.retried.isEmpty else { return }
        guard let skipped = result.skipped.first else { return }
        switch skipped.reason {
        case .missing:
            throw JobQueueStoreError.missingJob(jobID)
        case .ineligible(.sessionCancelled):
            if let job = jobs.first(where: { $0.id == jobID }) {
                throw JobQueueStoreError.sessionCancelled(job.sessionID)
            }
            throw JobQueueStoreError.missingJob(jobID)
        case .ineligible(let eligibility):
            throw JobQueueStoreError.manualRetryRejected(jobID, eligibility)
        }
    }

    func manualRetryEligibility(jobID: String) throws -> ManualJobRetryEligibility {
        try ensureLoaded()
        guard let job = jobs.first(where: { $0.id == jobID }) else {
            throw JobQueueStoreError.missingJob(jobID)
        }
        return ManualJobRetryEligibility.evaluate(
            job,
            sessionIsCancelled: cancelledSessionIDs.contains(job.sessionID)
        )
    }

    func eligibleManualRetryJobs(jobIDs: Set<String>) throws -> [SessionJob] {
        try ensureLoaded()
        return jobs
            .filter { jobIDs.contains($0.id) }
            .filter {
                ManualJobRetryEligibility.evaluate(
                    $0,
                    sessionIsCancelled: cancelledSessionIDs.contains($0.sessionID)
                ) == .eligible
            }
            .sorted { $0.id < $1.id }
    }

    func retryJobs(jobIDs: Set<String>) throws -> ManualRetryBatchResult {
        try ensureLoaded()
        let now = Date()
        var prospectiveJobs = jobs
        var retried: [SessionJob] = []
        var skipped: [ManualRetrySkippedJob] = []

        for jobID in jobIDs.sorted() {
            guard let index = prospectiveJobs.firstIndex(where: { $0.id == jobID }) else {
                skipped.append(ManualRetrySkippedJob(jobID: jobID, reason: .missing))
                continue
            }
            let job = prospectiveJobs[index]
            let eligibility = ManualJobRetryEligibility.evaluate(
                job,
                sessionIsCancelled: cancelledSessionIDs.contains(job.sessionID)
            )
            guard eligibility == .eligible else {
                skipped.append(ManualRetrySkippedJob(jobID: jobID, reason: .ineligible(eligibility)))
                continue
            }
            prospectiveJobs[index].status = .pending
            prospectiveJobs[index].attemptCount = 0
            prospectiveJobs[index].lastAttemptAt = nil
            prospectiveJobs[index].nextAttemptAt = now
            prospectiveJobs[index].lastError = nil
            prospectiveJobs[index].lastFailureDisposition = nil
            prospectiveJobs[index].updatedAt = now
            retried.append(prospectiveJobs[index])
        }

        if !retried.isEmpty {
            try persist(prospectiveJobs)
        }
        return ManualRetryBatchResult(retried: retried, skipped: skipped)
    }

    func resolveUnknownPrint(
        jobID: String,
        resolution: UnknownPrintResolution
    ) throws -> SessionJob {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            throw JobQueueStoreError.missingJob(jobID)
        }
        guard jobs[index].kind == .autoPrint,
              jobs[index].status == .failed,
              jobs[index].lastFailureDisposition == .sideEffectUnknown else {
            return jobs[index]
        }
        switch resolution {
        case .printed:
            jobs[index].status = .succeeded
            jobs[index].lastError = nil
            jobs[index].lastFailureDisposition = nil
            jobs[index].nextAttemptAt = nil
        case .notPrinted:
            if cancelledSessionIDs.contains(jobs[index].sessionID) {
                cancelledSessionIDs.remove(jobs[index].sessionID)
                do {
                    try persistCancellationBarrier()
                } catch {
                    cancelledSessionIDs.insert(jobs[index].sessionID)
                    throw error
                }
            }
            jobs[index].status = .pending
            // The unknown outcome was not a confirmed printer attempt and
            // therefore must not consume an automatic retry budget.
            jobs[index].attemptCount = max(0, jobs[index].attemptCount - 1)
            jobs[index].lastAttemptAt = nil
            jobs[index].lastError = nil
            jobs[index].lastFailureDisposition = nil
            jobs[index].nextAttemptAt = Date()
        }
        jobs[index].updatedAt = Date()
        try persist()
        return jobs[index]
    }

    func forceRequeueCloudUpload(
        sessionID: String,
        finalizationTransactionID: String? = nil
    ) throws -> CloudUploadRequeueResult {
        try ensureLoaded()
        guard !cancelledSessionIDs.contains(sessionID) else { return .sessionCancelled }
        guard let index = jobs.firstIndex(where: {
            $0.sessionID == sessionID
                && $0.kind == .cloudUpload
                && (finalizationTransactionID == nil || $0.finalizationTransactionID == finalizationTransactionID)
        }) else {
            return .notFound
        }

        switch jobs[index].status {
        case .pending, .waitingRetry:
            return .alreadyQueued
        case .running:
            return .alreadyRunning
        case .failed, .cancelled, .succeeded:
            jobs[index].status = .pending
            jobs[index].attemptCount = 0
            jobs[index].lastAttemptAt = nil
            jobs[index].nextAttemptAt = Date()
            jobs[index].lastError = nil
            jobs[index].lastFailureDisposition = nil
            jobs[index].updatedAt = Date()
            try persist()
            return .queued
        }
    }

    func requeueFailedCloudUploads(
        sessionIDs: Set<String>,
        finalizationTransactionIDs: [String: String] = [:]
    ) throws -> Int {
        try ensureLoaded()
        let now = Date()
        var count = 0
        for index in jobs.indices where sessionIDs.contains(jobs[index].sessionID)
            && !cancelledSessionIDs.contains(jobs[index].sessionID)
            && jobs[index].kind == .cloudUpload
            && (finalizationTransactionIDs[jobs[index].sessionID] == nil
                || jobs[index].finalizationTransactionID == finalizationTransactionIDs[jobs[index].sessionID])
            && jobs[index].status == .failed
            && jobs[index].lastFailureDisposition == .retryable {
            jobs[index].status = .pending
            jobs[index].attemptCount = 0
            jobs[index].lastAttemptAt = nil
            jobs[index].nextAttemptAt = now
            jobs[index].lastError = nil
            jobs[index].lastFailureDisposition = nil
            jobs[index].updatedAt = now
            count += 1
        }
        if count > 0 { try persist() }
        return count
    }

    func cancel(jobID: String) throws {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            throw JobQueueStoreError.missingJob(jobID)
        }
        guard jobs[index].status != .succeeded else { return }
        guard !(jobs[index].kind == .autoPrint && jobs[index].status == .running),
              jobs[index].lastFailureDisposition != .sideEffectUnknown else { return }
        jobs[index].status = .cancelled
        jobs[index].nextAttemptAt = nil
        jobs[index].updatedAt = Date()
        try persist()
    }

    func cancelJobs(sessionID: String) throws {
        try ensureLoaded()
        cancelledSessionIDs.insert(sessionID)
        try persistCancellationBarrier()
        var changed = false
        for index in jobs.indices where jobs[index].sessionID == sessionID {
            guard jobs[index].status != .succeeded, jobs[index].status != .cancelled else { continue }
            guard !(jobs[index].kind == .autoPrint
                && (jobs[index].status == .running || jobs[index].lastFailureDisposition == .sideEffectUnknown)) else { continue }
            jobs[index].status = .cancelled
            jobs[index].lastError = "Session cancelled"
            jobs[index].nextAttemptAt = nil
            jobs[index].updatedAt = Date()
            changed = true
        }
        if changed { try persist() }
    }

    func cancelOptionalJobs(sessionID: String) throws {
        try ensureLoaded()
        let optionalKinds = Set(SessionJobKind.allCases.filter(\.isOptional))
        var changed = false
        for index in jobs.indices where jobs[index].sessionID == sessionID
            && optionalKinds.contains(jobs[index].kind)
            && jobs[index].status != .succeeded
            && jobs[index].status != .cancelled {
            guard !(jobs[index].kind == .autoPrint
                && (jobs[index].status == .running || jobs[index].lastFailureDisposition == .sideEffectUnknown)) else { continue }
            jobs[index].status = .cancelled
            jobs[index].nextAttemptAt = nil
            jobs[index].updatedAt = Date()
            changed = true
        }
        if changed { try persist() }
    }

    func resetInterruptedJobs() throws {
        try ensureLoaded()
        let now = Date()
        var changed = false
        for index in jobs.indices where jobs[index].status == .running {
            if jobs[index].kind == .autoPrint {
                jobs[index].status = .failed
                jobs[index].lastError = "Print submission outcome is unknown after app restart. Verify the printer before retrying."
                jobs[index].lastFailureDisposition = .sideEffectUnknown
                jobs[index].nextAttemptAt = nil
            } else {
                jobs[index].status = .pending
                jobs[index].lastAttemptAt = nil
                jobs[index].nextAttemptAt = now
            }
            jobs[index].updatedAt = now
            changed = true
        }
        if changed { try persist() }
    }

    func migrateLegacyJobs(
        sessionID: String,
        transactionID: String,
        kinds: Set<SessionJobKind>,
        requiresCloudPublicationBeforePrint: Bool = false
    ) throws {
        try ensureLoaded()
        var changed = false
        for kind in kinds {
            guard !jobs.contains(where: {
                $0.sessionID == sessionID
                    && $0.kind == kind
                    && $0.finalizationTransactionID == transactionID
            }),
            let candidate = jobs.indices
                .filter({ jobs[$0].sessionID == sessionID && jobs[$0].kind == kind && jobs[$0].finalizationTransactionID == nil })
                .min(by: { jobs[$0].createdAt == jobs[$1].createdAt ? jobs[$0].id < jobs[$1].id : jobs[$0].createdAt < jobs[$1].createdAt }) else {
                continue
            }
            jobs[candidate].finalizationTransactionID = transactionID
            jobs[candidate].requiresCloudPublicationBeforePrint = kind == .autoPrint && requiresCloudPublicationBeforePrint
            jobs[candidate].updatedAt = Date()
            changed = true
        }
        if requiresCloudPublicationBeforePrint,
           let printIndex = jobs.firstIndex(where: {
               $0.sessionID == sessionID
                   && $0.finalizationTransactionID == transactionID
                   && $0.kind == .autoPrint
                   && $0.status != .succeeded
                   && $0.status != .running
                   && $0.requiresCloudPublicationBeforePrint != true
           }) {
            jobs[printIndex].requiresCloudPublicationBeforePrint = true
            jobs[printIndex].updatedAt = Date()
            changed = true
        }
        if changed { try persist() }
    }

    func purgeOldSucceededJobs(olderThan date: Date) throws {
        try ensureLoaded()
        let oldCount = jobs.count
        let sessionsWithActiveWork = Set(
            jobs.filter { $0.status != .succeeded && $0.status != .cancelled }
                .map(\.sessionID)
        )
        jobs.removeAll {
            $0.status == .succeeded
            && $0.updatedAt < date
            && !sessionsWithActiveWork.contains($0.sessionID)
        }
        if jobs.count != oldCount { try persist() }
    }

    func deleteJobs(sessionID: String) throws {
        try ensureLoaded()
        let oldCount = jobs.count
        jobs.removeAll { $0.sessionID == sessionID }
        if jobs.count != oldCount { try persist() }
    }

    private func reconcileCloudDependentPrints(sessionID: String, transactionID: String?) {
        guard let cloudJob = jobs.first(where: {
            $0.sessionID == sessionID
                && $0.finalizationTransactionID == transactionID
                && $0.kind == .cloudUpload
        }) else { return }
        let now = Date()
        for index in jobs.indices where jobs[index].sessionID == sessionID
            && jobs[index].finalizationTransactionID == transactionID
            && jobs[index].kind == .autoPrint
            && jobs[index].requiresCloudPublicationBeforePrint == true {
            if cloudJob.status == .failed || cloudJob.status == .cancelled {
                guard jobs[index].status == .pending || jobs[index].status == .waitingRetry else { continue }
                jobs[index].status = .cancelled
                jobs[index].lastError = SessionJobDependencyPolicy.printWithheldUntilCloudPublishedError
                jobs[index].lastFailureDisposition = nil
                jobs[index].nextAttemptAt = nil
                jobs[index].updatedAt = now
            } else if cloudJob.status == .succeeded,
                      jobs[index].status == .cancelled,
                      jobs[index].lastError == SessionJobDependencyPolicy.printWithheldUntilCloudPublishedError {
                jobs[index].status = .pending
                jobs[index].lastError = nil
                jobs[index].lastFailureDisposition = nil
                jobs[index].nextAttemptAt = now
                jobs[index].updatedAt = now
            }
        }
    }

    func forgetCancellationBarrierIfSafe(sessionID: String) throws {
        try ensureLoaded()
        guard cancelledSessionIDs.contains(sessionID) else { return }
        guard jobs.allSatisfy({ $0.sessionID != sessionID }) else { return }
        let previous = cancelledSessionIDs
        cancelledSessionIDs.remove(sessionID)
        do {
            try persistCancellationBarrier()
        } catch {
            cancelledSessionIDs = previous
            throw error
        }
    }

    private func ensureLoaded() throws {
        switch loadState {
        case .notLoaded:
            _ = try load()
        case .loaded:
            return
        case .persistenceUnavailable, .corrupt:
            throw loadError ?? JobQueueStoreError.persistenceFailed(fileURL, "Queue is unavailable")
        }
    }

    private func readCancellationBarrier() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: cancellationFileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: cancellationFileURL)
            return Set(try JSONDecoder().decode([String].self, from: data))
        } catch {
            let failure = JobQueueStoreError.corrupt(cancellationFileURL, error.localizedDescription, nil)
            markUnavailable(failure, state: .corrupt)
            throw failure
        }
    }

    private func persistCancellationBarrier() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(cancelledSessionIDs.sorted()).write(to: cancellationFileURL, options: [.atomic])
        } catch {
            let failure = JobQueueStoreError.persistenceFailed(
                cancellationFileURL,
                error.localizedDescription
            )
            markUnavailable(failure, state: .persistenceUnavailable)
            throw failure
        }
    }

    private func normalize(
        _ source: [SessionJob],
        cancelledSessionIDs: Set<String>
    ) -> (jobs: [SessionJob], changed: Bool) {
        var jobs = source
        let now = Date()
        var changed = false
        for index in jobs.indices where jobs[index].status == .running {
            if jobs[index].kind == .autoPrint {
                jobs[index].status = .failed
                jobs[index].lastError = "Print submission outcome is unknown after app restart. Verify the printer before retrying."
                jobs[index].lastFailureDisposition = .sideEffectUnknown
                jobs[index].nextAttemptAt = nil
            } else {
                jobs[index].status = .pending
                jobs[index].lastAttemptAt = nil
                jobs[index].nextAttemptAt = now
            }
            jobs[index].updatedAt = now
            changed = true
        }
        // Older versions could persist a cancelled session's uncertain print
        // as cancelled. Keep the uncertainty operator-visible after restart.
        for index in jobs.indices where jobs[index].kind == .autoPrint
            && jobs[index].lastFailureDisposition == .sideEffectUnknown
            && jobs[index].status == .cancelled {
            jobs[index].status = .failed
            jobs[index].lastError = jobs[index].lastError
                ?? "Print submission outcome is unknown. Verify the printer before resolving this job."
            jobs[index].nextAttemptAt = nil
            jobs[index].updatedAt = now
            changed = true
        }
        for index in jobs.indices where cancelledSessionIDs.contains(jobs[index].sessionID)
            && jobs[index].status != .succeeded
            && jobs[index].status != .cancelled
            && !(jobs[index].kind == .autoPrint
                && jobs[index].lastFailureDisposition == .sideEffectUnknown) {
            jobs[index].status = .cancelled
            jobs[index].lastError = "Session cancelled"
            jobs[index].nextAttemptAt = nil
            jobs[index].updatedAt = now
            changed = true
        }
        let reconciled = reconcileDuplicateJobs(jobs)
        return (reconciled.jobs, changed || reconciled.changed)
    }

    private func persist() throws {
        try persist(jobs)
    }

    private func persist(_ prospectiveJobs: [SessionJob]) throws {
        do {
            try persistDurableJobs(prospectiveJobs)
            jobs = prospectiveJobs
            persistedJobs = prospectiveJobs
            lastPersistenceError = nil
        } catch {
            jobs = persistedJobs
            let failure = JobQueueStoreError.persistenceFailed(fileURL, error.localizedDescription)
            markUnavailable(failure, state: .persistenceUnavailable)
            throw failure
        }
    }

    private func persistDurableJobs(_ jobs: [SessionJob]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
#if DEBUG
        if failNextPersistence {
            failNextPersistence = false
            throw NSError(
                domain: "PRCPhotoBooth.JobQueueStoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Injected queue persistence failure"]
            )
        }
#endif
        try encoder.encode(jobs).write(to: fileURL, options: [.atomic])
    }

    private func markUnavailable(_ error: JobQueueStoreError, state: JobQueueLoadState) {
        loadError = error
        loadState = state
        lastPersistenceError = error.localizedDescription
    }

    private func preserveCorruptFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("jobs-corrupt-\(formatter.string(from: Date())).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("jobs-corrupt-\(formatter.string(from: Date()))-\(suffix).json")
            suffix += 1
        }
        try FileManager.default.copyItem(at: fileURL, to: backup)
        return backup
    }

    private func reconcileDuplicateJobs(_ source: [SessionJob]) -> (jobs: [SessionJob], changed: Bool) {
        var jobs = source
        var changed = false
        // A succeeded record wins; otherwise preserve an uncertain physical
        // side effect; otherwise keep the oldest stable record. Every other
        // record is cancelled so recovery cannot schedule duplicate work.
        let groups = Dictionary(grouping: jobs.indices.filter { jobs[$0].status != .cancelled }) {
            "\(jobs[$0].sessionID)|\(jobs[$0].finalizationTransactionID ?? "legacy")|\(jobs[$0].kind.rawValue)"
        }
        for indices in groups.values where indices.count > 1 {
            let winner = indices.min { left, right in
                let leftJob = jobs[left]
                let rightJob = jobs[right]
                let leftRank = leftJob.status == .succeeded ? 0 : leftJob.lastFailureDisposition == .sideEffectUnknown ? 1 : 2
                let rightRank = rightJob.status == .succeeded ? 0 : rightJob.lastFailureDisposition == .sideEffectUnknown ? 1 : 2
                if leftRank != rightRank { return leftRank < rightRank }
                if leftJob.createdAt != rightJob.createdAt { return leftJob.createdAt < rightJob.createdAt }
                return leftJob.id < rightJob.id
            }!
            for index in indices where index != winner {
                jobs[index].status = .cancelled
                jobs[index].nextAttemptAt = nil
                jobs[index].lastError = "Duplicate job record cancelled during queue recovery."
                jobs[index].updatedAt = Date()
                changed = true
            }
        }
        return (jobs, changed)
    }
}
