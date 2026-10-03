import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Booth connection presentation")
@MainActor
struct BoothConnectionPresentationTests {
    @Test("preferred Mac identity survives discovery gaps without showing its device ID")
    func preferredMacSurvivesDiscoveryGap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peerID = "8E4F15E6-4BB4-4F3D-BE1F-CEBF14592AE2"
        let discovery = BoothDiscoveredPeer(
            id: peerID,
            displayName: peerID,
            role: .mac,
            appVersion: "1.4.3",
            protocolVersion: BoothTransportHello.currentProtocolVersion,
            networkPreference: .wifi,
            availableInterfaces: [.wifi]
        )
        let trusted = TrustedBoothPeer(id: peerID, displayName: "Event Booth Mac", role: .mac)
        var cache = BoothDiscoveryPresentationCache()
        cache.update([discovery], at: now)
        var nearby = cache.nearbyMacs(at: now, trustedPeers: [trusted], preferredPeerID: peerID)

        #expect(nearby.count == 1)
        #expect(nearby[0].displayName == "Event Booth Mac")
        #expect(!nearby[0].isStale)

        cache.update([], at: now.addingTimeInterval(1))
        nearby = cache.nearbyMacs(
            at: now.addingTimeInterval(1),
            trustedPeers: [trusted],
            preferredPeerID: peerID
        )
        let preferred = BoothPreferredMacPresentation.resolve(
            preferredPeerID: peerID,
            trustedPeers: [trusted],
            nearbyMacs: nearby,
            connectionState: .connecting,
            connectedPeerID: nil,
            isAuthenticated: false,
            isSecureChannelEstablished: false,
            isReconnectInProgress: true,
            hasPreferredControlAttempt: false
        )

