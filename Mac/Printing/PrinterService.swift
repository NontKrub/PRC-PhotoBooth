import AppKit
import Foundation
import ImageIO
import Observation

enum ConfiguredPrinterStatus: Sendable, Equatable {
    case systemDefault
    case unavailable(name: String)
}

enum PrintSubmissionOutcome: Sendable, Equatable {
    case submitted
    case cancelled
    case unknown
}

enum PrinterLifecycleState: Sendable, Equatable {
    case idle
    case submitting(operationID: UUID, startedAt: Date)
    case unknownAwaitingAppKitCompletion(operationID: UUID, startedAt: Date, timedOutAt: Date)
}

struct PrinterTestResult: Sendable, Equatable {
    var date: Date
    var printerName: String
    var isSuccess: Bool
    var message: String
    var outcome: PrintSubmissionOutcome? = nil
}

enum PrinterDocument: Equatable, Sendable {
    case testPage(date: Date)
    case photoStrip(URL)
}

enum PrintLayoutMode: String, CaseIterable, Equatable, Sendable {
    case fit
    case fill

    var title: String {
        switch self {
        case .fit: return "Fit to Page"
        case .fill: return "Fill Page"
        }
    }
}

enum PrintLayoutGeometry {
    static func destinationRect(
        imageSize: CGSize,
        printableBounds: CGRect,
        mode: PrintLayoutMode
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              printableBounds.width > 0,
              printableBounds.height > 0 else {
            return .zero
        }

        let scale: CGFloat
        switch mode {
        case .fit:
            scale = min(
                printableBounds.width / imageSize.width,
                printableBounds.height / imageSize.height
            )
        case .fill:
            scale = max(
                printableBounds.width / imageSize.width,
                printableBounds.height / imageSize.height
            )
        }

        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: printableBounds.midX - size.width / 2,
            y: printableBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

nonisolated enum PrinterDocumentValidator {
    static func isReadableImage(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
            && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}

@MainActor
struct PrinterPrintRequest {
    let document: PrinterDocument
    let showsPrintDialog: Bool

    var showsProgressPanel: Bool { showsPrintDialog }
    var canSpawnSeparateThread: Bool { true }
}

@MainActor
protocol PrinterBackend: AnyObject {
    func availablePrinterNames() -> [String]
    func defaultPrinterName() -> String?
    func submit(_ request: PrinterPrintRequest) async throws
    func setOperationCompletionHandler(_ handler: (@MainActor @Sendable () -> Void)?)
}

@MainActor
extension PrinterBackend {
    func setOperationCompletionHandler(_ handler: (@MainActor @Sendable () -> Void)?) {}
}

@MainActor
@Observable
final class PrinterService {
    nonisolated static let printOperationTimeout: TimeInterval = 300

    private let backend: any PrinterBackend

    private(set) var availablePrinterNames: [String] = []
    private(set) var lastTestResult: PrinterTestResult?
    private(set) var lifecycleState: PrinterLifecycleState = .idle
    private(set) var printRequestCount = 0
    private(set) var printSuccessCount = 0
    private(set) var printFailureCount = 0
    private(set) var lastPrintAt: Date?
    private(set) var lastPrintError: String?
    private(set) var currentPrintStartedAt: Date?

    init(backend: any PrinterBackend = AppKitPrinterBackend()) {
        self.backend = backend
        backend.setOperationCompletionHandler { [weak self] in
            self?.operationDidComplete()
        }
        refreshPrinters()
    }

    var isPrinting: Bool { lifecycleState != .idle }
    var isIdle: Bool { lifecycleState == .idle }

    func resolveUnknownPrint(as outcome: PrintSubmissionOutcome) {
        guard case .unknownAwaitingAppKitCompletion = lifecycleState,
              outcome != .unknown else { return }
        endPrint()
    }

    func refreshPrinters() {
        availablePrinterNames = backend.availablePrinterNames()
        if let result = lastTestResult, result.printerName != backend.defaultPrinterName() {
            lastTestResult = nil
        }
    }

    func configuredPrinterStatus() -> ConfiguredPrinterStatus {
        guard let name = backend.defaultPrinterName(), !name.isEmpty else {
            return .unavailable(name: "No system default printer")
        }
        return availablePrinterNames.contains(name)
            ? .systemDefault
            : .unavailable(name: name)
    }

    func clearTestResult() {
        lastTestResult = nil
    }

    func printTestPage() async throws -> PrintSubmissionOutcome {
        refreshPrinters()
        let date = Date()
        let request = PrinterPrintRequest(
            document: .testPage(date: date),
            showsPrintDialog: true
        )
        try beginPrint()
        var releaseLane = true
        defer { if releaseLane { endPrint() } }
        do {
            try await backend.submit(request)
            printSuccessCount += 1
            lastPrintAt = date
            lastPrintError = nil
            lastTestResult = PrinterTestResult(
                date: date,
                printerName: backend.defaultPrinterName() ?? "System Default",
                isSuccess: true,
                message: "Test print submitted.",
                outcome: .submitted
            )
            return .submitted
        } catch {
            if case PrinterServiceError.cancelled = error {
                lastTestResult = PrinterTestResult(
                    date: date,
                    printerName: backend.defaultPrinterName() ?? "System Default",
                    isSuccess: false,
                    message: "Print dialog cancelled by operator.",
                    outcome: .cancelled
                )
                return .cancelled
            }
            if case PrinterServiceError.timeout = error {
                releaseLane = false
                markPrintUnknown()
                printFailureCount += 1
                lastPrintAt = date
                lastPrintError = error.localizedDescription
                lastTestResult = PrinterTestResult(
                    date: date,
                    printerName: backend.defaultPrinterName() ?? "System Default",
                    isSuccess: false,
                    message: error.localizedDescription,
                    outcome: .unknown
                )
                throw JobExecutionError.sideEffectUnknown(error.localizedDescription)
            }
            printFailureCount += 1
            lastPrintAt = date
            lastPrintError = error.localizedDescription
            lastTestResult = PrinterTestResult(
                date: date,
                printerName: backend.defaultPrinterName() ?? "System Default",
                isSuccess: false,
                message: error.localizedDescription,
                outcome: nil
            )
            throw JobExecutionError.retryable(error.localizedDescription)
        }
    }

    func printStrip(at url: URL, showPrintDialog: Bool) async throws {
        refreshPrinters()
        let isReadableImage = await Task.detached(priority: .utility) {
            PrinterDocumentValidator.isReadableImage(at: url)
        }.value
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw JobExecutionError.permanent(PrinterServiceError.missingSource(url).localizedDescription)
        }
        guard isReadableImage else {
            throw JobExecutionError.permanent(PrinterServiceError.invalidImage(url).localizedDescription)
        }

        let request = PrinterPrintRequest(
            document: .photoStrip(url),
            showsPrintDialog: showPrintDialog
        )
        try beginPrint()
        var releaseLane = true
        defer { if releaseLane { endPrint() } }
        do {
            try await backend.submit(request)
            printSuccessCount += 1
            lastPrintAt = Date()
            lastPrintError = nil
        } catch {
            if case PrinterServiceError.cancelled = error { return }
            printFailureCount += 1
            lastPrintAt = Date()
            lastPrintError = error.localizedDescription
            if case PrinterServiceError.timeout = error {
                releaseLane = false
                markPrintUnknown()
                throw JobExecutionError.sideEffectUnknown(error.localizedDescription)
            }
            if let error = error as? PrinterServiceError, error.isPermanent {
                throw JobExecutionError.permanent(error.localizedDescription)
            }
            throw JobExecutionError.retryable(error.localizedDescription)
        }
    }

    private func beginPrint() throws {
        guard case .idle = lifecycleState else { throw PrinterServiceError.busy }
        let operationID = UUID()
        let startedAt = Date()
        lifecycleState = .submitting(operationID: operationID, startedAt: startedAt)
        currentPrintStartedAt = startedAt
        printRequestCount += 1
    }

    private func endPrint() {
        lifecycleState = .idle
        currentPrintStartedAt = nil
    }

    private func markPrintUnknown() {
        guard case .submitting(let operationID, let startedAt) = lifecycleState else { return }
        lifecycleState = .unknownAwaitingAppKitCompletion(
            operationID: operationID,
            startedAt: startedAt,
            timedOutAt: Date()
        )
    }

    private func operationDidComplete() {
        guard case .unknownAwaitingAppKitCompletion = lifecycleState else { return }
        endPrint()
    }

}

private enum PrintRunResult: Sendable {
    case completed(Bool)
    case timedOut
}

@MainActor
private final class AppKitPrinterBackend: PrinterBackend {
    private var activeDelegates: [ObjectIdentifier: PrintOperationDelegate] = [:]
    private var operationCompletionHandler: (@MainActor @Sendable () -> Void)?

    func availablePrinterNames() -> [String] {
        NSPrinter.printerNames
    }

    func defaultPrinterName() -> String? {
        NSPrintInfo.shared.printer.name
    }

    func setOperationCompletionHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        operationCompletionHandler = handler
    }

    func submit(_ request: PrinterPrintRequest) async throws {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            throw PrinterServiceError.unavailable("Print configuration unavailable")
        }
        let imageableBounds = printInfo.imageablePageBounds
        let printableFrame = NSRect(origin: .zero, size: imageableBounds.size)
        let view: NSView

        switch request.document {
        case .testPage(let date):
            view = PrinterTestPageView(
                frame: printableFrame,
                printerName: printInfo.printer.name,
                paperSize: "\(Int(imageableBounds.width)) × \(Int(imageableBounds.height)) pt",
                date: date
            )
        case .photoStrip(let sourceURL):
            guard let image = NSImage(contentsOf: sourceURL) else {
                throw PrinterServiceError.invalidImage(sourceURL)
            }
            view = PrintablePhotoStripView(image: image, printInfo: printInfo)
        }

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.canSpawnSeparateThread = request.canSpawnSeparateThread
        operation.showsPrintPanel = request.showsPrintDialog
        operation.showsProgressPanel = request.showsProgressPanel
        if request.showsPrintDialog {
            var options = operation.printPanel.options
            options.formUnion([
                .showsCopies,
                .showsPaperSize,
                .showsOrientation,
                .showsScaling,
                .showsPreview,
                .showsPageSetupAccessory
            ])
            operation.printPanel.options = options
            if let printableView = view as? PrintablePhotoStripView {
                operation.printPanel.addAccessoryController(
                    PrintLayoutAccessoryController(printableView: printableView)
                )
            }
        }

        guard let hostWindow = Self.hostWindow() else {
            throw PrinterServiceError.unavailable("No host window is available for printing.")
        }
        let operationID = ObjectIdentifier(operation)
        let timeout = request.showsPrintDialog ? PrinterService.printOperationTimeout : 120
        let result = await withTaskGroup(of: PrintRunResult.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<PrintRunResult, Never>) in
                    Task { @MainActor in
                        let delegate = PrintOperationDelegate(
                            continuation: continuation,
                            onCompletion: { [weak self] in
                                Task { @MainActor [weak self] in
                                    self?.activeDelegates.removeValue(forKey: operationID)
                                    self?.operationCompletionHandler?()
                                }
                            }
                        )
                        self.activeDelegates[operationID] = delegate
                        operation.runModal(
                            for: hostWindow,
                            delegate: delegate,
                            didRun: #selector(PrintOperationDelegate.printOperationDidRun(_:success:contextInfo:)),
                            contextInfo: nil
                        )
                    }
                }
            }
            group.addTask {
                // AppKit normally always calls back. When it does not, the
                // print lane would block for the rest of the app's life.
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return .timedOut }
                await MainActor.run {
                    self.activeDelegates[operationID]?.timeout()
                }
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        switch result {
        case .timedOut:
            throw PrinterServiceError.timeout
        case .completed(let success):
            guard success else {
                throw request.showsPrintDialog ? PrinterServiceError.cancelled : PrinterServiceError.rejected
            }
        }
    }

    private static func hostWindow() -> NSWindow? {
        NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !$0.styleMask.contains(.borderless) })
            ?? NSApp.windows.first(where: { $0.isVisible })
    }
}

