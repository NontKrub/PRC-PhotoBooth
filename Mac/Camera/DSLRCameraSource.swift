import ImageCaptureCore
import CoreGraphics
import CoreImage
import Observation
import AVFoundation

// MARK: - Settings types

struct DSLRShutterSpeed: Identifiable, Hashable {
    let label: String
    let reciprocal: Int   // denominator of 1/N seconds
    var id: String { label }

    static let presets: [DSLRShutterSpeed] = [
        .init(label: "1/30",   reciprocal: 30),
        .init(label: "1/60",   reciprocal: 60),
        .init(label: "1/100",  reciprocal: 100),
        .init(label: "1/125",  reciprocal: 125),
        .init(label: "1/160",  reciprocal: 160),
        .init(label: "1/200",  reciprocal: 200),
        .init(label: "1/250",  reciprocal: 250),
        .init(label: "1/320",  reciprocal: 320),
        .init(label: "1/500",  reciprocal: 500),
        .init(label: "1/1000", reciprocal: 1000),
    ]
}

struct DSLRAperture: Identifiable, Hashable {
    let label: String
    var id: String { label }

    static let presets: [DSLRAperture] = [
        .init(label: "f/1.4"), .init(label: "f/1.8"), .init(label: "f/2"),
        .init(label: "f/2.8"), .init(label: "f/4"),   .init(label: "f/5.6"),
        .init(label: "f/8"),   .init(label: "f/11"),  .init(label: "f/16"),
    ]
}

enum DSLRFlashMode: String, CaseIterable, Identifiable {
    case off  = "Off"
    case auto = "Auto"
    case fill = "Fill Flash"
    var id: String { rawValue }
    // MTP/PTP FlashMode (0x500C): 1 = Auto, 2 = Off, 3 = Fill (forced)
    var ptpValue: UInt16 { switch self { case .off: 2; case .auto: 1; case .fill: 3 } }
}

let DSLRISOPresets = [100, 200, 400, 800, 1600, 3200, 6400]

struct DSLRControlSupport: Sendable {
    var iso = true
    var flash = true
    var shutter = false
    var aperture = false
}

// MARK: - DSLRCameraSource

@MainActor
@Observable
final class DSLRCameraSource: NSObject, CameraSource {
    enum SonyCaptureBufferAction: Equatable {
        case wait
        case discardStale
        case downloadCurrent
    }

    private typealias PTPReply = DSLRCameraPTPReply

    private enum PTPCommandPriority: Int {
        case normal
        case liveView
        case capture
    }

    private struct PTPSessionClose {
        let cameraIdentity: ObjectIdentifier
        let generation: UInt64
    }

    nonisolated static func ptpUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated static func ptpUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    nonisolated static func previewSleepInterval(
        targetFramesPerSecond: Int,
        elapsed: TimeInterval
    ) -> TimeInterval {
        guard targetFramesPerSecond > 0 else { return 0 }
        return max(0, (1.0 / Double(targetFramesPerSecond)) - max(0, elapsed))
    }

    nonisolated static func ptpResponseCode(from response: Data) -> UInt16 {
        ptpUInt16(response, at: 6) ?? 0
    }

    nonisolated static func newestPTPObjectHandle(from data: Data) -> UInt32? {
        guard let count = ptpUInt32(data, at: 0), count > 0 else { return nil }
        let requiredLength = 4 + Int(count) * 4
        guard data.count >= requiredLength else { return nil }
        return ptpUInt32(data, at: requiredLength - 4)
    }

    nonisolated static func parsePTPObjectHandles(from data: Data) -> Set<UInt32> {
        guard let count = ptpUInt32(data, at: 0), count > 0 else { return [] }
        var handles = Set<UInt32>()
        let availableCount = min(Int(count), (data.count - 4) / 4)
        for i in 0..<availableCount {
            if let handle = ptpUInt32(data, at: 4 + i * 4) {
                handles.insert(handle)
            }
        }
        return handles
    }

