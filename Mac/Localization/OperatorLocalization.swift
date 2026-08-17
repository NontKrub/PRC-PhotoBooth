import Foundation

func operatorString(_ key: String, locale: Locale) -> String {
    let language = locale.language.languageCode?.identifier ?? locale.identifier.split(separator: "_").first.map(String.init) ?? "en"
    let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? .main
    return bundle.localizedString(forKey: key, value: key, table: "Localizable")
}

func operatorFormat(_ key: String, locale: Locale, _ arguments: String...) -> String {
    String(
        format: operatorString(key, locale: locale),
        locale: locale,
        arguments: arguments
    )
}

func operatorPhotoSummary(photoCount: Int, countdownSeconds: Int, locale: Locale) -> String {
    operatorFormat(
        "%@ photos · %@s countdown",
        locale: locale,
        String(photoCount),
        String(countdownSeconds)
    )
}

func operatorCustomerLanguage(for locale: Locale) -> CustomerLanguage {
    locale.identifier.lowercased().hasPrefix("th") ? .thai : .english
}

func operatorCameraSourceName(_ source: CameraSourceKind, locale: Locale) -> String {
    operatorString(source.rawValue, locale: locale)
}

@MainActor
func operatorConnectingRoute(_ status: BoothConnectionStatus, locale: Locale) -> String {
    switch status.routeState {
    case .connectingLAN:
        return operatorString("Connecting via LAN…", locale: locale)
    case .connectingWiFi where status.requestedNetwork == .lan:
        return operatorString("Switching to Wi-Fi fallback…", locale: locale)
    case .connectingWiFi:
        return operatorString("Connecting via Wi-Fi…", locale: locale)
    case .disconnected, .connectedLAN, .connectedWiFi, .fallbackWiFi:
        return operatorString("Connecting…", locale: locale)
    }
}

func operatorPaperSizeName(_ size: SelphyPaperSize, locale: Locale) -> String {
    operatorString(size.rawValue, locale: locale)
}

func operatorFlashModeName(_ mode: DSLRFlashMode, locale: Locale) -> String {
    operatorString(mode.rawValue, locale: locale)
}

func operatorGalleryStatusName(_ status: GalleryApprovalStatus?, locale: Locale) -> String {
    guard let status else { return operatorString("All", locale: locale) }
    switch status {
    case .pending: return operatorString("Pending", locale: locale)
    case .approved: return operatorString("Approved", locale: locale)
    case .hidden: return operatorString("Hidden", locale: locale)
    }
}

func operatorJobKindName(_ kind: SessionJobKind, locale: Locale) -> String {
    let key: String
    switch kind {
    case .renderStrip: key = "Render strip"
    case .registerDownload: key = "Register download"
    case .updateGallery: key = "Update gallery"
    case .renderGIF: key = "Render GIF"
    case .cloudUpload: key = "Cloud upload"
    case .autoPrint: key = "Automatic print"
    }
    return operatorString(key, locale: locale)
}

func operatorJobStatusName(_ status: SessionJobStatus, locale: Locale) -> String {
    switch status {
    case .pending: return operatorString("Pending", locale: locale)
    case .running: return operatorString("Running", locale: locale)
    case .waitingRetry: return operatorString("Waiting", locale: locale)
    case .succeeded: return operatorString("Completed", locale: locale)
    case .failed: return operatorString("Failed", locale: locale)
    case .cancelled: return operatorString("Cancelled", locale: locale)
    }
}

func operatorPreflightTitle(_ id: PreflightCheckID, locale: Locale) -> String {
    let key: String
    switch id {
    case .activeEvent: key = "Active event"
    case .eventLayout: key = "Event layout"
    case .eventExperience: key = "Event experience"
    case .templateAssets: key = "Template assets"
    case .filterPipeline: key = "Filter pipeline"
    case .galleryStorage: key = "Gallery storage"
    case .cameraPermission: key = "Camera permission"
    case .cameraConnection: key = "Camera connection"
    case .cameraTestCapture: key = "Camera test capture"
    case .customerDisplay: key = "Customer display"
    case .wifiPath: key = "Wi-Fi path"
    case .lanPath: key = "LAN path"
    case .ipadTransport: key = "iPad transport"
    case .networkRoute: key = "Effective network route"
    case .outputFolder: key = "Output folder"
    case .diskSpace: key = "Disk space"
    case .localDownloadServer: key = "Local download server"
    case .localIPAddress: key = "Local IP address"
    case .runtimePersistence: key = "Runtime persistence"
    case .recoveryStorage: key = "Recovery storage"
    case .unfinishedSession: key = "Unfinished session"
    case .queueHealth: key = "Queue health"
    case .cloudUpload: key = "Cloud upload"
    case .printerConfiguration: key = "Printer configuration"
    case .printerTest: key = "Printer test"
    }
    return operatorString(key, locale: locale)
}

func operatorPreflightStatusName(_ status: PreflightCheckStatus, locale: Locale) -> String {
    switch status {
    case .passed: return operatorString("Passed", locale: locale)
    case .warning: return operatorString("Warning", locale: locale)
    case .failed: return operatorString("Failed", locale: locale)
    case .running: return operatorString("Running", locale: locale)
    case .notRun: return operatorString("Not run", locale: locale)
    case .skipped: return operatorString("Skipped", locale: locale)
    }
}

func operatorPreflightDetail(_ result: PreflightCheckResult, locale: Locale) -> String {
    if result.detail.hasPrefix("Active event: "), result.detail.hasSuffix(".") {
        let name = String(result.detail.dropFirst("Active event: ".count).dropLast())
        return operatorFormat("Active event: %@.", locale: locale, name)
    }
    if result.detail.hasPrefix("Gallery storage warning: ") {
        let message = String(result.detail.dropFirst("Gallery storage warning: ".count))
        return operatorFormat("Gallery storage warning: %@", locale: locale, message)
    }
    return operatorString(result.detail, locale: locale)
}

func operatorPhaseName(_ phase: BoothPhase, locale: Locale) -> String {
    switch phase {
    case .idle: return operatorString("Idle", locale: locale)
    case .selectingExperience: return operatorString("Selecting experience", locale: locale)
    case .readyToStart: return operatorString("Ready", locale: locale)
    case .countdown(let index, let seconds):
        return "\(operatorString("Countdown", locale: locale)) [\(index + 1)] \(seconds)s"
    case .captured(let index):
        return "\(operatorString("Captured", locale: locale)) [\(index + 1)]"
    case .review(let index):
        return "\(operatorString("Review", locale: locale)) [\(index + 1)]"
    case .captureRecovery(let index, _):
        return "\(operatorString("Capture recovery", locale: locale)) [\(index + 1)]"
    case .processing: return operatorString("Processing", locale: locale)
    case .finished: return operatorString("Finished", locale: locale)
    }
}
