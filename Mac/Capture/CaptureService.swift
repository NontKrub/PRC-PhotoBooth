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

    var usesDSLR = false
    var captureRotationDegrees: Int = 0
    var onPreviewJPEG: (@MainActor (Data) -> Void)?
    private(set) var capturedStills: [Int: CGImage] = [:]
    private(set) var isRunning = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init() {
        camera = AVFoundationCameraSource()
        dslr = DSLRCameraSource()
        camera.onPreviewJPEG = { [weak self] jpeg in
            Task { @MainActor [weak self] in
                guard let self, !self.usesDSLR else { return }
                self.onPreviewJPEG?(jpeg)
            }
        }
        dslr.onPreviewJPEG = { [weak self] jpeg in
            Task { @MainActor [weak self] in
                guard let self, self.usesDSLR else { return }
                self.onPreviewJPEG?(jpeg)
            }
        }
    }

    func start() throws {
        try camera.start()
        isRunning = true
    }

    func stop() {
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

    func captureStill(for photoIndex: Int) async throws -> CGImage {
        var image: CGImage
        if usesDSLR {
            guard dslr.isRunning else {
                throw DSLRError.captureFailed("DSLR is selected but not connected yet.")
            }
            image = try await dslr.captureStill()
        } else {
            image = try await camera.captureStill()
        }
        if captureRotationDegrees != 0 {
            image = rotated(image, by: captureRotationDegrees) ?? image
        }
        capturedStills[photoIndex] = image
        return image
    }

    func captureDiagnosticStill() async throws -> CGImage {
        var image: CGImage
        if dslr.isRunning {
            image = try await dslr.captureStill()
        } else {
            image = try await camera.captureStill()
        }
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
        // Sony live view is delivered through ImageCaptureCore, not the
        // AVFoundation preview stream, so use the active source's buffer.
        if usesDSLR {
            return dslr.rollingBuffer.drain(lastSeconds: 5)
        }
        return camera.rollingBuffer.drain(lastSeconds: 5)
    }

    func resetStills() {
        capturedStills = [:]
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

// MARK: - JPEG encode helper (used by CaptureService and AVFoundationCameraSource)

func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}
