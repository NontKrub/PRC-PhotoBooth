import Foundation
import CoreGraphics
#if canImport(Darwin)
import Darwin
#endif

actor BoothSoakTestRunner {
    private var isCancelled = false
    private var isStoppingGracefully = false
    private var activeProductionCoordinator: BoothCoordinator?
    private var activeProductionRunID: String?

    init() {}

    func cancel() async {
        isCancelled = true
        if let activeProductionCoordinator, let activeProductionRunID {
            await activeProductionCoordinator.cancelAutomatedSoakCycle(runID: activeProductionRunID)
        }
    }

    func stopGracefully() {
        isStoppingGracefully = true
    }

    static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    func run(
        config: BoothSoakTestConfig,
        captureService: CaptureService?,
        coordinator: BoothCoordinator?,
        progressHandler: @Sendable @escaping (BoothSoakTestState) async -> Void
    ) async throws -> BoothSoakTestReport {
        isCancelled = false
        isStoppingGracefully = false

        guard (1...500).contains(config.targetCycles), (1...8).contains(config.photosPerSession),
              config.physicalPrintEveryCycles > 0 else {
            throw BoothSoakTestError.invalidConfiguration("Choose 1–500 cycles, 1–8 photos, and a positive print interval.")
        }
        if config.testCloudUpload && config.mode != .productionPipeline {
            throw BoothSoakTestError.invalidConfiguration("Cloud uploads can be tested only in Production Pipeline mode.")
        }
        if config.enablePhysicalPrint && config.mode != .productionPipeline {
            throw BoothSoakTestError.invalidConfiguration("Physical printing is available only in Production Pipeline mode.")
        }

        let cameraIsReady = await MainActor.run {
            guard let coordinator else { return false }
            return coordinator.selectedCaptureSourceReady && !coordinator.capture.demoMode
        }
        switch config.mode {
        case .syntheticBenchmark:
            break
        case .cameraHardware:
            guard captureService != nil, cameraIsReady else { throw BoothSoakTestError.cameraRequired }
        case .productionPipeline:
            guard coordinator != nil else { throw BoothSoakTestError.coordinatorRequired }
        }

        let startedAt = Date()
        let baselineMemory = Self.currentResidentMemoryBytes()
        let baselineCameraReconnectCount = await MainActor.run {
            (config.mode != .syntheticBenchmark) ? coordinator?.cameraReconnectCount : nil
        }
        let baselineTransportReconnectCount = await coordinator?.soakTransportReconnectCount()
        await progressHandler(.preflight(message: "Preparing \(config.mode.rawValue)…"))

        let runID = UUID().uuidString
        if config.mode == .productionPipeline {
            guard let coordinator else { throw BoothSoakTestError.coordinatorRequired }
            try await coordinator.beginAutomatedSoakRun(runID: runID, config: config)
            activeProductionCoordinator = coordinator
            activeProductionRunID = runID
        }

        let scratchDirectory: URL? = if config.mode == .syntheticBenchmark {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("PRC-PhotoBooth-Soak", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
        } else {
            nil
        }
        if let scratchDirectory {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        }
        defer {
            if config.autoCleanupWorkingFiles, let scratchDirectory {
                try? FileManager.default.removeItem(at: scratchDirectory)
            }
        }

        var metrics: [BoothSoakCycleMetric] = []
        let invariantViolations: [String] = []
        var coverage: [String: String] = switch config.mode {
        case .syntheticBenchmark:
            [
                "Camera hardware": "NOT TESTED",
                "Session workflow, persistence, guest delivery, cloud, physical print, iPad": "NOT TESTED",
                "Synthetic compositor and queue benchmark": "NOT TESTED"
            ]
        case .cameraHardware:
            [
                "Camera hardware": "NOT TESTED",
                "Production session, persistence, rendering, queue, delivery, cloud, print, iPad": "NOT TESTED"
            ]
        case .productionPipeline:
            [
                "Production session": "NOT TESTED",
                "Session persistence": "NOT TESTED",
                "Rendering": "NOT TESTED",
                "Production job queue": "NOT TESTED",
                "Queue failures": "NOT TESTED",
                "Local guest delivery": "NOT TESTED",
                "Guest delivery": "NOT TESTED",
                "Cloud upload": config.testCloudUpload ? "NOT TESTED (enabled, no completed cycle yet)" : "NOT TESTED (disabled)",
                "Cloud QR route": config.testCloudUpload ? "NOT TESTED (enabled, no completed cycle yet)" : "NOT TESTED (disabled)",
                "Cloud cleanup": config.testCloudUpload ? "NOT TESTED (enabled, no completed cycle yet)" : "NOT TESTED (disabled)",
                "Soak cleanup": "NOT TESTED",
                "Physical printing": config.enablePhysicalPrint ? "NOT TESTED (no scheduled print cycle completed yet)" : "NOT TESTED (disabled)",
                "Gallery update": "NOT TESTED",
                "iPad hardware": "NOT TESTED (device model compatibility is not inferred from connection readiness)",
                "Camera reconnects": "NOT TESTED"
            ]
        }
        var stopAfterProductionFailure = false
        var queueFailureCount: Int?

        for cycle in 1...config.targetCycles {
            if isCancelled || isStoppingGracefully || stopAfterProductionFailure { break }
            let cycleStart = Date()
            var errors: [String] = []
            var captureLatencies: [Double] = []
            var captureAttemptCount = 0
            var captureFailureCount = 0
            var cameraRecoveryCount = 0
            var renderLatency: Double?
            var queueDrainSeconds: Double?
            var cycleResult: BoothAutomatedSoakCycleResult?
            var cycleWasInterrupted = false
            let scheduledPrint = config.mode == .productionPipeline
                && config.enablePhysicalPrint
                && (cycle - 1).isMultiple(of: config.physicalPrintEveryCycles)

            await progressHandler(.running(
                cycle: cycle,
                total: config.targetCycles,
                phase: "Starting \(config.mode.rawValue.lowercased()) cycle \(cycle)…",
                runID: runID
            ))

            do {
                switch config.mode {
                case .syntheticBenchmark:
                    guard let scratchDirectory else {
                        throw BoothSoakTestError.invalidConfiguration("Synthetic benchmark storage is unavailable.")
                    }
                    let result = try await runSyntheticBenchmarkCycle(
                        cycle: cycle,
                        config: config,
                        scratchDirectory: scratchDirectory,
                        runID: runID,
                        progressHandler: progressHandler
                    )
                    renderLatency = result.renderLatency
                    queueDrainSeconds = result.queueDrainSeconds

                case .cameraHardware:
                    guard let captureService else { throw BoothSoakTestError.cameraRequired }
                    for photoIndex in 0..<config.photosPerSession {
                        if isCancelled { break }
                        await progressHandler(.running(
                            cycle: cycle,
                            total: config.targetCycles,
                            phase: "Capturing physical camera photo \(photoIndex + 1)/\(config.photosPerSession)…",
                            runID: runID
                        ))
                        let captureStartedAt = Date()
                        captureAttemptCount += 1
                        do {
                            _ = try await captureService.captureStill(for: photoIndex)
                            captureLatencies.append(Date().timeIntervalSince(captureStartedAt))
                        } catch {
                            captureFailureCount += 1
                            throw error
                        }
                    }
                    if captureLatencies.count != config.photosPerSession {
                        throw CancellationError()
                    }

                case .productionPipeline:
                    guard let coordinator else { throw BoothSoakTestError.coordinatorRequired }
                    await progressHandler(.running(
                        cycle: cycle,
                        total: config.targetCycles,
                        phase: scheduledPrint ? "Running real session with physical print…" : "Running real production session…",
                        runID: runID
                    ))
                    let result = try await coordinator.runAutomatedSoakCycle(
                        runID: runID,
                        cycleIndex: cycle,
                        config: config,
                        printEnabled: scheduledPrint,
                        progressHandler: { stage in
                            await progressHandler(.running(
                                cycle: cycle,
                                total: config.targetCycles,
                                phase: stage,
                                runID: runID
                            ))
                        }
                    )
                    cycleResult = result
                    captureLatencies = result.captureLatencies
                    captureAttemptCount = result.captureAttemptCount
                    captureFailureCount = result.captureFailureCount
                    cameraRecoveryCount = result.cameraRecoveryCount
                    renderLatency = result.renderLatency
                    queueDrainSeconds = result.queueDrainSeconds
                    queueFailureCount = (queueFailureCount ?? 0) + result.queueFailureCount
                }
            } catch is CancellationError {
                cycleWasInterrupted = true
                if !isCancelled {
                    errors.append("Cycle was cancelled before reaching a safe boundary.")
                } else if config.mode == .productionPipeline {
                    coverage["Production session"] = "CANCELLED (operator requested cancellation during cycle \(cycle))"
                }
            } catch {
                errors.append(error.localizedDescription)
                if config.mode == .productionPipeline {
                    stopAfterProductionFailure = true
                    let reason = error.localizedDescription
                    if let coordinator {
                        await coordinator.retainFailedSoakDiagnostics(runID: runID, reason: reason)
                    }
                    let cycleQueueFailures = await coordinator?.failedSoakQueueJobCount(runID: runID)
                    if let cycleQueueFailures {
                        queueFailureCount = cycleQueueFailures
                        coverage["Queue failures"] = cycleQueueFailures == 0
                            ? "0 (session failed outside the finalization queue)"
                            : "FAIL (\(cycleQueueFailures) failed transaction-bound job(s))"
                        coverage["Production job queue"] = cycleQueueFailures == 0
                            ? "NOT TESTED (no queue job failure was observed)"
                            : "FAIL (\(cycleQueueFailures) failed transaction-bound job(s))"
                    }
                    coverage["Production session"] = "FAIL (cycle \(cycle): \(reason))"
                    coverage["Session persistence"] = "FAIL (production cycle did not complete)"
                    coverage["Rendering"] = reason.localizedCaseInsensitiveContains("render")
                        ? "FAIL (\(reason))"
                        : "NOT TESTED (production cycle did not reach a verified strip render)"
                    if config.testCloudUpload { coverage["Cloud upload"] = "FAIL (production cycle did not verify upload)" }
                    if config.testCloudUpload { coverage["Cloud QR route"] = "FAIL (production QR route was not verified)" }
                    if scheduledPrint {
                        coverage["Physical printing"] = reason.localizedCaseInsensitiveContains("unknown")
                            ? "WARNING (print side effect is unknown; operator verification required; no automatic retry)"
                            : "FAIL (scheduled print cycle did not complete)"
                    }
                }
            }

            if cycleWasInterrupted { break }

            if let cycleResult {
                coverage["Production session"] = "PASS (origin-tagged live session, accepted captures, finalization, and job drain)"
                coverage["Session persistence"] = "PASS (production manifest and output workspace)"
                coverage["Rendering"] = "PASS (production strip render)"
                coverage["Production job queue"] = "PASS (claimed and executed transaction-bound jobs)"
                coverage["Queue failures"] = "0 (all required and selected optional jobs succeeded)"
                coverage["Local guest delivery"] = if cycleResult.localDeliveryVerified {
                    "PASS (downloaded production strip verified)"
                } else if cycleResult.cloudUploadVerified,
                          UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP") {
                    "NOT TESTED (no authoritative local interface; cloud delivery was verified)"
                } else if UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP") {
                    "FAIL (local delivery was enabled but not verified)"
                } else {
                    "NOT TESTED"
                }
                coverage["Guest delivery"] = cycleResult.localDeliveryVerified
                    || (cycleResult.cloudUploadVerified && cycleResult.cloudQRRouteVerified)
                    ? "PASS (configured production delivery path verified)"
                    : (config.testCloudUpload ? "FAIL (the production QR route was not verified)" : "NOT TESTED")
                coverage["Cloud upload"] = config.testCloudUpload
                    ? (cycleResult.cloudUploadVerified ? "PASS (production cloud job succeeded)" : "FAIL (cloud upload was configured but not verified)")
                    : "NOT TESTED"
                coverage["Cloud QR route"] = config.testCloudUpload
                    ? (cycleResult.cloudQRRouteVerified
                        ? "PASS (production QR resolver matched the run-scoped URL and its strip returned HTTP 200)"
                        : "FAIL (production QR route did not match the verified cloud route)")
                    : "NOT TESTED"
                let remoteCleanupWarnings = cycleResult.cleanupWarnings.filter { $0.hasPrefix("Remote cloud cleanup") }
                coverage["Cloud cleanup"] = config.testCloudUpload
                    ? (remoteCleanupWarnings.isEmpty
                        ? "PASS (run-scoped public alias was removed after verification)"
                        : "WARNING (remote cleanup needs retry: \(remoteCleanupWarnings.joined(separator: " "))) ")
                    : "NOT TESTED"
                coverage["Soak cleanup"] = cycleResult.cleanupWarnings.isEmpty
                    ? (config.autoCleanupWorkingFiles
                        ? "PASS (test routes and configured artifacts were removed)"
                        : "PASS (run-scoped customer routes were depublished; diagnostic artifacts were retained by configuration)")
                    : "WARNING (\(cycleResult.cleanupWarnings.joined(separator: " ")))"
                if scheduledPrint {
                    coverage["Physical printing"] = cycleResult.physicalPrintVerified
                        ? "PASS (real print job succeeded in cycle \(cycle))"
                        : "FAIL (scheduled print job was not verified)"
                } else if coverage["Physical printing"] == nil {
                    coverage["Physical printing"] = config.enablePhysicalPrint
                        ? "NOT TESTED (no scheduled print cycle has completed yet)"
                        : "NOT TESTED"
                }
                coverage["Gallery update"] = cycleResult.galleryUpdateVerified
                    ? "PASS (production gallery job succeeded)"
                    : "NOT TESTED (gallery is disabled for this event)"
                coverage["Gallery isolation"] = cycleResult.galleryUpdateVerified
                    ? (cycleResult.galleryIsolationVerified
                        ? "PASS (soak entry persisted but is excluded from production gallery routes)"
                        : "FAIL (soak gallery entry was missing or production-visible)")
                    : "NOT TESTED (gallery job did not run)"
                coverage["iPad hardware"] = "NOT TESTED (display readiness and workflow messages do not validate every iPad model)"
            }

            if config.mode == .cameraHardware {
                coverage["Camera hardware"] = errors.isEmpty
                    ? "PASS (physical camera captured \(captureLatencies.count) image(s) in this cycle)"
                    : "FAIL (physical capture did not complete)"
                coverage["Production session, persistence, rendering, queue, delivery, cloud, print, iPad"] = "NOT TESTED"
            } else if config.mode == .syntheticBenchmark {
                coverage["Camera hardware"] = "NOT TESTED"
                coverage["Session workflow, persistence, guest delivery, cloud, physical print, iPad"] = "NOT TESTED"
                coverage["Synthetic compositor and queue benchmark"] = errors.isEmpty
                    ? "PASS (generated images and isolated claimed benchmark jobs)"
                    : "FAIL"
            }

            metrics.append(BoothSoakCycleMetric(
                cycleIndex: cycle,
                durationSeconds: Date().timeIntervalSince(cycleStart),
                captureLatencies: captureLatencies,
                captureAttemptCount: captureAttemptCount > 0 ? captureAttemptCount : nil,
                captureFailureCount: captureAttemptCount > 0 ? captureFailureCount : nil,
                cameraRecoveryCount: captureAttemptCount > 0 ? cameraRecoveryCount : nil,
                renderLatency: renderLatency,
                queueDrainSeconds: queueDrainSeconds,
                memoryFootprintBytes: Self.currentResidentMemoryBytes(),
                thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue,
                errors: errors
            ))

            if !errors.isEmpty, config.mode == .productionPipeline { break }
            if cycle < config.targetCycles, config.delayBetweenCyclesSeconds > 0,
               !isCancelled, !isStoppingGracefully {
                do {
                    try await Task.sleep(for: .milliseconds(Int(config.delayBetweenCyclesSeconds * 1000)))
                } catch {
                    isCancelled = true
                }
            }
        }

        if config.mode == .productionPipeline, let coordinator {
            let cleanupWarnings = await coordinator.endAutomatedSoakRun(runID: runID)
            if !cleanupWarnings.isEmpty {
                coverage["Soak cleanup"] = "WARNING (\(cleanupWarnings.joined(separator: " ")))"
                let remoteWarnings = cleanupWarnings.filter { $0.hasPrefix("Remote cloud cleanup") }
                if !remoteWarnings.isEmpty {
                    coverage["Cloud cleanup"] = "WARNING (\(remoteWarnings.joined(separator: " ")))"
                }
            } else if coverage["Soak cleanup"] == "NOT TESTED" {
                let diagnosticsRetained = metrics.count < config.targetCycles || metrics.contains { !$0.errors.isEmpty }
                coverage["Soak cleanup"] = diagnosticsRetained
                    ? "WARNING (run-scoped routes were depublished; failed or incomplete session artifacts were retained for diagnostics)"
                    : (config.autoCleanupWorkingFiles
                        ? "PASS (test routes and configured artifacts were removed)"
                        : "PASS (run-scoped customer routes were depublished; diagnostic artifacts were retained by configuration)")
            }
            activeProductionCoordinator = nil
            activeProductionRunID = nil
        }
        let cameraReconnectCount = await MainActor.run { () -> Int? in
            guard let coordinator, let baselineCameraReconnectCount else { return nil }
            return max(0, coordinator.cameraReconnectCount - baselineCameraReconnectCount)
        }
        coverage["Camera reconnects"] = cameraReconnectCount.map { "OBSERVED (\($0) camera reconnect(s) during this run)" }
            ?? "NOT TESTED"
        let transportReconnectCount: Int?
        if let coordinator, let baselineTransportReconnectCount {
            transportReconnectCount = max(
                0,
                await coordinator.soakTransportReconnectCount() - baselineTransportReconnectCount
            )
        } else {
            transportReconnectCount = nil
        }
        coverage["iPad transport reconnects"] = transportReconnectCount.map {
            "OBSERVED (\($0) authenticated transport reconnect(s) during this run)"
        } ?? "NOT TESTED"

        var environmentSnapshot = [
            "App version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "NOT AVAILABLE",
            "App build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "NOT AVAILABLE",
            "Git SHA": Bundle.main.object(forInfoDictionaryKey: "GitSHA") as? String ?? "NOT AVAILABLE",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "Mac model": Self.hardwareModel()
        ]
        if let coordinator {
            let boothSnapshot = await MainActor.run { coordinator.soakEnvironmentSnapshot() }
            environmentSnapshot.merge(boothSnapshot) { _, new in new }
        }
        let configurationSnapshot = [
            "Mode": config.mode.rawValue,
            "Target sessions": String(config.targetCycles),
            "Photos per session": String(config.photosPerSession),
            "Delay between sessions (seconds)": String(config.delayBetweenCyclesSeconds),
            "Physical print enabled": String(config.enablePhysicalPrint),
            "Print every N sessions": String(config.physicalPrintEveryCycles),
            "Cloud test upload enabled": String(config.testCloudUpload),
            "Automatic cleanup enabled": String(config.autoCleanupWorkingFiles)
        ]

        let requestedOutcome: BoothSoakTestOutcome? = if metrics.count < config.targetCycles {
            if isCancelled { .cancelled }
            else if isStoppingGracefully { .stoppedEarly }
            else { .failed }
        } else {
            nil
        }
        let report = BoothSoakTestReport.compute(
            mode: config.mode,
            targetCycles: config.targetCycles,
            startedAt: startedAt,
            finishedAt: Date(),
            baselineMemory: baselineMemory,
            metrics: metrics,
            reconnectCount: cameraReconnectCount,
            invariantViolations: invariantViolations,
            requestedOutcome: requestedOutcome,
            subsystemCoverage: coverage,
            runID: runID,
            transportReconnectCount: transportReconnectCount,
            queueFailureCount: queueFailureCount,
            environmentSnapshot: environmentSnapshot,
            configurationSnapshot: configurationSnapshot
        )

        switch report.outcome {
        case .passed:
            await progressHandler(.completed(report: report))
        case .completedWithWarnings:
            await progressHandler(.completed(report: report))
        case .failed:
            await progressHandler(.failed(error: report.summaryVerdict, partialReport: report))
        case .stoppedEarly:
            await progressHandler(.stopped(report: report))
        case .cancelled:
            await progressHandler(.cancelled(report: report))
        }
        return report
    }

    private func runSyntheticBenchmarkCycle(
        cycle: Int,
        config: BoothSoakTestConfig,
        scratchDirectory: URL,
        runID: String,
        progressHandler: @Sendable (BoothSoakTestState) async -> Void
    ) async throws -> (renderLatency: Double, queueDrainSeconds: Double) {
        var images: [Int: CGImage] = [:]
        for photoIndex in 0..<config.photosPerSession {
            if isCancelled { throw CancellationError() }
            await progressHandler(.running(
                cycle: cycle,
                total: config.targetCycles,
                phase: "Generating synthetic benchmark image \(photoIndex + 1)/\(config.photosPerSession)…",
                runID: runID
            ))
            guard let image = Self.syntheticImage(cycle: cycle, photoIndex: photoIndex) else {
                throw BoothSoakTestError.invalidConfiguration("Could not allocate a synthetic benchmark image.")
            }
            images[photoIndex] = image
        }

        let renderStartedAt = Date()
        let eventConfig = EventConfig(
            eventID: "soak-benchmark",
            eventName: "Synthetic Benchmark",
            photoCount: config.photosPerSession,
            countdownSeconds: 0
        )
        let compositor = Compositor(config: eventConfig, framePNG: nil)
        let stripImage = try compositor.render(images: images)
        let stripURL = scratchDirectory.appendingPathComponent("cycle-\(cycle)-strip.png")
        try compositor.savePNG(stripImage, to: stripURL)
        let renderLatency = Date().timeIntervalSince(renderStartedAt)

        await progressHandler(.running(cycle: cycle, total: config.targetCycles, phase: "Exercising isolated benchmark queue…", runID: runID))
        let queueStartedAt = Date()
        let sessionID = "benchmark-\(UUID().uuidString)"
        let transactionID = UUID().uuidString
        let queueStore = JobQueueStore(fileURL: scratchDirectory.appendingPathComponent("jobs.json"))
        let jobs = try await queueStore.enqueueBatch(
            sessionID: sessionID,
            kinds: [.renderStrip, .renderGIF],
            finalizationTransactionID: transactionID
        )
        for job in jobs {
            guard var claimed = try await queueStore.claim(jobID: job.id) else {
                throw BoothSoakTestError.invalidConfiguration("Synthetic benchmark queue failed to claim \(job.kind.rawValue).")
            }
            claimed.status = .succeeded
            claimed.updatedAt = Date()
            guard try await queueStore.finish(claimed) else {
                throw BoothSoakTestError.invalidConfiguration("Synthetic benchmark queue rejected the claimed \(job.kind.rawValue) completion.")
            }
        }
        return (renderLatency, Date().timeIntervalSince(queueStartedAt))
    }

    private static func syntheticImage(cycle: Int, photoIndex: Int) -> CGImage? {
        let width = 800
        let height = 600
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(
            red: CGFloat(cycle % 10) / 10,
            green: 0.5,
            blue: CGFloat(photoIndex % 8) / 8,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return "NOT AVAILABLE"
        }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return "NOT AVAILABLE"
        }
        let bytes = model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
