import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("HTTP request parsing")
struct HTTPServerRequestTests {
    @Test("handles fragmented POST headers and body")
    func fragmentedPost() throws {
        var parser = HTTPServerRequestParser()
        #expect(try parser.append(Data("POST /operator/api/action HTTP/1.1\r\nHost: booth\r\nContent-Length: 18\r\n\r\n{\"action\":\"pause\"}".utf8.prefix(20))) == nil)
        let rest = Data("POST /operator/api/action HTTP/1.1\r\nHost: booth\r\nContent-Length: 18\r\n\r\n{\"action\":\"pause\"}".utf8.dropFirst(20))
        let request = try parser.append(rest)
        #expect(request?.method == "POST")
        #expect(request?.path == "/operator/api/action")
        #expect(request?.header("host") == "booth")
        #expect(request?.body == Data("{\"action\":\"pause\"}".utf8))
    }

    @Test("rejects malformed and unsupported requests")
    func rejectsInvalidInput() throws {
        var malformed = HTTPServerRequestParser()
        #expect(throws: HTTPServerRequestError.malformed) {
            try malformed.append(Data("POST /bad\r\nNoColon\r\n\r\n".utf8))
        }
        var chunked = HTTPServerRequestParser()
        #expect(throws: HTTPServerRequestError.unsupportedTransferEncoding) {
            try chunked.append(Data("POST /operator/api/action HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        }
    }

    @Test("rejects oversized bodies")
    func rejectsOversizedBody() throws {
        var parser = HTTPServerRequestParser()
        let header = "POST /operator/api/action HTTP/1.1\r\nContent-Length: \(HTTPServerRequestParser.maximumBodyBytes + 1)\r\n\r\n"
        #expect(throws: HTTPServerRequestError.oversized) {
            try parser.append(Data(header.utf8))
        }
    }
}
