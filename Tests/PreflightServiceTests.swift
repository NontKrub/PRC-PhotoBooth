import Testing
import Foundation
import CoreGraphics

@testable import PRC_PhotoBooth_Mac

@Suite("Booth preflight")
struct PreflightServiceTests {
    @Test("no active event fails")
    @MainActor
    func noEventFails() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(event: nil))
        #expect(service.result(for: .activeEvent)?.status == .failed)
        #expect(service.readiness == .notReady)
    }

    @Test("invalid slot index fails")
    @MainActor
    func invalidSlotFails() async {
        let event = EventConfig(photoCount: 1, slots: [SharedPhotoSlot(photoIndex: 2)])
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(event: event))
        #expect(service.result(for: .eventLayout)?.status == .failed)
    }

    @Test("external viewer satisfies customer display")
    @MainActor
    func externalViewerSatisfiesDisplay() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(customerDisplayReady: true))
        #expect(service.result(for: .customerDisplay)?.status == .passed)
    }

    @Test("LAN fallback is reported as a warning")
    @MainActor
    func lanFallbackWarns() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(
            ipadConnected: true,
            requestedNetwork: .lan,
            effectiveNetwork: .wifi,
            networkFallbackActive: true
        ))
        #expect(service.result(for: .networkRoute)?.status == .warning)
    }

    @Test("preflight reports authenticated channels freshness reconnect state and queue backlog")
    @MainActor
    func transportAndQueueHealth() async {
        let service = BoothPreflightService()
        var base = context(
            ipadConnected: true,
            effectiveNetwork: .wifi
        )
        base.controlChannelConnected = true
        base.ipadPreviewChannelConnected = true
        base.lastControlActivityAt = Date()
        base.queuePendingCount = 2
        base.queueRunningCount = 1
        base.queueRetryingCount = 1
        base.queueFailedCount = 1
        base.oldestCriticalJobAge = 17

        await service.runSafeChecks(using: base)

        #expect(service.result(for: .authentication)?.status == .passed)
        #expect(service.result(for: .controlChannel)?.status == .passed)
        #expect(service.result(for: .previewChannel)?.status == .passed)
        #expect(service.result(for: .networkFreshness)?.status == .passed)
        #expect(service.result(for: .reconnectState)?.status == .passed)
        #expect(service.result(for: .queueHealth)?.detail.contains("pending=2") == true)
        #expect(service.result(for: .queueHealth)?.detail.contains("oldest critical job=17s") == true)

        base.reconnectInProgress = true
        base.reconnectAttempt = 2
        await service.runSafeChecks(using: base)
        #expect(service.result(for: .reconnectState)?.status == .warning)

        base.reconnectInProgress = false
        base.lastControlActivityAt = Date().addingTimeInterval(-9)
        await service.runSafeChecks(using: base)
        #expect(service.result(for: .networkFreshness)?.status == .failed)
    }

    @Test("authenticated iPad requires secure and verified asset channels")
    @MainActor
    func secureAndAssetChannelsAreRequired() async {
        let service = BoothPreflightService()
        var base = context(ipadConnected: true, effectiveNetwork: .wifi)
        base.controlChannelConnected = true
        base.ipadPreviewChannelConnected = true
        base.lastControlActivityAt = Date()
        base.secureTransportReady = false
        base.assetChannelConnected = true
        base.assetChannelVerified = false

        await service.runSafeChecks(using: base)

        #expect(service.result(for: .secureTransport)?.status == .failed)
        #expect(service.result(for: .assetChannel)?.status == .failed)
        #expect(service.readiness == .notReady)
    }

    @Test("disk thresholds are reported")
    @MainActor
    func diskThresholds() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(availableDiskBytes: 1_000_000_000))
        #expect(service.result(for: .diskSpace)?.status == .failed)
        await service.runSafeChecks(using: context(availableDiskBytes: 3_000_000_000))
        #expect(service.result(for: .diskSpace)?.status == .warning)
    }

    @Test("cloud disabled is skipped")
    @MainActor
    func cloudDisabledSkips() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context())
        #expect(service.result(for: .cloudUpload)?.status == .skipped)
    }

    @Test("automatic printing requires a configured printer")
    @MainActor
    func autoPrintRequiresPrinter() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(automaticPrintingEnabled: true))
        #expect(service.result(for: .printerConfiguration)?.status == .failed)
    }

    @Test("required and optional queue failures have different readiness effects")
    @MainActor
    func queueFailures() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(optionalJobPendingOrFailed: true))
        #expect(service.result(for: .queueHealth)?.status == .warning)
        #expect(service.readiness == .readyWithWarnings)
        await service.runSafeChecks(using: context(requiredJobFailed: true))
        #expect(service.readiness == .notReady)
    }

    @Test("unfinished capture blocks readiness")
    @MainActor
    func unfinishedCaptureBlocks() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(unfinishedCaptureSession: true))
        #expect(service.result(for: .unfinishedSession)?.status == .failed)
        #expect(service.readiness == .notReady)
    }

    @Test("AVFoundation permission denial blocks AVFoundation capture")
    @MainActor
    func avFoundationPermissionDenialBlocksCapture() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(cameraPermissionGranted: false))
        #expect(service.result(for: .cameraPermission)?.status == .failed)
        #expect(service.readiness == .notReady)
    }

    @Test("DSLR capture is independent from AVFoundation permission")
    @MainActor
    func dslrCaptureIgnoresAVFoundationPermission() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(
            cameraSourceKind: .dslr,
            cameraPermissionGranted: false,
            cameraConnected: true,
            previewPermissionGranted: false,
            previewConnected: false
        ))
        #expect(service.result(for: .cameraConnection)?.status == .passed)
        #expect(service.result(for: .cameraPermission)?.status == .warning)
        #expect(service.readiness == .readyWithWarnings)
    }

    @Test("disconnected DSLR blocks capture")
    @MainActor
    func disconnectedDSLRBlocksCapture() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(cameraSourceKind: .dslr, cameraConnected: false))
        #expect(service.result(for: .cameraConnection)?.status == .failed)
        #expect(service.readiness == .notReady)
    }

    @Test("optional DSLR preview failure is a warning")
    @MainActor
    func optionalPreviewFailureWarns() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(
            cameraSourceKind: .dslr,
            cameraPermissionGranted: false,
            cameraConnected: true,
            previewPermissionGranted: false,
            previewConnected: false,
            previewRequired: false
        ))
        #expect(service.result(for: .cameraConnection)?.status == .passed)
        #expect(service.readiness == .readyWithWarnings)
    }

    @Test("unavailable runtime storage blocks readiness")
    @MainActor
    func unavailableRuntimeStorageBlocksReadiness() async {
        let service = BoothPreflightService()
        await service.runSafeChecks(using: context(startupComponents: [
            .runtimeDirectory: StartupComponentHealth(status: .unavailable, detail: "Runtime directory is unavailable.")
        ]))
        #expect(service.result(for: .runtimePersistence)?.status == .failed)
        #expect(service.readiness == .notReady)
    }
