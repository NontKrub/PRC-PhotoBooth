import SwiftUI
import AVFoundation

struct OperatorConsoleView: View {
    var onOpenOperations: () -> Void
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(SessionStateMachine.self) private var sm
    @Environment(\.locale) private var locale
    @State private var showPrintPrompt = false
    @State private var showPrintAgainConfirmation = false
    @State private var showGrid = false

    var body: some View {
        HStack(spacing: 0) {
            cameraPanel
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                connectionBanner
                readinessBanner
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        cameraSourcePicker
                        if coordinator.cameraSourceKind == .dslr {
                            dslrPanel
                        }
                        eventInfoPanel
                        if let img = coordinator.currentStripPreview {
                            stripPreviewPanel(image: img)
                        }
                        phasePanel
                        sessionControls
                        overrideControls
                        Spacer(minLength: 0)
                        serverInfoPanel
                    }
                    .padding()
                }
            }
            .frame(width: 300)
        }
        .onChange(of: sm.phase) { _, newPhase in
            if case .finished = newPhase { showPrintPrompt = true }
        }
        .alert("Print Photo Strip?", isPresented: $showPrintPrompt) {
            Button("Print") { coordinator.printCurrentStrip() }
            Button("Skip", role: .cancel) {}
        } message: {
            Text("Send the strip to your connected Selphy printer.")
        }
        .confirmationDialog("Print this strip again?", isPresented: $showPrintAgainConfirmation, titleVisibility: .visible) {
            Button("Print Again") { coordinator.printAgainCurrentStrip() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This submits a new print request and does not create another persistent automatic-print job.")
        }
    }

    // MARK: - Camera panel

    var cameraPanel: some View {
        ZStack {
            Color.black
            if !coordinator.cameraPermissionGranted {
                permissionDeniedOverlay
            } else {
                ActiveCameraPreviewView(
                    preview: ActiveCameraPreviewResolver.resolve(
                        capture: coordinator.capture,
                        source: coordinator.cameraSourceKind
                    ),
                    showGrid: showGrid,
                    onStart: coordinator.cameraSourceKind == .avFoundation
                        ? { Task { await coordinator.checkCameraPermission() } }
                        : nil
                )
                if coordinator.cameraSourceKind == .dslr {
                    dslrPreviewBadge
                }
            }
        }
        .frame(minWidth: 480)
    }

    var dslrPreviewBadge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Label(coordinator.capture.dslr.isLivePreviewActive
                      ? "DSLR Live Preview"
                      : (coordinator.capture.dslr.isRunning ? "DSLR Control Active" : "DSLR Standby"),
                      systemImage: coordinator.capture.dslr.isRunning ? "camera.fill" : "camera")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(coordinator.capture.dslr.isRunning ? Color.green.opacity(0.8) : Color.orange.opacity(0.8),
                                in: Capsule())
            }
            .padding(12)
        }
    }

    var permissionDeniedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("Camera Access Required")
                .font(.headline).foregroundStyle(.white)
            Text("Grant camera access in System Settings → Privacy & Security → Camera.")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    // MARK: - Connection banner

    var connectionBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(connectionColor).frame(width: 8, height: 8)
            Text(connectionLabel).font(.caption)
            Spacer()
            if case .connected = coordinator.multipeer.connectionState {
                Image(systemName: "wifi").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(connectionColor.opacity(0.08))
    }

    var readinessBanner: some View {
        Button(action: onOpenOperations) {
            HStack(spacing: 8) {
                Circle().fill(readinessColor).frame(width: 8, height: 8)
                Text(readinessLabel).font(.caption)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(readinessColor.opacity(0.08))
        }
        .buttonStyle(.plain)
    }

    var readinessLabel: String {
        switch coordinator.preflight.readiness {
        case .ready: return operatorString("Booth Ready", locale: locale)
        case .readyWithWarnings: return operatorString("Ready with Warnings", locale: locale)
        case .notReady: return operatorString("Booth Not Ready", locale: locale)
        case .checking: return operatorString("Checking Booth…", locale: locale)
        }
    }

    var readinessColor: Color {
        switch coordinator.preflight.readiness {
        case .ready: return .green
        case .readyWithWarnings: return .orange
        case .notReady: return .red
        case .checking: return .blue
        }
    }

    var connectionColor: Color {
        switch coordinator.multipeer.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .red
        }
    }

    var connectionLabel: String {
        switch coordinator.multipeer.connectionState {
        case .connected(let name): return operatorFormat("iPad connected: %@", locale: locale, name)
        case .connecting:          return operatorString("Connecting to iPad…", locale: locale)
        case .disconnected:        return operatorString("iPad not connected", locale: locale)
        }
    }

    // MARK: - Camera source picker

    var cameraSourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Camera Source", systemImage: "camera")
                .font(.caption).foregroundStyle(.secondary)
            @Bindable var c = coordinator
            Picker("", selection: $c.cameraSourceKind) {
                ForEach(CameraSourceKind.allCases) { kind in
                    Text(operatorCameraSourceName(kind, locale: locale)).tag(kind)
                }
            }
            .labelsHidden()

            Toggle("Grid overlay", isOn: $showGrid).font(.caption2)

            // AVFoundation device list + mirror toggle
            if coordinator.cameraSourceKind == .avFoundation {
                @Bindable var cam = coordinator.capture.camera
                let devices = cam.availableDevices
                if devices.isEmpty {
                    Text("No cameras found").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $cam.selectedDeviceID) {
                        ForEach(devices) { dev in
                            Label(dev.name, systemImage: iconName(for: dev.kind)).tag(Optional(dev.id))
                        }
                    }
                    .labelsHidden()
                    .font(.caption2)
                }
                Toggle("Mirror camera", isOn: Binding(
                    get: { cam.isMirrored },
                    set: { coordinator.setMirrored($0) }
                ))
                .font(.caption2)

                HStack {
                    Text("Flash").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $cam.flashMode) {
                        Text("Off").tag(AVCaptureDevice.FlashMode.off)
                        Text("Auto").tag(AVCaptureDevice.FlashMode.auto)
                        Text("On").tag(AVCaptureDevice.FlashMode.on)
                    }
                    .labelsHidden()
                    .font(.caption2)
                }
                Text("Ignored by cameras with no flash hardware (most webcams).")
                    .font(.caption2).foregroundStyle(.tertiary)

                if cam.isContinuityCamera {
                    if cam.hasTorch {
                        Toggle("Torch", isOn: $cam.torchOn).font(.caption2)
                    }
                    HStack {
                        Text("EV").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $cam.exposureEV, in: -2...2)
                        Text(String(format: "%.1f", cam.exposureEV)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
    }

    private func iconName(for kind: CameraDeviceInfo.Kind) -> String {
        switch kind {
        case .builtIn:          return "camera.fill"
        case .continuityCamera: return "iphone"
        case .usb, .dslr:       return "cable.connector"
        }
    }

    // MARK: - DSLR panel

    var dslrPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DSLR / Mirrorless", systemImage: "camera.aperture")
                .font(.caption).foregroundStyle(.secondary)

            // Detected cameras
            let dslrDevices = coordinator.capture.dslr.availableDevices
            if dslrDevices.isEmpty {
                Label("No tethered camera detected", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                Text("Connect camera via USB and set USB mode to PC Remote.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                @Bindable var dslr = coordinator.capture.dslr
                Picker("Camera", selection: $dslr.selectedDeviceID) {
                    ForEach(dslrDevices) { dev in
                        Text(dev.name).tag(Optional(dev.id))
                    }
                }
                .labelsHidden()
                .font(.caption)
            }

            // Image Capture conflict warning
            let imageCaptureRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.Image_Capture").isEmpty
            let photosRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.Photos").isEmpty
            if imageCaptureRunning || photosRunning {
                let names = [imageCaptureRunning ? "Image Capture" : nil,
                             photosRunning ? "Photos" : nil]
                    .compactMap { $0 }.joined(separator: " & ")
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(names) is open — it may block the camera session.")
                            .font(.caption2)
                        Button("Quit \(names)") {
                            NSRunningApplication
                                .runningApplications(withBundleIdentifier: "com.apple.Image_Capture")
                                .forEach { $0.terminate() }
                            NSRunningApplication
                                .runningApplications(withBundleIdentifier: "com.apple.Photos")
                                .forEach { $0.terminate() }
                        }
                        .font(.caption2)
                    }
                }
                .padding(6)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            // Connect / Disconnect
            let dslr = coordinator.capture.dslr
            if dslr.isRunning {
                Button(action: { coordinator.disconnectDSLR() }) {
                    Label("Disconnect", systemImage: "eject.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else if dslr.isConnecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption)
                }
                .frame(maxWidth: .infinity)
            } else {
                Button(action: { coordinator.connectDSLR() }) {
                    Label("Connect Camera", systemImage: "cable.connector")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.capture.dslr.availableDevices.isEmpty)
            }

            if coordinator.capture.dslr.isRunning {
                Divider()
                Button(action: { coordinator.testCameraCapture() }) {
                    Label(LocalizedStringKey(coordinator.capture.dslr.isCapturing ? "Capturing..." : "Test Capture"),
                          systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .font(.caption)
                .disabled(coordinator.capture.dslr.isCapturing)
                dslrSettingsPanel
                if coordinator.capture.dslr.isLivePreviewActive {
                    Text("Live preview: Sony ZV-E10 PTP stream")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if let preview = coordinator.capture.camera.availableDevices
                    .first(where: { $0.id == coordinator.capture.camera.selectedDeviceID }) {
                    Text("Live preview device: \(preview.name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Live preview: not exposed by this USB mode")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - DSLR settings

    var dslrSettingsPanel: some View {
        @Bindable var dslr = coordinator.capture.dslr
        let support = dslr.controlSupport
        let usingAutoPictureMode = dslr.isSonyZVE10 && dslr.automaticPictureMode
        return VStack(alignment: .leading, spacing: 8) {
            Label("Camera Settings", systemImage: "slider.horizontal.3")
                .font(.caption).foregroundStyle(.secondary)

            if dslr.isSonyZVE10 {
                Toggle("Auto picture mode", isOn: $dslr.automaticPictureMode)
                    .font(.caption)
                    .onChange(of: dslr.automaticPictureMode) { _, _ in
                        dslr.applySettings()
                    }
                Text("Uses the ZV-E10's AUTO or P exposure program. ISO, shutter speed, and aperture stay automatic.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Flash
            HStack {
                Text("Flash").font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                Picker("", selection: $dslr.flashMode) {
                    ForEach(DSLRFlashMode.allCases) { m in Text(operatorFlashModeName(m, locale: locale)).tag(m) }
                }
                .labelsHidden().font(.caption2)
                .disabled(!support.flash)
            }

            // ISO
            HStack {
                Text("ISO").font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                Picker("", selection: $dslr.iso) {
                    ForEach(DSLRISOPresets, id: \.self) { v in Text("\(v)").tag(v) }
                }
                .labelsHidden().font(.caption2)
                .disabled(!support.iso || usingAutoPictureMode)
            }

            // Shutter speed
            HStack {
                Text("Shutter").font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                Picker("", selection: $dslr.shutterSpeed) {
                    ForEach(DSLRShutterSpeed.presets) { s in Text(s.label).tag(s) }
                }
                .labelsHidden().font(.caption2)
                .disabled(!support.shutter || usingAutoPictureMode)
            }

            // Aperture (display-only reminder — PTP aperture is camera-specific encoded)
            HStack {
                Text("Aperture").font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                Picker("", selection: $dslr.aperture) {
                    ForEach(DSLRAperture.presets) { a in Text(a.label).tag(a) }
                }
                .labelsHidden().font(.caption2)
                .disabled(!support.aperture || usingAutoPictureMode)
            }
            Text("Set aperture on camera body when disabled — USB PTP support varies by camera.")
                .font(.caption2).foregroundStyle(.tertiary)

            if !support.shutter || !support.aperture {
                Text("Some DSLR controls are unavailable on this camera's USB profile.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Button(action: { coordinator.capture.dslr.applySettings() }) {
                Label("Apply to Camera", systemImage: "arrow.up.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    // MARK: - Strip preview

    private func stripPreviewPanel(image: CGImage) -> some View {
        // NSBitmapImageRep preserves raw pixel layout; NSImage(cgImage:) can re-flip
        let rep = NSBitmapImageRep(cgImage: image)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return VStack(alignment: .leading, spacing: 4) {
            Label("Strip Preview", systemImage: "photo.stack")
                .font(.caption).foregroundStyle(.secondary)
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 200)
                .cornerRadius(6)
        }
    }

    // MARK: - Event info

    var eventInfoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Active Event", systemImage: "calendar")
                .font(.caption).foregroundStyle(.secondary)
            if let event = coordinator.activeEvent {
                Text(event.name).font(.headline)
                Text(operatorPhotoSummary(
                    photoCount: event.photoCount,
                    countdownSeconds: event.countdownSeconds,
                    locale: locale
                ))
                    .font(.caption).foregroundStyle(.secondary)
                if event.slots.isEmpty {
                    Label("No photo slots defined", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Label("No active event — go to Event Setup", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Phase

    var phasePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Session Phase", systemImage: "circle.dashed")
                .font(.caption).foregroundStyle(.secondary)
            Text(operatorPhaseName(sm.phase, locale: locale))
                .font(.headline).foregroundStyle(phaseColor)
            if case .countdown(_, let secs) = sm.phase {
                ProgressView(value: Double(secs),
                             total: Double(sm.config.countdownSeconds))
                    .tint(.orange)
            }
            if case .finished = sm.phase {
                Button("Print Again") { showPrintAgainConfirmation = true }
                    .buttonStyle(.bordered)
                finishedWebDeliveryStatus
            }
            if case .processing = sm.phase {
                processingStatus
            }
        }
    }

    @ViewBuilder
    private var finishedWebDeliveryStatus: some View {
        let sessionID = coordinator.lastCompletedSessionID ?? sm.currentSessionID
        if !sessionID.isEmpty,
           let job = coordinator.jobQueue.jobs.first(where: {
               $0.sessionID == sessionID && $0.kind == .cloudUpload
           }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Web Delivery", systemImage: webDeliveryIcon(job))
                    Spacer()
                    Text(webDeliveryStatus(job))
                        .font(.caption)
                        .foregroundStyle(webDeliveryColor(job))
                }
                if job.status == .waitingRetry, let next = job.nextAttemptAt {
                    (Text("Retry scheduled ") + Text(next, style: .relative))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if job.status == .failed || job.status == .cancelled {
                    Text(job.lastError ?? "The QR may not work until the upload is retried.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("The printed QR is still valid. Retrying the upload will restore the same link.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Retry Web Upload") {
                        coordinator.retryCloudUpload(sessionID: sessionID)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func webDeliveryStatus(_ job: SessionJob) -> String {
        switch job.status {
        case .pending: return "Waiting"
        case .running: return "Uploading… Attempt \(job.attemptCount)"
        case .waitingRetry: return "Retry scheduled"
        case .succeeded: return "Uploaded"
        case .failed: return "Upload failed"
        case .cancelled: return "Upload cancelled"
        }
    }

    private func webDeliveryIcon(_ job: SessionJob) -> String {
        switch job.status {
        case .pending, .waitingRetry: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private func webDeliveryColor(_ job: SessionJob) -> Color {
        switch job.status {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .running, .waitingRetry: return .orange
        case .pending: return .secondary
        }
    }

    private var processingStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            let sessionJobs = coordinator.jobQueue.jobs.filter { $0.sessionID == sm.currentSessionID }
            if let strip = sessionJobs.first(where: { $0.kind == .renderStrip }) {
                Text(LocalizedStringKey(strip.status == .succeeded ? "Strip ready" : "Rendering strip…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let download = sessionJobs.first(where: { $0.kind == .registerDownload }) {
                Text(LocalizedStringKey(download.status == .succeeded ? "Download ready" : "Preparing download…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sessionJobs.contains(where: { $0.kind == .cloudUpload && $0.status != .succeeded }) {
                Text("Cloud upload pending").font(.caption).foregroundStyle(.secondary)
            }
            if sessionJobs.contains(where: { $0.kind == .renderGIF && $0.status != .succeeded }) {
                Text("GIF processing").font(.caption).foregroundStyle(.secondary)
            }
            if sessionJobs.contains(where: { $0.kind == .autoPrint && $0.status != .succeeded }) {
                Text("Print pending").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var phaseColor: Color {
        switch sm.phase {
        case .idle, .selectingExperience, .readyToStart:  return .primary
        case .countdown:            return .orange
        case .captured:             return .blue
        case .review:               return .purple
        case .captureRecovery:      return .red
        case .processing:           return .yellow
        case .finished:             return .green
        }
    }

    // MARK: - Session controls

    var sessionControls: some View {
        VStack(spacing: 8) {
            Button(action: { coordinator.startSession() }) {
                Label("Start Session", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.activeEvent == nil
                      || (sm.phase != .idle && sm.phase != .readyToStart)
                      || !coordinator.cameraPermissionGranted
                      || !coordinator.capture.isRunning
                      || (coordinator.cameraSourceKind == .dslr && !coordinator.capture.dslr.isRunning)
                      || !coordinator.isCustomerDisplayReady
                      || coordinator.recoveryService.recoverableCaptureSession != nil)
            .help(coordinator.activeEvent == nil ? "Select an active event first" :
                  !coordinator.cameraPermissionGranted ? "Camera permission required" :
                  !coordinator.capture.isRunning ? "Start the selected camera first" :
                  (coordinator.cameraSourceKind == .dslr && !coordinator.capture.dslr.isRunning) ? "Connect DSLR camera first" :
                  !coordinator.isCustomerDisplayReady ? "Connect an iPad or activate the external viewer" :
                  coordinator.recoveryService.recoverableCaptureSession != nil ? "Resume or discard the unfinished session in Operations." : "")

            Button(action: { coordinator.operatorOverride(.cancelSession) }) {
                Label("Reset to Idle", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(sm.phase == .idle)
        }
    }

    // MARK: - Overrides

    var overrideControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Operator Override", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                overrideBtn("Retake", icon: "arrow.counterclockwise") { coordinator.operatorOverride(.forceRetake) }
                    .disabled(!canRetake)
                overrideBtn("Skip", icon: "forward.fill") { coordinator.operatorOverride(.skip) }
                    .disabled(!canSkip)
                overrideBtn("Cancel", icon: "xmark", tint: .red) { coordinator.operatorOverride(.cancelSession) }
                    .disabled(sm.phase == .idle)
            }
        }
    }

    private func overrideBtn(_ label: LocalizedStringKey, icon: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    var iPadConnected: Bool { if case .connected = coordinator.multipeer.connectionState { return true }; return false }
    var canRetake: Bool { if case .review = sm.phase { return true }; return false }
    var canSkip: Bool   { if case .review = sm.phase { return true }; return false }

    // MARK: - Server info

    var serverInfoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Download Server", systemImage: "network")
                .font(.caption2).foregroundStyle(.secondary)
            if coordinator.serverURL.isEmpty {
                Text("Not available (no LAN IP)").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(coordinator.serverURL).font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(.bottom, 8)
    }
}

enum ActiveCameraPreview {
    case image(CGImage)
    case session(AVCaptureSession, mirrored: Bool)
    case unavailable(title: String, detail: String)
}

@MainActor
enum ActiveCameraPreviewResolver {
    static func resolve(capture: CaptureService, source: CameraSourceKind) -> ActiveCameraPreview {
        let selectedDeviceKind = capture.camera.availableDevices
            .first { $0.id == capture.camera.selectedDeviceID }?.kind
        return resolve(
            source: source,
            demoImage: capture.demoMode ? capture.demoPreviewImage : nil,
            dslrPreview: capture.dslr.latestPreviewImage,
            dslrLastCapture: capture.dslr.lastCapturedImage,
            fallbackSession: capture.camera.captureSession,
            fallbackDeviceKind: selectedDeviceKind,
            cameraRunning: capture.isRunning,
            mirrored: capture.camera.isMirrored
        )
    }

    static func resolve(
        source: CameraSourceKind,
        demoImage: CGImage?,
        dslrPreview: CGImage?,
        dslrLastCapture: CGImage?,
        fallbackSession: AVCaptureSession?,
        fallbackDeviceKind: CameraDeviceInfo.Kind?,
        cameraRunning: Bool,
        mirrored: Bool
    ) -> ActiveCameraPreview {
        if let demoImage { return .image(demoImage) }

        if source == .dslr {
            if let dslrPreview { return .image(dslrPreview) }
            if cameraRunning,
               let fallbackSession,
               let fallbackDeviceKind,
               fallbackDeviceKind != .builtIn {
                return .session(fallbackSession, mirrored: mirrored)
            }
            if let dslrLastCapture { return .image(dslrLastCapture) }
            return .unavailable(
                title: "Sony PTP Standby",
                detail: "Connect the camera to start Sony PTP live view."
            )
        }

        if cameraRunning, let fallbackSession {
            return .session(fallbackSession, mirrored: mirrored)
        }
        return .unavailable(title: "Camera not running", detail: "Start the camera to show a live preview.")
    }
}

struct ActiveCameraPreviewView: View {
    let preview: ActiveCameraPreview
    var showGrid = false
    var onStart: (() -> Void)?

    var body: some View {
        Group {
            switch preview {
            case .image(let image):
                CapturedImagePreview(cgImage: image)
            case .session(let session, let mirrored):
                CameraPreviewView(captureSession: session, isMirrored: mirrored)
                    .aspectRatio(4 / 3, contentMode: .fit)
            case .unavailable(let title, let detail):
                VStack(spacing: 12) {
                    Image(systemName: "camera.slash.fill")
                        .font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(title).foregroundStyle(.secondary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    if let onStart {
                        Button("Start Camera", action: onStart)
                            .buttonStyle(.bordered)
                    }
                }
        }
        }
        .overlay {
            if showGrid { GridOverlayView() }
        }
    }
}

private struct CapturedImagePreview: View {
    let cgImage: CGImage

    var body: some View {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AVFoundation preview (NSViewRepresentable)

struct CameraPreviewView: NSViewRepresentable {
    let captureSession: AVCaptureSession?
    var isMirrored = false
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView() }
    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.updateSession(captureSession, isMirrored: isMirrored)
    }
}

final class PreviewNSView: NSView {
    private var layer_: AVCaptureVideoPreviewLayer?
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { CALayer() }

    func updateSession(_ session: AVCaptureSession?, isMirrored: Bool = false) {
        if layer_?.session !== session {
            layer_?.removeFromSuperlayer()
            guard let session else { return }
            wantsLayer = true
            let l = AVCaptureVideoPreviewLayer(session: session)
            l.videoGravity = .resizeAspect
            l.frame = bounds
            self.layer?.addSublayer(l)
            layer_ = l
        }
        // ponytail: CATransform3D flip avoids AVCaptureConnection_Tundra crash on Continuity Camera
        layer_?.transform = isMirrored
            ? CATransform3DMakeScale(-1, 1, 1)
            : CATransform3DIdentity
    }

    override func layout() {
        super.layout()
        layer_?.frame = bounds
    }
}

// MARK: - Grid overlay (composition guide — rule of thirds + center crosshair)

struct GridOverlayView: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                path.move(to: CGPoint(x: w/3, y: 0));   path.addLine(to: CGPoint(x: w/3, y: h))
                path.move(to: CGPoint(x: 2*w/3, y: 0)); path.addLine(to: CGPoint(x: 2*w/3, y: h))
                path.move(to: CGPoint(x: 0, y: h/3));   path.addLine(to: CGPoint(x: w, y: h/3))
                path.move(to: CGPoint(x: 0, y: 2*h/3)); path.addLine(to: CGPoint(x: w, y: 2*h/3))
                let cx = w/2, cy = h/2, len: CGFloat = 16
                path.move(to: CGPoint(x: cx - len, y: cy)); path.addLine(to: CGPoint(x: cx + len, y: cy))
                path.move(to: CGPoint(x: cx, y: cy - len)); path.addLine(to: CGPoint(x: cx, y: cy + len))
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
