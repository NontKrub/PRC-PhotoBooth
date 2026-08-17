import Foundation
import CoreGraphics
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Observation

@MainActor
@Observable
final class CaptureService {
    let camera: AVFoundationCameraSource   // always used for preview
    let dslr: DSLRCameraSource             // used for still capture when usesDSLR == true
#if DEBUG
    let demoCamera = DemoCameraSource()
    private var demoFailures: [Int: DemoCaptureFailure] = [:]
    private var pendingDemoRecoveryImage: CGImage?
#endif
    private var lastCaptureImage: CGImage?
    private(set) var demoPreviewImage: CGImage?
    private(set) var lastCaptureAt: Date?
    private(set) var lastCaptureDuration: Double?
    private(set) var lastCaptureError: String?
    private(set) var captureSuccessCount = 0
    private(set) var captureFailureCount = 0
    private(set) var recoveredTransferCount = 0

    var usesDSLR = false
    var demoMode = false
    var captureRotationDegrees: Int = 0
    var onPreviewJPEG: (@MainActor (Data) -> Void)?
    private(set) var capturedStills: [Int: CGImage] = [:]
    private(set) var isRunning = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init() {
        camera = AVFoundationCameraSource()
        dslr = DSLRCameraSource()
#if DEBUG
        configureDemoFailures()
#endif
        camera.onPreviewJPEG = { [weak self] jpeg in
            Task { @MainActor [weak self] in
                guard let self, !self.usesDSLR else { return }
                self.onPreviewJPEG?(jpeg)
            }
        }
        dslr.onPreviewJPEG = { [weak self] jpeg in
            guard let self, self.usesDSLR else { return }
            self.onPreviewJPEG?(jpeg)
        }
    }

    func start() throws {
#if DEBUG
        if demoMode {
            demoCamera.onPreviewJPEG = { [weak self] jpeg in
                if let source = CGImageSourceCreateWithData(jpeg as CFData, nil) {
                    self?.demoPreviewImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                }
                self?.onPreviewJPEG?(jpeg)
            }
            try demoCamera.start()
            isRunning = true
            return
        }
#endif
        try camera.start()
        isRunning = true
    }

    func stop() {
#if DEBUG
        if demoMode {
            demoCamera.stop()
        }
#endif
        camera.stop()
        if dslr.isRunning { dslr.stop() }
        isRunning = false
    }

    func startDSLR() throws {
        try dslr.start()
    }

    func stopDSLR() {
        dslr.stop()
    }

    func setPreviewFrameRate(_ framesPerSecond: Int) {
        camera.setPreviewFrameRate(framesPerSecond)
        dslr.setPreviewFrameRate(framesPerSecond)
    }

    func setPreviewQuality(_ profile: PreviewQualityProfile) {
        camera.setPreviewQuality(profile)
        // Sony live-view JPEGs stay at the camera's native dimensions; only its
        // polling rate follows the selected transport profile.
        dslr.setPreviewFrameRate(profile.defaultFramesPerSecond)
    }

    func captureStill(for photoIndex: Int) async throws -> CGImage {
        let startedAt = Date()
        do {
        var image: CGImage
#if DEBUG
        if demoMode {
            if let failure = demoFailures.removeValue(forKey: photoIndex) {
                // Simulate a fired shutter with an image that remains recoverable.
                pendingDemoRecoveryImage = try await demoCamera.captureStill()
                throw failure
            }
            image = try await demoCamera.captureStill()
        } else {
            if usesDSLR {
            guard dslr.isRunning else {
                throw DSLRError.captureFailed("DSLR is selected but not connected yet.")
            }
            image = try await dslr.captureStill()
            } else {
                image = try await camera.captureStill()
            }
        }
#else
        if usesDSLR {
            guard dslr.isRunning else {
                throw DSLRError.captureFailed("DSLR is selected but not connected yet.")
            }
            image = try await dslr.captureStill()
        } else {
            image = try await camera.captureStill()
        }
#endif
        if captureRotationDegrees != 0 {
            image = rotated(image, by: captureRotationDegrees) ?? image
        }
        capturedStills[photoIndex] = image
        lastCaptureImage = image
        lastCaptureAt = Date()
        lastCaptureDuration = Date().timeIntervalSince(startedAt)
        lastCaptureError = nil
        captureSuccessCount += 1
        return image
        } catch {
            lastCaptureAt = Date()
            lastCaptureDuration = Date().timeIntervalSince(startedAt)
            lastCaptureError = error.localizedDescription
            captureFailureCount += 1
            throw error
        }
    }

