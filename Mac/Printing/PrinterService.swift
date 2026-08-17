import Foundation
import AppKit
import Observation

enum ConfiguredPrinterStatus: Sendable, Equatable {
    case systemDefault
    case unavailable(name: String)
}

struct PrinterTestResult: Sendable, Equatable {
    var date: Date
    var printerName: String
    var isSuccess: Bool
    var message: String
}

@MainActor
struct PrinterPrintRequest {
    var sourceURL: URL?
    var isTestPage: Bool
    var showsPrintDialog: Bool
    var testDate: Date
}

@MainActor
protocol PrinterBackend: AnyObject {
    func availablePrinterNames() -> [String]
    func defaultPrinterName() -> String?
    func submit(_ request: PrinterPrintRequest) async throws
}

@MainActor
@Observable
final class PrinterService {
    private let backend: any PrinterBackend

    private(set) var availablePrinterNames: [String] = []
    private(set) var lastTestResult: PrinterTestResult?
    private(set) var isPrinting = false
    private(set) var printRequestCount = 0
    private(set) var printSuccessCount = 0
    private(set) var printFailureCount = 0
    private(set) var lastPrintAt: Date?
    private(set) var lastPrintError: String?

    init(backend: any PrinterBackend = AppKitPrinterBackend()) {
        self.backend = backend
        refreshPrinters()
    }

    func refreshPrinters() {
        availablePrinterNames = backend.availablePrinterNames()
        invalidateTestResult()
    }

    func configuredPrinterStatus() -> ConfiguredPrinterStatus {
        guard let name = backend.defaultPrinterName(), !name.isEmpty else {
            return .unavailable(name: "No system default printer")
        }
        return availablePrinterNames.isEmpty || availablePrinterNames.contains(name)
            ? .systemDefault
            : .unavailable(name: name)
    }

    func invalidateTestResult() {
        lastTestResult = nil
    }

    func printTestPage() async throws {
        let request = PrinterPrintRequest(
            sourceURL: nil,
            isTestPage: true,
            showsPrintDialog: true,
            testDate: Date()
        )
        isPrinting = true
        printRequestCount += 1
        defer { isPrinting = false }
        do {
            try await backend.submit(request)
            printSuccessCount += 1
            lastPrintAt = request.testDate
            lastPrintError = nil
            lastTestResult = PrinterTestResult(
                date: request.testDate,
                printerName: backend.defaultPrinterName() ?? "System Default",
                isSuccess: true,
                message: "Test print submitted."
            )
        } catch {
            if case PrinterServiceError.cancelled = error {
                lastTestResult = PrinterTestResult(
                    date: request.testDate,
                    printerName: backend.defaultPrinterName() ?? "System Default",
                    isSuccess: false,
                    message: "Print dialog cancelled."
                )
                return
            }
            printFailureCount += 1
            lastPrintAt = request.testDate
            lastPrintError = error.localizedDescription
            lastTestResult = PrinterTestResult(
                date: request.testDate,
                printerName: backend.defaultPrinterName() ?? "System Default",
                isSuccess: false,
                message: error.localizedDescription
            )
            throw JobExecutionError.retryable(error.localizedDescription)
        }
    }

    func printStrip(at url: URL, showPrintDialog: Bool) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw JobExecutionError.permanent("Photo strip is missing: \(url.path)")
        }
        let request = PrinterPrintRequest(
            sourceURL: url,
            isTestPage: false,
            showsPrintDialog: showPrintDialog,
            testDate: Date()
        )
        isPrinting = true
        printRequestCount += 1
        defer { isPrinting = false }
        do {
            try await backend.submit(request)
            printSuccessCount += 1
            lastPrintAt = request.testDate
            lastPrintError = nil
        } catch {
            if case PrinterServiceError.cancelled = error {
                return
            }
            printFailureCount += 1
            lastPrintAt = request.testDate
            lastPrintError = error.localizedDescription
            throw JobExecutionError.retryable(error.localizedDescription)
        }
    }

}

@MainActor
private final class AppKitPrinterBackend: PrinterBackend {
    func availablePrinterNames() -> [String] {
        NSPrinter.printerNames
    }

    func defaultPrinterName() -> String? {
        NSPrintInfo.shared.printer.name
    }

    func submit(_ request: PrinterPrintRequest) async throws {
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        let paperSize = printInfo.paperSize
        let view: NSView
        if let sourceURL = request.sourceURL,
           let image = NSImage(contentsOf: sourceURL) {
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: paperSize))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            view = imageView
        } else {
            view = PrinterTestPageView(
                frame: NSRect(origin: .zero, size: paperSize),
                printerName: printInfo.printer.name,
                paperSize: "\(Int(paperSize.width)) × \(Int(paperSize.height)) pt",
                date: request.testDate
            )
        }

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.showsPrintPanel = request.showsPrintDialog
        operation.showsProgressPanel = true
        guard operation.run() else {
            throw request.showsPrintDialog ? PrinterServiceError.cancelled : PrinterServiceError.rejected
        }
    }
}

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
    case cancelled
    case rejected

    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "Configured printer unavailable: \(name)"
        case .cancelled: return "Print dialog cancelled."
        case .rejected: return "The print operation was rejected."
        }
    }
}
