import Foundation

@MainActor
final class SessionJobExecutor: SessionJobExecuting {
    func execute(_ job: SessionJob) async throws {
        throw JobExecutionError.permanent("No executor configured for \(job.kind.rawValue).")
    }
}
