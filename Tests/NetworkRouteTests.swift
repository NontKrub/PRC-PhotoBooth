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

    @Test("Initial Ethernet path false does not abort a probing LAN attempt")
    func initialEthernetFalseKeepsLANProbeAlive() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)

        #expect(route.lanPathChanged(isAvailable: false, wifiAvailable: true) == .none)
        #expect(route.state == .connectingLAN)
    }

    @Test("Delayed Ethernet availability can complete the LAN handshake")
    func delayedEthernetAvailabilityCompletesHandshake() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)

        #expect(route.lanPathChanged(isAvailable: false, wifiAvailable: true) == .none)
        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true) == .none)
        _ = route.lanHandshakeSucceeded(peer: "iPad")

        #expect(route.state == .connectedLAN(peer: "iPad"))
    }

    @Test("Established Ethernet loss falls back to Wi-Fi")
    func establishedEthernetLossFallsBack() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: true, wifiAvailable: true)
        _ = route.lanHandshakeSucceeded(peer: "iPad")

        #expect(route.lanPathChanged(isAvailable: false, wifiAvailable: true) == .startWiFi(fallback: true))
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

    @Test("Healthy Wi-Fi fallback recovers LAN while the booth is idle")
    func fallbackRecoversLANWhenIdle() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true, boothIsIdle: true) == .startLAN)
        #expect(route.state == .connectingLAN)
        #expect(route.transportDisconnected(lanAvailable: true, wifiAvailable: true) == .startLAN)
    }

    @Test("LAN return during capture remains on Wi-Fi until idle")
    func fallbackDefersLANRecoveryDuringCapture() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true, boothIsIdle: false) == .none)
        #expect(route.state == .fallbackWiFi(peer: "iPad"))
        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true, boothIsIdle: true) == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("LAN recovery command is emitted once after the route starts")
    func fallbackRecoveryDoesNotFlap() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true) == .startLAN)
        #expect(route.lanPathChanged(isAvailable: true, wifiAvailable: true) == .none)
    }

    @Test("Wi-Fi loss stays unavailable when Wi-Fi is selected")
    func selectedWiFiLossDoesNotSwitchToLAN() {
        var route = BoothNetworkRouteMachine(preference: .wifi)
        _ = route.start(lanAvailable: true, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: false)

        let command = route.wifiPathChanged(isAvailable: false, lanAvailable: true)

        #expect(command == .unavailable)
        #expect(route.state == .disconnected)
    }

    @Test("Wi-Fi fallback loss retries available LAN")
    func fallbackWiFiLossRetriesLAN() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        let command = route.wifiPathChanged(isAvailable: false, lanAvailable: true)

        #expect(command == .startLAN)
        #expect(route.state == .connectingLAN)
    }

    @Test("Wi-Fi fallback loss becomes unavailable without LAN")
    func fallbackWiFiLossWithoutLANIsUnavailable() {
        var route = BoothNetworkRouteMachine(preference: .lan)
        _ = route.start(lanAvailable: false, wifiAvailable: true)
        _ = route.wifiConnected(peer: "iPad", fallback: true)

        let command = route.wifiPathChanged(isAvailable: false, lanAvailable: false)

        #expect(command == .unavailable)
        #expect(route.state == .disconnected)
    }
}

@Suite("iPad route discovery policy")
struct RouteDiscoveryPolicyTests {
    @Test("LAN preference waits for LAN when Wi-Fi is discovered first")
    func lanPreferenceWaitsForLAN() {
        var selection = BoothRouteDiscoverySelection()

        let waiting = selection.consider(.wifi, preferredPreference: .lan)
        let accepted = selection.consider(.wiredEthernet, preferredPreference: .lan)

        #expect(waiting == .waitingForPreferredInterface)
        #expect(accepted == .accepted)
        #expect(selection.selectedInterface == .wiredEthernet)
    }

    @Test("LAN preference promotes Wi-Fi only after LAN grace expires")
    func lanPreferenceFallsBackToPendingWiFi() {
        var selection = BoothRouteDiscoverySelection()

        let waiting = selection.consider(.wifi, preferredPreference: .lan)
        let promoted = selection.promotePending()

        #expect(waiting == .waitingForPreferredInterface)
        #expect(promoted == .wifi)
        #expect(selection.selectedInterface == .wifi)
    }