    func recoverLastCapture() async throws -> CGImage {
        let startedAt = Date()
        do {
#if DEBUG
        if demoMode {
            guard let image = pendingDemoRecoveryImage ?? lastCaptureImage else {
                throw DSLRError.captureFailed("No recoverable image is available.")
            }
            pendingDemoRecoveryImage = nil
            return image
        }
#endif
        guard usesDSLR else {
            throw DSLRError.captureFailed("The selected camera has no pending transfer to recover.")
        }
        var image = try await dslr.recoverLastCapture()
        if captureRotationDegrees != 0 {
            image = rotated(image, by: captureRotationDegrees) ?? image
        }
        lastCaptureImage = image
        lastCaptureAt = Date()
        lastCaptureDuration = Date().timeIntervalSince(startedAt)
        lastCaptureError = nil
        recoveredTransferCount += 1
        return image
        } catch {
            lastCaptureAt = Date()
            lastCaptureDuration = Date().timeIntervalSince(startedAt)
            lastCaptureError = error.localizedDescription
            throw error
        }
    }

    func storeStill(_ image: CGImage, for photoIndex: Int) {
        capturedStills[photoIndex] = image
        lastCaptureImage = image
    }

    func captureDiagnosticStill() async throws -> CGImage {
        var image: CGImage
#if DEBUG
        if demoMode {
            image = try await demoCamera.captureStill()
        } else {
            if dslr.isRunning {
                image = try await dslr.captureStill()
            } else {
                image = try await camera.captureStill()
            }
        }
#else
        if dslr.isRunning {
            image = try await dslr.captureStill()
        } else {
            image = try await camera.captureStill()
        }
#endif
        if captureRotationDegrees != 0 {
            image = rotated(image, by: captureRotationDegrees) ?? image
        }
        return image
    }

    private func rotated(_ image: CGImage, by degrees: Int) -> CGImage? {
        let angle = -CGFloat(degrees) * .pi / 180
        let ci = CIImage(cgImage: image)
        let r = ci.transformed(by: CGAffineTransform(rotationAngle: angle))
        let n = r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
        return ciContext.createCGImage(n, from: n.extent)
    }

    func drainBufferForGIF() -> [CGImage] {
#if DEBUG
        if demoMode {
            return DemoImageFactory.gifFrames(for: demoCamera.availableDevices.count)
        }
#endif
        // Sony live view is delivered through ImageCaptureCore, not the
        // AVFoundation preview stream, so use the active source's buffer.
        if usesDSLR {
            return dslr.rollingBuffer.drain(lastSeconds: 5)
        }
        return camera.rollingBuffer.drain(lastSeconds: 5)
    }

    func resetStills() {
        capturedStills = [:]
        lastCaptureImage = nil
#if DEBUG
        pendingDemoRecoveryImage = nil
#endif
    }

    func restoreStills(_ images: [Int: CGImage]) {
        capturedStills = images
    }

    func thumbnail(for cgImage: CGImage, maxDim: Int = 200) -> Data? {
        let scale = min(1.0, Double(maxDim) / Double(max(cgImage.width, cgImage.height)))
        let w = Int(Double(cgImage.width) * scale)
        let h = Int(Double(cgImage.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: CGSize(width: w, height: h)))
        guard let thumb = ctx.makeImage() else { return nil }
        return jpegData(from: thumb, quality: 0.6)
    }
}

#if DEBUG
struct DemoCaptureFailure: LocalizedError {
    let reason: CaptureFailureReason
    var errorDescription: String? { "Demo capture failure: \(reason.rawValue)" }
}

private extension CaptureService {
    func configureDemoFailures() {
        let arguments = ProcessInfo.processInfo.arguments
        let settings: [(String, CaptureFailureReason)] = [
            ("--demo-capture-fail-once=", .transferTimeout),
            ("--demo-capture-transfer-timeout=", .transferTimeout),
            ("--demo-camera-disconnect-on=", .cameraDisconnected),
            ("--demo-capture-decode-failure=", .decodeFailed)
        ]
        for (prefix, reason) in settings {
            for argument in arguments where argument.hasPrefix(prefix) {
                guard let index = Int(argument.dropFirst(prefix.count)), index >= 0 else { continue }
                demoFailures[index] = DemoCaptureFailure(reason: reason)
            }
        }
    }
}
#endif

// MARK: - JPEG encode helper (used by CaptureService and AVFoundationCameraSource)

func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}
