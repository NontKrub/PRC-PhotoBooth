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
}

private func context(
    event: EventConfig? = EventConfig(photoCount: 1, slots: [SharedPhotoSlot(photoIndex: 0)]),
    customerDisplayReady: Bool = true,
    ipadConnected: Bool = false,
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
    startupComponents: [StartupComponent: StartupComponentHealth] = [:]
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
        cloudSetupComplete: false,
        cloudConnectivityPassed: false,
        automaticPrintingEnabled: automaticPrintingEnabled,
        printerConfigured: false,
        printerTestResult: nil,
        startupComponents: startupComponents
    )
}
