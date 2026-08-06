import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Session QR payload resolver")
struct SessionQRCodePayloadResolverTests {
    private let local = " http://192.168.1.10:8585/ "
    private let publicBase = " https://photos.example/// "

    @Test("cloud disabled uses the local URL")
    func cloudDisabledUsesLocalURL() throws {
        let payload = try SessionQRCodePayloadResolver.resolve(
            token: "token",
            localBaseURL: local,
            publicBaseURL: publicBase,
            cloudUploadEnabled: false
        )

        #expect(payload == "http://192.168.1.10:8585/s/token/")
    }

    @Test("cloud enabled with a public base uses the public URL before upload")
    func cloudEnabledUsesPublicURL() throws {
        let payload = try SessionQRCodePayloadResolver.resolve(
            token: " token ",
            localBaseURL: local,
            publicBaseURL: publicBase,
            cloudUploadEnabled: true
        )

        #expect(payload == "https://photos.example/s/token/")
    }

    @Test("blank public base falls back to local URL")
    func blankPublicBaseUsesLocalURL() throws {
        let payload = try SessionQRCodePayloadResolver.resolve(
            token: "token",
            localBaseURL: local,
            publicBaseURL: "   ",
            cloudUploadEnabled: true
        )

        #expect(payload == "http://192.168.1.10:8585/s/token/")
    }

    @Test("empty token is rejected")
    func emptyTokenRejected() {
        #expect(throws: SessionQRCodePayloadError.emptyToken) {
            try SessionQRCodePayloadResolver.resolve(
                token: "  ",
                localBaseURL: local,
                publicBaseURL: publicBase,
                cloudUploadEnabled: false
            )
        }
    }

    @Test("empty resolved base is rejected")
    func emptyBaseRejected() {
        #expect(throws: SessionQRCodePayloadError.emptyBaseURL) {
            try SessionQRCodePayloadResolver.resolve(
                token: "token",
                localBaseURL: " ",
                publicBaseURL: nil,
                cloudUploadEnabled: false
            )
        }
    }
}