    nonisolated static func makePTPCommand(
        opcode: UInt16,
        transactionID: UInt32,
        parameters: [UInt32] = []
    ) -> Data {
        let length = 12 + parameters.count * 4
        var command = Data(count: length)
        command.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt32(length).littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4, as: UInt16.self)
            bytes.storeBytes(of: opcode.littleEndian, toByteOffset: 6, as: UInt16.self)
            bytes.storeBytes(of: transactionID.littleEndian, toByteOffset: 8, as: UInt32.self)
            for (index, parameter) in parameters.enumerated() {
                bytes.storeBytes(of: parameter.littleEndian, toByteOffset: 12 + index * 4, as: UInt32.self)
            }
        }
        return command
    }

    // ImageCaptureCore calls this completion on its own XPC queue. Keep it
    // nonisolated and free of actor state; callers resume on MainActor.
    nonisolated private static func sendPTPCommand(
        _ camera: ICCameraDevice,
        command: Data,
        outData: Data?,
        completion: @escaping @Sendable (PTPReply) -> Void
    ) {
        camera.requestSendPTPCommand(command, outData: outData) { data, response, error in
            completion(PTPReply(
                data: data,
                responseCode: ptpResponseCode(from: response),
                errorDescription: error?.localizedDescription
            ))
        }
    }

    private func executePTPCommand(
        _ camera: ICCameraDevice,
        command: Data,
        outData: Data? = nil,
        priority: PTPCommandPriority = .normal,
        captureScope: DSLRCaptureAttemptScope? = nil,
        beforeSend: (@MainActor () -> Bool)? = nil
    ) async -> PTPReply {
        guard !ptpCommandLane.isQuarantined else {
            return PTPReply(data: Data(), responseCode: 0, errorDescription: "Camera PTP lane is quarantined until the in-flight command finishes or the session closes")
        }
        let activeScope = captureScope ?? (priority == .capture ? activeCaptureScope : nil)
        let scope = DSLRCameraPTPScope(
            attemptID: activeScope?.attemptID,
            cameraGeneration: activeScope?.cameraGeneration ?? cameraGeneration
        )
        let result = await ptpCommandLane.execute(
            scope: scope,
            priority: priority.rawValue,
            timeout: .seconds(10),
            isCurrent: { [weak self] scope in
                guard let self,
                      self.connectedCamera === camera,
                      self.cameraGeneration == scope.cameraGeneration else { return false }
                guard let attemptID = scope.attemptID else { return true }
                guard let attempt = self.activeCaptureScope,
                      attempt.attemptID == attemptID,
                      attempt.cameraGeneration == scope.cameraGeneration,
                      let control = self.activeCaptureControl else { return false }
                return control.canContinue(attempt)
            },
            beforeSend: beforeSend,
            onNotSent: {
                guard let attemptID = scope.attemptID,
                      let control = self.activeCaptureControl else { return }
                control.confirmShutterWasNotDispatched(DSLRCaptureAttemptScope(
                    attemptID: attemptID,
                    cameraGeneration: scope.cameraGeneration
                ))
            },
            send: { ticket, completion in
                guard self.connectedCamera === camera,
                      self.cameraGeneration == ticket.scope.cameraGeneration else {
                    completion(PTPReply(
                        data: Data(),
                        responseCode: 0,
                        errorDescription: "Camera disconnected"
                    ))
                    return
                }
                let dispatch = {
                    Self.sendPTPCommand(camera, command: command, outData: outData, completion: completion)
                }
                guard let attemptID = ticket.scope.attemptID else {
                    dispatch()
                    return
                }
                let attemptScope = DSLRCaptureAttemptScope(
                    attemptID: attemptID,
                    cameraGeneration: ticket.scope.cameraGeneration
                )
                guard let control = self.activeCaptureControl else {
                    completion(PTPReply(data: Data(), responseCode: 0, errorDescription: "PTP command cancelled"))
                    return
                }
                guard control.performIfCurrent(attemptScope, action: dispatch) else {
                    if beforeSend != nil {
                        // `beforeSend` marks the Sony shutter as possibly issued.
                        // Clear that uncertainty only when the final dispatch gate
                        // proves the physical request was never enqueued.
                        control.confirmShutterWasNotDispatched(attemptScope)
                    }
                    completion(PTPReply(data: Data(), responseCode: 0, errorDescription: "PTP command cancelled"))
                    return
                }
            }
        )
        switch result {
        case .success(let reply):
            return reply
        case .failure(let failure):
            let message: String
            switch failure {
            case .cancelled: message = "PTP command cancelled"
            case .timedOut: message = "PTP command timed out after 10 seconds"
            case .disconnected: message = "Camera disconnected"
            }
            return PTPReply(data: Data(), responseCode: 0, errorDescription: message)
        }
    }

    private func nextPTPTransactionID() -> UInt32 {
        let transactionID = ptpTxID
        ptpTxID &+= 1
        return transactionID
    }

    private let browser = ICDeviceBrowser()
    private var camerasByID: [String: ICCameraDevice] = [:]
    private var connectedCamera: ICCameraDevice?
    // Set before requestTakePicture; resolved after download completes
    private var captureCompletion: CheckedContinuation<CGImage, Error>?
    private var activeCaptureAttemptID: UUID?
    private var activeCaptureScope: DSLRCaptureAttemptScope?
    private var activeCaptureControl: DSLRCaptureAttemptControl?
    private var cameraGeneration: UInt64 = 0
    private var pendingPTPSessionCloses: [PTPSessionClose] = []
    private var expectingCapture = false
    private var captureAttemptContexts = DSLRCaptureAttemptContextStore()
    private var shutterCommandGeneration: UInt64 = 0
    private var captureAttemptContext: DSLRCaptureAttemptContext? {
        captureAttemptContexts.active
    }
    private var pendingDownloadAttemptID: UUID?
    private var pendingDownloadGeneration: UInt64?
    private var pendingDownloadContextID: Int?
    private var nextDownloadContextID = 1
    private var pendingDownloadFile: ICCameraFile?
    private var pendingDownloadCandidate: CaptureMediaCandidate?
    private var pendingDownloadURL: URL?
    private var captureTimeoutTask: Task<Void, Never>?
    private var capturePreparationTask: Task<Void, Never>?
    private var pendingCapturePollTask: Task<Void, Never>?
    private enum AttemptTerminalResult {
        case success(CGImage)
        case failure(Error)
    }
    private var ptpTxID: UInt32 = 1
    private let ptpCommandLane = DSLRCameraPTPCommandLane()
    private var pollTask: Task<Void, Never>?    // continuous GetAllDevicePropDesc heartbeat
    private var reopenAfterClose = false
    private var ptpHealthy = false
    private var fallbackTakePictureIssued = false
    private var busyRejection = false   // Sony shutter control returned DeviceBusy (0x201D)
    private var suppressStatusPoll = false
    private var isDrainingPCBuffer = false
    private var liveViewTask: Task<Void, Never>?
    private var isRequestingLiveViewFrame = false
    private var isLiveViewLoopRunning: Bool { liveViewTask != nil }
    private var liveViewFailureCount = 0
    private var previewFramesPerSecond = 30
    private var measuredPreviewWindowStartedAt = Date()
    private var measuredPreviewFrameCount = 0
    private(set) var measuredPreviewFPS: Double?
    private var previewPTPRequestCount = 0
    private var previewPTPRequestDurationTotal: TimeInterval = 0
    private var previewFramesEmitted = 0
    private var previewMetricsWindowStartedAt = Date()
    private(set) var averagePreviewPTPRequestDuration: TimeInterval?
    private(set) var previewTemporaryFailureCount = 0
    private var lastStatusPollAt = Date.distantPast
    private(set) var isCapturing = false

    // Observable settings — sent to camera via PTP on applySettings()
    var iso: Int = 400
    var shutterSpeed: DSLRShutterSpeed = DSLRShutterSpeed.presets[3]   // 1/125
    var aperture: DSLRAperture = DSLRAperture.presets[5]               // f/5.6
    var flashMode: DSLRFlashMode = .off
    /// Lets the camera's AUTO or P exposure program choose ISO, shutter speed, and aperture.
    /// This is the recommended mode for the Sony ZV-E10.
    var automaticPictureMode = true

    // CameraSource
    private(set) var isRunning = false
    private(set) var isConnecting = false      // true between requestOpenSession and didOpenSession
    private(set) var availableDevices: [CameraDeviceInfo] = []
    private(set) var controlSupport = DSLRControlSupport()
    private(set) var lastCapturedImage: CGImage?
    private(set) var latestPreviewImage: CGImage?
    private(set) var isLivePreviewActive = false
    // Sony live view arrives as JPEG objects rather than AVFoundation sample
    // buffers. Keep its own rolling history so GIF capture works for a DSLR too.
    let rollingBuffer = RollingVideoBuffer(windowSeconds: 8, maxFPS: 15)
    var selectedDeviceID: String? {
        didSet {
            if oldValue != selectedDeviceID {
                captureAttemptContexts.invalidate()
            }
        }
    }
    var selectedDeviceName: String? {
        guard let selectedDeviceID else { return nil }
        return availableDevices.first(where: { $0.id == selectedDeviceID })?.name
    }
    var isSonyZVE10: Bool {
        selectedDeviceName?.localizedCaseInsensitiveContains("ZV-E10") == true
    }
    var isPTPHealthy: Bool { ptpHealthy }
    var onPreviewFrame: ((CVPixelBuffer) -> Void)?
    var onPreviewJPEG: ((Data) -> Void)?
    var onError: ((Error) -> Void)?
    var onConnectionStateChanged: (() -> Void)?

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
        browser.start()
    }

    func start() throws {
        guard let id = selectedDeviceID, let cam = camerasByID[id] else {
            throw DSLRError.noCamera
        }
        cameraGeneration &+= 1
        captureAttemptContexts.invalidate()
        connectedCamera = cam
        cam.delegate = self
        isConnecting = true
        onConnectionStateChanged?()
        cam.requestOpenSession()
        // isRunning / isConnecting are set in device(_:didOpenSessionWithError:)
    }

    func stop() {
        let closingGeneration = cameraGeneration
        if let scope = activeCaptureScope {
            finishCaptureAttempt(
                scope: scope,
                result: .failure(DSLRError.cameraDisconnected)
            )
        }
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        pendingCapturePollTask?.cancel()
        pendingCapturePollTask = nil
        stopSonyLiveView()
        pollTask?.cancel()
        pollTask = nil
        if let camera = connectedCamera {
            pendingPTPSessionCloses.append(PTPSessionClose(
                cameraIdentity: ObjectIdentifier(camera),
                generation: closingGeneration
            ))
            camera.requestCloseSession()
        }
        connectedCamera = nil
        cameraGeneration &+= 1
        ptpCommandLane.cancel(cameraGeneration: closingGeneration)
        isRunning = false
        isConnecting = false
        ptpHealthy = false
        captureAttemptContexts.invalidate()
        expectingCapture = false
        isCapturing = false
        resetPreviewMetrics()
        controlSupport = DSLRControlSupport()
        onConnectionStateChanged?()
    }

    func invalidateCaptureRecovery() {
        captureAttemptContexts.invalidate()
    }

    private func stableCameraIdentifier(for camera: ICCameraDevice) -> String? {
        if let uuid = camera.uuidString?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty {
            return "uuid:\(uuid)"
        }
        return nil
    }

    private func isAuthorizedCaptureCandidate(
        _ candidate: CaptureMediaCandidate,
        from camera: ICCameraDevice,
        attemptID: UUID
    ) -> Bool {
        guard connectedCamera === camera,
              activeCaptureAttemptID == attemptID,
              let scope = activeCaptureScope,
              scope.attemptID == attemptID,
              scope.cameraGeneration == cameraGeneration,
              let control = activeCaptureControl,
              control.canContinue(scope),
              let context = captureAttemptContext,
              let cameraIdentifier = stableCameraIdentifier(for: camera) else { return false }
        return DSLRCaptureAttemptValidator.authorizes(
            candidate,
            context: context,
            cameraIdentifier: cameraIdentifier
        )
    }

    private func isCurrentCapture(_ scope: DSLRCaptureAttemptScope, camera: ICCameraDevice) -> Bool {
        guard activeCaptureScope == scope,
              activeCaptureAttemptID == scope.attemptID,
              cameraGeneration == scope.cameraGeneration,
              connectedCamera === camera,
              let control = activeCaptureControl else { return false }
        return control.canContinue(scope)
    }

    @discardableResult
    private func recordShutterIssued(at date: Date = Date(), scope: DSLRCaptureAttemptScope) -> Bool {
        guard activeCaptureScope == scope,
              activeCaptureAttemptID == scope.attemptID,
              cameraGeneration == scope.cameraGeneration,
              let control = activeCaptureControl,
              let context = captureAttemptContext,
              context.expectedCameraIdentifier != nil,
              control.markShutterMayHaveBeenIssued(scope) else { return false }
        guard context.shutterIssuedAt == nil else {
            expectingCapture = true
            return true
        }
        shutterCommandGeneration &+= 1
        captureAttemptContexts.updateActive(
            context.recordingShutterIssued(at: date, generation: shutterCommandGeneration)
        )
        expectingCapture = true
        return true
    }

    private func isPTPCandidate(_ candidate: CaptureMediaCandidate, handle: UInt32) -> Bool {
        switch candidate {
        case .ptpObjectHandle(let candidateHandle):
            return candidateHandle == handle
        case .sonyPCBuffer:
            return handle == 0xFFFFC001
        case .cameraFile:
            return false
        }
    }

    func setPreviewFrameRate(_ framesPerSecond: Int) {
        previewFramesPerSecond = max(1, framesPerSecond)
    }

    // Sony ZV-E10 uses the Sony SDIO vendor capture protocol.
    // Trigger via SDIO_ControlDevice (0x9207); image arrives via ObjectAdded or ObjectInMemory.

    private func fetchPTPObjectHandles(
        _ cam: ICCameraDevice,
        scope: DSLRCaptureAttemptScope
    ) async -> PTPHandleBaselineResult {
        let command = Self.makePTPCommand(
            opcode: 0x1007,
            transactionID: nextPTPTransactionID(),
            parameters: [0xFFFFFFFF, 0, 0xFFFFFFFF]
        )
        let reply = await executePTPCommand(
            cam,
            command: command,
            priority: .capture,
            captureScope: scope
        )
        guard reply.errorDescription == nil, reply.responseCode == 0x2001 else {
            return .unavailable(reply.errorDescription ?? "GetObjectHandles returned an error response.")
        }
        return .success(Self.parsePTPObjectHandles(from: reply.data))
    }

    func captureStill() async throws -> CGImage {
        guard let cam = connectedCamera, isRunning else { throw DSLRError.noCamera }
        try Task.checkCancellation()
        guard let cameraIdentifier = stableCameraIdentifier(for: cam) else {
            throw DSLRError.captureFailed("Camera identity is unavailable; a private capture cannot be verified.")
        }
        guard !isCapturing else {
            throw DSLRError.captureFailed("A tethered capture is already in progress.")
        }
        guard !isDrainingPCBuffer else {
            throw DSLRError.captureFailed("Camera is clearing old PC-save images. Try again in a moment.")
        }
        guard !ptpCommandLane.isQuarantined else {
            throw DSLRError.captureFailed("Camera communication is still recovering from an unanswered PTP command. Reconnect the camera before capturing again.")
        }

        let attempt = CaptureAttempt()
        let scope = DSLRCaptureAttemptScope(
            attemptID: attempt.id,
            cameraGeneration: cameraGeneration
        )
        let control = DSLRCaptureAttemptControl(scope: scope)
        isCapturing = true
        let requestedAt = Date()
        let baselineFiles = Set((cam.mediaFiles ?? []).compactMap { ($0 as? ICCameraFile)?.name })
        let cameraTimeOffset = cam.capabilities.contains(ICDeviceCapability.cameraDeviceCanSyncClock.rawValue)
            && cam.timeOffset.isFinite ? cam.timeOffset : nil
        activeCaptureAttemptID = attempt.id
        activeCaptureScope = scope
        activeCaptureControl = control
        expectingCapture = false
        fallbackTakePictureIssued = false
        busyRejection = false

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                captureCompletion = continuation
                captureTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled,
                          let self,
                          self.activeCaptureScope == scope else { return }
                    if let cam = self.connectedCamera,
                       self.tryDownloadFreshestMediaFile(from: cam, scope: scope) {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(15))
                            guard !Task.isCancelled,
                                  let self,
                                  self.activeCaptureScope == scope,
                                  self.isCapturing else { return }
                            self.failCapture(
                                DSLRError.captureFailed("Capture download timed out."),
                                scope: scope
                            )
                        }
                        return
                    }
                    let message = control.shutterMayHaveBeenIssued(for: scope)
                        ? "The shutter may have fired, but no image was confirmed. Retry receiving the image before taking another photo."
                        : self.busyRejection
                            ? "Camera reported Busy and refused the shutter. On the ZV-E10: Setup → USB Connection → PC Remote, switch the photo/movie switch to Photo, and make sure the camera is showing live view (not a menu or playback screen)."
                            : "Timed out before the camera confirmed a photograph. Check the camera connection and SD card."
                    self.failCapture(DSLRError.captureFailed(message), scope: scope)
                }
                capturePreparationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.prepareCapture(
                        cam,
                        scope: scope,
                        control: control,
                        requestedAt: requestedAt,
                        baselineFiles: baselineFiles,
                        cameraIdentifier: cameraIdentifier,
                        cameraTimeOffset: cameraTimeOffset
                    )
                }
            }
        } onCancel: {
            _ = control.cancel(scope)
            Task { @MainActor [weak self] in
                self?.cancelCaptureAttempt(scope)
            }
        }
    }

    private func prepareCapture(
        _ cam: ICCameraDevice,
        scope: DSLRCaptureAttemptScope,
        control: DSLRCaptureAttemptControl,
        requestedAt: Date,
        baselineFiles: Set<String>,
        cameraIdentifier: String,
        cameraTimeOffset: TimeInterval?
    ) async {
        guard isCurrentCapture(scope, camera: cam) else { return }
        let baselineHandles = await fetchPTPObjectHandles(cam, scope: scope)
        guard isCurrentCapture(scope, camera: cam) else { return }
        guard !ptpCommandLane.isQuarantined else {
            failCapture(
                DSLRError.captureFailed("The camera did not answer its 10-second PTP baseline query. Reconnect the camera before capturing again."),
                scope: scope
            )
            return
        }

        let context = DSLRCaptureAttemptContext(
            id: scope.attemptID,
            requestedAt: requestedAt,
            baselineFileNames: baselineFiles,
            baselineObjectHandles: baselineHandles,
            expectedCameraIdentifier: cameraIdentifier,
            cameraTimeOffset: cameraTimeOffset
        )
        captureAttemptContexts.beginCapture(context)
        let baselineSucceeded: Bool
        if case .success = baselineHandles {
            baselineSucceeded = true
        } else {
            baselineSucceeded = false
        }
        captureAttemptContexts.clearPTPHandleQuarantineAfterFreshBaseline(
            cameraIdentifier: cameraIdentifier,
            baselineSucceeded: baselineSucceeded
        )

        guard control.canContinue(scope), isCurrentCapture(scope, camera: cam) else { return }
        if ptpHealthy {
            while isRequestingLiveViewFrame {
                try? await Task.sleep(for: .milliseconds(20))
                guard control.canContinue(scope), isCurrentCapture(scope, camera: cam) else { return }
            }
            await ptpSonyCapture(cam, scope: scope)
        } else {
            NSLog("[DSLR] PTP appears unhealthy (empty responses). Falling back to requestTakePicture().")
            triggerICCaptureFallback(reason: "PTP unhealthy", scope: scope)
        }
    }

    func recoverLastCapture() async throws -> CGImage {
        guard let cam = connectedCamera, isRunning else { throw DSLRError.noCamera }
        try Task.checkCancellation()
        guard !isCapturing else { throw DSLRError.captureFailed("A tethered capture is already in progress.") }
        guard captureAttemptContexts.beginRecovery(cameraIdentifier: stableCameraIdentifier(for: cam)) != nil else {
            throw DSLRError.captureFailed("No fresh image from this camera is available to recover. Retake the photograph.")
        }

        let attempt = CaptureAttempt()
        let scope = DSLRCaptureAttemptScope(
            attemptID: attempt.id,
            cameraGeneration: cameraGeneration
        )
        let control = DSLRCaptureAttemptControl(scope: scope)
        _ = control.markShutterMayHaveBeenIssued(scope)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                isCapturing = true
                activeCaptureAttemptID = attempt.id
                activeCaptureScope = scope
                activeCaptureControl = control
                captureCompletion = continuation
                // This is the original shutter attempt, not a new shutter.
                expectingCapture = true
                fallbackTakePictureIssued = false
                busyRejection = false

                captureTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(7))
                    guard !Task.isCancelled, let self, self.activeCaptureScope == scope else { return }
                    self.failCapture(
                        DSLRError.captureFailed("No recoverable image was found."),
                        scope: scope
                    )
                }
                pendingCapturePollTask = Task { @MainActor [weak self] in
                    guard let self, self.isCurrentCapture(scope, camera: cam) else { return }

                    _ = await self.ptpSonyGetAllDevicePropDesc(cam, captureAttemptID: attempt.id)

                    guard self.isCurrentCapture(scope, camera: cam) else { return }
                    await self.ptpGetObjectHandles(
                        cam,
                        attemptID: attempt.id,
                        failIfEmpty: false
                    )
                    guard self.isCurrentCapture(scope, camera: cam) else { return }
                    if !self.tryDownloadLatestMediaFile(from: cam, scope: scope) {
                        self.failCapture(
                            DSLRError.captureFailed("No recoverable image was found."),
                            scope: scope
                        )
                    }
                }
            }
        } onCancel: {
            _ = control.cancel(scope)
            Task { @MainActor [weak self] in
                self?.cancelCaptureAttempt(scope)
            }
        }
    }

    // MARK: - Sony PTP capture

    // Sony initialization sequence — call once after session opens.
    // SDIOConnect (0x9201) with 3 phases enables Sony vendor PTP commands.
    // Vendor prop codes reported by the camera — populated after SDIOConnect phases 1+2
    private var sonyVendorPropCodes: [UInt16] = []

    private func cycleSession() {
        guard let camera = connectedCamera else { return }
        reopenAfterClose = true
        pendingPTPSessionCloses.append(PTPSessionClose(
            cameraIdentity: ObjectIdentifier(camera),
            generation: cameraGeneration
        ))
        camera.requestCloseSession()  // sync Obj-C void — no async bridging
    }

    private func ptpSonyInit(_ cam: ICCameraDevice, generation: UInt64) async {
        guard connectedCamera === cam, cameraGeneration == generation, !Task.isCancelled else { return }
        await ptpSonySDIOConnect(cam, phase: 1)
        try? await Task.sleep(for: .milliseconds(200))
        guard connectedCamera === cam, cameraGeneration == generation, !Task.isCancelled else { return }
        await ptpSonySDIOConnect(cam, phase: 2)
        try? await Task.sleep(for: .milliseconds(300))
        guard connectedCamera === cam, cameraGeneration == generation, !Task.isCancelled else { return }
        await ptpSonyGetVendorPropCodes(cam)
        try? await Task.sleep(for: .milliseconds(300))
        guard connectedCamera === cam, cameraGeneration == generation, !Task.isCancelled else { return }
        await ptpSonySDIOConnect(cam, phase: 3)
        try? await Task.sleep(for: .milliseconds(300))
        guard connectedCamera === cam, cameraGeneration == generation, !Task.isCancelled else { return }
        // Give the controlling application priority, matching libgphoto2's Sony init.
        _ = await ptpSonySetControlAInt8(cam, prop: 0xD25A, value: 1, label: "SetPriorityMode")
        try? await Task.sleep(for: .milliseconds(300))
        guard connectedCamera === cam, cameraGeneration == generation, !Task.isCancelled else { return }
        // PcSaveImageFormat (D269): 1=RAW & JPEG, 2=JPEG Only, 3=RAW Only.
        // A booth needs the full-resolution rendered JPEG, not a paired 25 MB
        // RAW whose embedded preview is only 1616x1080.
        _ = await ptpSonySetControlAInt8(cam, prop: 0xD269, value: 2, label: "SetPcSaveJPEGOnly")
        try? await Task.sleep(for: .milliseconds(300))
        guard connectedCamera === cam, cameraGeneration == generation, !Task.isCancelled else { return }
        // Query D215 once at connection time. If previous clients left PC-save
        // images queued, the response handler drains those RAM-only objects.
        await ptpSonyGetAllDevicePropDesc(cam)
        try? await Task.sleep(for: .seconds(2))
        // Do not write 0xD2CA here. It is Sony's FormatMedia action, not the
        // still-image destination. The destination property is 0xD222 and should
        // remain under the camera's PC Remote settings.
    }

    // Sony Alpha live view is exposed as a continually refreshed JPEG object at
    // fixed RAM handle 0xFFFFC002. GetObjectInfo can temporarily report an
    // invalid handle while the next frame is being prepared, so failed frames
    // are retried without treating them as connection failures.
    private func startSonyLiveView(_ cam: ICCameraDevice) {
        stopSonyLiveView()
        liveViewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.isRunning,
                      self.connectedCamera === cam
                else { return }

                if self.isCapturing ||
                    self.isDrainingPCBuffer ||
                    self.suppressStatusPoll ||
                    self.isRequestingLiveViewFrame {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }

                let iterationStartedAt = ProcessInfo.processInfo.systemUptime
                self.isRequestingLiveViewFrame = true
                let requestStartedAt = ProcessInfo.processInfo.systemUptime
                let jpeg = await self.requestSonyLiveViewJPEG(cam)
                let requestDuration = ProcessInfo.processInfo.systemUptime - requestStartedAt
                self.isRequestingLiveViewFrame = false
                self.recordPreviewRequest(duration: requestDuration, succeeded: jpeg != nil)

                guard !Task.isCancelled else { return }
                if let jpeg {
                    // Forward original Sony JPEG before local decode. The network path
                    // does not need a decode/re-encode cycle.
                    self.onPreviewJPEG?(jpeg)
                    self.previewFramesEmitted += 1

                    if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        let wasInactive = !self.isLivePreviewActive
                        self.latestPreviewImage = image
                        self.rollingBuffer.append(image)
                        self.isLivePreviewActive = true
                        self.measuredPreviewFrameCount += 1
                        let elapsed = Date().timeIntervalSince(self.measuredPreviewWindowStartedAt)
                        if elapsed >= 1 {
                            self.measuredPreviewFPS = Double(self.measuredPreviewFrameCount) / elapsed
                            self.measuredPreviewFrameCount = 0
                            self.measuredPreviewWindowStartedAt = Date()
                        }
                        self.liveViewFailureCount = 0
                        if wasInactive {
                            NSLog("[DSLR] Sony live preview active: %dx%d, %d bytes",
                                  image.width, image.height, jpeg.count)
                        }
                    } else {
                        self.liveViewFailureCount += 1
                        if self.liveViewFailureCount >= 12 {
                            self.isLivePreviewActive = false
                        }
                    }
                } else {
                    self.liveViewFailureCount += 1
                    if self.liveViewFailureCount >= 12 {
                        self.isLivePreviewActive = false
                    }
                }

                let elapsed = ProcessInfo.processInfo.systemUptime - iterationStartedAt
                let remaining = Self.previewSleepInterval(
                    targetFramesPerSecond: self.previewFramesPerSecond,
                    elapsed: elapsed
                )
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                }
                self.logPreviewMetricsIfNeeded()
            }
        }
    }

    private func stopSonyLiveView() {
        liveViewTask?.cancel()
        liveViewTask = nil
        isRequestingLiveViewFrame = false
        liveViewFailureCount = 0
        isLivePreviewActive = false
        latestPreviewImage = nil
        resetPreviewMetrics()
    }

    private func resetPreviewMetrics() {
        measuredPreviewFPS = nil
        measuredPreviewFrameCount = 0
        measuredPreviewWindowStartedAt = Date()
        previewPTPRequestCount = 0
        previewPTPRequestDurationTotal = 0
        previewFramesEmitted = 0
        previewMetricsWindowStartedAt = Date()
        averagePreviewPTPRequestDuration = nil
        previewTemporaryFailureCount = 0
    }

    private func recordPreviewRequest(duration: TimeInterval, succeeded: Bool) {
        previewPTPRequestCount += 1
        previewPTPRequestDurationTotal += duration
        if !succeeded { previewTemporaryFailureCount += 1 }
    }

    private func logPreviewMetricsIfNeeded() {
#if DEBUG
        let now = Date()
        guard now.timeIntervalSince(previewMetricsWindowStartedAt) >= 2 else { return }
        let averageDuration = previewPTPRequestCount == 0
            ? 0
            : previewPTPRequestDurationTotal / Double(previewPTPRequestCount)
        averagePreviewPTPRequestDuration = averageDuration
        NSLog(
            "[DSLR] Sony preview requested=%d FPS received=%.1f emitted=%d avgPTP=%.1fms temporaryFailures=%d",
            previewFramesPerSecond,
            measuredPreviewFPS ?? 0,
            previewFramesEmitted,
            averageDuration * 1_000,
            previewTemporaryFailureCount
        )
        previewMetricsWindowStartedAt = now
        previewPTPRequestCount = 0
        previewPTPRequestDurationTotal = 0
        previewFramesEmitted = 0
#endif
    }

    private func requestSonyLiveViewJPEG(_ cam: ICCameraDevice) async -> Data? {
        let handle = UInt32(0xFFFFC002)
        let info = await sendPTPRequest(
            cam,
            opcode: 0x1008,
            parameter: handle,
            priority: .liveView
        )
        guard connectedCamera === cam, !Task.isCancelled else { return nil }
        guard info.errorDescription == nil, info.responseCode == 0x2001 else {
            if info.responseCode != 0x2009 && info.responseCode != 0x201D {
                NSLog("[DSLR] LiveView GetObjectInfo: error=%@ resp=0x%04X",
                      info.errorDescription ?? "none", info.responseCode)
            }
            return nil
        }

        let object = await sendPTPRequest(
            cam,
            opcode: 0x1009,
            parameter: handle,
            priority: .liveView
        )
        guard connectedCamera === cam, !Task.isCancelled else { return nil }
        guard object.errorDescription == nil, object.responseCode == 0x2001 else {
            if object.responseCode != 0x200F && object.responseCode != 0x201D {
                NSLog("[DSLR] LiveView GetObject: error=%@ resp=0x%04X",
                      object.errorDescription ?? "none", object.responseCode)
            }
            return nil
        }
        return Self.sonyLiveViewJPEGData(from: object.data)
    }

    private func sendPTPRequest(
        _ cam: ICCameraDevice,
        opcode: UInt16,
        parameter: UInt32,
        priority: PTPCommandPriority = .normal,
        captureScope: DSLRCaptureAttemptScope? = nil
    ) async -> PTPReply {
        let command = Self.makePTPCommand(
            opcode: opcode,
            transactionID: nextPTPTransactionID(),
            parameters: [parameter]
        )
        return await executePTPCommand(
            cam,
            command: command,
            priority: priority,
            captureScope: captureScope
        )
    }

    private func startPollLoop(_ cam: ICCameraDevice) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            while !Task.isCancelled {
                guard let self, self.isRunning, self.connectedCamera === cam else { return }
                if self.canStartStatusPoll {
                    await self.ptpSonyGetAllDevicePropDesc(cam)
                }
                let interval = self.isLiveViewLoopRunning ? 5.0 : 1.5
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private var canStartStatusPoll: Bool {
        guard !suppressStatusPoll,
              !isCapturing,
              !isDrainingPCBuffer,
              !isRequestingLiveViewFrame else { return false }
        let minimumInterval = isLiveViewLoopRunning ? 5.0 : 1.5
        return Date().timeIntervalSince(lastStatusPollAt) >= minimumInterval
    }

    @discardableResult
    private func ptpSonyGetAllDevicePropDesc(
        _ cam: ICCameraDevice,
        captureAttemptID: UUID? = nil
    ) async -> UInt16? {
        let captureScope: DSLRCaptureAttemptScope?
        if let captureAttemptID {
            guard connectedCamera === cam,
                  activeCaptureAttemptID == captureAttemptID,
                  let activeCaptureScope,
                  activeCaptureScope.attemptID == captureAttemptID,
                  isCurrentCapture(activeCaptureScope, camera: cam) else { return nil }
            captureScope = activeCaptureScope
        } else {
            guard connectedCamera === cam, canStartStatusPoll else { return nil }
            captureScope = nil
        }
        lastStatusPollAt = Date()
        let command = Self.makePTPCommand(opcode: 0x9209, transactionID: nextPTPTransactionID())
        let reply = await executePTPCommand(
            cam,
            command: command,
            priority: captureAttemptID == nil ? .normal : .capture,
            captureScope: captureScope
        )
        guard connectedCamera === cam, !Task.isCancelled else { return nil }
        if let captureAttemptID {
            guard activeCaptureAttemptID == captureAttemptID,
                  let captureScope,
                  isCurrentCapture(captureScope, camera: cam) else { return nil }
        }
        notePTPHealth(dataLen: reply.data.count, responseCode: reply.responseCode)
        NSLog("[DSLR] GetAllDevicePropDesc: %d bytes, resp=0x%04X", reply.data.count, reply.responseCode)
        let objectInMemory = Self.parseSonyUInt16CurrentValue(reply.data, property: 0xD215)
        if let objectInMemory { NSLog("[DSLR] ObjectInMemory=0x%04X", objectInMemory) }

        if let captureAttemptID,
           let context = captureAttemptContext,
           activeCaptureAttemptID == captureAttemptID {
            let updated = context.shutterIssuedAt == nil
                ? context.recordingObjectInMemoryBaseline(objectInMemory)
                : context.recordingObjectInMemoryValue(objectInMemory)
            captureAttemptContexts.updateActive(updated)
        }
        guard connectedCamera === cam, Self.sonyObjectInMemoryIsReady(objectInMemory) else {
            return objectInMemory
        }
        if let captureAttemptID,
           let captureScope,
           isAuthorizedCaptureCandidate(
               .sonyPCBuffer(objectInMemoryValue: objectInMemory),
               from: cam,
               attemptID: captureAttemptID
           ) {
            NSLog("[DSLR] ObjectInMemory ready via GetAll → reading PC buffer")
            expectingCapture = false
            pollTask?.cancel()
            pollTask = nil
            await ptpGetObject(
                cam,
                handle: 0xFFFFC001,
                candidate: .sonyPCBuffer(objectInMemoryValue: objectInMemory),
                attemptID: captureAttemptID,
                failIfEmpty: true,
                captureScope: captureScope
            )
        } else if captureAttemptID == nil,
                  captureCompletion == nil,
                  !isCapturing,
                  !isDrainingPCBuffer,
                  !isLiveViewLoopRunning {
            await ptpDiscardPCBufferObject(cam)
        }
        return objectInMemory
    }

    private func ptpSonyGetVendorPropCodes(_ cam: ICCameraDevice) async {
        // Opcode 0x9202 with param1=0xC8, matching Sony SDIO and libgphoto2.
        let command = Self.makePTPCommand(
            opcode: 0x9202,
            transactionID: nextPTPTransactionID(),
            parameters: [0xC8]
        )
        let reply = await executePTPCommand(cam, command: command)
        guard connectedCamera === cam, !Task.isCancelled else { return }
        if let error = reply.errorDescription { NSLog("[DSLR] GetVendorPropCodes error: %@", error); return }
        notePTPHealth(dataLen: reply.data.count, responseCode: reply.responseCode)
        NSLog("[DSLR] GetVendorPropCodes: %d data bytes, resp=0x%04X", reply.data.count, reply.responseCode)
        let codes = Self.parseSonyVendorCodes(reply.data)
        NSLog("[DSLR] Vendor props (%d): %@", codes.count, codes.map { String(format: "0x%04X", $0) }.joined(separator: ", "))
        sonyVendorPropCodes = codes
        controlSupport.shutter = codes.contains(0xD20D)
        controlSupport.aperture = codes.contains(0x5007) || codes.contains(0xD211)
    }

    // Sony's 0x9202 payload is: UInt16(0x00C8), then one or two PTP
    // UInt16 arrays (UInt32 count followed by values).
    nonisolated static func parseSonyVendorCodes(_ data: Data) -> [UInt16] {
        func uint16(at offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func uint32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        guard uint16(at: 0) == 0x00C8 else { return [] }
        var offset = 2
        var codes: [UInt16] = []
        for _ in 0..<2 {
            guard let count = uint32(at: offset) else { break }
            offset += 4
            let availableCount = min(Int(count), (data.count - offset) / 2)
            for index in 0..<availableCount {
                if let code = uint16(at: offset + index * 2) {
                    codes.append(code)
                }
            }
            offset += availableCount * 2
            guard availableCount == Int(count) else { break }
        }
        return codes
    }

    // Sony GetAllDevicePropDesc concatenates vendor descriptors. For UINT16
    // properties, the current value begins eight bytes after the property code:
    // code(2), type(2), get/set(1), enabled(1), default(2), current(2).
    nonisolated static func parseSonyUInt16CurrentValue(
        _ data: Data,
        property: UInt16
    ) -> UInt16? {
        guard data.count >= 10 else { return nil }
        let low = UInt8(property & 0x00FF)
        let high = UInt8(property >> 8)
        for offset in 0...(data.count - 10) {
            guard data[offset] == low,
                  data[offset + 1] == high,
                  data[offset + 2] == 0x04,
                  data[offset + 3] == 0x00
            else { continue }
            return UInt16(data[offset + 8]) | (UInt16(data[offset + 9]) << 8)
        }
        return nil
    }

    nonisolated static func sonyObjectInMemoryIsReady(_ value: UInt16?) -> Bool {
        value.map { $0 >= 0x8000 } ?? false
    }

    nonisolated static func sonyCaptureBufferAction(
        objectInMemory: UInt16?,
        shutterIssued: Bool
    ) -> SonyCaptureBufferAction {
        guard sonyObjectInMemoryIsReady(objectInMemory) else { return .wait }
        return shutterIssued ? .downloadCurrent : .discardStale
    }

    // Sony can send an ARW object to the PC buffer when the camera's PC-save
    // format is RAW or RAW+JPEG. ARW files contain one or more complete JPEG
    // previews; return their byte ranges so capture can still produce a CGImage.
    nonisolated static func embeddedJPEGRanges(in data: Data) -> [Range<Int>] {
        guard data.count >= 4 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var ranges: [Range<Int>] = []
            var currentStart: Int?
            var offset = 0

            while offset + 1 < bytes.count {
                if offset + 2 < bytes.count,
                   bytes[offset] == 0xFF,
                   bytes[offset + 1] == 0xD8,
                   bytes[offset + 2] == 0xFF {
                    currentStart = offset
                    offset += 3
                    continue
                }
                if let imageStart = currentStart,
                   bytes[offset] == 0xFF,
                   bytes[offset + 1] == 0xD9 {
                    ranges.append(imageStart..<(offset + 2))
                    currentStart = nil
                    offset += 2
                    continue
                }
                offset += 1
            }
            return ranges
        }
    }

    // Sony live-view objects begin with a little-endian offset to the JPEG.
    // Some ImageCaptureCore versions strip or retain different portions of the
    // object wrapper, so fall back to the largest complete embedded JPEG.
    nonisolated static func sonyLiveViewJPEGData(from data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        let advertisedOffset = Int(UInt32(data[0])
            | (UInt32(data[1]) << 8)
            | (UInt32(data[2]) << 16)
            | (UInt32(data[3]) << 24))
        let ranges = embeddedJPEGRanges(in: data)

        if let advertised = ranges.first(where: { $0.lowerBound == advertisedOffset }) {
            return data.subdata(in: advertised)
        }
        guard let largest = ranges.max(by: { $0.count < $1.count }) else { return nil }
        return data.subdata(in: largest)
    }

    private func ptpSonySDIOConnect(_ cam: ICCameraDevice, phase: Int) async {
        let command = Self.makePTPCommand(
            opcode: 0x9201,
            transactionID: nextPTPTransactionID(),
            parameters: [UInt32(phase), 0, 0]
        )
        let reply = await executePTPCommand(cam, command: command)
        guard connectedCamera === cam, !Task.isCancelled else { return }
        if let error = reply.errorDescription { NSLog("[DSLR] SDIOConnect(%d) error: %@", phase, error); return }
        notePTPHealth(dataLen: reply.data.count, responseCode: reply.responseCode)
        NSLog("[DSLR] SDIOConnect(%d) resp=0x%04X %@", phase, reply.responseCode,
              reply.responseCode == 0 ? "⚠ empty — PTP may not be working" : "")
    }

    // Sony capture: AF half-press → shutter → release.
    // Uses SDIO_ControlDevice (0x9207), Sony's vendor capture opcode.
    // 0xD2C1 = ShutterHalfRelease (AF), 0xD2C2 = ShutterRelease (capture)
    // REQUIRES camera in PC Remote USB mode (Setup → USB Connection → PC Remote)
    private func ptpSonyCapture(_ cam: ICCameraDevice, scope: DSLRCaptureAttemptScope) async {
        guard isCurrentCapture(scope, camera: cam) else { return }
        suppressStatusPoll = true
        defer { suppressStatusPoll = false }

        guard await drainSonyPCBufferBeforeCapture(cam, scope: scope) else {
            guard isCurrentCapture(scope, camera: cam) else { return }
            failCapture(
                DSLRError.captureFailed("Could not clear an older image from the camera."),
                scope: scope
            )
            return
        }
        guard isCurrentCapture(scope, camera: cam) else { return }
        expectingCapture = true

        NSLog("[DSLR] Sony capture: sending AF half-press (0xD2C1=2)...")
        let afCode = await ptpSonySetControlB(cam, prop: 0xD2C1, value: 2, label: "AF-press", scope: scope)
        guard isCurrentCapture(scope, camera: cam) else { return }
        guard !ptpCommandLane.isQuarantined else {
            failCapture(DSLRError.captureFailed("The camera stopped responding during autofocus. Reconnect before capturing again."), scope: scope)
            return
        }
        if afCode == 0 {
            NSLog("[DSLR] AF-press got no response (USB hiccup?); retrying once")
            try? await Task.sleep(for: .milliseconds(300))
            guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return }
            _ = await ptpSonySetControlB(cam, prop: 0xD2C1, value: 2, label: "AF-press-retry", scope: scope)
            guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return }
        }
        // Sony's reference sequence sends full-press immediately after half-press,
        // then holds both while focus settles.
        try? await Task.sleep(for: .milliseconds(100))
        guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return }

        var shutterAccepted = false
        var lastCode: UInt16 = 0
        for attempt in 1...3 {
            NSLog("[DSLR] Sony capture: sending shutter attempt %d (0xD2C2=2)...", attempt)
            guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return }
            let code = await ptpSonySetControlB(
                cam,
                prop: 0xD2C2,
                value: 2,
                label: "Shutter-press",
                scope: scope
            )
            guard isCurrentCapture(scope, camera: cam) else { return }
            guard !ptpCommandLane.isQuarantined else {
                failCapture(DSLRError.captureFailed("The shutter result is unknown because the camera stopped responding. Retry receiving before taking another photo."), scope: scope)
                return
            }
            lastCode = code
            if code == 0x2001 {
                shutterAccepted = true
                busyRejection = false
                break
            }
            if code == 0x201D {
                activeCaptureControl?.confirmShutterRejected(scope)
                busyRejection = true
                NSLog("[DSLR] Shutter-press busy; waiting before retry %d/3", attempt)
                try? await Task.sleep(for: .milliseconds(900))
                continue
            }
            break
        }
        if !shutterAccepted && lastCode == 0x201D { busyRejection = true }

        // Keep both half-press and full-press held while autofocus settles.
        // Sony's reference capture flow allows up to one second here.
        try? await Task.sleep(for: .seconds(1))
        guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return }
        _ = await ptpSonySetControlB(cam, prop: 0xD2C2, value: 1, label: "Shutter-release", scope: scope)
        guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return }
        try? await Task.sleep(for: .milliseconds(160))
        guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return }
        _ = await ptpSonySetControlB(cam, prop: 0xD2C1, value: 1, label: "AF-release", scope: scope)
        guard isCurrentCapture(scope, camera: cam) else { return }

        guard shutterAccepted else {
            guard lastCode == 0x201D else {
                failCapture(
                    DSLRError.captureFailed("The camera did not confirm the shutter command. Check the camera before trying again."),
                    scope: scope
                )
                return
            }
            triggerICCaptureFallback(reason: "Sony shutter command stayed busy", scope: scope)
            startPendingCapturePoll(cam, scope: scope)
            return
        }

        startPendingCapturePoll(cam, scope: scope)
    }

    private func drainSonyPCBufferBeforeCapture(_ cam: ICCameraDevice, scope: DSLRCaptureAttemptScope) async -> Bool {
        while isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined {
            let objectInMemory = await ptpSonyGetAllDevicePropDesc(cam, captureAttemptID: scope.attemptID)
            guard isCurrentCapture(scope, camera: cam), !ptpCommandLane.isQuarantined else { return false }
            guard Self.sonyCaptureBufferAction(
                objectInMemory: objectInMemory,
                shutterIssued: false
            ) == .discardStale else { return true }
            guard await ptpDiscardPCBufferObject(cam, captureScope: scope) else { return false }
        }
        return false
    }

    // libgphoto2 sends Sony shutter control props (D2C1, D2C2) as PTP_DTC_UINT16.
    @discardableResult
    private func ptpSonySetControlB(_ cam: ICCameraDevice, prop: UInt16, value: UInt16,
                                    label: String,
                                    scope: DSLRCaptureAttemptScope) async -> UInt16 {
        let cmd = Self.makePTPCommand(opcode: 0x9207, transactionID: nextPTPTransactionID(), parameters: [UInt32(prop)])
        var outData = Data(count: 2)
        outData.withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: 0, as: UInt16.self)
        }
        let beforeSend: (@MainActor () -> Bool)?
        if prop == 0xD2C2 && value == 2 {
            beforeSend = { [weak self] in self?.recordShutterIssued(scope: scope) ?? false }
        } else {
            beforeSend = nil
        }
        let reply = await executePTPCommand(
            cam,
            command: cmd,
            outData: outData,
            priority: .capture,
            captureScope: scope,
            beforeSend: beforeSend
        )
        if let error = reply.errorDescription { NSLog("[DSLR] %@ error: %@", label, error); return 0 }
        NSLog("[DSLR] %@ resp=0x%04X", label, reply.responseCode)
        return reply.responseCode
    }

    // Sony SDIO_SetExtDevicePropValue (0x9205), used for application priority.
    @discardableResult
    private func ptpSonySetControlAInt8(_ cam: ICCameraDevice, prop: UInt16, value: Int8,
                                        label: String) async -> UInt16 {
        let cmd = Self.makePTPCommand(opcode: 0x9205, transactionID: nextPTPTransactionID(), parameters: [UInt32(prop)])
        let outData = Data([UInt8(bitPattern: value)])
        let reply = await executePTPCommand(cam, command: cmd, outData: outData)
        if let error = reply.errorDescription { NSLog("[DSLR] %@ error: %@", label, error); return 0 }
        NSLog("[DSLR] %@ resp=0x%04X", label, reply.responseCode)
        return reply.responseCode
    }

    private func startPendingCapturePoll(_ cam: ICCameraDevice, scope: DSLRCaptureAttemptScope) {
        pendingCapturePollTask?.cancel()
        pendingCapturePollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...18 {
                guard self.isCurrentCapture(scope, camera: cam),
                      self.expectingCapture,
                      self.captureCompletion != nil else { return }
                try? await Task.sleep(for: .seconds(1))
                guard self.isCurrentCapture(scope, camera: cam),
                      self.expectingCapture,
                      self.captureCompletion != nil,
                      !self.ptpCommandLane.isQuarantined else { return }
                if self.tryDownloadFreshestMediaFile(from: cam, scope: scope) { return }
                NSLog("[DSLR] Capture fallback poll %d/18: ObjectInMemory", attempt)
                await self.ptpSonyGetAllDevicePropDesc(cam, captureAttemptID: scope.attemptID)
                guard self.isCurrentCapture(scope, camera: cam), !self.ptpCommandLane.isQuarantined else { return }
            }
            if self.isCurrentCapture(scope, camera: cam), self.expectingCapture {
                self.failCapture(
                    DSLRError.captureFailed("The shutter may have fired, but no image arrived. Retry receiving before taking another photo."),
                    scope: scope
                )
            }
        }
    }

    // Reading Sony's fixed RAM handle consumes one queued PC-save object.
    // DeleteObject is intentionally not used because Sony does not support it
    // for this buffer.
    @discardableResult
    private func ptpDiscardPCBufferObject(
        _ cam: ICCameraDevice,
        captureScope: DSLRCaptureAttemptScope? = nil
    ) async -> Bool {
        guard !isDrainingPCBuffer else { return false }
        isDrainingPCBuffer = true
        defer { isDrainingPCBuffer = false }
        let handle = UInt32(0xFFFFC001)
        NSLog("[DSLR] Draining one stale PC-buffer object")
        let info = await sendPTPRequest(
            cam,
            opcode: 0x1008,
            parameter: handle,
            priority: captureScope == nil ? .normal : .capture,
            captureScope: captureScope
        )
        guard info.errorDescription == nil, info.responseCode == 0x2001 else {
            NSLog("[DSLR] PC-buffer drain info failed: error=%@ resp=0x%04X", info.errorDescription ?? "none", info.responseCode)
            return false
        }
        let object = await sendPTPRequest(
            cam,
            opcode: 0x1009,
            parameter: handle,
            priority: captureScope == nil ? .normal : .capture,
            captureScope: captureScope
        )
        NSLog("[DSLR] PC-buffer drain: error=%@ dataLen=%d resp=0x%04X", object.errorDescription ?? "none", object.data.count, object.responseCode)
        let consumed = object.errorDescription == nil
            && object.responseCode == 0x2001
            && !object.data.isEmpty
            && connectedCamera === cam
        if consumed, captureCompletion == nil {
            Task { @MainActor [weak self] in
                guard let self, self.connectedCamera === cam, !self.isDrainingPCBuffer else { return }
                await self.ptpSonyGetAllDevicePropDesc(cam)
            }
        }
        return consumed
    }

    // Standard MTP GetDevicePropValue (0x1015)
    private func ptpGetDevicePropValue(_ cam: ICCameraDevice, prop: UInt16, label: String) async {
        let reply = await sendPTPRequest(cam, opcode: 0x1015, parameter: UInt32(prop))
        if let error = reply.errorDescription { NSLog("[DSLR] %@ error: %@", label, error); return }
        let hex = reply.data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        NSLog("[DSLR] %@ resp=0x%04X data(%d)=[%@]", label, reply.responseCode, reply.data.count, hex)
    }

    // Standard MTP SetDevicePropValue (0x1016) — UInt16 value
    private func ptpSetDevicePropValue(_ cam: ICCameraDevice, prop: UInt16, value: UInt16, label: String) async {
        var outData = Data(count: 2)
        outData.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: 0, as: UInt16.self) }
        let command = Self.makePTPCommand(opcode: 0x1016, transactionID: nextPTPTransactionID(), parameters: [UInt32(prop)])
        let reply = await executePTPCommand(cam, command: command, outData: outData)
        if let error = reply.errorDescription { NSLog("[DSLR] %@ error: %@", label, error); return }
        NSLog("[DSLR] %@ resp=0x%04X", label, reply.responseCode)
    }

    // Sony GetDevicePropertyValue (0x9204) — read a single prop value
    private func ptpSonyReadProp(_ cam: ICCameraDevice, prop: UInt16, label: String) async {
        let reply = await sendPTPRequest(cam, opcode: 0x9204, parameter: UInt32(prop))
        if let error = reply.errorDescription { NSLog("[DSLR] ReadProp %@ error: %@", label, error); return }
        let hex = reply.data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        NSLog("[DSLR] ReadProp %@: resp=0x%04X data(%d)=[%@]", label, reply.responseCode, reply.data.count, hex)
    }

    // GetObjectHandles (0x1007) — fallback download when no ObjectAdded event with handle.
    // Used for Sony PC-save mode (no SD card) where 0xC202 fires instead of 0x4002.
    private func ptpGetObjectHandles(
        _ cam: ICCameraDevice,
        attemptID: UUID,
        failIfEmpty: Bool = true
    ) async {
        guard let scope = activeCaptureScope,
              scope.attemptID == attemptID,
              isCurrentCapture(scope, camera: cam) else { return }
        let command = Self.makePTPCommand(
            opcode: 0x1007,
            transactionID: nextPTPTransactionID(),
            parameters: [0xFFFFFFFF, 0, 0xFFFFFFFF]
        )
        let reply = await executePTPCommand(
            cam,
            command: command,
            priority: .capture,
            captureScope: scope
        )
        guard isCurrentCapture(scope, camera: cam) else { return }
        guard reply.errorDescription == nil, reply.responseCode == 0x2001 else {
            NSLog("[DSLR] GetObjectHandles failed: error=%@ resp=0x%04X", reply.errorDescription ?? "none", reply.responseCode)
            if failIfEmpty {
                failCapture(DSLRError.captureFailed("Could not query camera objects"), attemptID: attemptID)
            }
            return
        }
        NSLog("[DSLR] GetObjectHandles returned %d bytes", reply.data.count)
        
        let allHandles = Self.parsePTPObjectHandles(from: reply.data).sorted()
        
        guard let context = captureAttemptContext,
              let cameraIdentifier = stableCameraIdentifier(for: cam),
              context.expectedCameraIdentifier == cameraIdentifier else {
            if failIfEmpty {
                failCapture(DSLRError.captureFailed("Camera identity could not be verified."), attemptID: attemptID)
            }
            return
        }

        let validHandles = allHandles.filter {
            DSLRCaptureAttemptValidator.authorizes(
                .ptpObjectHandle($0),
                context: context,
                cameraIdentifier: cameraIdentifier
            )
        }
        
        guard let lastHandle = validHandles.last else {
            NSLog("[DSLR] GetObjectHandles has no new handles (%d bytes)", reply.data.count)
            if failIfEmpty {
                failCapture(DSLRError.captureFailed("No image was available from the camera"), attemptID: attemptID)
            }
            return
        }
        
        guard connectedCamera === cam else { return }
        NSLog("[DSLR] Downloading last handle=0x%08X", lastHandle)
        await ptpGetObject(
            cam,
            handle: lastHandle,
            candidate: .ptpObjectHandle(lastHandle),
            attemptID: attemptID,
            failIfEmpty: failIfEmpty,
            captureScope: scope
        )
    }

    // Downloads a captured object by handle.
    // Tries GetObjectInfo first to probe IC's interception, then GetObject (0x1009),
    // then GetPartialObject (0x101B) as fallback.
    private func ptpGetObject(
        _ cam: ICCameraDevice,
        handle: UInt32,
        candidate: CaptureMediaCandidate,
        attemptID: UUID,
        failIfEmpty: Bool = true,
        captureScope: DSLRCaptureAttemptScope
    ) async {
        guard isCurrentCapture(captureScope, camera: cam),
              captureScope.attemptID == attemptID,
              isPTPCandidate(candidate, handle: handle),
              isAuthorizedCaptureCandidate(candidate, from: cam, attemptID: attemptID) else { return }
        let priority: PTPCommandPriority = .capture
        NSLog("[DSLR] GetObjectInfo handle=0x%08X", handle)
        let info = await sendPTPRequest(
            cam,
            opcode: 0x1008,
            parameter: handle,
            priority: priority,
            captureScope: captureScope
        )
        NSLog("[DSLR] GetObjectInfo: %d bytes resp=0x%04X", info.data.count, info.responseCode)
        guard isCurrentCapture(captureScope, camera: cam), !Task.isCancelled else { return }
        guard isAuthorizedCaptureCandidate(candidate, from: cam, attemptID: attemptID) else { return }
        NSLog("[DSLR] IC mediaFiles after C201: count=%d", cam.mediaFiles?.count ?? 0)

        let object = await sendPTPRequest(
            cam,
            opcode: 0x1009,
            parameter: handle,
            priority: priority,
            captureScope: captureScope
        )
        NSLog("[DSLR] GetObject response: error=%@ dataLen=%d resp=0x%04X", object.errorDescription ?? "none", object.data.count, object.responseCode)
        guard isCurrentCapture(captureScope, camera: cam), !Task.isCancelled else { return }
        guard isAuthorizedCaptureCandidate(candidate, from: cam, attemptID: attemptID) else { return }
        if !object.data.isEmpty {
            resolveFromData(object.data, candidate: candidate, camera: cam, attemptID: attemptID)
            return
        }
        if !failIfEmpty { return }

        let partialParameters = [handle, 0, 0x00FFFFFF]
        let partial = await executePTPCommand(
            cam,
            command: Self.makePTPCommand(opcode: 0x101B, transactionID: nextPTPTransactionID(), parameters: partialParameters),
            priority: priority,
            captureScope: captureScope
        )
        NSLog("[DSLR] GetPartialObject: error=%@ dataLen=%d resp=0x%04X", partial.errorDescription ?? "none", partial.data.count, partial.responseCode)
        guard isCurrentCapture(captureScope, camera: cam), !Task.isCancelled else { return }
        guard isAuthorizedCaptureCandidate(candidate, from: cam, attemptID: attemptID) else { return }
        if !partial.data.isEmpty {
            resolveFromData(partial.data, candidate: candidate, camera: cam, attemptID: attemptID)
            return
        }
        guard partial.responseCode == 0x201D else {
            failCapture(DSLRError.captureFailed("IC blocks image download"), attemptID: attemptID)
            return
        }

        for attempt in 1...10 {
            try? await Task.sleep(for: .seconds(3))
            guard isCurrentCapture(captureScope, camera: cam), !Task.isCancelled else { return }
            let retry = await executePTPCommand(
                cam,
                command: Self.makePTPCommand(opcode: 0x101B, transactionID: nextPTPTransactionID(), parameters: partialParameters),
                priority: priority,
                captureScope: captureScope
            )
            NSLog("[DSLR] GetPartialObject retry %d/10: dataLen=%d resp=0x%04X", attempt, retry.data.count, retry.responseCode)
            guard isCurrentCapture(captureScope, camera: cam), !Task.isCancelled else { return }
            guard isAuthorizedCaptureCandidate(candidate, from: cam, attemptID: attemptID) else { return }
            if !retry.data.isEmpty {
                resolveFromData(retry.data, candidate: candidate, camera: cam, attemptID: attemptID)
                return
            }
            guard retry.responseCode == 0x201D else { break }
        }
        guard isCurrentCapture(captureScope, camera: cam), !Task.isCancelled else { return }
        NSLog("[DSLR] All download variants exhausted for 0x%08X", handle)
        failCapture(DSLRError.captureFailed("IC blocks image download"), attemptID: attemptID)
    }

    private func resolveFromData(
        _ data: Data,
        candidate: CaptureMediaCandidate,
        camera: ICCameraDevice,
        attemptID: UUID
    ) {
        guard isAuthorizedCaptureCandidate(candidate, from: camera, attemptID: attemptID) else { return }
        func finish(_ image: CGImage, source: CGImageSource, description: String) {
            guard self.isAuthorizedCaptureCandidate(candidate, from: camera, attemptID: attemptID) else { return }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientRaw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let orient = CGImagePropertyOrientation(rawValue: orientRaw) ?? .up
            let final: CGImage
            if orient != .up {
                let ci = CIImage(cgImage: image).oriented(orient)
                final = CIContext().createCGImage(ci, from: ci.extent) ?? image
            } else {
                final = image
            }
            NSLog("[DSLR] resolveFromData: decoded %dx%d %@ from %d bytes",
                  final.width, final.height, description, data.count)
            finishCaptureAttempt(attemptID: attemptID, result: .success(final))
        }

        // Direct JPEG, or a response that still contains a 12-byte PTP data header.
        for slice in [data, Data(data.dropFirst(12))] {
            if let source = CGImageSourceCreateWithData(slice as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                finish(image, source: source, description: "image")
                return
            }
        }

        // RAW PC-save mode: decode every embedded JPEG and choose the
        // highest-resolution preview rather than a small thumbnail.
        var best: (image: CGImage, source: CGImageSource, area: Int)?
        let ranges = Self.embeddedJPEGRanges(in: data)
        for range in ranges {
            let jpeg = data.subdata(in: range)
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            let area = image.width * image.height
            if best == nil || area > best!.area {
                best = (image, source, area)
            }
        }
        if let best {
            finish(best.image, source: best.source,
                   description: "embedded JPEG (\(ranges.count) candidate(s))")
            return
        }

        NSLog("[DSLR] resolveFromData: FAILED to decode %d bytes as JPEG or RAW preview", data.count)
        failCapture(
            DSLRError.captureFailed("Could not decode image received from camera"),
            attemptID: attemptID
        )
    }

    // Send current settings to camera via PTP — best-effort, silently ignored if unsupported
    func applySettings() {
        guard let cam = connectedCamera else { return }
        NSLog("[DSLR] applySettings autoPicture=%d iso=%d flash=%@ cam=%@",
              automaticPictureMode, iso, flashMode.rawValue, cam.name ?? "?")
        let flash = controlSupport.flash ? flashMode.ptpValue : nil
        let setISO = controlSupport.iso && !(isSonyZVE10 && automaticPictureMode)
        let isoValue = UInt16(min(iso, 65535))
        Task { @MainActor [weak self] in
            guard let self, self.connectedCamera === cam else { return }
            if let flash { await self.ptpSet(cam, propCode: 0x500C, value16: flash, label: "Set FlashMode") }
            if setISO { await self.ptpSet(cam, propCode: 0x5005, value16: isoValue, label: "Set ISO") }
        }
        if controlSupport.shutter && !(isSonyZVE10 && automaticPictureMode) {
            // Sony vendor shutter prop (0xD20D) value encoding differs by model and often requires
            // descriptor-driven value tables. Keep UI enabled-state honest, but do not write an
            // unverified encoding that can cause no-op behavior.
            NSLog("[DSLR] Shutter control detected, but value mapping is not configured yet.")
        }
        if !controlSupport.shutter || !controlSupport.aperture {
            var unsupported: [String] = []
            if !controlSupport.shutter { unsupported.append("shutter speed") }
            if !controlSupport.aperture { unsupported.append("aperture") }
            if !unsupported.isEmpty {
                NSLog("[DSLR] Unsupported control(s): %@", unsupported.joined(separator: ", "))
            }
        }
    }

    // MARK: - Download

    private func downloadCapturedFile(
        _ file: ICCameraFile,
        from cam: ICCameraDevice,
        candidate: CaptureMediaCandidate,
        attemptID: UUID
    ) {
        guard candidate == .cameraFile(name: file.name, creationDate: file.creationDate),
              isAuthorizedCaptureCandidate(candidate, from: cam, attemptID: attemptID),
              let scope = activeCaptureScope,
              scope.attemptID == attemptID else { return }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = tempDir.appendingPathComponent("prc_capture_\(attemptID.uuidString).jpg")
        pendingDownloadAttemptID = attemptID
        pendingDownloadGeneration = scope.cameraGeneration
        pendingDownloadFile = file
        pendingDownloadCandidate = candidate
        pendingDownloadURL = url
        let contextID = nextDownloadContextID
        nextDownloadContextID = contextID == Int.max ? 1 : contextID + 1
        pendingDownloadContextID = contextID
        // ImageCaptureCore treats contextInfo as opaque; this token is matched, never dereferenced.
        cam.requestDownloadFile(
            file,
            options: [
                .downloadsDirectoryURL: tempDir,
                .saveAsFilename: url.lastPathComponent,
                .overwrite: true
            ],
            downloadDelegate: self,
            didDownloadSelector: #selector(didFinishDownload(_:didDownloadFile:error:options:contextInfo:)),
            contextInfo: UnsafeMutableRawPointer(bitPattern: contextID)
        )
    }

    @objc nonisolated private func didFinishDownload(
        _ camera: ICCameraDevice,
        didDownloadFile file: ICCameraFile,
        error: Error?,
        options: [String: Any]?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        NSLog("[DSLR] didFinishDownload file=%@ error=%@", file.name ?? "?", error?.localizedDescription ?? "none")
        let downloadedCameraIdentity = ObjectIdentifier(camera)
        let downloadedContextID = contextInfo.map { Int(bitPattern: $0) }
        let downloadedFileName = file.name
        let downloadedFileCreationDate = file.creationDate
        let downloadErrorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self,
                  let attemptID = self.pendingDownloadAttemptID,
                  let candidate = self.pendingDownloadCandidate,
                  let url = self.pendingDownloadURL,
                  let connectedCamera = self.connectedCamera,
                  let generation = self.pendingDownloadGeneration,
                  let pendingContextID = self.pendingDownloadContextID,
                  downloadedContextID == pendingContextID,
                  generation == self.cameraGeneration,
                  ObjectIdentifier(connectedCamera) == downloadedCameraIdentity,
                  self.pendingDownloadFile?.name == downloadedFileName,
                  candidate == .cameraFile(name: downloadedFileName, creationDate: downloadedFileCreationDate),
                  self.isAuthorizedCaptureCandidate(candidate, from: connectedCamera, attemptID: attemptID)
            else { return }
            if let downloadErrorMessage {
                self.finishCaptureAttempt(
                    scope: DSLRCaptureAttemptScope(attemptID: attemptID, cameraGeneration: generation),
                    result: .failure(DSLRError.captureFailed(downloadErrorMessage))
                )
                return
            }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else {
                self.finishCaptureAttempt(
                    scope: DSLRCaptureAttemptScope(attemptID: attemptID, cameraGeneration: generation),
                    result: .failure(DSLRError.captureFailed("Could not decode downloaded image"))
                )
                return
            }
            // Apply EXIF orientation so the compositor sees an up-right image.
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let orientRaw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let orient = CGImagePropertyOrientation(rawValue: orientRaw) ?? .up
            let final: CGImage
            if orient != .up {
                let ci = CIImage(cgImage: img).oriented(orient)
                final = CIContext().createCGImage(ci, from: ci.extent) ?? img
            } else {
                final = img
            }
            try? FileManager.default.removeItem(at: url)
            self.finishCaptureAttempt(
                scope: DSLRCaptureAttemptScope(attemptID: attemptID, cameraGeneration: generation),
                result: .success(final)
            )
        }
    }

    private func finishCaptureAttempt(scope: DSLRCaptureAttemptScope, result: AttemptTerminalResult) {
        guard activeCaptureAttemptID == scope.attemptID,
              activeCaptureScope == scope,
              cameraGeneration == scope.cameraGeneration,
              let control = activeCaptureControl,
              control.resolve(scope) else { return }
        ptpCommandLane.cancel(
            scope: DSLRCameraPTPScope(
                attemptID: scope.attemptID,
                cameraGeneration: scope.cameraGeneration
            )
        )
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        capturePreparationTask?.cancel()
        capturePreparationTask = nil
        pendingCapturePollTask?.cancel()
        pendingCapturePollTask = nil
        pendingDownloadAttemptID = nil
        pendingDownloadGeneration = nil
        pendingDownloadContextID = nil
        pendingDownloadFile = nil
        pendingDownloadCandidate = nil
        pendingDownloadURL = nil
        expectingCapture = false
        fallbackTakePictureIssued = false
        isCapturing = false
        switch result {
        case .success:
            captureAttemptContexts.finish(succeeded: true)
        case .failure:
            captureAttemptContexts.finish(succeeded: false)
        }
        activeCaptureAttemptID = nil
        activeCaptureScope = nil
        activeCaptureControl = nil

        let completion = captureCompletion
        captureCompletion = nil
        switch result {
        case .success(let image):
            lastCapturedImage = image
            completion?.resume(returning: image)
        case .failure(let error):
            completion?.resume(throwing: error)
        }
    }

    private func finishCaptureAttempt(attemptID: UUID, result: AttemptTerminalResult) {
        guard let scope = activeCaptureScope, scope.attemptID == attemptID else { return }
        finishCaptureAttempt(scope: scope, result: result)
    }

    private func failCapture(_ error: Error, attemptID: UUID) {
        finishCaptureAttempt(attemptID: attemptID, result: .failure(error))
    }

    private func failCapture(_ error: Error, scope: DSLRCaptureAttemptScope) {
        finishCaptureAttempt(scope: scope, result: .failure(error))
    }

    private func cancelCaptureAttempt(_ scope: DSLRCaptureAttemptScope) {
        guard activeCaptureScope == scope,
              let control = activeCaptureControl else { return }
        _ = control.cancel(scope)
        if busyRejection,
           !fallbackTakePictureIssued,
           !control.shutterMayHaveBeenIssued(for: scope) {
            captureAttemptContexts.invalidate()
        }
        ptpCommandLane.cancel(
            scope: DSLRCameraPTPScope(
                attemptID: scope.attemptID,
                cameraGeneration: scope.cameraGeneration
            )
        )
        let message = control.shutterMayHaveBeenIssued(for: scope)
            ? "Capture was cancelled after a shutter command. The photo may have been taken; retry receiving before taking another photo."
            : "Capture was cancelled before the shutter was confirmed."
        finishCaptureAttempt(scope: scope, result: .failure(DSLRError.captureFailed(message)))
    }

    // MARK: - PTP

    private func ptpSet(_ cam: ICCameraDevice, propCode: UInt16, value16: UInt16, label: String) async {
        var data = Data(count: 2)
        data.withUnsafeMutableBytes { $0.storeBytes(of: value16.littleEndian, as: UInt16.self) }
        await ptpSetProp(cam, propCode: propCode, data: data, label: label)
    }

    private func ptpSet(_ cam: ICCameraDevice, propCode: UInt16, value32: UInt32, label: String) async {
        var data = Data(count: 4)
        data.withUnsafeMutableBytes { $0.storeBytes(of: value32.littleEndian, as: UInt32.self) }
        await ptpSetProp(cam, propCode: propCode, data: data, label: label)
    }

    private func ptpSetProp(_ cam: ICCameraDevice, propCode: UInt16, data: Data, label: String) async {
        // PTP SetDevicePropValue (0x1016): 16-byte command block + data phase
        let command = Self.makePTPCommand(opcode: 0x1016, transactionID: nextPTPTransactionID(), parameters: [UInt32(propCode)])
        let reply = await executePTPCommand(cam, command: command, outData: data)
        if let error = reply.errorDescription { onError?(DSLRError.settingFailed(error)); return }
        if reply.responseCode == 0 {
            NSLog("[DSLR] %@ response was empty/inconclusive (prop=0x%04X) — keeping previous value", label, propCode)
        } else if reply.responseCode != 0x2001 {
            let message = String(format: "%@ failed (prop=0x%04X, resp=0x%04X)", label, propCode, reply.responseCode)
            NSLog("[DSLR] %@", message)
            onError?(DSLRError.settingFailed(message))
        } else {
            NSLog("[DSLR] %@ ok (prop=0x%04X)", label, propCode)
        }
    }

    private func fileExt(_ name: String?) -> String {
        URL(fileURLWithPath: name ?? "").pathExtension.lowercased()
    }

    nonisolated static func isNewCaptureMediaFile(named name: String?, cataloged: Set<String>) -> Bool {
        name.map { !cataloged.contains($0) } ?? true
    }

    // Fallback when Sony does not emit ObjectAdded/C202 reliably.
    private func tryDownloadFreshestMediaFile(from cam: ICCameraDevice, scope: DSLRCaptureAttemptScope) -> Bool {
        guard isCurrentCapture(scope, camera: cam), expectingCapture,
              captureAttemptContext != nil else { return false }
        let all = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        guard !all.isEmpty else { return false }

        let fresh = all.filter { file in
            isAuthorizedCaptureCandidate(
                .cameraFile(name: file.name, creationDate: file.creationDate),
                from: cam,
                attemptID: scope.attemptID
            )
        }
        guard !fresh.isEmpty else { return false }

        let jpegExts: Set<String> = ["jpg", "jpeg"]
        let sorted = fresh.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        guard let file = sorted.first(where: { jpegExts.contains(fileExt($0.name)) }) ?? sorted.first else {
            return false
        }

        NSLog("[DSLR] Fallback catalog download: %@ (created=%@)", file.name ?? "?", String(describing: file.creationDate))
        expectingCapture = false
        downloadCapturedFile(
            file,
            from: cam,
            candidate: .cameraFile(name: file.name, creationDate: file.creationDate),
            attemptID: scope.attemptID
        )
        return true
    }

    private func tryDownloadLatestMediaFile(from cam: ICCameraDevice, scope: DSLRCaptureAttemptScope) -> Bool {
        tryDownloadFreshestMediaFile(from: cam, scope: scope)
    }

    private func triggerICCaptureFallback(reason: String, scope: DSLRCaptureAttemptScope) {
        guard let cam = connectedCamera,
              let control = activeCaptureControl,
              isCurrentCapture(scope, camera: cam),
              !fallbackTakePictureIssued,
              recordShutterIssued(at: Date(), scope: scope) else { return }
        fallbackTakePictureIssued = true
        expectingCapture = true
        NSLog("[DSLR] Triggering requestTakePicture fallback (%@)", reason)
        guard control.performIfCurrent(scope, action: { cam.requestTakePicture() }) else {
            control.confirmShutterWasNotDispatched(scope)
            fallbackTakePictureIssued = false
            expectingCapture = false
            return
        }
    }

    private func notePTPHealth(dataLen: Int, responseCode: UInt16) {
        if responseCode != 0 || dataLen > 0 {
            ptpHealthy = true
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension DSLRCameraSource: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        let id = cam.uuidString ?? cam.name ?? UUID().uuidString
        let name = cam.name ?? "Unknown Camera"
        NSLog("[DSLR] deviceBrowser didAdd: %@ caps=%@", name, cam.capabilities.description)
        camerasByID[id] = cam
        if !availableDevices.contains(where: { $0.id == id }) {
            availableDevices.append(CameraDeviceInfo(id: id, name: name, kind: .dslr))
        }
        if selectedDeviceID == nil { selectedDeviceID = id }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        let id = cam.uuidString ?? cam.name ?? ""
        camerasByID.removeValue(forKey: id)
        availableDevices.removeAll { $0.id == id }
        if selectedDeviceID == id { selectedDeviceID = availableDevices.first?.id }
        if connectedCamera === cam {
            let disconnectedGeneration = cameraGeneration
            let identity = ObjectIdentifier(cam)
            let staleGenerations = pendingPTPSessionCloses
                .filter { $0.cameraIdentity == identity }
                .map(\.generation)
            if let scope = activeCaptureScope {
                finishCaptureAttempt(
                    scope: scope,
                    result: .failure(DSLRError.cameraDisconnected)
                )
            }
            captureAttemptContexts.invalidate()
            stopSonyLiveView()
            pollTask?.cancel()
            pollTask = nil
            connectedCamera = nil
            cameraGeneration &+= 1
            pendingPTPSessionCloses.removeAll { $0.cameraIdentity == identity }
            for generation in Set(staleGenerations + [disconnectedGeneration]) {
                ptpCommandLane.cancel(cameraGeneration: generation, reason: .disconnected)
                ptpCommandLane.retire(cameraGeneration: generation)
            }
            isRunning = false
            isConnecting = false
            ptpHealthy = false
            controlSupport = DSLRControlSupport()
            onConnectionStateChanged?()
            onError?(DSLRError.cameraDisconnected)
        }
    }
}

