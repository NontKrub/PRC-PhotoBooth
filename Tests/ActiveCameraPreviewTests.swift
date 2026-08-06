import AVFoundation
import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Active camera preview")
struct ActiveCameraPreviewTests {
    @Test("demo image has priority")
    @MainActor
    func demoImageWins() {
        let demo = makeImage(width: 10)
        let dslr = makeImage(width: 20)
        let result = resolve(demoImage: demo, dslrPreview: dslr)

        guard case .image(let image) = result else {
            Issue.record("Expected demo image preview")
            return
        }
        #expect(image.width == 10)
    }

    @Test("DSLR live image has priority over fallback")
    @MainActor
    func dslrLiveImageWins() {
        let live = makeImage(width: 20)
        let result = resolve(dslrPreview: live, fallbackSession: AVCaptureSession(), fallbackDeviceKind: .usb)

        guard case .image(let image) = result else {
            Issue.record("Expected DSLR image preview")
            return
        }
        #expect(image.width == 20)
    }

    @Test("DSLR fallback excludes the built-in camera")
    @MainActor
    func dslrDoesNotUseBuiltInFallback() {
        let result = resolve(fallbackSession: AVCaptureSession(), fallbackDeviceKind: .builtIn)

        guard case .unavailable = result else {
            Issue.record("Expected unavailable DSLR preview")
            return
        }
    }

    @Test("DSLR uses a selected non-built-in fallback")
    @MainActor
    func dslrUsesExternalFallback() {
        let session = AVCaptureSession()
        let result = resolve(fallbackSession: session, fallbackDeviceKind: .usb)

        guard case .session(let resolved, _) = result else {
            Issue.record("Expected external fallback session")
            return
        }
        #expect(resolved === session)
    }

    @Test("DSLR uses the last capture only after live sources fail")
    @MainActor
    func dslrUsesLastCapture() {
        let lastCapture = makeImage(width: 30)
        let result = resolve(dslrLastCapture: lastCapture)

        guard case .image(let image) = result else {
            Issue.record("Expected last DSLR capture preview")
            return
        }
        #expect(image.width == 30)
    }

    @Test("AVFoundation mode uses its active session")
    @MainActor
    func avFoundationUsesSession() {
        let session = AVCaptureSession()
        let result = ActiveCameraPreviewResolver.resolve(
            source: .avFoundation,
            demoImage: nil,
            dslrPreview: nil,
            dslrLastCapture: nil,
            fallbackSession: session,
            fallbackDeviceKind: .builtIn,
            cameraRunning: true,
            mirrored: true
        )

        guard case .session(let resolved, let mirrored) = result else {
            Issue.record("Expected AVFoundation session preview")
            return
        }
        #expect(resolved === session)
        #expect(mirrored)
    }

    @MainActor
    private func resolve(
        demoImage: CGImage? = nil,
        dslrPreview: CGImage? = nil,
        dslrLastCapture: CGImage? = nil,
        fallbackSession: AVCaptureSession? = nil,
        fallbackDeviceKind: CameraDeviceInfo.Kind? = nil
    ) -> ActiveCameraPreview {
        ActiveCameraPreviewResolver.resolve(
            source: .dslr,
            demoImage: demoImage,
            dslrPreview: dslrPreview,
            dslrLastCapture: dslrLastCapture,
            fallbackSession: fallbackSession,
            fallbackDeviceKind: fallbackDeviceKind,
            cameraRunning: fallbackSession != nil,
            mirrored: false
        )
    }

    private func makeImage(width: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }
}
