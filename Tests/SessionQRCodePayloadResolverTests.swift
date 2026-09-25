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

    @Test("local guest routes require an available policy and explicit LAN enablement")
    func localGuestRoutesFollowPolicy() {
        #expect(GuestDeliveryPolicy.publicHTTPS.permitsLocalGuestHTTP(allowTrustedLocalHTTP: true))
        #expect(!GuestDeliveryPolicy.publicHTTPS.permitsLocalGuestHTTP(allowTrustedLocalHTTP: false))
        #expect(GuestDeliveryPolicy.trustedLocalHTTP.permitsLocalGuestHTTP(allowTrustedLocalHTTP: true))
        #expect(!GuestDeliveryPolicy.unavailable.permitsLocalGuestHTTP(allowTrustedLocalHTTP: true))
    }

    @Test("public base accepts HTTPS host, path prefix, and port")
    func acceptsSupportedHTTPSBases() throws {
        for base in [
            "https://photos.example.com",
            "https://photos.example.com/base/path",
            "https://photos.example.com:8443"
        ] {
            #expect(try SessionQRCodePayloadResolver.resolve(
                token: "token",
                localBaseURL: "http://192.168.1.10:8585",
                publicBaseURL: base,
                cloudUploadEnabled: true,
                isRelease: true
            ) == "\(base)/s/token/")
        }
    }

    @Test("shared validator canonicalizes HTTPS base URLs")
    func validatesAndCanonicalizesPublicBase() throws {
        let validated = try #require(ValidatedPublicGuestBaseURL(
            string: " https://photos.example.com/base/path/// "
        ))
        #expect(validated.canonicalString == "https://photos.example.com/base/path")
        #expect(validated.url.absoluteString == validated.canonicalString)
        #expect(ValidatedPublicGuestBaseURL(string: "http://photos.example.com") == nil)
    }

    @Test("public base rejects HTTP and malformed or credentialed URLs in every build")
    func rejectsInvalidPublicBasesInDebugAndRelease() {
        for base in [
            "http://photos.example.com",
            "https-not-really://photos.example.com",
            "//https://photos.example.com",
            "https://",
            "https://user:password@photos.example.com",
            "https://photos.example.com?event=one",
            "https://photos.example.com#gallery",
            "https://["
        ] {
            #expect(ValidatedPublicGuestBaseURL(string: base) == nil)
            for isRelease in [false, true] {
                #expect(SessionQRCodePayloadResolver.evaluatePolicy(
                    publicBaseURL: base,
                    cloudUploadEnabled: true,
                    allowTrustedLocalHTTP: false,
                    isRelease: isRelease
                ) == .unavailable, "Expected \(base) to be rejected")
                #expect(throws: SessionQRCodePayloadError.insecurePublicBaseURL) {
                    try SessionQRCodePayloadResolver.resolve(
                        token: "token",
                        localBaseURL: "http://192.168.1.10:8585",
                        publicBaseURL: base,
                        cloudUploadEnabled: true,
                        isRelease: isRelease
                    )
                }
            }
        }

        #expect(SessionQRCodePayloadResolver.evaluatePolicy(
            publicBaseURL: "//https://photos.example.com",
            cloudUploadEnabled: true,
            allowTrustedLocalHTTP: true
        ) == .unavailable)
        #expect(throws: SessionQRCodePayloadError.insecurePublicBaseURL) {
            try SessionQRCodePayloadResolver.resolve(
                token: "token",
                localBaseURL: "http://192.168.1.10:8585",
                publicBaseURL: "//https://photos.example.com",
                cloudUploadEnabled: true,
                allowTrustedLocalHTTP: true
            )
        }
    }

    @Test("rejects localhost and loopback local base URLs")
    func rejectsLocalhostAndLoopbackBaseURLs() {
        for localURL in [
            "http://localhost:8585",
            "http://127.0.0.1:8585",
            "http://127.0.0.2:8585",
            "http://0.0.0.0:8585",
            "http://[::1]:8585"
        ] {
            #expect(!SessionQRCodePayloadResolver.isRoutableLocalBase(localURL))
            #expect(throws: SessionQRCodePayloadError.self) {
                try SessionQRCodePayloadResolver.resolve(
                    token: "token",
                    localBaseURL: localURL,
                    publicBaseURL: nil,
                    cloudUploadEnabled: false,
                    allowTrustedLocalHTTP: true
                )
            }
            #expect(SessionQRCodePayloadResolver.evaluatePolicy(
                publicBaseURL: nil,
                cloudUploadEnabled: false,
                allowTrustedLocalHTTP: true,
                localBaseURL: localURL
            ) == .unavailable)
        }
    }

    @Test("accepts routable private IPv4 local base URL")
    func acceptsRoutablePrivateIPv4LocalBaseURL() throws {
        let payload = try SessionQRCodePayloadResolver.resolve(
            token: "guest-token",
            localBaseURL: "http://192.168.4.1:8585",
            publicBaseURL: nil,
            cloudUploadEnabled: false,
            allowTrustedLocalHTTP: true
        )
        #expect(payload == "http://192.168.4.1:8585/s/guest-token/")
    }
}