private final class PrintOperationDelegate: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PrintRunResult, Never>?
    private var resultDelivered = false
    private var appKitCompleted = false
    private let onCompletion: @Sendable () -> Void

    init(
        continuation: CheckedContinuation<PrintRunResult, Never>,
        onCompletion: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onCompletion = onCompletion
    }

    func complete(_ result: PrintRunResult) {
        lock.lock()
        guard !appKitCompleted else {
            lock.unlock()
            return
        }
        appKitCompleted = true
        let continuation = resultDelivered ? nil : self.continuation
        resultDelivered = true
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
        onCompletion()
    }

    func timeout() {
        lock.lock()
        guard !appKitCompleted, !resultDelivered else {
            lock.unlock()
            return
        }
        resultDelivered = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: .timedOut)
    }

    @objc
    func printOperationDidRun(
        _ printOperation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        complete(.completed(success))
    }
}

@MainActor
private final class PrintablePhotoStripView: NSView {
    private let image: NSImage
    private let printInfo: NSPrintInfo
    var layoutMode: PrintLayoutMode = .fit {
        didSet { needsDisplay = true }
    }

    init(image: NSImage, printInfo: NSPrintInfo) {
        self.image = image
        self.printInfo = printInfo
        super.init(frame: printInfo.imageablePageBounds)
    }

