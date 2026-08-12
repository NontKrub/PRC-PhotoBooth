import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("Session delivery state")
struct SessionDeliveryTests {
    @Test("resolves local, cloud, and print states from the existing queue")
    func resolvesDelivery() {
        let now = Date()
        func job(_ kind: SessionJobKind, _ status: SessionJobStatus) -> SessionJob {
            SessionJob(
                id: UUID().uuidString,
                sessionID: "session",
                kind: kind,
                status: status,
                createdAt: now,
                updatedAt: now,
                lastAttemptAt: nil,
                nextAttemptAt: nil,
                attemptCount: 0,
                lastError: nil
            )
        }

        let status = SessionDeliveryResolver.resolve([
            job(.renderStrip, .succeeded),
            job(.registerDownload, .succeeded),
            job(.cloudUpload, .waitingRetry),
            job(.autoPrint, .failed)
        ])

        #expect(status.local == .localReady)
        #expect(status.cloud == .cloudPending)
        #expect(status.print == .printFailed)
    }
}
