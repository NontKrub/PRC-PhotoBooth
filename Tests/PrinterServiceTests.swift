import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("PrinterService")
struct PrinterServiceTests {
    @Test("lists printers and detects unavailable configured printer")
    @MainActor
    func listsAndDetectsMissingPrinter() {
        let defaults = testDefaults()
        let backend = TestPrinterBackend(names: ["Canon Selphy"], defaultName: "Canon Selphy")
        let printer = PrinterService(backend: backend, defaults: defaults)

        printer.refreshPrinters()
        #expect(printer.availablePrinterNames == ["Canon Selphy"])
        #expect(printer.configuredPrinterStatus() == .systemDefault)

        defaults.set("Missing", forKey: "selphyPrinterName")
        #expect(printer.configuredPrinterStatus() == .unavailable(name: "Missing"))
    }

    @Test("successful and failed test prints update diagnostics")
    @MainActor
    func recordsTestResults() async throws {
        let defaults = testDefaults()
        let backend = TestPrinterBackend(names: ["Canon"], defaultName: "Canon")
        let printer = PrinterService(backend: backend, defaults: defaults)

        try await printer.printTestPage()
        #expect(printer.lastTestResult?.isSuccess == true)
        #expect(await backend.requests.last?.showsPrintDialog == false)

        await backend.failNext(with: TestPrinterError.offline)
        do {
            try await printer.printTestPage()
            Issue.record("Expected test print failure")
        } catch {
            #expect(printer.lastTestResult?.isSuccess == false)
        }
    }

    @Test("printer and paper changes invalidate the test result")
    @MainActor
    func invalidatesTestResult() async throws {
        let defaults = testDefaults()
        let backend = TestPrinterBackend(names: ["Canon", "Other"], defaultName: "Canon")
        let printer = PrinterService(backend: backend, defaults: defaults)

        try await printer.printTestPage()
        #expect(printer.lastTestResult != nil)
        defaults.set("Other", forKey: "selphyPrinterName")
        printer.invalidateTestResult()
        #expect(printer.lastTestResult == nil)

        try await printer.printTestPage()
        defaults.set(SelphyPaperSize.lSize.rawValue, forKey: "selphyPaperSize")
        printer.invalidateTestResult()
        #expect(printer.lastTestResult == nil)
    }

    @Test("interactive printing honors dialog setting")
    @MainActor
    func interactivePrintingHonorsDialog() async throws {
        let defaults = testDefaults()
        let backend = TestPrinterBackend(names: ["Canon"], defaultName: "Canon")
        let printer = PrinterService(backend: backend, defaults: defaults)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await printer.printStrip(at: file, showPrintDialog: true)
        #expect(await backend.requests.last?.showsPrintDialog == true)
        try await printer.printStrip(at: file, showPrintDialog: false)
        #expect(await backend.requests.last?.showsPrintDialog == false)
    }
}

@MainActor
private final class TestPrinterBackend: PrinterBackend {
    struct Request: Sendable {
        var sourceURL: URL?
        var showsPrintDialog: Bool
    }

    let names: [String]
    let defaultName: String?
    private(set) var requests: [Request] = []
    private var nextError: Error?

    init(names: [String], defaultName: String?) {
        self.names = names
        self.defaultName = defaultName
    }

    func availablePrinterNames() -> [String] { names }
    func defaultPrinterName() -> String? { defaultName }

    func submit(_ request: PrinterPrintRequest) async throws {
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        requests.append(Request(sourceURL: request.sourceURL, showsPrintDialog: request.showsPrintDialog))
    }

    func failNext(with error: Error) {
        nextError = error
    }
}

private enum TestPrinterError: LocalizedError {
    case offline
    var errorDescription: String? { "Printer offline" }
}

@MainActor
private func testDefaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: "PRC-Printer-\(UUID().uuidString)")!
    suite.set(SelphyPaperSize.postcard.rawValue, forKey: "selphyPaperSize")
    suite.set(1, forKey: "selphyCopies")
    suite.set(false, forKey: "selphySkipPrintDialog")
    return suite
}
