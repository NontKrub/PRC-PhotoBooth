import SwiftUI
import AppKit

struct OperationsView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.locale) private var locale
    @State private var showPrinterConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var serverStatus = LocalWebServerStatus(state: .stopped, registeredTokenCount: 0)
    @State private var boothHealth = BoothHealthSnapshot.empty
    @State private var manifests: [String: SessionManifest] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                readinessSummary
                preflightResults
                recoverySection
                webDeliverySection
                queueSection
                GalleryModerationView()
                printerSection
                serverSection
                healthSection
                remoteOperatorSection
            }
            .padding(24)
        }
        .navigationTitle("Operations")
        .task {
            await refreshServerStatus()
            await refreshManifests()
            boothHealth = await coordinator.healthSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refreshServerStatus()
                await refreshManifests()
                boothHealth = await coordinator.healthSnapshot()
            }
        }
        .confirmationDialog(
            "Run printer test?",
            isPresented: $showPrinterConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run Full Preflight") {
                Task { await coordinator.runFullPreflight(runPrinterTest: true) }
            }
            Button("Camera Only") {
                Task { await coordinator.runFullPreflight(runPrinterTest: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A printer test submits one diagnostic page and does not use a guest session.")
        }
        .confirmationDialog(
            "Discard unfinished session?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            if let session = coordinator.recoveryService.recoverableCaptureSession {
                Button("Discard Session", role: .destructive) {
                    coordinator.recoveryService.discardCaptureSession(sessionID: session.manifest.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Accepted files and the unfinished SwiftData session will be removed. The cancelled manifest remains for diagnostics.")
        }
    }

    private var readinessSummary: some View {
        GroupBox {
            HStack(spacing: 16) {
                Image(systemName: readinessIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(readinessColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(readinessTitle).font(.title2.bold())
                    if let lastRun = coordinator.preflight.lastRunAt {
                        (Text("Last checked ") + Text(lastRun, style: .relative) + Text(" ago"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No checks have run yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Run Safe Checks") {
                    Task { await coordinator.runSafePreflight() }
                }
                .buttonStyle(.bordered)
                Button("Run Full Preflight") {
                    showPrinterConfirmation = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var preflightResults: some View {
        GroupBox("Preflight Results") {
            if coordinator.preflight.results.isEmpty {
                Text("Run Safe Checks to inspect the booth.").foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(coordinator.preflight.results) { result in
                        PreflightStatusRow(result: result)
                        if result.id != coordinator.preflight.results.last?.id { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if let recoverable = coordinator.recoveryService.recoverableCaptureSession {
            GroupBox("Session Recovery") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recoverable.manifest.eventName).font(.headline)
                    Text("Started \(recoverable.manifest.startedAt, style: .date) at \(recoverable.manifest.startedAt, style: .time)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(acceptedCount(recoverable.manifest)) of \(recoverable.manifest.eventConfig.photoCount) photos accepted · next photo \(recoverable.manifest.nextPhotoIndex + 1)")
                    Text(recoverable.manifest.absoluteDirectoryPath)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if let issue = recoverable.issue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("The last unaccepted preview was not saved and will be retaken.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Resume") {
                            coordinator.recoveryService.resumeCaptureSession(sessionID: recoverable.manifest.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recoverable.issue != nil)
                        Button("Discard", role: .destructive) { showDiscardConfirmation = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var webDeliverySection: some View {
        GroupBox("Web Delivery") {
            let jobs = coordinator.jobQueue.jobs
                .filter { $0.kind == .cloudUpload }
                .sorted { $0.createdAt > $1.createdAt }
            if jobs.isEmpty {
                Text(UserDefaults.standard.bool(forKey: "cloudUploadEnabled")
                     ? "No completed sessions have a web upload job."
                     : "Not configured")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(jobs) { job in
                        webDeliveryRow(job)
                        if job.id != jobs.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func webDeliveryRow(_ job: SessionJob) -> some View {
        let manifest = manifests[job.sessionID]
        let title = manifest?.eventName ?? "Session \(job.sessionID.prefix(8))"
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold())
                    if let startedAt = manifest?.startedAt {
                        Text(startedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(job.sessionID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Label(webDeliveryStatus(job), systemImage: webDeliveryIcon(job))
                    .foregroundStyle(webDeliveryColor(job))
            }
            if job.status == .succeeded {
                Text("Last successful upload: \(job.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if job.status == .waitingRetry, let next = job.nextAttemptAt {
                (Text("Retry scheduled ") + Text(next, style: .relative))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = job.lastError, job.status == .failed || job.status == .cancelled {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if job.status == .failed || job.status == .cancelled {
                Text("The printed QR is still valid. Retrying the upload will restore the same link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if job.status == .failed || job.status == .cancelled || job.status == .succeeded {
                HStack {
                    Spacer()
                    Button(job.status == .succeeded ? "Re-upload Web Files" : "Retry Web Upload") {
                        coordinator.retryCloudUpload(sessionID: job.sessionID)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func webDeliveryStatus(_ job: SessionJob) -> String {
        switch job.status {
        case .pending: return "Waiting"
        case .running: return "Uploading… Attempt \(job.attemptCount)"
        case .waitingRetry: return "Retry scheduled"
        case .succeeded: return "Uploaded"
        case .failed, .cancelled: return "Upload failed"
        }
    }

    private func webDeliveryIcon(_ job: SessionJob) -> String {
        switch job.status {
        case .pending, .waitingRetry: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .cancelled: return "exclamationmark.triangle.fill"
        }
    }

    private func webDeliveryColor(_ job: SessionJob) -> Color {
        switch job.status {
        case .succeeded: return .green
        case .failed, .cancelled: return .red
        case .running, .waitingRetry: return .orange
        case .pending: return .secondary
        }
    }

    private var queueSection: some View {
        GroupBox("Persistent Queue") {
            VStack(alignment: .leading, spacing: 10) {
                let counts = queueCounts
                HStack(spacing: 16) {
                    queueCount("Pending", counts.pending)
                    queueCount("Running", counts.running)
                    queueCount("Waiting", counts.waiting)
                    queueCount("Failed", counts.failed)
                    queueCount("Completed", counts.completed)
                    Spacer()
                    Button("Retry All Failed") { coordinator.jobQueue.retryAllFailed() }
                        .disabled(counts.failed == 0)
                }
                if let error = coordinator.jobQueue.lastQueueError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                ForEach(coordinator.jobQueue.jobs) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(operatorJobKindName(job.kind, locale: locale)) · \(job.sessionID.prefix(8))")
                                .font(.subheadline.bold())
                            Spacer()
                            Text(operatorJobStatusName(job.status, locale: locale))
                                .foregroundStyle(job.status == .failed ? .red : .secondary)
                            if (job.status == .failed || job.status == .cancelled) && job.kind != .cloudUpload {
                                Button("Retry") { coordinator.jobQueue.retry(jobID: job.id) }
                            }
                            if job.kind.isOptional && job.status != .succeeded && job.status != .cancelled {
                                Button("Cancel") { coordinator.jobQueue.cancel(jobID: job.id) }
                            }
                            Button("Open Folder") { openFolder(for: job.sessionID) }
                        }
                        Text("\(operatorString("Attempts", locale: locale)): \(job.attemptCount)" + (job.lastError.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if let next = job.nextAttemptAt {
                            (Text("Next attempt ") + Text(next, style: .relative))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
        }
    }

    private var printerSection: some View {
        GroupBox("Printer Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                Text(printerStatusText)
                Text("\(operatorString("Paper", locale: locale)): \(UserDefaults.standard.string(forKey: "selphyPaperSize") ?? SelphyPaperSize.postcard.rawValue) · \(operatorString("Copies", locale: locale)): \(max(1, UserDefaults.standard.integer(forKey: "selphyCopies")))")
                    .font(.caption).foregroundStyle(.secondary)
                if let result = coordinator.printer.lastTestResult {
                    Label(result.message, systemImage: result.isSuccess ? "checkmark.circle" : "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(result.isSuccess ? .green : .red)
                } else {
                    Text("Printer test: Not run this launch.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Print Test Page") {
                        Task { try? await coordinator.printer.printTestPage(); await coordinator.runSafePreflight() }
                    }
                    .buttonStyle(.bordered)
                    Button("Open System Print Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Printers-Scanners-Settings")!)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var serverSection: some View {
        GroupBox("Local Download Server") {
            VStack(alignment: .leading, spacing: 5) {
                Text(serverStatusText)
                Text("Registered tokens: \(serverStatus.registeredTokenCount)")
                    .font(.caption).foregroundStyle(.secondary)
                if !coordinator.serverURL.isEmpty {
                    Text("LAN URL: \(coordinator.serverURL)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var healthSection: some View {
        GroupBox("Device Health") {
            let camera = boothHealth.camera
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(camera.cameraName ?? camera.cameraKind).font(.headline)
                    Spacer()
                    Label(camera.connected ? "Connected" : (camera.connecting ? "Connecting" : "Unavailable"),
                          systemImage: camera.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(camera.connected ? .green : .orange)
                }
                HStack(spacing: 18) {
                    healthValue("Control", boothHealth.controlConnection)
                    healthValue("Preview", camera.livePreviewActive ? "Active" : "Inactive")
                    healthValue("PTP", camera.ptpHealthy.map { $0 ? "Healthy" : "Degraded" } ?? "n/a")
                    healthValue("Failures", "\(camera.captureFailureCount)")
                    healthValue("Recovered", "\(camera.recoveredTransferCount)")
                }
                HStack(spacing: 18) {
                    healthValue("Last capture", camera.lastCaptureAt.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    healthValue("Receive", camera.lastCaptureDuration.map { String(format: "%.1fs", $0) } ?? "—")
                    healthValue("Disk", boothHealth.diskAvailableBytes.map(formatBytes) ?? "—")
                    Spacer()
                    Button(coordinator.isBoothPaused ? "Resume Booth" : "Pause Booth") {
                        coordinator.isBoothPaused ? coordinator.resumeBooth() : coordinator.pauseBooth()
                    }
                    .buttonStyle(.bordered)
                }
                if let delivery = boothHealth.delivery {
                    Text("Delivery: \(delivery.local.rawValue)" +
                         (delivery.cloud.map { " · \($0.rawValue)" } ?? "") +
                         (delivery.print.map { " · \($0.rawValue)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var remoteOperatorSection: some View {
        GroupBox("Remote Operator") {
            let pairingURL = coordinator.operatorPairingURL
            HStack(alignment: .top, spacing: 16) {
                if let qr = generateQRCode(from: pairingURL) {
                    Image(nsImage: NSImage(cgImage: qr, size: .zero))
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 130, height: 130)
                        .accessibilityLabel("Remote operator pairing QR code")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Scan to connect an operator device.")
                    Text(pairingURL).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Copy Pairing Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pairingURL, forType: .string)
                        }
                        if let station = coordinator.sharingStationURL {
                            Text("Sharing Station: \(station)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func healthValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced())
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var readinessTitle: String {
        switch coordinator.preflight.readiness {
        case .ready: return operatorString("Ready", locale: locale)
        case .readyWithWarnings: return operatorString("Ready with Warnings", locale: locale)
        case .notReady: return operatorString("Not Ready", locale: locale)
        case .checking: return operatorString("Checking…", locale: locale)
        }
    }

    private var readinessIcon: String {
        switch coordinator.preflight.readiness {
        case .ready: return "checkmark.seal.fill"
        case .readyWithWarnings: return "exclamationmark.triangle.fill"
        case .notReady: return "xmark.octagon.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        }
    }

    private var readinessColor: Color {
        switch coordinator.preflight.readiness {
        case .ready: return .green
        case .readyWithWarnings: return .orange
        case .notReady: return .red
        case .checking: return .blue
        }
    }

    private var printerStatusText: String {
        switch coordinator.printer.configuredPrinterStatus() {
        case .systemDefault: return operatorString("Selected printer: System Default", locale: locale)
        case .available(let name): return operatorFormat("Selected printer: %@", locale: locale, name)
        case .unavailable(let name): return operatorFormat("Configured printer unavailable: %@", locale: locale, name)
        }
    }

    private var serverStatusText: String {
        switch serverStatus.state {
        case .stopped: return operatorString("Stopped", locale: locale)
        case .starting: return operatorString("Starting…", locale: locale)
        case .ready(let port): return operatorFormat("Ready on port %@", locale: locale, String(port))
        case .failed(let message): return operatorFormat("Failed: %@", locale: locale, message)
        }
    }

    private var queueCounts: (pending: Int, running: Int, waiting: Int, failed: Int, completed: Int) {
        (
            coordinator.jobQueue.jobs.filter { $0.status == .pending }.count,
            coordinator.jobQueue.jobs.filter { $0.status == .running }.count,
            coordinator.jobQueue.jobs.filter { $0.status == .waitingRetry }.count,
            coordinator.jobQueue.jobs.filter { $0.status == .failed }.count,
            coordinator.jobQueue.jobs.filter { $0.status == .succeeded }.count
        )
    }

    private func queueCount(_ title: String, _ count: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title3.bold())
            Text(operatorString(title, locale: locale)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func acceptedCount(_ manifest: SessionManifest) -> Int {
        manifest.shots.filter { $0.imageFileName != nil }.count
    }

    private func refreshServerStatus() async {
        serverStatus = await coordinator.server.statusSnapshot()
    }

    private func refreshManifests() async {
        var loaded: [String: SessionManifest] = [:]
        for result in await coordinator.manifestStore.loadAll() {
            if case .loaded(let manifest) = result {
                loaded[manifest.id] = manifest
            }
        }
        manifests = loaded
    }

    private func openFolder(for sessionID: String) {
        Task {
            guard let manifest = try? await coordinator.manifestStore.load(sessionID: sessionID) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true))
        }
    }
}
