import Foundation
import SwiftUI

@Observable
@MainActor
public final class BoothSoakTestController {
    public var config: BoothSoakTestConfig = BoothSoakTestConfig()
    public var state: BoothSoakTestState = .idle
    public var latestReport: BoothSoakTestReport?
    public var preflightErrors: [String] = []
    public var preflightWarnings: [String] = []

    private var runner: BoothSoakTestRunner?
    private var runTask: Task<Void, Never>?

    public init() {}

    public var isPreflightValid: Bool {
        preflightErrors.isEmpty
    }

    func validatePreflight(coordinator: BoothCoordinator?) {
        preflightErrors.removeAll()
        preflightWarnings.removeAll()

        // 1. Storage check
        let tempDir = FileManager.default.temporaryDirectory
        if let values = try? tempDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) {
            let freeGB = Double(bytes) / (1024 * 1024 * 1024)
            if freeGB < 1.0 {
                preflightErrors.append("Critically low disk space: \(String(format: "%.1f", freeGB)) GB available. At least 2.0 GB required.")
            } else if freeGB < 3.0 {
                preflightWarnings.append("Low disk space: \(String(format: "%.1f", freeGB)) GB available.")
            }
        }

        // 2. Camera check
        if let coord = coordinator {
            if !coord.cameraPermissionGranted {
                preflightErrors.append("Camera access permission has not been granted.")
            }
        }

        // 3. Print safety invariant
        if config.enablePhysicalPrint {
            preflightWarnings.append("⚠️ PHYSICAL PRINTING IS ENABLED! Real paper and ribbon will be consumed for all \(config.targetCycles) sessions.")
        }
    }

    func start(coordinator: BoothCoordinator?) {
        guard !state.isRunning else { return }
        validatePreflight(coordinator: coordinator)
        guard isPreflightValid else { return }

        let activeRunner = BoothSoakTestRunner()
        self.runner = activeRunner
        let testConfig = self.config
        let captureService = coordinator?.capture

        state = .preflight(message: "Starting soak test runner...")

        runTask = Task { @MainActor in
            do {
                let report = try await activeRunner.run(
                    config: testConfig,
                    captureService: captureService,
                    coordinator: coordinator,
                    progressHandler: { [weak self] newState in
                        Task { @MainActor in
                            self?.state = newState
                        }
                    }
                )
                self.latestReport = report
                self.state = .completed(report: report)
            } catch {
                self.state = .failed(error: error.localizedDescription, partialReport: self.latestReport)
            }
        }
    }

    public func stopGracefully() {
        Task {
            await runner?.stopGracefully()
        }
    }

    public func cancel() {
        Task {
            await runner?.cancel()
        }
        runTask?.cancel()
        state = .idle
    }

    public func exportReport(to destinationURL: URL) throws {
        guard let report = latestReport else {
            throw NSError(domain: "PRCPhotoBooth.SoakTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "No soak test report available to export."])
        }
        let markdown = report.markdownSummary()
        try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
    }
}