// MARK: - ICCameraDeviceDelegate

extension DSLRCameraSource: @preconcurrency ICCameraDeviceDelegate {
    // New file appeared on camera — triggered after requestTakePicture (and during initial SD card cataloging)
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let files = items.compactMap { $0 as? ICCameraFile }
        NSLog("[DSLR] cameraDevice didAdd %d items (expectingCapture=%d): %@",
              files.count, expectingCapture ? 1 : 0,
              files.map { "\($0.name ?? "?") date=\(String(describing: $0.creationDate))" }.joined(separator: ", "))
        guard expectingCapture,
              let attemptID = activeCaptureAttemptID,
              connectedCamera === camera else { return }

        let freshFiles = files.filter { file in
            isAuthorizedCaptureCandidate(
                .cameraFile(name: file.name, creationDate: file.creationDate),
                from: camera,
                attemptID: attemptID
            )
        }
        NSLog("[DSLR] fresh files: %d", freshFiles.count)

        let jpegExts: Set<String> = ["jpg", "jpeg"]
        guard let file = freshFiles.first(where: { jpegExts.contains(fileExt($0.name)) }) ?? freshFiles.first
        else { return }
        NSLog("[DSLR] downloading: %@", file.name ?? "?")
        expectingCapture = false
        downloadCapturedFile(
            file,
            from: camera,
            candidate: .cameraFile(name: file.name, creationDate: file.creationDate),
            attemptID: attemptID
        )
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) { }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // ICCameraDevice calls this on its own internal thread — use nonisolated + dispatch to MainActor
        guard eventData.count >= 12 else { return }
        let code = Self.ptpUInt16(eventData, at: 6) ?? 0
        let handle = Self.ptpUInt32(eventData, at: 12) ?? 0xFFFFFFFF
        let param1 = Self.ptpUInt32(eventData, at: 12) ?? 0
        let eventCameraIdentity = ObjectIdentifier(camera)
        NSLog("[DSLR] PTP event 0x%04X param=0x%08X (%d bytes)", code, param1, eventData.count)
        Task { @MainActor [weak self] in
            guard let self,
                  let cam = self.connectedCamera,
                  ObjectIdentifier(cam) == eventCameraIdentity else { return }
            let eventGeneration = self.cameraGeneration
            NSLog("[DSLR] PTP event 0x%04X (expectingCapture=%d)", code, self.expectingCapture ? 1 : 0)
            // ObjectAdded: standard (0x4002) or Sony vendor (0xC201)
            if (code == 0x4002 || code == 0xC201) && self.expectingCapture {
                guard let scope = self.activeCaptureScope,
                      scope.cameraGeneration == eventGeneration,
                      self.isAuthorizedCaptureCandidate(
                          .ptpObjectHandle(handle),
                          from: cam,
                          attemptID: scope.attemptID
                      ) else { return }
                NSLog("[DSLR] ObjectAdded handle=0x%08X → pausing status work, waiting 1s then ptpGetObject", handle)
                self.expectingCapture = false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard self.connectedCamera === cam,
                          self.cameraGeneration == eventGeneration,
                          self.isCurrentCapture(scope, camera: cam),
                          self.isAuthorizedCaptureCandidate(
                              .ptpObjectHandle(handle),
                              from: cam,
                              attemptID: scope.attemptID
                          ) else { return }
                    await self.ptpGetObject(
                        cam,
                        handle: handle,
                        candidate: .ptpObjectHandle(handle),
                        attemptID: scope.attemptID,
                        captureScope: scope
                    )
                }
                return
            }
            // Sony DevicePropChanged (0xC202). ObjectInMemory (0xD215) signals
            // that a PC-save capture is becoming available at the fixed RAM handle.
            // Other property changes (focus, exposure, etc.) must not consume the
            // pending capture.
            if code == 0xC202 && param1 == 0xD215 && self.expectingCapture {
                guard let scope = self.activeCaptureScope,
                      scope.cameraGeneration == eventGeneration,
                      self.activeCaptureAttemptID == scope.attemptID,
                      self.captureAttemptContext?.shutterIssuedAt != nil else { return }
                NSLog("[DSLR] Sony ObjectInMemory changed → checking transition proof")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard self.connectedCamera === cam,
                          self.cameraGeneration == eventGeneration,
                          self.isCurrentCapture(scope, camera: cam) else { return }
                    _ = await self.ptpSonyGetAllDevicePropDesc(cam, captureAttemptID: scope.attemptID)
                }
                return
            }
            // 0xC203 = Sony status update — requires GetAllDevicePropDesc response to advance camera state
            if code == 0xC203 &&
                !self.suppressStatusPoll &&
                !self.isCapturing &&
                !self.isRequestingLiveViewFrame {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.connectedCamera === cam,
                          self.cameraGeneration == eventGeneration else { return }
                    await self.ptpSonyGetAllDevicePropDesc(cam)
                }
            }
        }
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        NSLog("[DSLR] catalog complete — %@, %d items on card", device.name ?? "?", device.mediaFiles?.count ?? 0)
        guard connectedCamera === device else { return }
        captureAttemptContexts.cameraCatalogDidComplete(
            identifier: stableCameraIdentifier(for: device)
        )
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) { }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) { }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        NSLog("[DSLR] didOpenSession device=%@ error=%@", device.name ?? "?", error?.localizedDescription ?? "none")
        guard let cam = device as? ICCameraDevice else { isConnecting = false; return }
        guard connectedCamera === cam else { return }
        if let error {
            let failedGeneration = cameraGeneration
            if let scope = activeCaptureScope, scope.cameraGeneration == failedGeneration {
                finishCaptureAttempt(
                    scope: scope,
                    result: .failure(DSLRError.cameraDisconnected)
                )
            }
            isConnecting = false
            connectedCamera = nil
            cameraGeneration &+= 1
            ptpCommandLane.cancel(cameraGeneration: failedGeneration, reason: .disconnected)
            ptpCommandLane.retire(cameraGeneration: failedGeneration)
            isRunning = false
            onConnectionStateChanged?()
            let msg = "Could not open camera session: \(error.localizedDescription). "
                    + "Quit Image Capture.app and Photos.app, ensure the ZV-E10 is in PC Remote mode "
                    + "(Setup → USB Connection → PC Remote), then reconnect."
            onError?(DSLRError.captureFailed(msg))
            return
        }
        captureAttemptContexts.cameraSessionDidOpen(
            identifier: stableCameraIdentifier(for: cam)
        )
        // isConnecting stays true through the full Sony handshake so the UI's "Connecting…"
        // state covers it, not just the IC session-open call.
        let openedGeneration = cameraGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ptpHealthy = false
            self.lastStatusPollAt = .distantPast
            await self.ptpSonyInit(cam, generation: openedGeneration)   // Sony SDIO vendor init — must precede capture commands
            guard self.connectedCamera === cam,
                  self.cameraGeneration == openedGeneration,
                  !Task.isCancelled else { return }
            self.isRunning = true
            self.isConnecting = false
            self.startSonyLiveView(cam)
            self.startPollLoop(cam)
            self.onConnectionStateChanged?()
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard let cam = device as? ICCameraDevice else { return }
        let identity = ObjectIdentifier(cam)
        let pendingCloseIndex = pendingPTPSessionCloses.firstIndex { $0.cameraIdentity == identity }
        let closingGeneration: UInt64
        if let pendingCloseIndex {
            closingGeneration = pendingPTPSessionCloses.remove(at: pendingCloseIndex).generation
        } else if connectedCamera === cam {
            closingGeneration = cameraGeneration
        } else {
            return
        }
        if let scope = activeCaptureScope, scope.cameraGeneration == closingGeneration {
            finishCaptureAttempt(
                scope: scope,
                result: .failure(DSLRError.cameraDisconnected)
            )
        }
        ptpCommandLane.cancel(cameraGeneration: closingGeneration, reason: .disconnected)
        ptpCommandLane.retire(cameraGeneration: closingGeneration)
        guard connectedCamera === cam, cameraGeneration == closingGeneration else { return }
        captureAttemptContexts.cameraDidDisconnect(
            identifier: stableCameraIdentifier(for: cam)
        )
        stopSonyLiveView()
        pollTask?.cancel(); pollTask = nil
        ptpHealthy = false
        NSLog("[DSLR] didCloseSession error=%@ reopen=%d", error?.localizedDescription ?? "none", reopenAfterClose ? 1 : 0)
        if reopenAfterClose, let cam = connectedCamera {
            reopenAfterClose = false
            cameraGeneration &+= 1
            NSLog("[DSLR] Reopening IC session to reset D2CA state")
            cam.requestOpenSession()
        } else {
            connectedCamera = nil
            cameraGeneration &+= 1
            isConnecting = false
            isRunning = false
            onConnectionStateChanged?()
        }
    }
    func didRemove(_ device: ICDevice) {
        guard let cam = device as? ICCameraDevice, connectedCamera === cam else { return }
        let disconnectedGeneration = cameraGeneration
        let identity = ObjectIdentifier(cam)
        let staleGenerations = pendingPTPSessionCloses
            .filter { $0.cameraIdentity == identity }
            .map(\.generation)
        captureAttemptContexts.cameraDidDisconnect(
            identifier: stableCameraIdentifier(for: cam)
        )
        if let scope = activeCaptureScope {
            finishCaptureAttempt(
                scope: scope,
                result: .failure(DSLRError.cameraDisconnected)
            )
        }
        stopSonyLiveView()
        pollTask?.cancel(); pollTask = nil
        connectedCamera = nil
        cameraGeneration &+= 1
        pendingPTPSessionCloses.removeAll { $0.cameraIdentity == identity }
        for generation in Set(staleGenerations + [disconnectedGeneration]) {
            ptpCommandLane.cancel(cameraGeneration: generation, reason: .disconnected)
            ptpCommandLane.retire(cameraGeneration: generation)
        }
        isRunning = false
        isConnecting = false
        ptpHealthy = false
        controlSupport = DSLRControlSupport()
        onConnectionStateChanged?()
        onError?(DSLRError.cameraDisconnected)
    }
}

// MARK: - ICCameraDeviceDownloadDelegate

extension DSLRCameraSource: ICCameraDeviceDownloadDelegate { }

// MARK: - Errors

enum DSLRError: LocalizedError {
    case noCamera
    case cameraDisconnected
    case captureFailed(String)
    case settingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No tethered camera found. Connect via USB and set the camera to PC Remote mode (Sony ZV-E10: Setup → USB Connection → PC Remote)."
        case .cameraDisconnected: return "Camera disconnected"
        case .captureFailed(let msg): return "Capture failed: \(msg)"
        case .settingFailed(let msg): return "Setting failed: \(msg)"
        }
    }
}
