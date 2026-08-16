import Foundation
import Network
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Local download server")
struct LocalWebServerTests {
    @Test("bind failure is reported without crashing")
    @MainActor
    func bindFailureIsReported() async throws {
        let holder = try NWListener(using: .tcp)
        let port = try await withCheckedThrowingContinuation { continuation in
            holder.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = holder.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: TestError.missingPort)
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            holder.start(queue: .global(qos: .utility))
        }
        defer { holder.cancel() }

        let server = LocalWebServer(port: port)
        try await server.start()
        let status = await server.waitUntilReady(timeout: 2)
        guard case .failed = status.state else {
            Issue.record("Expected a failed status for an occupied port: \(status)")
            return
        }
    }
}

private enum TestError: Error {
    case missingPort
}
