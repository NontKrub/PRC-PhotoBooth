import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Network route policy")
struct NetworkRouteTests {
    @Test("Wi-Fi preference never selects LAN")
    func wifiPreferenceWins() {
        var route = BoothNetworkRouteMachine(preference: .wifi)

        let command = route.start(lanAvailable: true, wifiAvailable: true)

        #expect(command == .startWiFi(fallback: false))
        #expect(route.state == .connectingWiFi)
    }

    @Test("LAN preference uses LAN after a valid handshake")
    func lanHandshakeConnects() {
        var route = BoothNetworkRouteMachine(preference: .lan)

        #expect(route.start(lanAvailable: true, wifiAvailable: true) == .startLAN)
        #expect(route.lanHandshakeSucceeded(peer: "iPad") == .none)
        #expect(route.state == .connectedLAN(peer: "iPad"))
        #expect(route.effectiveTransport == .lan)
    }

    @Test("LAN-unavailable falls back to Wi-Fi")
    func unavailableLANFallsBack() {
        var route = BoothNetworkRouteMachine(preference: .lan)

        let command = route.start(lanAvailable: false, wifiAvailable: true)

        #expect(command == .startWiFi(fallback: true))
        #expect(route.state == .connectingWiFi)
    }

    @Test("LAN handshake timeout falls back to Wi-Fi")
    func handshakeTimeoutFallsBack() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)

        let command = route.lanHandshakeTimedOut(wifiAvailable: true)

        #expect(command == .startWiFi(fallback: true))
        #expect(route.state == .connectingWiFi)
    }

    @Test("No LAN and no Wi-Fi becomes unavailable")
    func noNetworkIsUnavailable() {
        var route = BoothNetworkRouteMachine(preference: .lan)

        let command = route.start(lanAvailable: false, wifiAvailable: false)

        #expect(command == .unavailable)
        #expect(route.state == .disconnected)
        #expect(route.effectiveTransport == .unavailable)
    }

    @Test("Healthy Wi-Fi fallback does not switch when LAN reappears")
    func fallbackHasHysteresis() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true) == .none)
        #expect(route.state == .fallbackWiFi(peer: "iPad"))
        #expect(route.transportDisconnected(lanAvailable: true, wifiAvailable: true) == .startLAN)
    }
}
