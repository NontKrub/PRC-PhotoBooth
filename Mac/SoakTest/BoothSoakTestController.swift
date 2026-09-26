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

        if !(1...500).contains(config.targetCycles) {
            preflightErrors.append("Target cycles must be between 1 and 500.")
        }
        if !(1...8).contains(config.photosPerSession) {
            preflightErrors.append("Photos per session must be between 1 and 8.")
        }
        if !(1...500).contains(config.physicalPrintEveryCycles) {
            preflightErrors.append("Physical print interval must be between 1 and 500 cycles.")
        }
        if config.testCloudUpload && config.mode != .productionPipeline {
            preflightErrors.append("Cloud testing is available only in Production Pipeline mode.")
        }
        if config.enablePhysicalPrint && config.mode != .productionPipeline {
            preflightErrors.append("Physical printing requires Production Pipeline mode.")
        }

        // Production uses the same volume as real session files; the benchmark uses scratch storage.
        let storageURL = config.mode == .productionPipeline
            ? coordinator.flatMap { $0.productionSoakOutputDirectory }
            : FileManager.default.temporaryDirectory
        if config.mode == .productionPipeline && storageURL == nil {
            preflightErrors.append("The production session output volume is unavailable.")
        }
        let tempDir = storageURL ?? FileManager.default.temporaryDirectory
        let capacityValues = try? tempDir.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let values = capacityValues,
           let bytes = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) {
            let freeGB = Double(bytes) / (1024 * 1024 * 1024)
            if freeGB < 2.0 {
                preflightErrors.append("Critically low disk space: \(String(format: "%.1f", freeGB)) GB available. At least 2.0 GB is required.")
            } else if freeGB < 3.0 {
                preflightWarnings.append("Low disk space: \(String(format: "%.1f", freeGB)) GB available.")
            }

            if config.mode == .productionPipeline,
               (1...500).contains(config.targetCycles),
               let photoCount = coordinator?.productionSoakPhotoCount {
                let megabytesPerSession = photoCount * 10 + 10
                let estimatedBytes = Int64(config.targetCycles * megabytesPerSession) * 1_048_576
                let reserveBytes: Int64 = 1_073_741_824
                if bytes < estimatedBytes + reserveBytes {
                    let estimateGB = Double(estimatedBytes) / (1024 * 1024 * 1024)
                    let requiredGB = Double(estimatedBytes + reserveBytes) / (1024 * 1024 * 1024)
                    preflightErrors.append(
                        "Estimated soak output is \(String(format: "%.1f", estimateGB)) GB; keep a 1.0 GB reserve, so \(String(format: "%.1f", requiredGB)) GB is required."
                    )
                }
            }
        } else if config.mode == .productionPipeline {
            preflightErrors.append("Available storage could not be read, so disk capacity cannot be verified.")
        }

        // 2. Camera check
        switch config.mode {
        case .syntheticBenchmark:
            break
        case .cameraHardware:
            guard let coordinator else {
                preflightErrors.append("Camera Hardware mode requires the live booth camera service.")
                break
            }
            if !coordinator.selectedCaptureSourceReady {
                preflightErrors.append("The selected physical camera is not ready.")
            }
            if coordinator.capture.demoMode {
                preflightErrors.append("Demo camera mode cannot be counted as hardware verification.")
            }
        case .productionPipeline:
            guard let coordinator else {
                preflightErrors.append("Production Pipeline mode requires the live BoothCoordinator.")
                break
            }
            preflightErrors.append(contentsOf: coordinator.productionSoakReadinessIssues(config: config))
        }

        // 3. Print safety invariant
        if config.enablePhysicalPrint {
            let count = (config.targetCycles + config.physicalPrintEveryCycles - 1) / config.physicalPrintEveryCycles
            preflightWarnings.append("PHYSICAL PRINTING IS ENABLED: up to \(count) real print jobs, at a rate of one on the first cycle and every \(config.physicalPrintEveryCycles) cycles after that.")
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
        latestReport = nil

        state = .preflight(message: "Starting soak test runner...")

        runTask = Task { @MainActor in
            do {
                let report = try await activeRunner.run(
                    config: testConfig,
                    captureService: captureService,
                    coordinator: coordinator,
                    progressHandler: { [weak self] newState in
                        await MainActor.run {
                            self?.state = newState
                        }
                    }
                )
                self.latestReport = report
                switch report.outcome {
                case .passed:
                    self.state = .completed(report: report)
                case .failed:
                    self.state = .failed(error: report.summaryVerdict, partialReport: report)
                case .stoppedEarly:
                    self.state = .stopped(report: report)
                case .cancelled:
                    self.state = .cancelled(report: report)
                }
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
        state = .stopping(reason: "Canceling the active session at a safe capture and persistence boundary.")
    }

    public func exportReport(to destinationURL: URL) throws {
        guard let report = latestReport else {
            throw NSError(domain: "PRCPhotoBooth.SoakTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "No soak test report available to export."])
        }
        let markdown = report.markdownSummary()
        try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
    }
}
