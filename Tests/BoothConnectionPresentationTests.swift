import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Booth connection presentation")
@MainActor
struct BoothConnectionPresentationTests {
    @Test("disconnected status is shared consistently")
    func disconnected() {
        let status = BoothConnectionStatus(requestedNetwork: .lan)

        let presentation = BoothConnectionPresentationResolver.resolve(status)

        #expect(presentation.stateText == "No iPad connected")
        #expect(presentation.requestedTransport == "LAN")
        #expect(presentation.effectiveTransport == "Unavailable")
        #expect(!presentation.controlConnected)
        #expect(!presentation.previewConnected)
    }

    @Test("connecting routes expose the requested route")
    func connectingRoutes() {
        let status = BoothConnectionStatus(requestedNetwork: .lan)
        status.publish(
            requestedNetwork: .lan,
            state: .connecting,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .connectingLAN,
            effectiveNetwork: .unavailable
        )

        #expect(BoothConnectionPresentationResolver.resolve(status).stateText == "Connecting via LAN")

        status.publish(
            requestedNetwork: .lan,
            state: .connecting,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .connectingWiFi,
            effectiveNetwork: .unavailable,
            fallbackReason: "LAN unavailable"
        )
        #expect(BoothConnectionPresentationResolver.resolve(status).stateText == "Connecting via Wi-Fi fallback")
    }

    @Test("connected LAN and Wi-Fi fallback expose the same details")
    func connectedRoutes() {
        let status = BoothConnectionStatus(requestedNetwork: .lan)
        status.publish(
            requestedNetwork: .lan,
            state: .connected(peerName: "iPad Pro"),
            peerID: "peer",
            peerDisplayName: "iPad Pro",
            routeState: .connectedLAN(peer: "iPad Pro"),
            effectiveNetwork: .lan,
            lanHandshake: .ready,
            isPreviewChannelConnected: true
        )
        var presentation = BoothConnectionPresentationResolver.resolve(status)
        #expect(presentation.peerName == "iPad Pro")
        #expect(presentation.effectiveTransport == "Ethernet")
        #expect(presentation.lanHandshake == "Ready")
        #expect(presentation.controlConnected)
        #expect(presentation.previewConnected)
        #expect(presentation.fallbackText == nil)

        status.publish(
            requestedNetwork: .lan,
            state: .connected(peerName: "iPad Pro"),
            peerID: "peer",
            peerDisplayName: "iPad Pro",
            routeState: .fallbackWiFi(peer: "iPad Pro"),
            effectiveNetwork: .wifi,
            fallbackReason: "LAN unavailable",
            lanHandshake: .timeout,
            isPreviewChannelConnected: false
        )
        presentation = BoothConnectionPresentationResolver.resolve(status)
        #expect(presentation.effectiveTransport == "Wi-Fi")
        #expect(presentation.fallbackText == "Wi-Fi fallback active: LAN unavailable")
        #expect(presentation.controlConnected)
        #expect(!presentation.previewConnected)
    }
}