@Test("unknown disk space is a warning, not a fabricated low-space failure")
@MainActor
func unknownDiskSpaceWarns() async {
    let service = BoothPreflightService()
    await service.runSafeChecks(using: context(availableDiskBytes: nil))
    #expect(service.result(for: .diskSpace)?.status == .warning)
    #expect(service.result(for: .diskSpace)?.detail == "Available disk space could not be determined.")
}

@Test("full preflight maps printer submitted, cancelled, and backend failure")
@MainActor
func fullPreflightPrinterOutcomes() async {
    let service = BoothPreflightService()
    let base = context()

    await service.runFullPreflight(using: base, runPrinterTest: true, cameraTest: {}, printerTest: { .submitted })
    #expect(service.result(for: .printerTest)?.status == .passed)

    await service.runFullPreflight(using: base, runPrinterTest: true, cameraTest: {}, printerTest: { .cancelled })
    #expect(service.result(for: .printerTest)?.status == .skipped)
    #expect(service.result(for: .printerTest)?.detail == "Printer test cancelled by operator.")

    await service.runFullPreflight(
        using: base,
        runPrinterTest: true,
        cameraTest: {},
        printerTest: { throw TestPreflightError.printerOffline }
    )
    #expect(service.result(for: .printerTest)?.status == .failed)
}

@Test("a stored cancelled printer test remains skipped on safe checks")
@MainActor
func storedCancelledPrinterTestSkips() async {
    let service = BoothPreflightService()
    var base = context()
    let cancelled = PrinterTestResult(
        date: Date(),
        printerName: "Canon",
        isSuccess: false,
        message: "Printer test cancelled by operator.",
        outcome: .cancelled
    )

    base.printerTestResult = cancelled
    await service.runSafeChecks(using: base)
    #expect(service.result(for: .printerTest)?.status == .skipped)
}

