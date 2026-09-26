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
                "Local guest delivery": "NOT TESTED",
                "Guest delivery": "NOT TESTED",
                "Cloud upload": config.testCloudUpload ? "NOT TESTED (enabled, no completed cycle yet)" : "NOT TESTED (disabled)",
                "Physical printing": config.enablePhysicalPrint ? "NOT TESTED (no scheduled print cycle completed yet)" : "NOT TESTED (disabled)",
                "Gallery update": "NOT TESTED",
                "iPad hardware": "NOT TESTED (device model compatibility is not inferred from connection readiness)",
                "Camera reconnects": "NOT TESTED"
            ]
        }
        var stopAfterProductionFailure = false

        for cycle in 1...config.targetCycles {
            if isCancelled || isStoppingGracefully || stopAfterProductionFailure { break }
            let cycleStart = Date()
            var errors: [String] = []
            var captureLatencies: [Double] = []
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
                phase: "Starting \(config.mode.rawValue.lowercased()) cycle \(cycle)…"
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
                            phase: "Capturing physical camera photo \(photoIndex + 1)/\(config.photosPerSession)…"
                        ))
                        let captureStartedAt = Date()
                        _ = try await captureService.captureStill(for: photoIndex)
                        captureLatencies.append(Date().timeIntervalSince(captureStartedAt))
                    }
                    if captureLatencies.count != config.photosPerSession {
                        throw CancellationError()
                    }

                case .productionPipeline:
                    guard let coordinator else { throw BoothSoakTestError.coordinatorRequired }
                    await progressHandler(.running(
                        cycle: cycle,
                        total: config.targetCycles,
                        phase: scheduledPrint ? "Running real session with physical print…" : "Running real production session…"
                    ))
                    let result = try await coordinator.runAutomatedSoakCycle(
                        runID: runID,
                        cycleIndex: cycle,
                        config: config,
                        printEnabled: scheduledPrint
                    )
                    cycleResult = result
                    captureLatencies = result.captureLatencies
                    renderLatency = result.renderLatency
                    queueDrainSeconds = result.queueDrainSeconds
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
                    coverage["Production session"] = "FAIL (cycle \(cycle): \(reason))"
                    coverage["Session persistence"] = "FAIL (production cycle did not complete)"
                    coverage["Rendering"] = "FAIL (production cycle did not complete)"
                    coverage["Production job queue"] = "FAIL (production cycle did not complete)"
                    if config.testCloudUpload { coverage["Cloud upload"] = "FAIL (production cycle did not verify upload)" }
                    if scheduledPrint { coverage["Physical printing"] = "FAIL (scheduled print cycle did not complete)" }
                }
            }

            if cycleWasInterrupted { break }

            if let cycleResult {
                coverage["Production session"] = "PASS (origin-tagged live session, accepted captures, finalization, and job drain)"
                coverage["Session persistence"] = "PASS (production manifest and output workspace)"
                coverage["Rendering"] = "PASS (production strip render)"
                coverage["Production job queue"] = "PASS (claimed and executed transaction-bound jobs)"
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
                coverage["Guest delivery"] = cycleResult.localDeliveryVerified || cycleResult.cloudUploadVerified
                    ? "PASS (configured production delivery path verified)"
                    : "NOT TESTED"
                coverage["Cloud upload"] = config.testCloudUpload
                    ? (cycleResult.cloudUploadVerified ? "PASS (production cloud job succeeded)" : "FAIL (cloud upload was configured but not verified)")
                    : "NOT TESTED"
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
            await coordinator.endAutomatedSoakRun(runID: runID)
            activeProductionCoordinator = nil
            activeProductionRunID = nil
        }
        let cameraReconnectCount = await MainActor.run { () -> Int? in
            guard let coordinator, let baselineCameraReconnectCount else { return nil }
            return max(0, coordinator.cameraReconnectCount - baselineCameraReconnectCount)
        }
        coverage["Camera reconnects"] = cameraReconnectCount.map { "OBSERVED (\($0) camera reconnect(s) during this run)" }
            ?? "NOT TESTED"

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
            subsystemCoverage: coverage
        )

        switch report.outcome {
        case .passed:
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
        progressHandler: @Sendable (BoothSoakTestState) async -> Void
    ) async throws -> (renderLatency: Double, queueDrainSeconds: Double) {
        var images: [Int: CGImage] = [:]
        for photoIndex in 0..<config.photosPerSession {
            if isCancelled { throw CancellationError() }
            await progressHandler(.running(
                cycle: cycle,
                total: config.targetCycles,
                phase: "Generating synthetic benchmark image \(photoIndex + 1)/\(config.photosPerSession)…"
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

        await progressHandler(.running(cycle: cycle, total: config.targetCycles, phase: "Exercising isolated benchmark queue…"))
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
}
