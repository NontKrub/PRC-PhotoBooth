import Foundation
import CoreGraphics
#if canImport(Darwin)
import Darwin
#endif

actor BoothSoakTestRunner {
    private var isCancelled = false
    private var isStoppingGracefully = false

    init() {}

    func cancel() {
        isCancelled = true
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

        let startedAt = Date()
        let baselineMemory = Self.currentResidentMemoryBytes()

        await progressHandler(.preflight(message: "Initializing soak test environment..."))

        var metrics: [BoothSoakCycleMetric] = []
        var invariantViolations: [String] = []

        // Invariant guard: Print Safety
        if config.enablePhysicalPrint {
            invariantViolations.append("Physical printing was explicitly enabled for soak test. Ensure adequate paper/ink.")
        }

        for cycle in 1...config.targetCycles {
            if isCancelled {
                await progressHandler(.stopping(reason: "Soak test cancelled by operator."))
                break
            }
            if isStoppingGracefully {
                await progressHandler(.stopping(reason: "Soak test stopped gracefully after cycle \(cycle - 1)."))
                break
            }

            let cycleStart = Date()
            var cycleErrors: [String] = []
            var captureLatencies: [Double] = []
            var renderLatency: Double? = nil
            var queueDrainSeconds: Double? = nil

            await progressHandler(.running(cycle: cycle, total: config.targetCycles, phase: "Starting cycle \(cycle)/\(config.targetCycles)..."))

            switch config.mode {
            case .cameraOnly:
                await progressHandler(.running(cycle: cycle, total: config.targetCycles, phase: "Camera capture [1/\(config.photosPerSession)]..."))
                for photoIdx in 0..<config.photosPerSession {
                    if isCancelled { break }
                    let capStart = Date()
                    if let captureService {
                        do {
                            _ = try await captureService.captureStill(for: photoIdx)
                        } catch {
                            cycleErrors.append("Capture \(photoIdx) failed: \(error.localizedDescription)")
                        }
                    } else {
                        // Synthetic capture fallback for testing environments
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    let capDuration = Date().timeIntervalSince(capStart)
                    captureLatencies.append(capDuration)
                }

            case .fullPipeline:
                let sessionID = "soak-\(UUID().uuidString)"
                let scratchDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("soak-sessions", isDirectory: true)
                    .appendingPathComponent(sessionID, isDirectory: true)
                try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

                defer {
                    if config.autoCleanupWorkingFiles {
                        try? FileManager.default.removeItem(at: scratchDirectory)
                    }
                }

                // Phase 1: Captures
                var capturedImages: [Int: CGImage] = [:]
                for photoIdx in 0..<config.photosPerSession {
                    if isCancelled { break }
                    await progressHandler(.running(cycle: cycle, total: config.targetCycles, phase: "Capturing photo \(photoIdx + 1)/\(config.photosPerSession)..."))
                    let capStart = Date()
                    var stillImage: CGImage? = nil
                    if let captureService {
                        do {
                            stillImage = try await captureService.captureStill(for: photoIdx)
                        } catch {
                            cycleErrors.append("Capture \(photoIdx) failed: \(error.localizedDescription)")
                        }
                    }

                    if stillImage == nil {
                        // Create deterministic synthetic photo for full-pipeline verification
                        let renderer = CGColorSpaceCreateDeviceRGB()
                        if let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: renderer, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            ctx.setFillColor(red: CGFloat(cycle % 10) / 10.0, green: 0.5, blue: CGFloat(photoIdx) / 3.0, alpha: 1.0)
                            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
                            if let img = ctx.makeImage() {
                                capturedImages[photoIdx] = img
                            }
                        }
                    } else if let img = stillImage {
                        capturedImages[photoIdx] = img
                    }
                    captureLatencies.append(Date().timeIntervalSince(capStart))
                }

                // Phase 2: Compositor Rendering
                await progressHandler(.running(cycle: cycle, total: config.targetCycles, phase: "Compositing strip..."))
                let renderStart = Date()
                let eventConfig = EventConfig(
                    eventID: "soak-event",
                    eventName: "Event Readiness Soak",
                    photoCount: config.photosPerSession,
                    countdownSeconds: 3
                )
                let compositor = Compositor(config: eventConfig, framePNG: nil)
                do {
                    let stripImage = try compositor.render(images: capturedImages, qrPayload: "http://192.168.1.100:8585/s/soak-token/")
                    let stripURL = scratchDirectory.appendingPathComponent("strip.png")
                    try compositor.savePNG(stripImage, to: stripURL)
                    renderLatency = Date().timeIntervalSince(renderStart)
                } catch {
                    cycleErrors.append("Compositor render failed: \(error.localizedDescription)")
                }

                // Phase 3: Simulated Job Queue Processing
                await progressHandler(.running(cycle: cycle, total: config.targetCycles, phase: "Processing jobs..."))
                let queueStart = Date()
                let queueStore = JobQueueStore(fileURL: scratchDirectory.appendingPathComponent("jobs.json"))
                let txID = UUID().uuidString
                do {
                    let jobs = try await queueStore.enqueueBatch(
                        sessionID: sessionID,
                        kinds: [SessionJobKind.renderStrip, SessionJobKind.renderGIF],
                        finalizationTransactionID: txID
                    )
                    for var job in jobs {
                        job.status = .succeeded
                        _ = try await queueStore.finish(job)
                    }
                    queueDrainSeconds = Date().timeIntervalSince(queueStart)
                } catch {
                    cycleErrors.append("JobQueue error: \(error.localizedDescription)")
                }
            }

            let cycleDuration = Date().timeIntervalSince(cycleStart)
            let currentMemory = Self.currentResidentMemoryBytes()
            let thermalState = ProcessInfo.processInfo.thermalState.rawValue

            let metric = BoothSoakCycleMetric(
                cycleIndex: cycle,
                durationSeconds: cycleDuration,
                captureLatencies: captureLatencies,
                renderLatency: renderLatency,
                queueDrainSeconds: queueDrainSeconds,
                memoryFootprintBytes: currentMemory,
                thermalStateRaw: thermalState,
                errors: cycleErrors
            )
            metrics.append(metric)

            if config.delayBetweenCyclesSeconds > 0 && !isCancelled && !isStoppingGracefully {
                try? await Task.sleep(for: .milliseconds(Int(config.delayBetweenCyclesSeconds * 1000)))
            }
        }

        let finishedAt = Date()
        let report = BoothSoakTestReport.compute(
            mode: config.mode,
            targetCycles: config.targetCycles,
            startedAt: startedAt,
            finishedAt: finishedAt,
            baselineMemory: baselineMemory,
            metrics: metrics,
            invariantViolations: invariantViolations
        )

        if report.failedCycles > 0 || !report.invariantViolations.isEmpty {
            await progressHandler(.failed(error: report.summaryVerdict, partialReport: report))
        } else {
            await progressHandler(.completed(report: report))
        }

        return report
    }
}
