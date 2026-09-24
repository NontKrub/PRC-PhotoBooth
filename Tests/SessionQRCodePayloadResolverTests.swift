import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Session QR payload resolver")
struct SessionQRCodePayloadResolverTests {
    private let local = " http://192.168.1.10:8585/ "
    private let publicBase = " https://photos.example/// "
    private let insecurePublicBase = " http://photos.example/// "

    @Test("cloud disabled with trusted local HTTP uses local URL")
    func cloudDisabledWithTrustedLocalHTTPUsesLocalURL() throws {
        let payload = try SessionQRCodePayloadResolver.resolve(
            token: "token",
            localBaseURL: local,
            publicBaseURL: publicBase,
            cloudUploadEnabled: false,
            allowTrustedLocalHTTP: true
        )

        #expect(payload == "http://192.168.1.10:8585/s/token/")
    }

    @Test("cloud disabled without trusted local HTTP throws localHTTPNotAllowed")
    func cloudDisabledWithoutTrustedLocalHTTPThrows() {
        #expect(throws: SessionQRCodePayloadError.localHTTPNotAllowed) {
            try SessionQRCodePayloadResolver.resolve(
                token: "token",
                localBaseURL: local,
                publicBaseURL: publicBase,
                cloudUploadEnabled: false,
                allowTrustedLocalHTTP: false
            )
        }
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

    @Test("blank public base with trusted local HTTP falls back to local URL")
    func blankPublicBaseWithTrustedLocalHTTPUsesLocalURL() throws {
        let payload = try SessionQRCodePayloadResolver.resolve(
            token: "token",
            localBaseURL: local,
            publicBaseURL: "   ",
            cloudUploadEnabled: true,
            allowTrustedLocalHTTP: true
        )

        #expect(payload == "http://192.168.1.10:8585/s/token/")
    }

    @Test("blank public base without trusted local HTTP throws")
    func blankPublicBaseWithoutTrustedLocalHTTPThrows() {
        #expect(throws: SessionQRCodePayloadError.localHTTPNotAllowed) {
            try SessionQRCodePayloadResolver.resolve(
                token: "token",
                localBaseURL: local,
                publicBaseURL: "   ",
                cloudUploadEnabled: true,
                allowTrustedLocalHTTP: false
            )
        }
    }

    @Test("insecure public URL in release throws insecurePublicBaseURL")
    func insecurePublicURLInReleaseThrows() {
        #expect(throws: SessionQRCodePayloadError.insecurePublicBaseURL) {
            try SessionQRCodePayloadResolver.resolve(
                token: "token",
                localBaseURL: local,
                publicBaseURL: insecurePublicBase,
                cloudUploadEnabled: true,
                isRelease: true
            )
        }
    }

    @Test("empty token is rejected")
    func emptyTokenRejected() {
        #expect(throws: SessionQRCodePayloadError.emptyToken) {
            try SessionQRCodePayloadResolver.resolve(
                token: "  ",
                localBaseURL: local,
                publicBaseURL: publicBase,
                cloudUploadEnabled: false,
                allowTrustedLocalHTTP: true
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
                cloudUploadEnabled: false,
                allowTrustedLocalHTTP: true
            )
        }
    }

    @Test("evaluate policy returns publicHTTPS, trustedLocalHTTP, or unavailable")
    func evaluatePolicyTests() {
        // HTTPS cloud enabled
        #expect(SessionQRCodePayloadResolver.evaluatePolicy(
            publicBaseURL: "https://photos.example.com",
            cloudUploadEnabled: true,
            allowTrustedLocalHTTP: false,
            isRelease: true
        ) == .publicHTTPS)

        // Insecure cloud in release is unavailable
        #expect(SessionQRCodePayloadResolver.evaluatePolicy(
            publicBaseURL: "http://photos.example.com",
            cloudUploadEnabled: true,
            allowTrustedLocalHTTP: false,
            isRelease: true
        ) == .unavailable)

        // Cloud disabled, trusted local enabled
        #expect(SessionQRCodePayloadResolver.evaluatePolicy(
            publicBaseURL: nil,
            cloudUploadEnabled: false,
            allowTrustedLocalHTTP: true,
            isRelease: true
        ) == .trustedLocalHTTP)

        // Cloud disabled, trusted local disabled
        #expect(SessionQRCodePayloadResolver.evaluatePolicy(
            publicBaseURL: nil,
            cloudUploadEnabled: false,
            allowTrustedLocalHTTP: false,
            isRelease: true
        ) == .unavailable)
    }
}
