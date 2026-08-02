import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import SwiftData
import Observation
import AVFoundation

enum CameraSourceKind: String, CaseIterable, Identifiable {
    case avFoundation = "Built-in / USB / Continuity"
    case dslr         = "DSLR / Mirrorless (USB Tethered)"
    var id: String { rawValue }
}

// Which channel carries the live preview stream to the iPad.
// Control messages (session state, countdown, etc.) always go over MultipeerConnectivity —
// only the high-bandwidth preview frames move between Wi-Fi (MPC) and USB cable.
enum PreviewConnectionMode: String, CaseIterable, Identifiable {
    case wireless = "Wireless (Wi-Fi)"
    case cable    = "Cable (USB)"
    var id: String { rawValue }
}

enum PreviewFrameRate: Int, CaseIterable, Identifiable {
    case standard = 30
    case maximum = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }
}

enum SelphyPaperSize: String, CaseIterable {
    case postcard   = "Postcard (4×6\")"
    case lSize      = "L-size (3.5×5\")"
    case creditCard = "Credit Card"

    var pointSize: NSSize {
        switch self {
        case .postcard:    return NSSize(width: 288, height: 432) // 4×6 in at 72 pt/in
        case .lSize:       return NSSize(width: 252, height: 360)
        case .creditCard:  return NSSize(width: 153, height: 244)
        }
    }
}

@MainActor
@Observable
final class BoothCoordinator {
    let multipeer: MultipeerService
    let capture: CaptureService
    let stateMachine: SessionStateMachine
    let server: LocalWebServer
    let store: DataStore
    let cloudSSHSetup: CloudSSHSetupService
    let usbPreview = USBPreviewServer()

