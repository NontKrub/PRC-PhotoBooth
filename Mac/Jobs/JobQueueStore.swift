import Foundation

enum JobQueueStoreError: LocalizedError, Equatable {
    case corrupt(URL, String, URL?)
    case missingJob(String)
    case invalidJob(String)

    var errorDescription: String? {
        switch self {
        case .corrupt(let url, let message, let backup):
            let preserved = backup.map { " Preserved as \($0.lastPathComponent)." } ?? ""
            return "Corrupt job queue \(url.path): \(message).\(preserved)"
        case .missingJob(let id): return "Job not found: \(id)"
        case .invalidJob(let id): return "Invalid job identifier: \(id)"
        }
    }
}

actor JobQueueStore {
    private let fileURL: URL
    private var jobs: [SessionJob] = []
    private var hasLoaded = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [SessionJob] {
        if hasLoaded { return jobs }
        hasLoaded = true
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try persist()
            return jobs
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = try decoder.decode([SessionJob].self, from: Data(contentsOf: fileURL))
            let now = Date()
            var changed = false
            for index in jobs.indices {
                if jobs[index].status == .running {
                    jobs[index].status = .pending
                    jobs[index].lastAttemptAt = nil
                    jobs[index].nextAttemptAt = now
                    jobs[index].updatedAt = now
                    changed = true
                }
            }
            changed = cancelDuplicateActiveJobs() || changed
            if changed { try persist() }
            return jobs
        } catch {
            let backup = try? preserveCorruptFile()
            jobs = []
            try persist()
            throw JobQueueStoreError.corrupt(fileURL, error.localizedDescription, backup)
        }
    }

    func snapshot() -> [SessionJob] {
        jobs
    }

    func enqueue(sessionID: String, kind: SessionJobKind) throws -> SessionJob {
        try ensureLoaded()
        if let existing = jobs.first(where: { $0.sessionID == sessionID && $0.kind == kind && $0.status != .cancelled }) {
            return existing
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
            lastError: nil
        )
        jobs.append(job)
        try persist()
        return job
    }

    func update(_ job: SessionJob) throws {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
            throw JobQueueStoreError.missingJob(job.id)
        }
        jobs[index] = job
        try persist()
    }

    func retry(jobID: String) throws {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            throw JobQueueStoreError.missingJob(jobID)
        }
        guard jobs[index].status != .succeeded else { return }
        jobs[index].status = .pending
        jobs[index].attemptCount = 0
        jobs[index].lastAttemptAt = nil
        jobs[index].nextAttemptAt = Date()
        jobs[index].lastError = nil
        jobs[index].updatedAt = Date()
        try persist()
    }

    func forceRequeueCloudUpload(sessionID: String) throws -> CloudUploadRequeueResult {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: {
            $0.sessionID == sessionID && $0.kind == .cloudUpload
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
            jobs[index].updatedAt = Date()
            try persist()
            return .queued
        }
    }

    func cancel(jobID: String) throws {
        try ensureLoaded()
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            throw JobQueueStoreError.missingJob(jobID)
        }
        guard jobs[index].status != .succeeded else { return }
        jobs[index].status = .cancelled
        jobs[index].nextAttemptAt = nil
        jobs[index].updatedAt = Date()
        try persist()
    }

    func cancelJobs(sessionID: String) throws {
        try ensureLoaded()
        var changed = false
        for index in jobs.indices where jobs[index].sessionID == sessionID {
            guard jobs[index].status != .succeeded, jobs[index].status != .cancelled else { continue }
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
            jobs[index].status = .pending
            jobs[index].lastAttemptAt = nil
            jobs[index].nextAttemptAt = now
            jobs[index].updatedAt = now
            changed = true
        }
        if changed { try persist() }
    }

    func purgeOldSucceededJobs(olderThan date: Date) throws {
        try ensureLoaded()
        let oldCount = jobs.count
        jobs.removeAll { $0.status == .succeeded && $0.updatedAt < date }
        if jobs.count != oldCount { try persist() }
    }

    func deleteJobs(sessionID: String) throws {
        try ensureLoaded()
        let oldCount = jobs.count
        jobs.removeAll { $0.sessionID == sessionID }
        if jobs.count != oldCount { try persist() }
    }

    private func ensureLoaded() throws {
        if !hasLoaded { _ = try load() }
    }

    private func persist() throws {
        var encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: [.atomic])
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
        try FileManager.default.moveItem(at: fileURL, to: backup)
        return backup
    }

    private func cancelDuplicateActiveJobs() -> Bool {
        var seen = Set<String>()
        var changed = false
        for index in jobs.indices {
            guard jobs[index].status != .cancelled else { continue }
            let key = "\(jobs[index].sessionID)|\(jobs[index].kind.rawValue)"
            if seen.contains(key) {
                jobs[index].status = .cancelled
                jobs[index].nextAttemptAt = nil
                jobs[index].lastError = "Duplicate job record cancelled during queue recovery."
                jobs[index].updatedAt = Date()
                changed = true
            } else {
                seen.insert(key)
            }
        }
        return changed
    }
}
