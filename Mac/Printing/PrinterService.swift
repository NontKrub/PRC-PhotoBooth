import Foundation
import AppKit
import Observation

enum ConfiguredPrinterStatus: Sendable, Equatable {
    case systemDefault
    case available(name: String)
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
    var printerName: String?
    var paperSizeRawValue: String
    var copies: Int
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
    private let defaults: UserDefaults

    private(set) var availablePrinterNames: [String] = []
    private(set) var lastTestResult: PrinterTestResult?
    private(set) var isPrinting = false

    init(backend: any PrinterBackend = AppKitPrinterBackend(), defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
        refreshPrinters()
    }

    func refreshPrinters() {
        availablePrinterNames = backend.availablePrinterNames()
        if !defaults.bool(forKey: "selphySkipPrintDialog") || !hasConfiguredPrinter {
            defaults.set(false, forKey: "selphyAutoPrintAfterSession")
        }
        invalidateTestResult()
    }

    func configuredPrinterStatus() -> ConfiguredPrinterStatus {
        let saved = defaults.string(forKey: "selphyPrinterName") ?? ""
        guard !saved.isEmpty else { return .systemDefault }
        return availablePrinterNames.contains(saved) ? .available(name: saved) : .unavailable(name: saved)
    }

    func invalidateTestResult() {
        lastTestResult = nil
    }

    func printTestPage() async throws {
        let status = configuredPrinterStatus()
        let printerName: String?
        do {
            printerName = try selectedPrinterName(for: status)
        } catch {
            lastTestResult = PrinterTestResult(
                date: Date(),
                printerName: configuredPrinterLabel,
                isSuccess: false,
                message: error.localizedDescription
            )
            throw JobExecutionError.retryable(error.localizedDescription)
        }
        let request = PrinterPrintRequest(
            sourceURL: nil,
            isTestPage: true,
            printerName: printerName,
            paperSizeRawValue: paperSizeRawValue,
            copies: copies,
            showsPrintDialog: false,
            testDate: Date()
        )
        isPrinting = true
        defer { isPrinting = false }
        do {
            try await backend.submit(request)
            lastTestResult = PrinterTestResult(
                date: request.testDate,
                printerName: printerName ?? "System Default",
                isSuccess: true,
                message: "Test print submitted."
            )
        } catch {
            lastTestResult = PrinterTestResult(
                date: request.testDate,
                printerName: printerName ?? "System Default",
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
        let status = configuredPrinterStatus()
        let printerName: String?
        do {
            printerName = try selectedPrinterName(for: status)
        } catch {
            throw JobExecutionError.retryable(error.localizedDescription)
        }
        let request = PrinterPrintRequest(
            sourceURL: url,
            isTestPage: false,
            printerName: printerName,
            paperSizeRawValue: paperSizeRawValue,
            copies: copies,
            showsPrintDialog: showPrintDialog,
            testDate: Date()
        )
        isPrinting = true
        defer { isPrinting = false }
        do {
            try await backend.submit(request)
        } catch {
            throw JobExecutionError.retryable(error.localizedDescription)
        }
    }

    private var paperSizeRawValue: String {
        defaults.string(forKey: "selphyPaperSize") ?? SelphyPaperSize.postcard.rawValue
    }

    private var copies: Int {
        max(1, defaults.integer(forKey: "selphyCopies"))
    }

    private var configuredPrinterLabel: String {
        switch configuredPrinterStatus() {
        case .systemDefault: return "System Default"
        case .available(let name), .unavailable(let name): return name
        }
    }

    private var hasConfiguredPrinter: Bool {
        switch configuredPrinterStatus() {
        case .available: return true
        case .unavailable: return false
        case .systemDefault:
            guard let name = backend.defaultPrinterName() else { return false }
            return availablePrinterNames.contains(name)
        }
    }

    private func selectedPrinterName(for status: ConfiguredPrinterStatus) throws -> String? {
        switch status {
        case .systemDefault: return nil
        case .available(let name): return name
        case .unavailable(let name): throw PrinterServiceError.unavailable(name)
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
        let paper = SelphyPaperSize(rawValue: request.paperSizeRawValue) ?? .postcard
        let view: NSView
        if let sourceURL = request.sourceURL,
           let image = NSImage(contentsOf: sourceURL) {
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: paper.pointSize))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            view = imageView
        } else {
            view = PrinterTestPageView(
                frame: NSRect(origin: .zero, size: paper.pointSize),
                printerName: request.printerName ?? "System Default",
                paperSize: paper.rawValue,
                date: request.testDate
            )
        }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        if let printerName = request.printerName {
            guard let printer = NSPrinter(name: printerName) else {
                throw PrinterServiceError.unavailable(printerName)
            }
            printInfo.printer = printer
        }
        printInfo.paperSize = paper.pointSize
        printInfo.orientation = .portrait
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.dictionary().setValue(request.copies, forKey: "NSCopies")

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.showsPrintPanel = request.showsPrintDialog
        operation.showsProgressPanel = true
        guard operation.run() else { throw PrinterServiceError.rejected }
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
    case rejected

    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "Configured printer unavailable: \(name)"
        case .rejected: return "The print operation was rejected."
        }
    }
}