@Test("guest delivery security checks report passed for HTTPS, warning for trusted LAN, and fail if required QR is disabled")
@MainActor
func guestDeliverySecurityCheck() async {
    let service = BoothPreflightService()

    // 1. HTTPS public base -> passed
    var ctx = context(publicBaseURL: "https://photos.example.com")
    ctx.cloudUploadEnabled = true
    await service.runSafeChecks(using: ctx)
    #expect(service.result(for: .guestDeliverySecurity)?.status == .passed)

    // 2. Trusted private LAN HTTP -> warning
    var ctxLAN = context(allowTrustedLocalHTTP: true)
    ctxLAN.cloudUploadEnabled = false
    await service.runSafeChecks(using: ctxLAN)
    #expect(service.result(for: .guestDeliverySecurity)?.status == .warning)

    // 3. Disabled with QR elements in template -> failed
    let qrElement = SharedQRCodeElement(normalizedRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
    let eventWithQR = EventConfig(photoCount: 1, slots: [SharedPhotoSlot(photoIndex: 0)], qrCodeElements: [qrElement])
    var ctxQR = context(event: eventWithQR, allowTrustedLocalHTTP: false)
    ctxQR.cloudUploadEnabled = false
    await service.runSafeChecks(using: ctxQR)
    #expect(service.result(for: .guestDeliverySecurity)?.status == .failed)

    // 4. Disabled without QR elements in template -> warning (not failed)
    let eventNoQR = EventConfig(photoCount: 1, slots: [SharedPhotoSlot(photoIndex: 0)], qrCodeElements: [])
    var ctxNoQR = context(event: eventNoQR, allowTrustedLocalHTTP: false)
    ctxNoQR.cloudUploadEnabled = false
    await service.runSafeChecks(using: ctxNoQR)
    #expect(service.result(for: .guestDeliverySecurity)?.status == .warning)
}
}

private enum TestPreflightError: LocalizedError {
    case printerOffline
    var errorDescription: String? { "Printer offline" }
}

private func context(
    event: EventConfig? = EventConfig(photoCount: 1, slots: [SharedPhotoSlot(photoIndex: 0)]),
    customerDisplayReady: Bool = true,
    ipadConnected: Bool = false,
    secureTransportReady: Bool = true,
    assetChannelConnected: Bool = true,
    assetChannelVerified: Bool = true,
    requestedNetwork: BoothNetworkPreference = .wifi,
    effectiveNetwork: BoothEffectiveNetworkTransport = .unavailable,
    wifiPathAvailable: Bool = true,
    lanPathAvailable: Bool = false,
    networkFallbackActive: Bool = false,
    availableDiskBytes: Int64? = 12_000_000_000,
    automaticPrintingEnabled: Bool = false,
    requiredJobFailed: Bool = false,
    optionalJobPendingOrFailed: Bool = false,
    unfinishedCaptureSession: Bool = false,
    cameraSourceKind: CameraSourceKind = .avFoundation,
    cameraPermissionGranted: Bool = true,
    cameraConnected: Bool = true,
    previewPermissionGranted: Bool = true,
    previewConnected: Bool = true,
    previewRequired: Bool = false,
    startupComponents: [StartupComponent: StartupComponentHealth] = [:],
    allowTrustedLocalHTTP: Bool = false,
    publicBaseURL: String? = nil
) -> BoothPreflightContext {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-Preflight-\(UUID().uuidString)")
    return BoothPreflightContext(
        event: event,
        cameraPermissionGranted: cameraPermissionGranted,
        cameraConnected: cameraConnected,
        cameraSourceKind: cameraSourceKind,
        previewPermissionGranted: previewPermissionGranted,
        previewConnected: previewConnected,
        previewRequired: previewRequired,
        customerDisplayReady: customerDisplayReady,
        ipadConnected: ipadConnected,
        secureTransportReady: secureTransportReady,
        assetChannelConnected: assetChannelConnected,
        assetChannelVerified: assetChannelVerified,
        requestedNetwork: requestedNetwork,
        effectiveNetwork: effectiveNetwork,
        wifiPathAvailable: wifiPathAvailable,
        lanPathAvailable: lanPathAvailable,
        networkFallbackActive: networkFallbackActive,
        outputFolderURL: output,
        availableDiskBytes: availableDiskBytes,
        localServerStatus: LocalWebServerStatus(state: .ready(port: 8585), registeredTokenCount: 0),
        localServerHealthPassed: true,
        localIPAddress: "192.168.1.5",
        runtimeDirectoryURL: output.appendingPathComponent("Runtime"),
        runtimePersistenceAvailable: true,
        queuePersistenceAvailable: true,
        unfinishedCaptureSession: unfinishedCaptureSession,
        requiredJobFailed: requiredJobFailed,
        optionalJobPendingOrFailed: optionalJobPendingOrFailed,
        cloudUploadEnabled: false,
        allowTrustedLocalHTTP: allowTrustedLocalHTTP,
        publicBaseURL: publicBaseURL,
        cloudSetupComplete: false,
        cloudConnectivityPassed: false,
        automaticPrintingEnabled: automaticPrintingEnabled,
        printerConfigured: false,
        printerTestResult: nil,
        startupComponents: startupComponents
    )
}