    @Test("Wi-Fi preference wins when both interfaces are discovered")
    func wifiPreferenceWins() {
        var selection = BoothRouteDiscoverySelection()

        let waiting = selection.consider(.wiredEthernet, preferredPreference: .wifi)
        let accepted = selection.consider(.wifi, preferredPreference: .wifi)

        #expect(waiting == .waitingForPreferredInterface)
        #expect(accepted == .accepted)
        #expect(selection.selectedInterface == .wifi)
    }

    @Test("Advertised Mac preference is authoritative")
    func advertisedPreferenceWins() {
        var selection = BoothRouteDiscoverySelection()

        let ignored = selection.consider(
            .wifi,
            preferredPreference: .wifi,
            advertisedPreference: .lan
        )
        let accepted = selection.consider(
            .wiredEthernet,
            preferredPreference: .wifi,
            advertisedPreference: .lan
        )

        #expect(ignored == .waitingForPreferredInterface)
        #expect(accepted == .accepted)
        #expect(selection.selectedInterface == .wiredEthernet)
    }

    @Test("LAN advertisement still permits Wi-Fi fallback after the grace window")
    func advertisedLANFallsBackToWiFi() {
        var selection = BoothRouteDiscoverySelection()

        #expect(selection.consider(
            .wifi,
            preferredPreference: .wifi,
            advertisedPreference: .lan
        ) == .waitingForPreferredInterface)
        #expect(selection.promotePending() == .wifi)
    }

    @Test("Reset permits a new discovery cycle")
    func resetPermitsNewSelection() {
        var selection = BoothRouteDiscoverySelection()
        _ = selection.consider(.wifi, preferredPreference: .wifi)

        selection.reset()

        #expect(selection.selectedInterface == nil)
        #expect(selection.pendingInterface == nil)
        let accepted = selection.consider(.wiredEthernet, preferredPreference: .lan)

        #expect(accepted == .accepted)
        #expect(selection.selectedInterface == .wiredEthernet)
    }
}

@Suite("Ethernet diagnostics")
@MainActor
struct EthernetDiagnosticsTests {
    @Test("Ethernet probe does not change the requested route")
    func probeIsNonDestructive() async {
        let status = BoothConnectionStatus(requestedNetwork: .wifi)
        let transport = NetworkBoothTransport(
            role: .mac,
            networkPreference: .wifi,
            connectionStatus: status
        )

        let result = await transport.probeEthernet()

        #expect(transport.requestedNetworkPreference == .wifi)
        #expect(!result.interfaceAvailable)
        #expect(!result.peerDiscovered)
        #expect(!result.controlConnected)
        #expect(!result.handshakeSucceeded)
        #expect(!result.previewConnected)
        #expect(result.error != nil)
    }
}

@Suite("Transport callback policy")
struct TransportCallbackPolicyTests {
    @Test("Callback from previous transport generation is ignored")
    func staleCallbackIsIgnored() {
        var gate = BoothTransportCallbackGate()
        let connectionAGeneration = gate.generation

        gate.invalidate()

        #expect(!gate.accepts(connectionAGeneration))
        #expect(gate.accepts(gate.generation))
    }

    @Test("Discovery callback from a previous generation is ignored")
    func staleDiscoveryCallbackIsIgnored() {
        var gate = BoothRouteDiscoveryGenerationGate()
        let oldGeneration = gate.begin()
        let currentGeneration = gate.begin()

        #expect(!gate.accepts(oldGeneration))
        #expect(gate.accepts(currentGeneration))
    }
}

@Suite("Preview channel identity")
struct PreviewChannelIdentityTests {
    @Test("preview channel must match the verified control peer")
    func matchesControlPeer() {
        #expect(previewPeerMatchesControlPeer(
            previewPeerID: "peer",
            controlPeerID: "peer",
            identityRequired: true
        ))
        #expect(!previewPeerMatchesControlPeer(
            previewPeerID: "stale-peer",
            controlPeerID: "peer",
            identityRequired: true
        ))
        #expect(!previewPeerMatchesControlPeer(
            previewPeerID: nil,
            controlPeerID: "peer",
            identityRequired: true
        ))
        #expect(previewPeerMatchesControlPeer(
            previewPeerID: nil,
            controlPeerID: nil,
            identityRequired: false
        ))
    }
}