    required init?(coder: NSCoder) {
        fatalError("Printable photo strip does not support NSCoder.")
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        printInfo.imageablePageBounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let printableBounds = printInfo.imageablePageBounds
        NSColor.white.setFill()
        printableBounds.fill()
        let destination = PrintLayoutGeometry.destinationRect(
            imageSize: image.size,
            printableBounds: printableBounds,
            mode: layoutMode
        )
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

@MainActor
private final class PrintLayoutAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    private weak var printableView: PrintablePhotoStripView?
    private let selector: NSSegmentedControl
    @objc dynamic private var selectedLayoutModeRawValue = PrintLayoutMode.fit.rawValue

    init(printableView: PrintablePhotoStripView) {
        self.printableView = printableView
        selector = NSSegmentedControl(
            labels: PrintLayoutMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init(nibName: nil, bundle: nil)
        title = "Photo Layout"
        selector.target = self
        selector.action = #selector(layoutModeChanged(_:))
        selector.selectedSegment = 0
    }

    required init?(coder: NSCoder) {
        fatalError("Print layout accessory does not support NSCoder.")
    }

    override func loadView() {
        let label = NSTextField(labelWithString: "Photo layout")
        let stack = NSStackView(views: [label, selector])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = stack
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[
            .itemName: "Photo Layout",
            .itemDescription: currentMode.title
        ]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        [#keyPath(selectedLayoutModeRawValue)]
    }

    private var currentMode: PrintLayoutMode {
        guard PrintLayoutMode.allCases.indices.contains(selector.selectedSegment) else { return .fit }
        return PrintLayoutMode.allCases[selector.selectedSegment]
    }

    @objc private func layoutModeChanged(_ sender: NSSegmentedControl) {
        guard PrintLayoutMode.allCases.indices.contains(sender.selectedSegment) else { return }
        let mode = currentMode
        willChangeValue(forKey: "localizedSummaryItems")
        selectedLayoutModeRawValue = mode.rawValue
        didChangeValue(forKey: "localizedSummaryItems")
        printableView?.layoutMode = mode
    }
}

@MainActor
private final class PrinterTestPageView: NSView {
    private let printerName: String
    private let paperSize: String
    private let date: Date

    init(frame: NSRect, printerName: String, paperSize: String, date: Date) {
        self.printerName = printerName
        self.paperSize = paperSize
        self.date = date
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("Printer test page does not support NSCoder.")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()

        let area = bounds.insetBy(dx: 18, dy: 18)
        NSColor.black.setStroke()
        NSBezierPath(rect: area).stroke()

        let text = [
            "PRC PhotoBooth Printer Test",
            printerName,
            paperSize,
            DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
        ]
        for (index, line) in text.enumerated() {
            line.draw(
                at: NSPoint(x: area.minX + 16, y: area.maxY - 28 - CGFloat(index * 20)),
                withAttributes: [.font: NSFont.systemFont(ofSize: index == 0 ? 16 : 11)]
            )
        }

        NSColor.gray.setStroke()
        let center = NSBezierPath()
        center.move(to: NSPoint(x: area.midX, y: area.minY))
        center.line(to: NSPoint(x: area.midX, y: area.maxY))
        center.move(to: NSPoint(x: area.minX, y: area.midY))
        center.line(to: NSPoint(x: area.maxX, y: area.midY))
        center.stroke()

        for point in [
            NSPoint(x: area.minX, y: area.minY),
            NSPoint(x: area.minX, y: area.maxY),
            NSPoint(x: area.maxX, y: area.minY),
            NSPoint(x: area.maxX, y: area.maxY)
        ] {
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }
}

enum PrinterServiceError: LocalizedError {
    case unavailable(String)
    case busy
    case cancelled
    case rejected
    case timeout
    case missingSource(URL)
    case invalidImage(URL)

    var isPermanent: Bool {
        switch self {
        case .missingSource, .invalidImage: return true
        case .timeout: return true
        case .unavailable, .busy, .cancelled, .rejected: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "Configured printer unavailable: \(name)"
        case .busy: return "A print is already in progress."
        case .cancelled: return "Print dialog cancelled."
        case .rejected: return "The print operation was rejected."
        case .timeout: return "Print completion could not be confirmed; verify the printer before retrying."
        case .missingSource(let url): return "Photo strip is missing: \(url.path)"
        case .invalidImage(let url): return "Photo strip is unreadable: \(url.path)"
        }
    }
}
