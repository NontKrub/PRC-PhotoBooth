import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

private enum PreviewStreamFormat {
    // 640 px is noticeably soft when it fills a Retina iPad. Keep this below
    // the camera's full frame while preserving enough detail for a large kiosk.
    static let maxDimension: CGFloat = 1_280
    static let jpegQuality: CGFloat = 0.7
}

private final class ThreadSafeCIContext: @unchecked Sendable {
    let value = CIContext(options: [.useSoftwareRenderer: false])
}

private final class PreviewFrameThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var minimumInterval: TimeInterval
    private var lastPublishedAt: TimeInterval = -.infinity

    init(maxFPS: Double) {
        minimumInterval = 1 / maxFPS
    }

    func shouldPublishPreview(at time: TimeInterval = CACurrentMediaTime()) -> Bool {
        lock.withLock {
            guard time - lastPublishedAt >= minimumInterval else { return false }
            lastPublishedAt = time
            return true
        }
    }

    func setMaxFPS(_ maxFPS: Double) {
        precondition(maxFPS > 0)
        lock.withLock {
            minimumInterval = 1 / maxFPS
            lastPublishedAt = -.infinity
        }
    }
}

@MainActor
@Observable
final class AVFoundationCameraSource: NSObject, CameraSource {
    private(set) var isRunning = false
    private(set) var availableDevices: [CameraDeviceInfo] = []
    var selectedDeviceID: String? {
        didSet {
            guard selectedDeviceID != oldValue, isRunning else { return }
            restart()
        }
    }
    var onError: ((Error) -> Void)?

    // Callback with compressed JPEG (Data: Sendable) — emitted from sample-buffer delegate
    var onPreviewJPEG: ((Data) -> Void)?

    // Flash mode applied at capture time (most webcams return empty supportedFlashModes)
    var flashMode: AVCaptureDevice.FlashMode = .off
    var isMirrored = false

    var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var stillContinuation: CheckedContinuation<CGImage, Error>?
    private var requestedPreviewFramesPerSecond = 30

    // rollingBuffer is NSLock-guarded internally — safe to share across threads
    let rollingBuffer = RollingVideoBuffer(windowSeconds: 8, maxFPS: 15)
    // CIContext is thread-safe; the nonisolated delegate uses this immutable instance for preview rendering.
    nonisolated private let ciContext = ThreadSafeCIContext()
    // Keep preview updates at the selected rate, independent of the camera's
    // native frame rate (which can be 30 or 60 FPS).
    nonisolated private let previewFrameThrottle = PreviewFrameThrottle(maxFPS: 30)

    private let sampleQueue = DispatchQueue(label: "com.nont.camera.sample", qos: .userInitiated)

