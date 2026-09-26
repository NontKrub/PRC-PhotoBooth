import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SoakTestSettingsView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @State private var controller = BoothSoakTestController()
    @State private var showStartConfirmation = false
    @State private var exportErrorMessage: String?
    @State private var showExportSuccess = false
    @State private var usesCustomCycleCount = false
    @State private var customCycleCountText = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection
            Divider()

            switch controller.state {
            case .idle:
                configurationForm
                preflightCard
                actionButtons
            case .preflight(let msg):
                VStack(alignment: .center, spacing: 16) {
                    ProgressView()
                    Text(msg)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            case .running(let cycle, let total, let phase):
                runningProgressView(cycle: cycle, total: total, phase: phase)
            case .stopping(let reason):
                stoppingView(reason: reason)
            case .completed(let report):
                reportView(report: report)
            case .failed(let err, let report):
                if let report {
                    reportView(report: report, errorMessage: err)
                } else {
                    failureView(error: err)
                }
            case .stopped(let report), .cancelled(let report):
                reportView(report: report)
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            usesCustomCycleCount = ![1, 10, 25, 50, 100, 500].contains(controller.config.targetCycles)
            customCycleCountText = String(controller.config.targetCycles)
            controller.validatePreflight(coordinator: coordinator)
        }
        .onChange(of: controller.config) { _, _ in
            controller.validatePreflight(coordinator: coordinator)
        }
        .onChange(of: coordinator.productionSoakPhotoCount) { _, _ in
            controller.validatePreflight(coordinator: coordinator)
        }
        .onChange(of: controller.config.mode) { oldMode, newMode in
            guard oldMode == .productionPipeline, newMode != .productionPipeline else { return }
            controller.config.enablePhysicalPrint = false
            controller.config.testCloudUpload = false
        }
        .confirmationDialog(
            "Start Event Readiness Soak Test?",
            isPresented: $showStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start \(controller.config.targetCycles)-Cycle \(controller.config.mode.rawValue) Test") {
                controller.start(coordinator: coordinator)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        switch controller.config.mode {
        case .syntheticBenchmark:
            return "Generates synthetic images and runs isolated compositor and queue benchmarks. This does not validate production sessions, camera hardware, networking, printing, or iPad compatibility."
        case .cameraHardware:
            return "Captures \(controller.config.photosPerSession) images per cycle from the selected physical camera. It does not create sessions or validate finalization, delivery, printing, or iPad compatibility."
        case .productionPipeline:
            var message = "Runs \(controller.config.targetCycles) real sessions using the active event, camera, production storage, finalization queue, and configured guest delivery. Completed soak sessions are cleaned up when auto-cleanup is enabled."
            if controller.config.testCloudUpload {
                message += "\n\nCloud upload is enabled. Each cycle uses the current production settings but publishes into this run’s temporary cloud namespace."
                if controller.config.autoCleanupWorkingFiles {
                    message += " Auto-cleanup removes the temporary public alias and remote files after verification."
                } else {
                    message += " Auto-cleanup is off, so the remote test files and aliases remain on the server."
                }
            }
            if controller.config.enablePhysicalPrint {
                let count = (controller.config.targetCycles + controller.config.physicalPrintEveryCycles - 1) / controller.config.physicalPrintEveryCycles
                message += "\n\nPHYSICAL PRINTING IS ENABLED: up to \(count) real print jobs, starting in cycle 1 and repeating every \(controller.config.physicalPrintEveryCycles) cycles."
            }
            return message
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Event Readiness & Soak Testing", systemImage: "flame.fill")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text("Choose a synthetic benchmark, physical camera check, or production session soak. Only Production Pipeline exercises the live booth workflow.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var configurationForm: some View {
        return VStack(alignment: .leading, spacing: 16) {
            Text("Test Configuration")
                .font(.headline)

            Picker("Mode", selection: $controller.config.mode) {
                ForEach(BoothSoakTestMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(controller.config.mode.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.config.mode != .productionPipeline {
                Stepper(
                    "Photos per cycle: \(controller.config.photosPerSession)",
                    value: $controller.config.photosPerSession,
                    in: 1...8
                )
            } else {
                Label("Uses the active event’s configured template and photo count.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Picker("Target cycles", selection: Binding(
                    get: { usesCustomCycleCount ? 0 : controller.config.targetCycles },
                    set: { selected in
                        if selected == 0 {
                            usesCustomCycleCount = true
                            customCycleCountText = ""
                            controller.config.targetCycles = 0
                        } else {
                            usesCustomCycleCount = false
                            customCycleCountText = String(selected)
                            controller.config.targetCycles = selected
                        }
                    }
                )) {
                    Text("1 (Single-cycle check)").tag(1)
                    Text("10 (Quick Smoke)").tag(10)
                    Text("25 (Short Benchmark)").tag(25)
                    Text("50 (Standard Soak)").tag(50)
                    Text("100 (Stress Test)").tag(100)
                    Text("500 (Full Event Soak)").tag(500)
                    Text("Custom…").tag(0)
                }
                .frame(width: 260)

                if usesCustomCycleCount {
                    TextField("1–500", text: $customCycleCountText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Custom target cycles")
                        .onChange(of: customCycleCountText) { _, value in
                            let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
                            controller.config.targetCycles = parsed.flatMap { (1...500).contains($0) ? $0 : nil } ?? 0
                        }
                    Text("cycles")
                        .foregroundStyle(.secondary)
                }
            }

            workloadSummary

            HStack {
                Text("Delay Between Cycles:")
                    .frame(width: 140, alignment: .leading)
                Slider(value: $controller.config.delayBetweenCyclesSeconds, in: 0.2...5.0, step: 0.2)
                    .frame(width: 160)
                Text(String(format: "%.1f s", controller.config.delayBetweenCyclesSeconds))
                    .font(.callout.monospacedDigit())
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto-cleanup test session files", isOn: $controller.config.autoCleanupWorkingFiles)
                    .font(.body)
                Text(controller.config.mode == .productionPipeline
                    ? "Removes completed local sessions tagged for this run. Failed sessions keep their local evidence; soak delivery routes are removed when the run ends."
                    : "Removes this run’s isolated benchmark files when the run finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Test cloud upload using current production settings", isOn: $controller.config.testCloudUpload)
                    .disabled(controller.config.mode != .productionPipeline)
                Text(controller.config.autoCleanupWorkingFiles
                    ? "Each cycle uploads to a temporary run-scoped path. Auto-cleanup removes its public alias and remote files after verification. Review the configured destination and credentials before enabling."
                    : "Each cycle uploads to a temporary run-scoped path. Turning off auto-cleanup leaves those remote files and aliases in place. Review the configured destination and credentials before enabling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $controller.config.enablePhysicalPrint) {
                    HStack {
                        Text("Enable Physical Printing")
                            .bold()
                        if controller.config.enablePhysicalPrint {
                            Text("DANGEROUS")
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.2))
                                .foregroundStyle(.red)
                                .cornerRadius(4)
                        }
                    }
                }
                .disabled(controller.config.mode != .productionPipeline)
                if controller.config.mode == .productionPipeline {
                    Stepper(
                        "Print first cycle, then every \(controller.config.physicalPrintEveryCycles) cycles",
                        value: $controller.config.physicalPrintEveryCycles,
                        in: 1...500
                    )
                    .disabled(!controller.config.enablePhysicalPrint)
                }
                Text("Opt-in sends real print jobs to the configured printer. The cadence limits paper and ribbon use.")
                    .font(.caption)
                    .foregroundStyle(controller.config.enablePhysicalPrint ? .red : .secondary)
            }
            .padding(12)
            .background(controller.config.enablePhysicalPrint ? Color.red.opacity(0.08) : Color.primary.opacity(0.03))
            .cornerRadius(8)
        }
    }

    private var workloadSummary: some View {
        let cycles = max(0, controller.config.targetCycles)
        let productionPhotos = coordinator.productionSoakPhotoCount
        let captureCount: Int? = switch controller.config.mode {
        case .productionPipeline: productionPhotos.map { cycles * $0 }
        case .cameraHardware: cycles * controller.config.photosPerSession
        case .syntheticBenchmark: nil
        }
        let estimateBytes = productionPhotos.map { Int64(cycles * ($0 * 10 + 10)) * 1_048_576 }

        return VStack(alignment: .leading, spacing: 4) {
            Text("Expected workload")
                .font(.subheadline.weight(.medium))
            if controller.config.mode == .productionPipeline {
                if let productionPhotos, let captureCount {
                    Text("\(cycles) sessions × \(productionPhotos) photos = \(captureCount) camera captures.")
                    if let estimateBytes {
                        Text("Estimated new output: about \(Self.formatBytes(estimateBytes)); estimate uses 10 MiB per photo plus 10 MiB per session.")
                    }
                } else {
                    Text("Photo count is unavailable until the active event template finishes loading.")
                }
                if controller.config.enablePhysicalPrint {
                    let printCount = (cycles + controller.config.physicalPrintEveryCycles - 1)
                        / max(1, controller.config.physicalPrintEveryCycles)
                    Text("Physical print jobs: up to \(printCount).")
                        .foregroundStyle(.red)
                }
            } else if controller.config.mode == .cameraHardware, let captureCount {
                Text("\(cycles) cycles × \(controller.config.photosPerSession) photos = \(captureCount) camera captures.")
            } else {
                Text("\(cycles) synthetic benchmark cycles; no camera captures.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var preflightCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preflight Diagnostics")
                .font(.headline)

            if controller.preflightErrors.isEmpty && controller.preflightWarnings.isEmpty {
                Label("All preflight checks passed. Ready for soak testing.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                ForEach(controller.preflightErrors, id: \.self) { err in
                    Label(err, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
                ForEach(controller.preflightWarnings, id: \.self) { warn in
                    Label(warn, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private var actionButtons: some View {
        HStack {
            Button("Start Soak Test") {
                controller.validatePreflight(coordinator: coordinator)
                if controller.isPreflightValid {
                    showStartConfirmation = true
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!controller.isPreflightValid)

            Spacer()
        }
        .padding(.top, 8)
    }

    private func runningProgressView(cycle: Int, total: Int, phase: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Soak Test In Progress")
                    .font(.headline)
                Spacer()
                Text("Cycle \(cycle) of \(total)")
                    .font(.subheadline.monospacedDigit().bold())
            }

            ProgressView(value: Double(cycle), total: Double(total))

            HStack {
                Label(phase, systemImage: "gearshape.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((Double(cycle) / Double(total)) * 100))%")
                    .font(.caption.monospacedDigit())
            }

            Divider()

            HStack(spacing: 12) {
                Button("Stop After Current Cycle") {
                    controller.stopGracefully()
                }
                .buttonStyle(.bordered)

                Button("Cancel Active Session", role: .destructive) {
                    controller.cancel()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(12)
    }

    private func stoppingView(reason: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Stopping Soak Test...")
                .font(.headline)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func reportView(report: BoothSoakTestReport, errorMessage: String? = nil) -> some View {
        let title: String
        let symbol: String
        let tint: Color
        switch report.outcome {
        case .passed:
            title = "Soak Test Passed"
            symbol = "checkmark.seal.fill"
            tint = .green
        case .failed:
            title = "Soak Test Failed"
            symbol = "xmark.octagon.fill"
            tint = .red
        case .stoppedEarly:
            title = "Soak Test Stopped Early"
            symbol = "stop.circle.fill"
            tint = .orange
        case .cancelled:
            title = "Soak Test Cancelled"
            symbol = "xmark.circle.fill"
            tint = .secondary
        }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(
                    title,
                    systemImage: symbol
                )
                .font(.title3.bold())
                .foregroundStyle(tint)

                Spacer()

                Button("Export Report…") {
                    exportReport(report)
                }
                .buttonStyle(.bordered)
            }

            Text(report.summaryVerdict)
                .font(.subheadline)
                .foregroundStyle(report.outcome == .failed ? .red : .primary)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // Metrics Grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                metricCell(title: "Cycles Completed", value: "\(report.completedCycles) / \(report.targetCycles)")
                metricCell(title: "Avg Cycle Duration", value: String(format: "%.2f s", report.averageCycleDurationSeconds))
                if report.captureSampleCount > 0 {
                    metricCell(title: "Avg Capture Latency", value: String(format: "%.3f s", report.avgCaptureLatencySeconds))
                    metricCell(title: "P95 Capture Latency", value: String(format: "%.3f s", report.p95CaptureLatencySeconds))
                }
                if let avgR = report.avgRenderLatencySeconds {
                    metricCell(title: "Avg Render Latency", value: String(format: "%.3f s", avgR))
                }
                if let p95R = report.p95RenderLatencySeconds {
                    metricCell(title: "P95 Render Latency", value: String(format: "%.3f s", p95R))
                }
                metricCell(title: "Peak RSS", value: String(format: "%.1f MB", Double(report.peakMemoryBytes) / (1024 * 1024)))
                metricCell(title: "Peak RSS Growth", value: rssGrowth(from: report.baselineMemoryBytes, to: report.peakMemoryBytes))
                metricCell(title: "Final RSS Growth", value: rssGrowth(from: report.baselineMemoryBytes, to: report.finalMemoryBytes))
                metricCell(title: "Thermal Events", value: "\(report.thermalTransitions)")
                metricCell(title: "Camera Reconnects", value: report.reconnectCount.map { String($0) } ?? "NOT TESTED")
            }

            if !report.subsystemCoverage.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Subsystem Coverage")
                        .font(.headline)
                    ForEach(report.subsystemCoverage.keys.sorted(), id: \.self) { subsystem in
                        HStack(alignment: .top) {
                            Text(subsystem)
                                .frame(width: 230, alignment: .leading)
                            Text(report.subsystemCoverage[subsystem] ?? "NOT TESTED")
                                .foregroundStyle((report.subsystemCoverage[subsystem] ?? "").hasPrefix("FAIL") ? .red : .secondary)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                    }
                }
            }

            if !report.invariantViolations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Issues & Warnings")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ForEach(report.invariantViolations, id: \.self) { v in
                        Text("• \(v)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            HStack {
                Button("Run Another Test") {
                    controller.state = .idle
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(12)
    }

    private func metricCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rssGrowth(from baseline: UInt64, to sample: UInt64) -> String {
        String(format: "%+.1f MB", (Double(sample) - Double(baseline)) / (1024 * 1024))
    }

    private func failureView(error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Soak Test Failed")
                .font(.headline)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Reset") {
                controller.state = .idle
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func exportReport(_ report: BoothSoakTestReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.nameFieldStringValue = "PRC-SoakTest-Report-\(ISO8601DateFormatter().string(from: Date())).md"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try controller.exportReport(to: url)
                } catch {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
