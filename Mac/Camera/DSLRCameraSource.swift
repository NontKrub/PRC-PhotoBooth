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
    private struct PTPReply: Sendable {
        let data: Data
        let responseCode: UInt16
        let errorDescription: String?
    }

    private let browser = ICDeviceBrowser()
    private var camerasByID: [String: ICCameraDevice] = [:]
    private var connectedCamera: ICCameraDevice?
    // Set before requestTakePicture; resolved after download completes
    private var captureCompletion: CheckedContinuation<CGImage, Error>?
    private var expectingCapture = false
    private var captureRequestedAt: Date?     // used to filter out old SD card files during cataloging
    private nonisolated let captureFilename = "prc_last_capture.jpg"
    private var ptpTxID: UInt32 = 1
    private var pollTask: Task<Void, Never>?    // continuous GetAllDevicePropDesc heartbeat
    private var reopenAfterClose = false
    private var ptpHealthy = false
    private var fallbackTakePictureIssued = false
    private var busyRejection = false   // Sony shutter control returned DeviceBusy (0x201D)
    private var suppressStatusPoll = false
    private var isDrainingPCBuffer = false
    private var liveViewTask: Task<Void, Never>?
    private var isRequestingLiveViewFrame = false
    private var liveViewFailureCount = 0
    private var previewFramesPerSecond = 30
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
    var selectedDeviceID: String?
    var selectedDeviceName: String? {
        guard let selectedDeviceID else { return nil }
        return availableDevices.first(where: { $0.id == selectedDeviceID })?.name
    }
    var isSonyZVE10: Bool {
        selectedDeviceName?.localizedCaseInsensitiveContains("ZV-E10") == true
    }
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
        connectedCamera = cam
        cam.delegate = self
        isConnecting = true
        onConnectionStateChanged?()
        cam.requestOpenSession()
        // isRunning / isConnecting are set in device(_:didOpenSessionWithError:)
    }

    func stop() {
        stopSonyLiveView()
        connectedCamera?.requestCloseSession()
        connectedCamera = nil
        isRunning = false
        isConnecting = false
        ptpHealthy = false
        controlSupport = DSLRControlSupport()
        onConnectionStateChanged?()
    }

    func setPreviewFrameRate(_ framesPerSecond: Int) {
        previewFramesPerSecond = max(1, framesPerSecond)
    }

    // Sony ZV-E10 uses the Sony SDIO vendor capture protocol.
    // Trigger via SDIO_ControlDevice (0x9207); image arrives via ObjectAdded or ObjectInMemory.
    func captureStill() async throws -> CGImage {
        guard let cam = connectedCamera, isRunning else { throw DSLRError.noCamera }
        guard !isCapturing else {
            throw DSLRError.captureFailed("A tethered capture is already in progress.")
        }
        guard !isDrainingPCBuffer else {
            throw DSLRError.captureFailed("Camera is clearing old PC-save images. Try again in a moment.")
        }
        return try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else { cont.resume(throwing: DSLRError.noCamera); return }
            isCapturing = true
            captureCompletion = cont
            expectingCapture = true
            fallbackTakePictureIssued = false
            busyRejection = false
            captureRequestedAt = Date()
            if ptpHealthy {
                Task { @MainActor [weak self] in
                    while self?.isRequestingLiveViewFrame == true {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    await self?.ptpSonyCapture(cam)
                }
            } else {
                NSLog("[DSLR] PTP appears unhealthy (empty responses). Falling back to requestTakePicture().")
                triggerICCaptureFallback(reason: "PTP unhealthy")
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await MainActor.run { [weak self] in
                    guard let self, self.expectingCapture else { return }
                    if let cam = self.connectedCamera, self.tryDownloadFreshestMediaFile(from: cam) {
                        return
                    }
                    let msg = self.busyRejection
                        ? "Camera reported Busy and refused the shutter. On the ZV-E10: Setup → USB Connection → PC Remote, switch the photo/movie switch to Photo, and make sure the camera is showing live view (not a menu or playback screen)."
                        : "Timed out. Check: shutter fires on camera? SD card inserted?"
                    self.failCapture(DSLRError.captureFailed(msg))
                }
            }
        }
    }

    // MARK: - Sony PTP capture

    // Sony initialization sequence — call once after session opens.
    // SDIOConnect (0x9201) with 3 phases enables Sony vendor PTP commands.
    // Vendor prop codes reported by the camera — populated after SDIOConnect phases 1+2
    private var sonyVendorPropCodes: [UInt16] = []

    private func cycleSession() {
        reopenAfterClose = true
        connectedCamera?.requestCloseSession()  // sync Obj-C void — no async bridging
    }

    private func ptpSonyInit(_ cam: ICCameraDevice) async {
        ptpSonySDIOConnect(cam, phase: 1)
        try? await Task.sleep(for: .milliseconds(200))
        ptpSonySDIOConnect(cam, phase: 2)
        try? await Task.sleep(for: .milliseconds(300))
        ptpSonyGetVendorPropCodes(cam)
        try? await Task.sleep(for: .milliseconds(300))
        ptpSonySDIOConnect(cam, phase: 3)
        try? await Task.sleep(for: .milliseconds(300))
        // Give the controlling application priority, matching libgphoto2's Sony init.
        ptpSonySetControlAInt8(cam, prop: 0xD25A, value: 1, label: "SetPriorityMode")
        try? await Task.sleep(for: .milliseconds(300))
        // PcSaveImageFormat (D269): 1=RAW & JPEG, 2=JPEG Only, 3=RAW Only.
        // A booth needs the full-resolution rendered JPEG, not a paired 25 MB
        // RAW whose embedded preview is only 1616x1080.
        ptpSonySetControlAInt8(cam, prop: 0xD269, value: 2, label: "SetPcSaveJPEGOnly")
        try? await Task.sleep(for: .milliseconds(300))
        // Query D215 once at connection time. If previous clients left PC-save
        // images queued, the response handler drains those RAM-only objects.
        ptpSonyGetAllDevicePropDesc(cam)
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

                self.isRequestingLiveViewFrame = true
                let jpeg = await self.requestSonyLiveViewJPEG(cam)
                self.isRequestingLiveViewFrame = false

                guard !Task.isCancelled else { return }
                if let jpeg,
                   let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    let wasInactive = !self.isLivePreviewActive
                    self.latestPreviewImage = image
                    self.rollingBuffer.append(image)
                    self.isLivePreviewActive = true
                    self.liveViewFailureCount = 0
                    self.onPreviewJPEG?(jpeg)
                    if wasInactive {
                        NSLog("[DSLR] Sony live preview active: %dx%d, %d bytes",
                              image.width, image.height, jpeg.count)
                    }
                    // PTP request time also counts toward the interval. A Sony
                    // body may not sustain the selected rate, but avoid adding
                    // an artificial 14 FPS ceiling on top of that limitation.
                    let delay = max(1, 1_000 / self.previewFramesPerSecond)
                    try? await Task.sleep(for: .milliseconds(delay))
                } else {
                    self.liveViewFailureCount += 1
                    if self.liveViewFailureCount >= 12 {
                        self.isLivePreviewActive = false
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
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
    }

    private func requestSonyLiveViewJPEG(_ cam: ICCameraDevice) async -> Data? {
        let handle = UInt32(0xFFFFC002)
        let info = await sendPTPRequest(cam, opcode: 0x1008, parameter: handle)
        guard info.errorDescription == nil, info.responseCode == 0x2001 else {
            if info.responseCode != 0x2009 && info.responseCode != 0x201D {
                NSLog("[DSLR] LiveView GetObjectInfo: error=%@ resp=0x%04X",
                      info.errorDescription ?? "none", info.responseCode)
            }
            return nil
        }

        let object = await sendPTPRequest(cam, opcode: 0x1009, parameter: handle)
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
        parameter: UInt32
    ) async -> PTPReply {
        var command = Data(count: 16)
        let txID = ptpTxID
        ptpTxID += 1
        command.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,       toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian,   toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: opcode.littleEndian,           toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: txID.littleEndian,             toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: parameter.littleEndian,        toByteOffset: 12, as: UInt32.self)
        }
        let immutableCommand = command

        return await withCheckedContinuation { continuation in
            cam.requestSendPTPCommand(immutableCommand, outData: nil) { data, response, error in
                let code: UInt16 = response.count >= 8
                    ? response.withUnsafeBytes {
                        $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian
                    }
                    : 0
                continuation.resume(returning: PTPReply(
                    data: data,
                    responseCode: code,
                    errorDescription: error?.localizedDescription
                ))
            }
        }
    }

    private func startPollLoop(_ cam: ICCameraDevice) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                if !self.suppressStatusPoll {
                    self.ptpSonyGetAllDevicePropDesc(cam)
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func ptpSonyGetAllDevicePropDesc(_ cam: ICCameraDevice) {
        var cmd = Data(count: 12)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(12).littleEndian,     toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4, as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x9209).littleEndian, toByteOffset: 6, as: UInt16.self)
            ptr.storeBytes(of: txID.littleEndian,           toByteOffset: 8, as: UInt32.self)
        }
        cam.requestSendPTPCommand(cmd, outData: nil) { [weak self] inData, resp, error in
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            let objectInMemory = Self.parseSonyUInt16CurrentValue(inData, property: 0xD215)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notePTPHealth(dataLen: inData.count, responseCode: code)
                if let objectInMemory {
                    NSLog("[DSLR] ObjectInMemory=0x%04X", objectInMemory)
                }
                // Some Sony bodies update D215 without sending C201/C202. A value
                // at or above 0x8000 means the PC-save object is ready at the
                // camera's fixed RAM handle.
                if let objectInMemory,
                   objectInMemory >= 0x8000,
                   self.expectingCapture,
                   let currentCamera = self.connectedCamera {
                    NSLog("[DSLR] ObjectInMemory ready via GetAll → reading PC buffer")
                    self.expectingCapture = false
                    self.pollTask?.cancel()
                    self.pollTask = nil
                    self.ptpGetObject(currentCamera, handle: 0xFFFFC001)
                } else if let objectInMemory,
                          objectInMemory >= 0x8000,
                          self.captureCompletion == nil,
                          !self.isCapturing,
                          !self.isDrainingPCBuffer,
                          let currentCamera = self.connectedCamera {
                    self.ptpDiscardPCBufferObject(currentCamera)
                }
            }
            NSLog("[DSLR] GetAllDevicePropDesc: %d bytes, resp=0x%04X", inData.count, code)
        }
    }

    private func ptpSonyGetVendorPropCodes(_ cam: ICCameraDevice) {
        // Opcode 0x9202 with param1=0xC8, matching Sony SDIO and libgphoto2.
        var cmd = Data(count: 16)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,      toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian,  toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x9202).littleEndian,  toByteOffset: 6,  as: UInt16.self) // GetVendorPropCodes
            ptr.storeBytes(of: txID.littleEndian,            toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(0xC8).littleEndian,    toByteOffset: 12, as: UInt32.self)
        }
        cam.requestSendPTPCommand(cmd, outData: nil) { [weak self] inData, resp, error in
            if let e = error { NSLog("[DSLR] GetVendorPropCodes error: %@", e.localizedDescription); return }
            let respCode: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            Task { @MainActor [weak self] in
                self?.notePTPHealth(dataLen: inData.count, responseCode: respCode)
            }
            NSLog("[DSLR] GetVendorPropCodes: %d data bytes, resp=0x%04X", inData.count, respCode)
            let codes = Self.parseSonyVendorCodes(inData)
            NSLog("[DSLR] Vendor props (%d): %@", codes.count,
                  codes.map { String(format: "0x%04X", $0) }.joined(separator: ", "))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sonyVendorPropCodes = codes
                self.controlSupport.shutter = codes.contains(0xD20D)
                self.controlSupport.aperture = codes.contains(0x5007) || codes.contains(0xD211)
            }
        }
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

    private func ptpSonySDIOConnect(_ cam: ICCameraDevice, phase: Int) {
        var cmd = Data(count: 24)  // 12 header + 3×4 params
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(24).littleEndian,    toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4, as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x9201).littleEndian, toByteOffset: 6, as: UInt16.self) // SDIOConnect
            ptr.storeBytes(of: txID.littleEndian,          toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(phase).littleEndian, toByteOffset: 12, as: UInt32.self)
            ptr.storeBytes(of: UInt32(0).littleEndian,     toByteOffset: 16, as: UInt32.self)
            ptr.storeBytes(of: UInt32(0).littleEndian,     toByteOffset: 20, as: UInt32.self)
        }
        cam.requestSendPTPCommand(cmd, outData: nil) { _, resp, error in
            if let e = error { NSLog("[DSLR] SDIOConnect(%d) error: %@", phase, e.localizedDescription); return }
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            Task { @MainActor [weak self] in self?.notePTPHealth(dataLen: 0, responseCode: code) }
            NSLog("[DSLR] SDIOConnect(%d) resp=0x%04X (%d bytes) %@",
                  phase, code, resp.count, resp.isEmpty ? "⚠ empty — PTP may not be working" : "")
        }
    }

    // Sony capture: AF half-press → shutter → release.
    // Uses SDIO_ControlDevice (0x9207), Sony's vendor capture opcode.
    // 0xD2C1 = ShutterHalfRelease (AF), 0xD2C2 = ShutterRelease (capture)
    // REQUIRES camera in PC Remote USB mode (Setup → USB Connection → PC Remote)
    private func ptpSonyCapture(_ cam: ICCameraDevice) async {
        pollTask?.cancel()
        pollTask = nil
        suppressStatusPoll = true
        defer { suppressStatusPoll = false }

        NSLog("[DSLR] Sony capture: sending AF half-press (0xD2C1=2)...")
        let afCode = await ptpSonySetControlB(cam, prop: 0xD2C1, value: 2, label: "AF-press")
        if afCode == 0 {
            // 0 means no PTP response at all (USB pipe stall), not a real camera answer — retry once.
            NSLog("[DSLR] AF-press got no response (USB hiccup?); retrying once")
            try? await Task.sleep(for: .milliseconds(300))
            _ = await ptpSonySetControlB(cam, prop: 0xD2C1, value: 2, label: "AF-press-retry")
        }
        // Sony's reference sequence sends full-press immediately after half-press,
        // then holds both while focus settles.
        try? await Task.sleep(for: .milliseconds(100))

        var shutterAccepted = false
        var lastCode: UInt16 = 0
        for attempt in 1...3 {
            NSLog("[DSLR] Sony capture: sending shutter attempt %d (0xD2C2=2)...", attempt)
            let code = await ptpSonySetControlB(cam, prop: 0xD2C2, value: 2, label: "Shutter-press")
            lastCode = code
            if code == 0x2001 {
                shutterAccepted = true
                break
            }
            if code == 0x201D {
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
        _ = await ptpSonySetControlB(cam, prop: 0xD2C2, value: 1, label: "Shutter-release")
        try? await Task.sleep(for: .milliseconds(160))
        _ = await ptpSonySetControlB(cam, prop: 0xD2C1, value: 1, label: "AF-release")

        guard shutterAccepted else {
            triggerICCaptureFallback(reason: "Sony shutter command stayed busy")
            startPendingCapturePoll(cam)
            return
        }

        startPendingCapturePoll(cam)
    }

    // libgphoto2 sends Sony shutter control props (D2C1, D2C2) as PTP_DTC_UINT16.
    @discardableResult
    private func ptpSonySetControlB(_ cam: ICCameraDevice, prop: UInt16, value: UInt16,
                                    label: String) async -> UInt16 {
        var cmd = Data(count: 16)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x9207).littleEndian, toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: txID.littleEndian,           toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(prop).littleEndian,   toByteOffset: 12, as: UInt32.self)
        }
        var outData = Data(count: 2)
        outData.withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: 0, as: UInt16.self)
        }
        return await withCheckedContinuation { continuation in
            cam.requestSendPTPCommand(cmd, outData: outData) { _, resp, error in
                if let e = error {
                    NSLog("[DSLR] %@ error: %@", label, e.localizedDescription)
                    continuation.resume(returning: 0)
                    return
                }
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
                NSLog("[DSLR] %@ resp=0x%04X (%d bytes)", label, code, resp.count)
                continuation.resume(returning: code)
            }
        }
    }

    // Sony SDIO_SetExtDevicePropValue (0x9205), used for application priority.
    private func ptpSonySetControlAInt8(_ cam: ICCameraDevice, prop: UInt16, value: Int8,
                                        label: String) {
        var cmd = Data(count: 16)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x9205).littleEndian, toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: txID.littleEndian,           toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(prop).littleEndian,   toByteOffset: 12, as: UInt32.self)
        }
        let outData = Data([UInt8(bitPattern: value)])
        cam.requestSendPTPCommand(cmd, outData: outData) { _, resp, error in
            if let error {
                NSLog("[DSLR] %@ error: %@", label, error.localizedDescription)
                return
            }
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            NSLog("[DSLR] %@ resp=0x%04X (%d bytes)", label, code, resp.count)
        }
    }

    private func startPendingCapturePoll(_ cam: ICCameraDevice) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...18 {
                guard self.expectingCapture, self.captureCompletion != nil else { return }
                try? await Task.sleep(for: .seconds(1))
                guard self.expectingCapture, self.captureCompletion != nil else { return }
                guard let cam = self.connectedCamera else { return }
                if self.tryDownloadFreshestMediaFile(from: cam) { return }
                NSLog("[DSLR] Capture fallback poll %d/18: GetObjectHandles", attempt)
                self.ptpGetObjectHandles(cam)
            }
            if self.expectingCapture {
                self.triggerICCaptureFallback(reason: "No Sony object event or handle after shutter")
            }
        }
    }

    // Reading Sony's fixed RAM handle consumes one queued PC-save object.
    // DeleteObject is intentionally not used because Sony does not support it
    // for this buffer.
    private func ptpDiscardPCBufferObject(_ cam: ICCameraDevice) {
        guard !isDrainingPCBuffer else { return }
        isDrainingPCBuffer = true
        let handle = UInt32(0xFFFFC001)
        var infoCmd = Data(count: 16)
        let infoTxID = ptpTxID; ptpTxID += 1
        infoCmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,         toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian,     toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x1008).littleEndian,     toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: infoTxID.littleEndian,           toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: handle.littleEndian,             toByteOffset: 12, as: UInt32.self)
        }

        var objectCmd = Data(count: 16)
        let objectTxID = ptpTxID; ptpTxID += 1
        objectCmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x1009).littleEndian, toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: objectTxID.littleEndian,     toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: handle.littleEndian,         toByteOffset: 12, as: UInt32.self)
        }
        let getObjectCommand = objectCmd

        NSLog("[DSLR] Draining one stale PC-buffer object")
        cam.requestSendPTPCommand(infoCmd, outData: nil) { [weak self] _, infoResp, infoError in
            let infoCode: UInt16 = infoResp.count >= 8
                ? infoResp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            guard infoError == nil, infoCode == 0x2001 else {
                NSLog("[DSLR] PC-buffer drain info failed: error=%@ resp=0x%04X",
                      infoError?.localizedDescription ?? "none", infoCode)
                Task { @MainActor [weak self] in self?.isDrainingPCBuffer = false }
                return
            }
            cam.requestSendPTPCommand(getObjectCommand, outData: nil) { [weak self] data, resp, error in
                let code: UInt16 = resp.count >= 8
                    ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                    : 0
                NSLog("[DSLR] PC-buffer drain: error=%@ dataLen=%d resp=0x%04X",
                      error?.localizedDescription ?? "none", data.count, code)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isDrainingPCBuffer = false
                    if error == nil, code == 0x2001, !data.isEmpty,
                       let currentCamera = self.connectedCamera {
                        self.ptpSonyGetAllDevicePropDesc(currentCamera)
                    }
                }
            }
        }
    }

    // Standard MTP GetDevicePropValue (0x1015)
    private func ptpGetDevicePropValue(_ cam: ICCameraDevice, prop: UInt16, label: String) {
        var cmd = Data(count: 16)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x1015).littleEndian, toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: txID.littleEndian,           toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(prop).littleEndian,   toByteOffset: 12, as: UInt32.self)
        }
        cam.requestSendPTPCommand(cmd, outData: nil) { inData, resp, error in
            if let e = error { NSLog("[DSLR] %@ error: %@", label, e.localizedDescription); return }
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            let hex = inData.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            NSLog("[DSLR] %@ resp=0x%04X data(%d)=[%@]", label, code, inData.count, hex)
        }
    }

    // Standard MTP SetDevicePropValue (0x1016) — UInt16 value
    private func ptpSetDevicePropValue(_ cam: ICCameraDevice, prop: UInt16, value: UInt16, label: String) {
        var cmd = Data(count: 16)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x1016).littleEndian, toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: txID.littleEndian,           toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(prop).littleEndian,   toByteOffset: 12, as: UInt32.self)
        }
        var outData = Data(count: 2)
        outData.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: 0, as: UInt16.self) }
        cam.requestSendPTPCommand(cmd, outData: outData) { _, resp, error in
            if let e = error { NSLog("[DSLR] %@ error: %@", label, e.localizedDescription); return }
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            NSLog("[DSLR] %@ resp=0x%04X (%d bytes)", label, code, resp.count)
        }
    }

    // Sony GetDevicePropertyValue (0x9204) — read a single prop value
    private func ptpSonyReadProp(_ cam: ICCameraDevice, prop: UInt16, label: String) {
        var cmd = Data(count: 16)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x9204).littleEndian, toByteOffset: 6,  as: UInt16.self)
            ptr.storeBytes(of: txID.littleEndian,           toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(prop).littleEndian,   toByteOffset: 12, as: UInt32.self)
        }
        cam.requestSendPTPCommand(cmd, outData: nil) { inData, resp, error in
            if let e = error { NSLog("[DSLR] ReadProp %@ error: %@", label, e.localizedDescription); return }
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            let hex = inData.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            NSLog("[DSLR] ReadProp %@: resp=0x%04X data(%d)=[%@]", label, code, inData.count, hex)
        }
    }

    // GetObjectHandles (0x1007) — fallback download when no ObjectAdded event with handle.
    // Used for Sony PC-save mode (no SD card) where 0xC202 fires instead of 0x4002.
    private func ptpGetObjectHandles(_ cam: ICCameraDevice) {
        var cmd = Data(count: 24)  // 3 params
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(24).littleEndian,         toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian,     toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x1007).littleEndian,     toByteOffset: 6,  as: UInt16.self) // GetObjectHandles
            ptr.storeBytes(of: txID.littleEndian,               toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(0xFFFFFFFF).littleEndian, toByteOffset: 12, as: UInt32.self) // all storages
            ptr.storeBytes(of: UInt32(0x00000000).littleEndian, toByteOffset: 16, as: UInt32.self) // all formats
            ptr.storeBytes(of: UInt32(0xFFFFFFFF).littleEndian, toByteOffset: 20, as: UInt32.self) // all parents
        }
        cam.requestSendPTPCommand(cmd, outData: nil) { [weak self] inData, _, error in
            if let e = error { NSLog("[DSLR] GetObjectHandles error: %@", e.localizedDescription); return }
            NSLog("[DSLR] GetObjectHandles returned %d bytes", inData.count)
            // PTP array: [4 count][4 handle0][4 handle1]...
            guard inData.count >= 8 else { return }
            let count = inData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
            NSLog("[DSLR] GetObjectHandles count=%d", count)
            guard count > 0 else { return }
            // Download the last handle (newest object)
            let lastHandle = inData.withUnsafeBytes {
                $0.load(fromByteOffset: Int(4 + (count - 1) * 4), as: UInt32.self).littleEndian
            }
            NSLog("[DSLR] Downloading last handle=0x%08X", lastHandle)
            Task { @MainActor [weak self] in
                guard let self, let connectedCamera = self.connectedCamera else { return }
                self.ptpGetObject(connectedCamera, handle: lastHandle)
            }
        }
    }

    // Downloads a captured object by handle.
    // Tries GetObjectInfo first to probe IC's interception, then GetObject (0x1009),
    // then GetPartialObject (0x101B) as fallback.
    private func ptpGetObject(_ cam: ICCameraDevice, handle: UInt32) {
        // Step 1: GetObjectInfo (0x1008) — probe whether IC knows about the object.
        var infoCmd = Data(count: 16)
        let txInfo = ptpTxID; ptpTxID += 1
        infoCmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,     toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4,  as: UInt16.self)
            ptr.storeBytes(of: UInt16(0x1008).littleEndian, toByteOffset: 6,  as: UInt16.self) // GetObjectInfo
            ptr.storeBytes(of: txInfo.littleEndian,         toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: handle.littleEndian,         toByteOffset: 12, as: UInt32.self)
        }
        NSLog("[DSLR] GetObjectInfo handle=0x%08X", handle)
        cam.requestSendPTPCommand(infoCmd, outData: nil) { [weak self] infoData, infoResp, _ in
            let infoRespCode: UInt16 = infoResp.count >= 8
                ? infoResp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            NSLog("[DSLR] GetObjectInfo: %d bytes resp=0x%04X", infoData.count, infoRespCode)
            // Also check IC's file catalog for the object
            Task { @MainActor [weak self] in
                guard let self, let cam = self.connectedCamera else { return }
                let n = cam.mediaFiles?.count ?? 0
                NSLog("[DSLR] IC mediaFiles after C201: count=%d", n)
            }
            // Step 2: GetObject (0x1009) — IC may intercept (returns 0 bytes)
            var cmd = Data(count: 16)
            let txID = (self?.ptpTxID ?? 1); if let s = self { s.ptpTxID += 1 }
            cmd.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: UInt32(16).littleEndian,   toByteOffset: 0,  as: UInt32.self)
                ptr.storeBytes(of: UInt16(0x0001).littleEndian, toByteOffset: 4, as: UInt16.self)
                ptr.storeBytes(of: UInt16(0x1009).littleEndian, toByteOffset: 6, as: UInt16.self)
                ptr.storeBytes(of: txID.littleEndian,           toByteOffset: 8, as: UInt32.self)
                ptr.storeBytes(of: handle.littleEndian,         toByteOffset: 12, as: UInt32.self)
            }
            NSLog("[DSLR] Sending GetObject handle=0x%08X", handle)
            cam.requestSendPTPCommand(cmd, outData: nil) { [weak self] inData, objResp, error in
                let objRespCode: UInt16 = objResp.count >= 8
                    ? objResp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                    : 0
                NSLog("[DSLR] GetObject response: error=%@ dataLen=%d resp=0x%04X",
                      error?.localizedDescription ?? "none", inData.count, objRespCode)
                guard let self else { return }
                if inData.count > 0 {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.resolveFromData(inData)
                    }
                    return
                }
                // Step 3: GetPartialObject (0x101B) — IC may not intercept this opcode
                var partCmd = Data(count: 24) // 3 params: handle, offset, maxBytes
                let txPart = self.ptpTxID; self.ptpTxID += 1
                partCmd.withUnsafeMutableBytes { ptr in
                    ptr.storeBytes(of: UInt32(24).littleEndian,       toByteOffset: 0,  as: UInt32.self)
                    ptr.storeBytes(of: UInt16(0x0001).littleEndian,   toByteOffset: 4,  as: UInt16.self)
                    ptr.storeBytes(of: UInt16(0x101B).littleEndian,   toByteOffset: 6,  as: UInt16.self) // GetPartialObject
                    ptr.storeBytes(of: txPart.littleEndian,           toByteOffset: 8,  as: UInt32.self)
                    ptr.storeBytes(of: handle.littleEndian,           toByteOffset: 12, as: UInt32.self)
                    ptr.storeBytes(of: UInt32(0).littleEndian,        toByteOffset: 16, as: UInt32.self) // offset=0
                    ptr.storeBytes(of: UInt32(0x00FFFFFF).littleEndian, toByteOffset: 20, as: UInt32.self) // max 16MB
                }
                NSLog("[DSLR] Trying GetPartialObject handle=0x%08X", handle)
                cam.requestSendPTPCommand(partCmd, outData: nil) { [weak self] partData, _, partErr in
                    NSLog("[DSLR] GetPartialObject: error=%@ dataLen=%d",
                          partErr?.localizedDescription ?? "none", partData.count)
                    guard let self else { return }
                    if partData.count > 0 {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.resolveFromData(partData)
                        }
                        return
                    }
                    // Step 4: Retry GetPartialObject up to 10x (camera returns 0x201D=DeviceBusy while writing)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        var attempt = 0
                        while attempt < 10 {
                            attempt += 1
                            try? await Task.sleep(for: .seconds(3))
                            guard let cam = self.connectedCamera else { break }
                            var sonyCmd = Data(count: 24)
                            let txSony = self.ptpTxID; self.ptpTxID += 1
                            sonyCmd.withUnsafeMutableBytes { ptr in
                                ptr.storeBytes(of: UInt32(24).littleEndian,         toByteOffset: 0,  as: UInt32.self)
                                ptr.storeBytes(of: UInt16(0x0001).littleEndian,     toByteOffset: 4,  as: UInt16.self)
                                ptr.storeBytes(of: UInt16(0x101B).littleEndian,     toByteOffset: 6,  as: UInt16.self) // GetPartialObject
                                ptr.storeBytes(of: txSony.littleEndian,             toByteOffset: 8,  as: UInt32.self)
                                ptr.storeBytes(of: handle.littleEndian,             toByteOffset: 12, as: UInt32.self)
                                ptr.storeBytes(of: UInt32(0).littleEndian,          toByteOffset: 16, as: UInt32.self)
                                ptr.storeBytes(of: UInt32(0x00FFFFFF).littleEndian, toByteOffset: 20, as: UInt32.self)
                            }
                            NSLog("[DSLR] GetPartialObject retry %d/10 handle=0x%08X", attempt, handle)
                            let result = await withCheckedContinuation { (cont: CheckedContinuation<(Data, UInt16), Never>) in
                                cam.requestSendPTPCommand(sonyCmd, outData: nil) { d, r, _ in
                                    let code: UInt16 = r.count >= 8
                                        ? r.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                                        : 0
                                    cont.resume(returning: (d, code))
                                }
                            }
                            NSLog("[DSLR] GetPartialObject retry %d: dataLen=%d resp=0x%04X", attempt, result.0.count, result.1)
                            if result.0.count > 0 {
                                self.resolveFromData(result.0)
                                return
                            }
                            if result.1 != 0x201D { break }  // stop retrying if not DeviceBusy
                        }
                        NSLog("[DSLR] All download variants exhausted for 0x%08X", handle)
                        self.failCapture(DSLRError.captureFailed("IC blocks image download"))
                    }
                }
            }
        }
    }

    private func resolveFromData(_ data: Data) {
        func finish(_ image: CGImage, source: CGImageSource, description: String) {
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
            lastCapturedImage = final
            captureCompletion?.resume(returning: final)
            captureCompletion = nil
            expectingCapture = false
            fallbackTakePictureIssued = false
            isCapturing = false
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
        failCapture(DSLRError.captureFailed("Could not decode image received from camera"))
    }

    // Send current settings to camera via PTP — best-effort, silently ignored if unsupported
    func applySettings() {
        guard let cam = connectedCamera else { return }
        NSLog("[DSLR] applySettings autoPicture=%d iso=%d flash=%@ cam=%@",
              automaticPictureMode, iso, flashMode.rawValue, cam.name ?? "?")
        if controlSupport.flash {
            ptpSet(cam, propCode: 0x500C, value16: flashMode.ptpValue, label: "Set FlashMode")   // FlashMode
        }
        if controlSupport.iso && !(isSonyZVE10 && automaticPictureMode) {
            ptpSet(cam, propCode: 0x5005, value16: UInt16(min(iso, 65535)), label: "Set ISO")  // ExposureIndex ISO
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

    func downloadCapturedFile(_ file: ICCameraFile, from cam: ICCameraDevice) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        cam.requestDownloadFile(
            file,
            options: [
                .downloadsDirectoryURL: tempDir,
                .saveAsFilename: captureFilename,
                .overwrite: true
            ],
            downloadDelegate: self,
            didDownloadSelector: #selector(didFinishDownload(_:didDownloadFile:error:options:contextInfo:)),
            contextInfo: nil
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
        if let error {
            Task { @MainActor [weak self] in self?.failCapture(error) }
            return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(captureFilename)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            Task { @MainActor [weak self] in
                self?.failCapture(DSLRError.captureFailed("Could not decode downloaded image"))
            }
            return
        }
        // Apply EXIF orientation so the compositor sees an up-right image
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
        Task { @MainActor [weak self] in
            self?.captureCompletion?.resume(returning: final)
            self?.captureCompletion = nil
            self?.lastCapturedImage = final
            self?.expectingCapture = false
            self?.fallbackTakePictureIssued = false
            self?.isCapturing = false
        }
    }

    private func failCapture(_ error: Error) {
        expectingCapture = false
        fallbackTakePictureIssued = false
        isCapturing = false
        captureCompletion?.resume(throwing: error)
        captureCompletion = nil
    }

    // MARK: - PTP

    private func ptpSet(_ cam: ICCameraDevice, propCode: UInt16, value16: UInt16, label: String) {
        var data = Data(count: 2)
        data.withUnsafeMutableBytes { $0.storeBytes(of: value16.littleEndian, as: UInt16.self) }
        ptpSetProp(cam, propCode: propCode, data: data, label: label)
    }

    private func ptpSet(_ cam: ICCameraDevice, propCode: UInt16, value32: UInt32, label: String) {
        var data = Data(count: 4)
        data.withUnsafeMutableBytes { $0.storeBytes(of: value32.littleEndian, as: UInt32.self) }
        ptpSetProp(cam, propCode: propCode, data: data, label: label)
    }

    private func ptpSetProp(_ cam: ICCameraDevice, propCode: UInt16, data: Data, label: String) {
        // PTP SetDevicePropValue (0x1016): 16-byte command block + data phase
        var cmd = Data(count: 16)
        let txID = ptpTxID; ptpTxID += 1
        cmd.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian,       toByteOffset: 0,  as: UInt32.self)
            ptr.storeBytes(of: UInt16(0x0001).littleEndian,   toByteOffset: 4,  as: UInt16.self) // Command Block
            ptr.storeBytes(of: UInt16(0x1016).littleEndian,   toByteOffset: 6,  as: UInt16.self) // SetDevicePropValue
            ptr.storeBytes(of: txID.littleEndian,             toByteOffset: 8,  as: UInt32.self)
            ptr.storeBytes(of: UInt32(propCode).littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        cam.requestSendPTPCommand(cmd, outData: data) { [weak self] _, resp, error in
            if let error {
                Task { @MainActor [weak self] in self?.onError?(error) }
                return
            }
            let code: UInt16 = resp.count >= 8
                ? resp.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
                : 0
            if code == 0 {
                NSLog("[DSLR] %@ response was empty/inconclusive (prop=0x%04X) — keeping previous value", label, propCode)
                return
            }
            if code != 0x2001 {
                let msg = String(format: "%@ failed (prop=0x%04X, resp=0x%04X)", label, propCode, code)
                NSLog("[DSLR] %@", msg)
                Task { @MainActor [weak self] in self?.onError?(DSLRError.settingFailed(msg)) }
            } else {
                NSLog("[DSLR] %@ ok (prop=0x%04X)", label, propCode)
            }
        }
    }

    private func fileExt(_ name: String?) -> String {
        URL(fileURLWithPath: name ?? "").pathExtension.lowercased()
    }

    // Fallback when Sony does not emit ObjectAdded/C202 reliably.
    private func tryDownloadFreshestMediaFile(from cam: ICCameraDevice) -> Bool {
        guard expectingCapture else { return false }
        let all = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        guard !all.isEmpty else { return false }

        let cutoff = (captureRequestedAt ?? .distantPast).addingTimeInterval(-60)
        let fresh = all.filter { ($0.creationDate ?? .distantPast) >= cutoff }
        guard !fresh.isEmpty else { return false }

        let jpegExts: Set<String> = ["jpg", "jpeg"]
        let sorted = fresh.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        guard let file = sorted.first(where: { jpegExts.contains(fileExt($0.name)) }) ?? sorted.first else {
            return false
        }

        NSLog("[DSLR] Fallback catalog download: %@ (created=%@)", file.name ?? "?", String(describing: file.creationDate))
        expectingCapture = false
        downloadCapturedFile(file, from: cam)
        return true
    }

    private func triggerICCaptureFallback(reason: String) {
        guard expectingCapture, !fallbackTakePictureIssued, let cam = connectedCamera else { return }
        fallbackTakePictureIssued = true
        NSLog("[DSLR] Triggering requestTakePicture fallback (%@)", reason)
        cam.requestTakePicture()
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
        NSLog("[DSLR] deviceBrowser didAdd: %@ caps=%@", name, (cam.capabilities ?? []).description)
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
            connectedCamera = nil; isRunning = false
            isConnecting = false
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
        guard expectingCapture else { return }

        // Filter out old SD card files that arrive during initial cataloging.
        // Only accept files whose creation date is within 60 seconds of when we fired the shutter.
        // (60s buffer handles camera clock drift)
        let cutoff = (captureRequestedAt ?? .distantPast).addingTimeInterval(-60)
        let freshFiles = files.filter { ($0.creationDate ?? .distantFuture) >= cutoff }
        NSLog("[DSLR] fresh files (date>=%@): %d", "\(cutoff)", freshFiles.count)

        let jpegExts: Set<String> = ["jpg", "jpeg"]
        guard let file = freshFiles.first(where: { jpegExts.contains(fileExt($0.name)) }) ?? freshFiles.first
        else { return }
        NSLog("[DSLR] downloading: %@", file.name ?? "?")
        expectingCapture = false
        downloadCapturedFile(file, from: camera)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) { }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // ICCameraDevice calls this on its own internal thread — use nonisolated + dispatch to MainActor
        guard eventData.count >= 12 else { return }
        let code = eventData.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
        let handle: UInt32 = eventData.count >= 16
            ? eventData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).littleEndian }
            : 0xFFFFFFFF
        let param1: UInt32 = eventData.count >= 16
            ? eventData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).littleEndian }
            : 0
        NSLog("[DSLR] PTP event 0x%04X param=0x%08X (%d bytes)", code, param1, eventData.count)
        Task { @MainActor [weak self] in
            guard let self, let cam = self.connectedCamera else { return }
            NSLog("[DSLR] PTP event 0x%04X (expectingCapture=%d)", code, self.expectingCapture ? 1 : 0)
            // ObjectAdded: standard (0x4002) or Sony vendor (0xC201)
            if (code == 0x4002 || code == 0xC201) && self.expectingCapture {
                NSLog("[DSLR] ObjectAdded handle=0x%08X → stopping poll, waiting 1s then ptpGetObject", handle)
                self.expectingCapture = false
                self.pollTask?.cancel(); self.pollTask = nil  // stop hammering camera during download
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    self.ptpGetObject(cam, handle: handle)
                }
                return
            }
            // Sony DevicePropChanged (0xC202). ObjectInMemory (0xD215) signals
            // that a PC-save capture is becoming available at the fixed RAM handle.
            // Other property changes (focus, exposure, etc.) must not consume the
            // pending capture.
            if code == 0xC202 && param1 == 0xD215 && self.expectingCapture {
                NSLog("[DSLR] Sony ObjectInMemory changed → reading PC buffer")
                self.expectingCapture = false
                self.pollTask?.cancel(); self.pollTask = nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    self.ptpGetObject(cam, handle: 0xFFFFC001)
                }
                return
            }
            // 0xC203 = Sony status update — requires GetAllDevicePropDesc response to advance camera state
            if code == 0xC203 &&
                !self.suppressStatusPoll &&
                !self.isRequestingLiveViewFrame {
                self.ptpSonyGetAllDevicePropDesc(cam)
            }
        }
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        NSLog("[DSLR] catalog complete — %@, %d items on card", device.name ?? "?", device.mediaFiles?.count ?? 0)
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) { }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) { }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        NSLog("[DSLR] didOpenSession device=%@ error=%@", device.name ?? "?", error?.localizedDescription ?? "none")
        if let error {
            isConnecting = false
            connectedCamera = nil
            isRunning = false
            onConnectionStateChanged?()
            let msg = "Could not open camera session: \(error.localizedDescription). "
                    + "Quit Image Capture.app and Photos.app, ensure the ZV-E10 is in PC Remote mode "
                    + "(Setup → USB Connection → PC Remote), then reconnect."
            onError?(DSLRError.captureFailed(msg))
            return
        }
        guard let cam = device as? ICCameraDevice else { isConnecting = false; return }
        // isConnecting stays true through the full Sony handshake so the UI's "Connecting…"
        // state covers it, not just the IC session-open call.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ptpSonyInit(cam)   // Sony SDIO vendor init — must precede capture commands
            self.isRunning = true
            self.isConnecting = false
            self.startSonyLiveView(cam)
            self.onConnectionStateChanged?()
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        stopSonyLiveView()
        pollTask?.cancel(); pollTask = nil
        NSLog("[DSLR] didCloseSession error=%@ reopen=%d", error?.localizedDescription ?? "none", reopenAfterClose ? 1 : 0)
        if reopenAfterClose, let cam = connectedCamera {
            reopenAfterClose = false
            NSLog("[DSLR] Reopening IC session to reset D2CA state")
            cam.requestOpenSession()
        } else {
            isConnecting = false
            isRunning = false
            onConnectionStateChanged?()
        }
    }
    func didRemove(_ device: ICDevice) {
        guard let cam = device as? ICCameraDevice, connectedCamera === cam else { return }
        stopSonyLiveView()
        pollTask?.cancel(); pollTask = nil
        connectedCamera = nil; isRunning = false
        isConnecting = false
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
