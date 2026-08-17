import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("PrinterService")
struct PrinterServiceTests {
    @Test("reports the macOS system default printer")
    @MainActor
    func listsAndDetectsMissingPrinter() {
        let backend = TestPrinterBackend(names: ["Canon Selphy"], defaultName: "Canon Selphy")
        let printer = PrinterService(backend: backend)

        printer.refreshPrinters()
        #expect(printer.availablePrinterNames == ["Canon Selphy"])
        #expect(printer.configuredPrinterStatus() == .systemDefault)

        let noDefault = PrinterService(
            backend: TestPrinterBackend(names: ["Canon Selphy"], defaultName: nil)
        )
        #expect(noDefault.configuredPrinterStatus() == .unavailable(name: "No system default printer"))
    }

    @Test("successful and failed test prints update diagnostics")
    @MainActor
    func recordsTestResults() async throws {
        let backend = TestPrinterBackend(names: ["Canon"], defaultName: "Canon")
        let printer = PrinterService(backend: backend)

        try await printer.printTestPage()
        #expect(printer.lastTestResult?.isSuccess == true)
        #expect(backend.requests.last?.showsPrintDialog == true)

        backend.failNext(with: TestPrinterError.offline)
        do {
            try await printer.printTestPage()
            Issue.record("Expected test print failure")
        } catch {
            #expect(printer.lastTestResult?.isSuccess == false)
        }
    }

    @Test("refresh invalidates the test result")
    @MainActor
    func invalidatesTestResult() async throws {
        let backend = TestPrinterBackend(names: ["Canon", "Other"], defaultName: "Canon")
        let printer = PrinterService(backend: backend)

        try await printer.printTestPage()
        #expect(printer.lastTestResult != nil)
        printer.refreshPrinters()
        #expect(printer.lastTestResult == nil)

        try await printer.printTestPage()
        printer.refreshPrinters()
        #expect(printer.lastTestResult == nil)
    }

    @Test("interactive printing honors dialog setting")
    @MainActor
    func interactivePrintingHonorsDialog() async throws {
        let backend = TestPrinterBackend(names: ["Canon"], defaultName: "Canon")
        let printer = PrinterService(backend: backend)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await printer.printStrip(at: file, showPrintDialog: true)
        #expect(backend.requests.last?.showsPrintDialog == true)
        try await printer.printStrip(at: file, showPrintDialog: false)
        #expect(backend.requests.last?.showsPrintDialog == false)
    }

    @Test("cancelling the system panel is not a retryable print failure")
    @MainActor
    func cancellationIsHandled() async throws {
        let backend = TestPrinterBackend(names: ["Canon"], defaultName: "Canon")
        let printer = PrinterService(backend: backend)
        backend.failNext(with: PrinterServiceError.cancelled)

        try await printer.printTestPage()

        #expect(printer.lastTestResult?.message == "Print dialog cancelled.")
        #expect(printer.printFailureCount == 0)
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
