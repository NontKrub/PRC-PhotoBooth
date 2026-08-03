#if DEBUG
import Foundation
import CoreGraphics
import CoreVideo

@MainActor
final class DemoCameraSource: CameraSource {
    private(set) var isRunning = false
    let availableDevices = [CameraDeviceInfo(id: "demo-camera", name: "Demo Camera", kind: .usb)]
    var selectedDeviceID: String? = "demo-camera"
    var onPreviewFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    var onPreviewJPEG: ((Data) -> Void)?
    private var previewTask: Task<Void, Never>?
    private var frameNumber = 0
    private var previewFrames: [Data] = []

    func start() throws {
        isRunning = true
        previewTask?.cancel()
        previewFrames = (0..<4).compactMap { index in
            guard let image = DemoImageFactory.image(width: 640, height: 360, captureNumber: index) else { return nil }
            return jpegData(from: image, quality: 0.72)
        }
        guard !previewFrames.isEmpty else { throw DemoCameraError.cannotCreatePreview }
        previewTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                self.onPreviewJPEG?(self.previewFrames[self.frameNumber % self.previewFrames.count])
                self.frameNumber += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        isRunning = false
        previewTask?.cancel()
        previewTask = nil
    }

    func captureStill() async throws -> CGImage {
        guard isRunning, let image = DemoImageFactory.image(captureNumber: frameNumber) else {
            throw DemoCameraError.notRunning
        }
        frameNumber += 1
        return image
    }
}

private enum DemoCameraError: LocalizedError {
    case notRunning
    case cannotCreatePreview

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Demo camera is not running."
        case .cannotCreatePreview: return "Demo camera could not create preview frames."
        }
    }
}
#endif