    override init() {
        super.init()
        refreshDeviceList()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDeviceList() }
            }
        }
    }

    private func restart() {
        stop()
        do { try start() } catch { onError?(error) }
    }

    func setPreviewFrameRate(_ framesPerSecond: Int) {
        requestedPreviewFramesPerSecond = max(1, framesPerSecond)
        previewFrameThrottle.setMaxFPS(Double(requestedPreviewFramesPerSecond))
        configurePreviewFrameRate()
    }

    private func configurePreviewFrameRate() {
        guard let device = activeDevice else { return }
        let requestedRate = Double(requestedPreviewFramesPerSecond)
        let preferredFormat = device.formats
            .filter { format in
                format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= requestedRate && $0.maxFrameRate >= requestedRate
                }
            }
            .filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return max(dimensions.width, dimensions.height) >= Int32(PreviewStreamFormat.maxDimension)
            }
            .min { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int64(l.width) * Int64(l.height) < Int64(r.width) * Int64(r.height)
            }

        guard let format = preferredFormat else {
            NSLog("[Camera] No %@ FPS format at %@ px or higher; keeping the active format.",
                  String(requestedPreviewFramesPerSecond), String(Int(PreviewStreamFormat.maxDimension)))
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(requestedPreviewFramesPerSecond))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            NSLog("[Camera] Could not set %@ FPS preview: %@",
                  String(requestedPreviewFramesPerSecond), error.localizedDescription)
        }
    }

    // CameraSource — preview frame unused; JPEG path used directly
    var onPreviewFrame: ((CVPixelBuffer) -> Void)? {
        get { nil }
        set { }
    }

    func refreshDeviceList() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        availableDevices = discovery.devices.map {
            let kind: CameraDeviceInfo.Kind = $0.deviceType == .builtInWideAngleCamera ? .builtIn
                : $0.deviceType == .continuityCamera ? .continuityCamera : .usb
            return CameraDeviceInfo(id: $0.uniqueID, name: $0.localizedName, kind: kind)
        }
        if selectedDeviceID == nil { selectedDeviceID = availableDevices.first?.id }
    }

    // MARK: - Continuity Camera controls (torch / EV)

    private var activeDevice: AVCaptureDevice?
    var torchOn = false { didSet { applyTorch() } }
    // ponytail: AVCaptureDevice.exposureTargetBias is iOS-only (API_UNAVAILABLE(macos) in the SDK).
    // macOS 15's real replacement (AVCaptureSystemExposureBiasSlider) is a system-rendered hardware
    // control widget, not an embeddable UI slider, and its Continuity Camera support is unverifiable
    // here — so EV is a software brightness adjustment (CIExposureAdjust) applied at capture time
    // instead of true sensor-level exposure control. Upgrade to the real API if Apple exposes a
    // plain settable property on macOS, or if system-control wiring is worth the complexity later.
    var exposureEV: Float = 0

    var isContinuityCamera: Bool { activeDevice?.deviceType == .continuityCamera }
    var hasTorch: Bool { activeDevice?.hasTorch ?? false }

    private func applyTorch() {
        guard let device = activeDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchOn ? .on : .off
            device.unlockForConfiguration()
        } catch { NSLog("[Camera] torch lock failed: \(error)") }
    }

    func start() throws {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let deviceID = selectedDeviceID,
              let device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .video)
        else { throw CameraError.noDevice }
        activeDevice = device
        configurePreviewFrameRate()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configFailed }
        session.addInput(input)

        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.setSampleBufferDelegate(self, queue: sampleQueue)
        videoOut.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOut) else { throw CameraError.configFailed }
        session.addOutput(videoOut)

        let photoOut = AVCapturePhotoOutput()
        guard session.canAddOutput(photoOut) else { throw CameraError.configFailed }
        session.addOutput(photoOut)

        captureSession = session
        photoOutput = photoOut
        session.startRunning()
        isRunning = true
    }

    func stop() {
        if torchOn { torchOn = false }
        captureSession?.stopRunning()
        isRunning = false
        activeDevice = nil
    }

    func captureStill() async throws -> CGImage {
        guard let photoOutput, let captureSession, captureSession.isRunning else {
            throw CameraError.notRunning
        }
        let raw = try await withCheckedThrowingContinuation { continuation in
            self.stillContinuation = continuation
            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        guard isMirrored || exposureEV != 0 else { return raw }
        var ci = CIImage(cgImage: raw)
        if isMirrored {
            let flip = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -ci.extent.width, y: 0)
            ci = ci.transformed(by: flip)
        }
        if exposureEV != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = ci
            filter.ev = exposureEV
            ci = filter.outputImage ?? ci
        }
        return ciContext.value.createCGImage(ci, from: ci.extent) ?? raw
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension AVFoundationCameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        rollingBuffer.append(pixelBuffer)

        guard previewFrameThrottle.shouldPublishPreview() else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1.0, PreviewStreamFormat.maxDimension / max(ciImage.extent.width, ciImage.extent.height))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.value.createCGImage(scaled, from: scaled.extent),
              let jpeg = jpegData(from: cgImage, quality: PreviewStreamFormat.jpegQuality)
        else { return }

        Task { @MainActor [weak self] in self?.onPreviewJPEG?(jpeg) }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension AVFoundationCameraSource: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            Task { @MainActor [weak self] in
                self?.stillContinuation?.resume(throwing: error)
                self?.stillContinuation = nil
            }
            return
        }
        let rawData = photo.fileDataRepresentation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { stillContinuation = nil }
            guard let data = rawData,
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let raw = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else {
                stillContinuation?.resume(throwing: CameraError.captureDataMissing)
                return
            }
            // CGImageSourceCreateImageAtIndex strips EXIF orientation, so apply it manually.
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
            let exifRaw = props?[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
            let img: CGImage
            if exifRaw != 1, let orientation = CGImagePropertyOrientation(rawValue: exifRaw) {
                let ci = CIImage(cgImage: raw).oriented(orientation)
                img = ciContext.value.createCGImage(ci, from: ci.extent) ?? raw
            } else {
                img = raw
            }
            stillContinuation?.resume(returning: img)
        }
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case noDevice, configFailed, notRunning, captureDataMissing
    var errorDescription: String? {
        switch self {
        case .noDevice:           return "No camera device found"
        case .configFailed:       return "Camera configuration failed"
        case .notRunning:         return "Camera is not running"
        case .captureDataMissing: return "Failed to get image data from capture"
        }
    }
}
