import SwiftUI
import AVFoundation

struct OperatorConsoleView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(SessionStateMachine.self) private var sm
    @State private var showPrintPrompt = false
    @State private var showGrid = false

    var body: some View {
        HStack(spacing: 0) {
            cameraPanel
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                connectionBanner
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
    }

    // MARK: - Camera panel

    var cameraPanel: some View {
        ZStack {
            Color.black
            if !coordinator.cameraPermissionGranted {
                permissionDeniedOverlay
            } else if coordinator.cameraSourceKind == .dslr {
                if let image = coordinator.capture.dslr.latestPreviewImage {
                    CapturedImagePreview(cgImage: image)
                        .overlay {
                            if showGrid { GridOverlayView() }
                        }
                } else if coordinator.capture.isRunning,
                   let session = coordinator.capture.camera.captureSession,
                   dslrPreviewDevice != nil {
                    CameraPreviewView(captureSession: session,
                                     isMirrored: coordinator.capture.camera.isMirrored)
                        .aspectRatio(4/3, contentMode: .fit)
                        .overlay {
                            if showGrid { GridOverlayView() }
                        }
                } else if let image = coordinator.capture.dslr.lastCapturedImage {
                    CapturedImagePreview(cgImage: image)
                        .overlay {
                            if showGrid { GridOverlayView() }
                        }
                } else {
                    dslrPTPPreviewOverlay
                }
                dslrPreviewBadge
            } else if coordinator.capture.isRunning, let session = coordinator.capture.camera.captureSession {
                CameraPreviewView(captureSession: session,
                                 isMirrored: coordinator.capture.camera.isMirrored)
                    .aspectRatio(4/3, contentMode: .fit)
                    .overlay {
                        if showGrid { GridOverlayView() }
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.slash.fill")
                        .font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text("Camera not running")
                        .foregroundStyle(.secondary)
                    Button("Start Camera") { Task { await coordinator.checkCameraPermission() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(minWidth: 480)
    }

    var dslrPreviewDevice: CameraDeviceInfo? {
        coordinator.capture.camera.availableDevices.first {
            $0.id == coordinator.capture.camera.selectedDeviceID && $0.kind != .builtIn
        }
    }

    var dslrPTPPreviewOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.65))
            Text(coordinator.capture.dslr.isRunning ? "Sony PTP Control Active" : "Sony PTP Standby")
                .font(.headline)
                .foregroundStyle(.white)
            Text(coordinator.capture.dslr.isRunning
                 ? "Waiting for the camera's Sony PTP live-view stream…"
                 : "Connect the camera to start Sony PTP live view.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
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

    var connectionColor: Color {
        switch coordinator.multipeer.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .red
        }
    }

    var connectionLabel: String {
        switch coordinator.multipeer.connectionState {
        case .connected(let name): return "iPad connected: \(name)"
        case .connecting:          return "Connecting to iPad…"
        case .disconnected:        return "iPad not connected"
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
                    Text(kind.rawValue).tag(kind)
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
                    Label(coordinator.capture.dslr.isCapturing ? "Capturing..." : "Test Capture",
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
                    ForEach(DSLRFlashMode.allCases) { m in Text(m.rawValue).tag(m) }
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
                Text("\(event.photoCount) photos · \(event.countdownSeconds)s countdown")
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
            Text(sm.phase.displayName)
                .font(.headline).foregroundStyle(phaseColor)
            if case .countdown(_, let secs) = sm.phase {
                ProgressView(value: Double(secs),
                             total: Double(sm.config.countdownSeconds))
                    .tint(.orange)
            }
        }
    }

    var phaseColor: Color {
        switch sm.phase {
        case .idle, .readyToStart:  return .primary
        case .countdown:            return .orange
        case .captured:             return .blue
        case .review:               return .purple
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
                      || (coordinator.cameraSourceKind == .dslr && !coordinator.capture.dslr.isRunning)
                      || !iPadConnected)
            .help(coordinator.activeEvent == nil ? "Select an active event first" :
                  !coordinator.cameraPermissionGranted ? "Camera permission required" :
                  (coordinator.cameraSourceKind == .dslr && !coordinator.capture.dslr.isRunning) ? "Connect DSLR camera first" :
                  !iPadConnected ? "iPad not connected" : "")

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

    private func overrideBtn(_ label: String, icon: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
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
