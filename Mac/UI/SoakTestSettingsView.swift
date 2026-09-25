import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SoakTestSettingsView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @State private var controller = BoothSoakTestController()
    @State private var showStartConfirmation = false
    @State private var exportErrorMessage: String?
    @State private var showExportSuccess = false

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
                reportView(report: report, isFailed: false)
            case .failed(let err, let report):
                if let report {
                    reportView(report: report, isFailed: true, errorMessage: err)
                } else {
                    failureView(error: err)
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            controller.validatePreflight(coordinator: coordinator)
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
            Text("This will execute \(controller.config.targetCycles) automated sessions to verify hardware stability, thermal state, and memory bounds.\(controller.config.enablePhysicalPrint ? "\n\n⚠️ WARNING: PHYSICAL PRINTING IS ENABLED!" : "")")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Event Readiness Soak Test", systemImage: "flame.fill")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text("Automated sustained-load verification to stress camera capture, compositing, job queueing, and local delivery before major live events.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test Configuration")
                .font(.headline)

            Picker("Mode", selection: $controller.config.mode) {
                ForEach(BoothSoakTestMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(controller.config.mode.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Target Cycles:")
                    .frame(width: 140, alignment: .leading)
                Picker("", selection: $controller.config.targetCycles) {
                    Text("10 (Quick Smoke)").tag(10)
                    Text("25 (Short Benchmark)").tag(25)
                    Text("50 (Standard Soak)").tag(50)
                    Text("100 (Stress Test)").tag(100)
                    Text("500 (Full Event Soak)").tag(500)
                }
                .labelsHidden()
                .frame(width: 200)
            }

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
                Text("Removes working photos and test strips after each cycle to prevent filling disk space.")
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
                Text("DO NOT enable during normal testing! Real paper and ribbon will be printed for every session.")
                    .font(.caption)
                    .foregroundStyle(controller.config.enablePhysicalPrint ? .red : .secondary)
            }
            .padding(12)
            .background(controller.config.enablePhysicalPrint ? Color.red.opacity(0.08) : Color.primary.opacity(0.03))
            .cornerRadius(8)
        }
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

                Button("Cancel Immediately", role: .destructive) {
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

    private func reportView(report: BoothSoakTestReport, isFailed: Bool, errorMessage: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(
                    isFailed ? "Soak Test Incomplete / Failed" : "Soak Test Passed",
                    systemImage: isFailed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
                )
                .font(.title3.bold())
                .foregroundStyle(isFailed ? .red : .green)

                Spacer()

                Button("Export Report…") {
                    exportReport(report)
                }
                .buttonStyle(.bordered)
            }

            Text(report.summaryVerdict)
                .font(.subheadline)
                .foregroundStyle(isFailed ? .red : .primary)

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
                metricCell(title: "Avg Capture Latency", value: String(format: "%.3f s", report.avgCaptureLatencySeconds))
                metricCell(title: "P95 Capture Latency", value: String(format: "%.3f s", report.p95CaptureLatencySeconds))
                if let avgR = report.avgRenderLatencySeconds {
                    metricCell(title: "Avg Render Latency", value: String(format: "%.3f s", avgR))
                }
                if let p95R = report.p95RenderLatencySeconds {
                    metricCell(title: "P95 Render Latency", value: String(format: "%.3f s", p95R))
                }
                metricCell(title: "Peak Memory", value: String(format: "%.1f MB", Double(report.peakMemoryBytes) / (1024 * 1024)))
                metricCell(title: "Thermal Events", value: "\(report.thermalTransitions)")
                metricCell(title: "Camera Reconnects", value: "\(report.reconnectCount)")
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