        #expect(nearby.count == 1)
        #expect(nearby[0].isStale)
        #expect(nearby[0].displayName == "Event Booth Mac")
        #expect(preferred.displayName == "Event Booth Mac")
        #expect(preferred.state == .reconnecting)
        #expect(!preferred.isSecurelyConnected)
    }

    @Test("offline preferred Mac stops appearing to reconnect after discovery expires")
    func offlinePreferredMacAfterDiscoveryExpires() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peerID = "offline-mac"
        let trusted = TrustedBoothPeer(id: peerID, displayName: "Event Booth Mac", role: .mac)
        let discovery = BoothDiscoveredPeer(
            id: peerID,
            displayName: "Event Booth Mac",
            role: .mac,
            appVersion: "1.4.3",
            protocolVersion: BoothTransportHello.currentProtocolVersion,
            networkPreference: .wifi,
            availableInterfaces: [.wifi]
        )
        var cache = BoothDiscoveryPresentationCache()
        cache.update([discovery], at: now)
        cache.update([], at: now.addingTimeInterval(1))
        let expiredAt = now.addingTimeInterval(BoothDiscoveryPresentationCache.retentionInterval + 1)
        cache.pruneExpired(at: expiredAt)
        let nearby = cache.nearbyMacs(at: expiredAt, trustedPeers: [trusted], preferredPeerID: peerID)

        let offline = BoothPreferredMacPresentation.resolve(
            preferredPeerID: peerID,
            trustedPeers: [trusted],
            nearbyMacs: nearby,
            connectionState: .connecting,
            connectedPeerID: nil,
            isAuthenticated: false,
            isSecureChannelEstablished: false,
            isReconnectInProgress: true,
            hasPreferredControlAttempt: false
        )
        #expect(nearby.isEmpty)
        #expect(offline.displayName == "Event Booth Mac")
        #expect(offline.state == .notConnected)
        #expect(!offline.isSecurelyConnected)

        let directLANAttempt = BoothPreferredMacPresentation.resolve(
            preferredPeerID: peerID,
            trustedPeers: [trusted],
            nearbyMacs: nearby,
            connectionState: .connecting,
            connectedPeerID: nil,
            isAuthenticated: false,
            isSecureChannelEstablished: false,
            isReconnectInProgress: true,
            hasPreferredControlAttempt: true
        )
        #expect(directLANAttempt.state == .reconnecting)
    }

    @Test("preferred Mac is not reported connected before secure transport is ready")
    func preferredMacRequiresSecureAuthority() {
        let peerID = "mac-studio"
        let peer = BoothDiscoveredPeer(
            id: peerID,
            displayName: "Studio Mac",
            role: .mac,
            appVersion: "1.4.3",
            protocolVersion: BoothTransportHello.currentProtocolVersion,
            networkPreference: .wifi,
            availableInterfaces: [.wifi]
        )
        var cache = BoothDiscoveryPresentationCache()
        cache.update([peer])
        let nearby = cache.nearbyMacs(trustedPeers: [], preferredPeerID: peerID)

        let negotiating = BoothPreferredMacPresentation.resolve(
            preferredPeerID: peerID,
            trustedPeers: [],
            nearbyMacs: nearby,
            connectionState: .connected(peerName: "Studio Mac"),
            connectedPeerID: peerID,
            isAuthenticated: true,
            isSecureChannelEstablished: false,
            isReconnectInProgress: false,
            hasPreferredControlAttempt: true
        )
        #expect(negotiating.state == .reconnecting)
        #expect(!negotiating.isSecurelyConnected)

        let connected = BoothPreferredMacPresentation.resolve(
            preferredPeerID: peerID,
            trustedPeers: [],
            nearbyMacs: nearby,
            connectionState: .connected(peerName: "Studio Mac"),
            connectedPeerID: peerID,
            isAuthenticated: true,
            isSecureChannelEstablished: true,
            isReconnectInProgress: false,
            hasPreferredControlAttempt: true
        )
        #expect(connected.state == .connected)
        #expect(connected.isSecurelyConnected)
    }

    @Test("nearby Mac cache expires old rows and keeps unknown fresh peers usable")
    func nearbyMacCacheRetention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peerID = "unknown-mac"
        let peer = BoothDiscoveredPeer(
            id: peerID,
            displayName: "Workshop Mac",
            role: .mac,
            appVersion: "1.4.3",
            protocolVersion: BoothTransportHello.currentProtocolVersion,
            networkPreference: .wifi,
            availableInterfaces: [.wifi]
        )
        var cache = BoothDiscoveryPresentationCache()
        cache.update([peer], at: now)

        let fresh = cache.nearbyMacs(at: now, trustedPeers: [], preferredPeerID: nil)
        #expect(fresh.count == 1)
        #expect(fresh[0].displayName == "Workshop Mac")
        #expect(!fresh[0].isTrusted)
        #expect(!fresh[0].isStale)

        cache.update([], at: now.addingTimeInterval(1))
        let stale = cache.nearbyMacs(at: now.addingTimeInterval(1), trustedPeers: [], preferredPeerID: nil)
        #expect(stale.count == 1)
        #expect(stale[0].isStale)

        cache.pruneExpired(at: now.addingTimeInterval(BoothDiscoveryPresentationCache.retentionInterval + 1))
        #expect(cache.nearbyMacs(at: now.addingTimeInterval(BoothDiscoveryPresentationCache.retentionInterval + 1), trustedPeers: [], preferredPeerID: nil).isEmpty)
    }

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

    @Test("network return states use the same presentation for Console and Settings")
    func networkReturnStates() {
        let status = BoothConnectionStatus(requestedNetwork: .lan)
        status.publish(
            requestedNetwork: .lan,
            state: .disconnected,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .disconnected,
            effectiveNetwork: .unavailable,
            isLANPathAvailable: false,
            isWiFiPathAvailable: false
        )
        let unavailable = BoothConnectionPresentationResolver.resolve(status)
        #expect(unavailable.stateText == "No iPad connected")
        #expect(unavailable.effectiveTransport == "Unavailable")
        #expect(unavailable == BoothConnectionPresentationResolver.resolve(status))

        status.publish(
            requestedNetwork: .lan,
            state: .connecting,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .connectingLAN,
            effectiveNetwork: .unavailable,
            isLANPathAvailable: true,
            isWiFiPathAvailable: false
        )
        let lanRecovery = BoothConnectionPresentationResolver.resolve(status)
        #expect(lanRecovery.stateText == "Connecting via LAN")
        #expect(lanRecovery == BoothConnectionPresentationResolver.resolve(status))

        status.publish(
            requestedNetwork: .lan,
            state: .connecting,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .connectingWiFi,
            effectiveNetwork: .unavailable,
            fallbackReason: "LAN unavailable",
            isLANPathAvailable: false,
            isWiFiPathAvailable: true
        )
        let wifiRecovery = BoothConnectionPresentationResolver.resolve(status)
        #expect(wifiRecovery.stateText == "Connecting via Wi-Fi fallback")
        #expect(wifiRecovery == BoothConnectionPresentationResolver.resolve(status))
    }

    @Test("connected LAN and Wi-Fi fallback expose the same details")
    func connectedRoutes() {
        let status = BoothConnectionStatus(requestedNetwork: .lan)
        status.publishPairing(
            trustedPeerIDs: ["peer"],
            preferredPeerID: "peer",
            updatePreferredPeer: true,
            authenticated: true
        )
        status.publish(
            requestedNetwork: .lan,
            state: .connected(peerName: "iPad Pro"),
            peerID: "peer",
            peerDisplayName: "iPad Pro",
            routeState: .connectedLAN(peer: "iPad Pro"),
            effectiveNetwork: .lan,
            isLANPathAvailable: false,
            lanPathObservation: .unavailable,
            lanHandshake: .ready,
            isPreviewChannelConnected: true
        )
        var presentation = BoothConnectionPresentationResolver.resolve(status)
        #expect(presentation.peerName == "iPad Pro")
        #expect(presentation.effectiveTransport == "Ethernet")
        #expect(presentation.lanHandshake == "Ready")
        #expect(presentation.controlConnected)
        #expect(presentation.previewConnected)
        #expect(presentation.ethernetAvailable)
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

    @Test("a preferred LAN route alone does not make Ethernet available")
    func preferredLANWithoutConnectionDoesNotCountAsAvailable() {
        let status = BoothConnectionStatus(requestedNetwork: .lan)
        status.publishPairing(
            trustedPeerIDs: ["peer"],
            preferredPeerID: "peer",
            updatePreferredPeer: true,
            authenticated: false
        )
        status.publishPathAvailability(lan: false, wifi: true)

        #expect(!BoothConnectionPresentationResolver.resolve(status).ethernetAvailable)
    }
}