    var activeEvent: BoothEvent? {
        didSet { capture.captureRotationDegrees = activeEvent?.cameraRotationDegrees ?? 0 }
    }
    var errorMessage: String?
    var serverURL: String = ""
    var cameraSourceKind: CameraSourceKind = .avFoundation {
        didSet {
            if cameraSourceKind == .avFoundation {
                capture.usesDSLR = false
            }
        }
    }
    var cameraPermissionGranted: Bool = false
    var previewConnectionMode: PreviewConnectionMode {
        get { PreviewConnectionMode(rawValue: UserDefaults.standard.string(forKey: "previewConnectionMode") ?? "") ?? .wireless }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "previewConnectionMode") }
    }
    var previewFrameRate: PreviewFrameRate {
        get { PreviewFrameRate(rawValue: UserDefaults.standard.integer(forKey: "previewFrameRate")) ?? .standard }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "previewFrameRate")
            capture.setPreviewFrameRate(newValue.rawValue)
        }
    }

    private var currentSession: BoothSession?
    private var gifFrames: [Int: [CGImage]] = [:]
    private var countdownTask: Task<Void, Never>?
    var currentStripPreview: CGImage?

    // MARK: - External display viewer
    private(set) var externalScreens: [NSScreen] = []
    private var externalDisplayWindow: NSWindow?
    var isExternalViewerActive: Bool { externalDisplayWindow != nil }

    init() {
        multipeer = MultipeerService(role: .mac)
        capture = CaptureService()
        stateMachine = SessionStateMachine()
        server = LocalWebServer(port: 8585)
        store = DataStore.shared
        cloudSSHSetup = CloudSSHSetupService()
        capture.dslr.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.errorMessage = "DSLR: \(err.localizedDescription)" }
        }
        capture.dslr.onConnectionStateChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.handleDSLRConnectionStateChanged() }
        }

        Task { @MainActor [self] in
            usbPreview.start()
            await checkCameraPermission()
            if cameraPermissionGranted { startCamera() }
            if let ip = LocalWebServer.lanIPAddress() {
                serverURL = "http://\(ip):8585"
            }
            try? await server.start()
            if let dir = picturesOutputDir() { await server.setSessDir(dir) }
            activeEvent = store.fetchActiveEvent()
            cleanupOldSessions(keepDays: 60)
        }

        setupMultipeerHandlers()

        refreshExternalScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshExternalScreens() }
        }
    }

    // MARK: - External display viewer

    func refreshExternalScreens() {
        externalScreens = NSScreen.screens.filter { $0 != NSScreen.main }
        if let window = externalDisplayWindow,
           let screen = window.screen,
           !NSScreen.screens.contains(screen) {
            hideExternalViewer()
        }
    }

    func showExternalViewer(on screen: NSScreen) {
        hideExternalViewer()
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: ExternalDisplayView()
            .environment(self)
            .environment(stateMachine))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        externalDisplayWindow = window
    }

    func hideExternalViewer() {
        externalDisplayWindow?.close()
        externalDisplayWindow = nil
    }

    // MARK: - Camera permission (M10)

    func checkCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermissionGranted = true
        case .notDetermined:
            cameraPermissionGranted = await AVCaptureDevice.requestAccess(for: .video)
            if cameraPermissionGranted { startCamera() }
        default:
            cameraPermissionGranted = false
        }
    }

    func startCamera() {
        do {
            capture.setPreviewFrameRate(previewFrameRate.rawValue)
            try capture.start()
            capture.onPreviewJPEG = { [weak self] jpeg in
                guard let self else { return }
                switch previewConnectionMode {
                case .wireless: multipeer.sendPreviewFrame(jpeg)
                case .cable:    usbPreview.send(jpeg)
                }
            }
        } catch {
            errorMessage = "Camera error: \(error.localizedDescription)"
        }
    }

    func setMirrored(_ isMirrored: Bool) {
        capture.camera.isMirrored = isMirrored
        multipeer.sendControl(.setMirrored(isMirrored: isMirrored))
    }

    func connectDSLR() {
        cameraSourceKind = .dslr
        capture.usesDSLR = false
        choosePreviewDeviceForDSLR()
        Task { @MainActor [weak self] in
            // External camera enumeration can lag behind USB session open; retry briefly.
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(500))
                self?.choosePreviewDeviceForDSLR()
                if let self,
                   self.capture.camera.availableDevices.contains(where: {
                       $0.id == self.capture.camera.selectedDeviceID && $0.kind != .builtIn
                   }) {
                    break
                }
            }
        }
        do {
            try capture.startDSLR()
        } catch {
            errorMessage = "DSLR connect failed: \(error.localizedDescription)"
            capture.usesDSLR = false
            cameraSourceKind = .avFoundation
        }
    }

    func disconnectDSLR() {
        capture.stopDSLR()
        capture.usesDSLR = false
        cameraSourceKind = .avFoundation
    }

    func testCameraCapture() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await capture.captureDiagnosticStill()
                errorMessage = nil
            } catch {
                errorMessage = "Test capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func handleDSLRConnectionStateChanged() {
        if capture.dslr.isRunning {
            if cameraSourceKind == .dslr { capture.usesDSLR = true }
            choosePreviewDeviceForDSLR()
            return
        }
        capture.usesDSLR = false
        if cameraSourceKind == .dslr && !capture.dslr.isConnecting {
            cameraSourceKind = .avFoundation
        }
    }

    private func choosePreviewDeviceForDSLR() {
        let preferredName = capture.dslr.selectedDeviceName?.lowercased()
        let candidates = capture.camera.availableDevices.filter { $0.kind != .builtIn }
        guard !candidates.isEmpty else { return }

        if let preferredName,
           let exact = candidates.first(where: { $0.name.lowercased().contains(preferredName) }) {
            capture.camera.selectedDeviceID = exact.id
            return
        }

        if let sony = candidates.first(where: { $0.name.lowercased().contains("sony") }) {
            capture.camera.selectedDeviceID = sony.id
            return
        }

        if capture.camera.selectedDeviceID == nil || !candidates.contains(where: { $0.id == capture.camera.selectedDeviceID }) {
            capture.camera.selectedDeviceID = candidates[0].id
        }
    }

    // MARK: - Session control

    func startSession() {
        guard let event = activeEvent else { return }
        let config = event.toEventConfig()
        stateMachine.startSession(config: config)
        currentSession = store.startSession(for: event)
        gifFrames = [:]
        capture.resetStills()
        multipeer.sendControl(.sessionStart)
        multipeer.sendControl(.eventConfig(config: config))
        beginCountdown(photoIndex: 0)
    }

    func beginCountdown(photoIndex: Int) {
        stateMachine.beginCountdown(photoIndex: photoIndex)
        multipeer.sendControl(.beginCountdown(photoIndex: photoIndex, seconds: stateMachine.config.countdownSeconds))
        runCountdown(photoIndex: photoIndex, seconds: stateMachine.config.countdownSeconds)
    }

    private func runCountdown(photoIndex: Int, seconds: Int) {
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: seconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                stateMachine.transition(to: .countdown(photoIndex: photoIndex, secondsRemaining: remaining))
                try? await Task.sleep(for: .seconds(1))
            }
            if !Task.isCancelled { await captureShot(photoIndex: photoIndex) }
        }
    }

    private func captureShot(photoIndex: Int) async {
        do {
            gifFrames[photoIndex] = capture.drainBufferForGIF()
            let image = try await capture.captureStill(for: photoIndex)
            let thumbData = capture.thumbnail(for: image) ?? Data()
            stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: thumbData)
            multipeer.sendControl(.shotCaptured(index: photoIndex, thumbnailData: thumbData))
            updateStripPreview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateStripPreview() {
        guard let event = activeEvent else { return }
        let config = event.toEventConfig()
        let frameURL = event.framePNGPath.flatMap { appSupportDir()?.appendingPathComponent($0) }
        let framePNG = frameURL.flatMap { loadCGImage(from: $0) }
        let images = capture.capturedStills
        let compositor = Compositor(config: config, framePNG: framePNG)
        Task.detached(priority: .utility) { [compositor, images] in
            let img = try? compositor.render(images: images)
            await MainActor.run { [weak self] in self?.currentStripPreview = img }
        }
    }

    func handleReviewDecision(photoIndex: Int, action: ReviewAction) {
        multipeer.sendControl(.reviewDecision(action: action))
        switch action {
        case .keep:
            stateMachine.keepShot(photoIndex: photoIndex)
            if case .processing = stateMachine.phase {
                Task { await finalizeSession() }
            } else if case .countdown(let next, _) = stateMachine.phase {
                beginCountdown(photoIndex: next)
            }
        case .retake:
            stateMachine.retakeShot(photoIndex: photoIndex)
            beginCountdown(photoIndex: photoIndex)
        }
    }

    func operatorOverride(_ action: OperatorAction) {
        let prevPhase = stateMachine.phase
        stateMachine.operatorOverride(action)
        multipeer.sendControl(.operatorOverride(action: action))
        switch action {
        case .forceStart:
            if prevPhase == .idle || prevPhase == .readyToStart { startSession() }
        case .forceRetake:
            if case .review(let idx) = prevPhase { beginCountdown(photoIndex: idx) }
        case .skip:
            if case .review(let idx) = prevPhase { handleReviewDecision(photoIndex: idx, action: .keep) }
        case .cancelSession:
            countdownTask?.cancel()
            currentSession = nil
        }
    }

    // MARK: - Finalize session

    private func finalizeSession() async {
        guard let event = activeEvent, let session = currentSession else { return }
        let config = event.toEventConfig()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        let relPath = "\(safeFolderName(event.name))/\(fmt.string(from: session.startedAt))"
        guard let sessDir = picturesOutputDir()?.appendingPathComponent(relPath) else { return }
        try? FileManager.default.createDirectory(at: sessDir, withIntermediateDirectories: true)

        // Composite strip
        let frameURL = event.framePNGPath.flatMap { appSupportDir()?.appendingPathComponent($0) }
        let framePNG = frameURL.flatMap { loadCGImage(from: $0) }
        let compositor = Compositor(config: config, framePNG: framePNG)
        let images = capture.capturedStills
        var stripPath: String? = nil
        var gifPath: String? = nil

        if let img = try? compositor.render(images: images) {
            let url = sessDir.appendingPathComponent("strip.png")
            try? compositor.savePNG(img, to: url)
            stripPath = "\(relPath)/strip.png"
            currentStripPreview = img
        }

        // GIF
        let allFrames = (0..<config.photoCount).flatMap { gifFrames[$0] ?? [] }
        if !allFrames.isEmpty {
            let url = sessDir.appendingPathComponent("booth.gif")
            try? GIFEncoder().encode(frames: allFrames, to: url)
            gifPath = "\(relPath)/booth.gif"
        }

        // Persist stills
        for (idx, image) in images {
            let url = sessDir.appendingPathComponent("shot_\(idx).jpg")
            if let data = jpegData(from: image, quality: 0.9) { try? data.write(to: url) }
            _ = store.recordShot(session: session, photoIndex: idx,
                                 imagePath: "shot_\(idx).jpg", retakeCount: 0)
        }

        let token = session.downloadToken
        await server.registerToken(token, sessionID: relPath)
        store.finishSession(session, stripPath: stripPath, gifPath: gifPath)

        // Async backup to server — fire and forget
        if UserDefaults.standard.bool(forKey: "cloudUploadEnabled") {
            let syncDir = sessDir; let syncRel = relPath; let syncToken = token
            Task.detached(priority: .background) {
                syncBoothSession(localDir: syncDir, relPath: syncRel, token: syncToken)
            }
        }

        let ip = LocalWebServer.lanIPAddress() ?? "localhost"
        let stored = (UserDefaults.standard.string(forKey: "publicBaseURL") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        // The trailing slash prevents nginx from issuing an absolute redirect that
        // exposes its internal tunnel port to guests scanning a public QR code.
        let qr = stored.isEmpty ? "http://\(ip):8585/s/\(token)/" : "\(stored)/s/\(token)/"

        let stripThumb: Data? = stripPath.flatMap { path in
            picturesOutputDir().flatMap { loadCGImage(from: $0.appendingPathComponent(path)) }
                               .flatMap { jpegData(from: $0, quality: 0.4) }
        }

        stateMachine.finishSession(qrPayload: qr)
        multipeer.sendControl(.sessionFinished(qrPayload: qr, stripThumbData: stripThumb, gifThumbData: nil))
        currentSession = nil
    }

    // MARK: - Session cleanup (M10)

    private func cleanupOldSessions(keepDays: Int) {
        guard let picsDir = picturesOutputDir() else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date())!
        let old = store.fetchSessions(finishedBefore: cutoff)
        for session in old {
            if let sp = session.stripPath {
                let dir = picsDir.appendingPathComponent(sp).deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir)
            }
            store.context.delete(session)
        }
        try? store.context.save()
    }

    // MARK: - Print

    func printCurrentStrip() {
        guard let cg = currentStripPreview else { return }
        let ud = UserDefaults.standard
        let raw = ud.string(forKey: "selphyPaperSize") ?? SelphyPaperSize.postcard.rawValue
        let paper = SelphyPaperSize(rawValue: raw) ?? .postcard
        let ptSize = paper.pointSize

        let nsImg = NSImage(cgImage: cg, size: .zero)
        let iv = NSImageView(frame: NSRect(origin: .zero, size: ptSize))
        iv.image = nsImg
        iv.imageScaling = .scaleProportionallyUpOrDown

        let pi = NSPrintInfo.shared.copy() as! NSPrintInfo
        pi.paperSize = ptSize
        pi.orientation = .portrait
        pi.topMargin = 0; pi.bottomMargin = 0; pi.leftMargin = 0; pi.rightMargin = 0
        pi.isHorizontallyCentered = true; pi.isVerticallyCentered = true

        let skipDialog = ud.bool(forKey: "selphySkipPrintDialog")
        if skipDialog {
            let copies = max(1, ud.integer(forKey: "selphyCopies"))
            pi.dictionary().setValue(copies, forKey: "NSCopies")
        }

        let op = NSPrintOperation(view: iv, printInfo: pi)
        op.showsPrintPanel = !skipDialog
        op.showsProgressPanel = true
        op.run()
    }

    // MARK: - Multipeer handlers

    private func setupMultipeerHandlers() {
        multipeer.onControlMessage = { [weak self] msg in
            self?.handleMessage(msg)
        }
    }

    private func handleMessage(_ msg: Message) {
        switch msg {
        case .hello(let role) where role == .iPad:
            if let event = activeEvent {
                multipeer.sendControl(.eventConfig(config: event.toEventConfig()))
            }
            resynciPad()
        case .setPreviewTransport(let transport):
            previewConnectionMode = transport == .usb ? .cable : .wireless
        case .sessionStart:
            if stateMachine.phase == .idle, activeEvent != nil {
                startSession()
            }
        case .reviewDecision(let action):
            if case .review(let idx) = stateMachine.phase {
                handleReviewDecision(photoIndex: idx, action: action)
            }
        default: break
        }
    }

    // Push current Mac state to iPad after (re)connect so it's never stuck at idle mid-session.
    private func resynciPad() {
        multipeer.sendControl(.setMirrored(isMirrored: capture.camera.isMirrored))
        switch stateMachine.phase {
        case .idle, .readyToStart:
            break
        case .countdown(let idx, let secs):
            multipeer.sendControl(.sessionStart)
            multipeer.sendControl(.eventConfig(config: stateMachine.config))
            multipeer.sendControl(.beginCountdown(photoIndex: idx, seconds: secs))
        case .captured(let idx), .review(let idx):
            if let thumb = stateMachine.keptShots[idx] {
                multipeer.sendControl(.sessionStart)
                multipeer.sendControl(.eventConfig(config: stateMachine.config))
                multipeer.sendControl(.shotCaptured(index: idx, thumbnailData: thumb))
            }
        case .processing:
            multipeer.sendControl(.sessionStart)
            multipeer.sendControl(.eventConfig(config: stateMachine.config))
        case .finished(let qr):
            multipeer.sendControl(.sessionFinished(qrPayload: qr, stripThumbData: nil, gifThumbData: nil))
        }
    }

    // MARK: - Directories

    func appSupportDir() -> URL? {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PRC-PhotoBooth")
        if let d { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return d
    }

    func picturesOutputDir() -> URL? {
        let d = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PRC-PhotoBooth")
        if let d { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return d
    }

    private func safeFolderName(_ s: String) -> String {
        let safe = s.components(separatedBy: CharacterSet(charactersIn: "/:\\*?\"<>|"))
                    .joined(separator: "-")
                    .trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? "Event" : safe
    }
}

extension LocalWebServer {
    func setSessDir(_ url: URL) { self.sessionsDirectory = url }
}

// MARK: - Server backup sync

private func syncBoothSession(localDir: URL, relPath: String, token: String) {
    let ud       = UserDefaults.standard
    let host     = ud.string(forKey: "cloudSSHHost")     ?? "homelab"
    let basePath = (ud.string(forKey: "cloudRemotePath") ?? "/bk1/prc/photobooth")
                       .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let remote   = "/\(basePath)/\(relPath)"
    let sDir     = "/\(basePath)/s"

    let html = boothDownloadPageHTML(token: token)
    try? html.data(using: .utf8)?.write(to: localDir.appendingPathComponent("index.html"))

    @discardableResult
    func run(_ label: String, _ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        // cloudflared lives in /opt/homebrew/bin; Process() doesn't inherit the user's PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let output = Pipe()
        p.standardOutput = output
        p.standardError = output
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("[Cloud Upload] \(label) could not start: \(error.localizedDescription)")
            return false
        }

        guard p.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8) ?? ""
            NSLog("[Cloud Upload] \(label) failed (exit \(p.terminationStatus)): \(details)")
            return false
        }
        return true
    }

    // ssh reads ~/.ssh/config → ProxyCommand cloudflared access ssh --hostname ssh.nakrub.me
    guard run("create remote directories", "/usr/bin/ssh", [host, "mkdir -p \(shellQuoted(remote)) \(shellQuoted(sDir))"]) else { return }

    // rsync passes the destination through the remote shell. Escape it here so
    // event folder names such as "New Event" reach their intended directory.
    let destination = "\(host):\(rsyncRemoteEscapedPath(remote))/"
    guard run("upload session", "/usr/bin/rsync", ["-az", "-e", "ssh", localDir.path + "/", destination]) else { return }

    _ = run("publish download link", "/usr/bin/ssh", [host, "ln -sfn \(shellQuoted(remote)) \(shellQuoted("\(sDir)/\(token)"))"])
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func rsyncRemoteEscapedPath(_ path: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
    return path.unicodeScalars.map { scalar in
        safe.contains(scalar) ? String(scalar) : "\\" + String(scalar)
    }.joined()
}

private func boothDownloadPageHTML(token: String) -> String {
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>PRC Photo Booth — Your Photos</title>
    <style>
    body{font-family:-apple-system,sans-serif;background:#111;color:#eee;text-align:center;padding:2rem;margin:0}
    h1{font-size:1.5rem;margin-bottom:.25rem}p{color:#aaa;font-size:.9rem;margin-bottom:2rem}
    img{max-width:90vw;max-height:70vh;border-radius:8px;display:block;margin:0 auto 1.5rem}
    a.btn{display:inline-block;background:#fff;color:#111;padding:.75rem 2rem;border-radius:8px;text-decoration:none;font-weight:600;margin:.5rem}
    a.btn.secondary{background:#333;color:#eee}
    </style>
    </head>
    <body>
    <h1>✨ Your Photo Strip</h1>
    <p>Tap a button to save your memories!</p>
    <img src="/s/\(token)/strip.png" alt="Photo Strip">
    <br>
    <a class="btn" href="/s/\(token)/strip.png" download="photobooth-strip.png">⬇ Save Strip</a>
    <a class="btn secondary" href="/s/\(token)/booth.gif" download="photobooth.gif">⬇ Save GIF</a>
    </body>
    </html>
    """
}
