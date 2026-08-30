import Foundation

public enum BoothNetworkPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case wifi
    case lan

    public var id: String { rawValue }
}

public enum BoothNetworkInterfacePolicy: String, Equatable, Hashable, Sendable {
    case wifi
    case wiredEthernet
}

public enum BoothEffectiveNetworkTransport: String, Codable, Equatable, Sendable {
    case wifi
    case lan
    case unavailable
}

public enum BoothNetworkRouteState: Equatable, Sendable {
    case disconnected
    case connectingLAN
    case connectedLAN(peer: String)
    case connectingWiFi
    case connectedWiFi(peer: String)
    case fallbackWiFi(peer: String?)

    public var effectiveTransport: BoothEffectiveNetworkTransport {
        switch self {
        case .connectedLAN:
            return .lan
        case .connectedWiFi, .fallbackWiFi:
            return .wifi
        case .disconnected, .connectingLAN, .connectingWiFi:
            return .unavailable
        }
    }
}

public enum BoothNetworkRouteCommand: Equatable, Sendable {
    case startLAN
    case startWiFi(fallback: Bool)
    case unavailable
    case none
}

func previewPeerMatchesControlPeer(
    previewPeerID: String?,
    controlPeerID: String?,
    identityRequired: Bool
) -> Bool {
    guard identityRequired else { return true }
    guard let previewPeerID, let controlPeerID else { return false }
    return previewPeerID == controlPeerID
}

struct BoothRouteDiscoverySelection: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case accepted
        case waitingForPreferredInterface
        case ignored
    }

    private(set) var selectedInterface: BoothNetworkInterfacePolicy?
    private(set) var pendingInterface: BoothNetworkInterfacePolicy?

    mutating func consider(
        _ interface: BoothNetworkInterfacePolicy,
        preferredPreference: BoothNetworkPreference,
        advertisedPreference: BoothNetworkPreference? = nil
    ) -> Decision {
        guard selectedInterface == nil else { return .ignored }

        let preference = advertisedPreference ?? preferredPreference
        let preferredInterface: BoothNetworkInterfacePolicy = preference == .lan ? .wiredEthernet : .wifi
        guard interface != preferredInterface else {
            selectedInterface = interface
            pendingInterface = nil
            return .accepted
        }

        pendingInterface = interface
        return .waitingForPreferredInterface
    }

    mutating func promotePending() -> BoothNetworkInterfacePolicy? {
        guard selectedInterface == nil, let pendingInterface else { return nil }
        selectedInterface = pendingInterface
        self.pendingInterface = nil
        return selectedInterface
    }

    mutating func reset() {
        selectedInterface = nil
        pendingInterface = nil
    }
}

struct BoothRouteDiscoveryGenerationGate: Equatable, Sendable {
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    mutating func invalidate() {
        generation += 1
    }

    func accepts(_ callbackGeneration: Int) -> Bool {
        callbackGeneration == generation
    }
}

public struct BoothNetworkRouteMachine: Equatable, Sendable {
    public private(set) var preference: BoothNetworkPreference
    public private(set) var state: BoothNetworkRouteState = .disconnected

    public init(preference: BoothNetworkPreference) {
        self.preference = preference
    }

    public var effectiveTransport: BoothEffectiveNetworkTransport {
        state.effectiveTransport
    }

    public mutating func beginLANAttempt() -> BoothNetworkRouteCommand {
        state = .connectingLAN
        return .startLAN
    }

    public mutating func startWiFiAttempt(
        wifiAvailable: Bool,
        fallback: Bool
    ) -> BoothNetworkRouteCommand {
        startWiFiIfAvailable(wifiAvailable, fallback: fallback)
    }

    public mutating func start(lanAvailable: Bool, wifiAvailable: Bool) -> BoothNetworkRouteCommand {
        switch preference {
        case .wifi:
            return startWiFiIfAvailable(wifiAvailable, fallback: false)
        case .lan:
            return startLANIfAvailable(lanAvailable, wifiAvailable: wifiAvailable)
        }
    }

    public mutating func preferenceChanged(
        to preference: BoothNetworkPreference,
        lanAvailable: Bool,
        wifiAvailable: Bool
    ) -> BoothNetworkRouteCommand {
        self.preference = preference
        return start(lanAvailable: lanAvailable, wifiAvailable: wifiAvailable)
    }

    public mutating func lanHandshakeSucceeded(peer: String) -> BoothNetworkRouteCommand {
        state = .connectedLAN(peer: peer)
        return .none
    }

    public mutating func lanHandshakeTimedOut(wifiAvailable: Bool) -> BoothNetworkRouteCommand {
        startWiFiIfAvailable(wifiAvailable, fallback: true)
    }

    public mutating func manualPreferredLANRetry(
        lanAvailable _: Bool,
        wifiAvailable _: Bool,
        boothIsIdle: Bool
    ) -> BoothNetworkRouteCommand {
        guard preference == .lan,
              case .fallbackWiFi = state,
              boothIsIdle else { return .none }
        state = .connectingLAN
        return .startLAN
    }

    public mutating func lanPathChanged(
        isAvailable: Bool,
        wifiAvailable: Bool,
        boothIsIdle: Bool = true
    ) -> BoothNetworkRouteCommand {
        if isAvailable {
            switch state {
            case .disconnected where preference == .lan:
                state = .connectingLAN
                return .startLAN
            case .fallbackWiFi where boothIsIdle:
                state = .connectingLAN
                return .startLAN
            default:
                return .none
            }
        }
        switch state {
        case .connectingLAN:
            // A first monitor sample can arrive before a direct Ethernet route is ready.
            // The connection/hello result is authoritative while this attempt is probing.
            return .none
        case .connectedLAN:
            return startWiFiIfAvailable(wifiAvailable, fallback: true)
        case .disconnected, .connectingWiFi, .connectedWiFi, .fallbackWiFi:
            return .none
        }
    }

    public mutating func wifiPathChanged(isAvailable: Bool, lanAvailable: Bool) -> BoothNetworkRouteCommand {
        if isAvailable {
            guard case .disconnected = state else { return .none }
            switch preference {
            case .wifi:
                return startWiFiIfAvailable(true, fallback: false)
            case .lan:
                return lanAvailable ? .none : startWiFiIfAvailable(true, fallback: true)
            }
        }
        switch state {
        case .connectingWiFi, .connectedWiFi, .fallbackWiFi:
            if preference == .lan, lanAvailable {
                state = .connectingLAN
                return .startLAN
            }
            state = .disconnected
            return .unavailable
        case .disconnected, .connectingLAN, .connectedLAN:
            return .none
        }
    }

    public mutating func wifiConnected(peer: String, fallback: Bool) -> BoothNetworkRouteCommand {
        state = fallback ? .fallbackWiFi(peer: peer) : .connectedWiFi(peer: peer)
        return .none
    }

    public mutating func transportDisconnected(
        lanAvailable: Bool,
        wifiAvailable: Bool
    ) -> BoothNetworkRouteCommand {
        state = .disconnected
        return start(lanAvailable: lanAvailable, wifiAvailable: wifiAvailable)
    }

    private mutating func startLANIfAvailable(
        _ lanAvailable: Bool,
        wifiAvailable: Bool
    ) -> BoothNetworkRouteCommand {
        guard lanAvailable else { return startWiFiIfAvailable(wifiAvailable, fallback: true) }
        state = .connectingLAN
        return .startLAN
    }

    private mutating func startWiFiIfAvailable(
        _ wifiAvailable: Bool,
        fallback: Bool
    ) -> BoothNetworkRouteCommand {
        guard wifiAvailable else {
            state = .disconnected
            return .unavailable
        }
        state = .connectingWiFi
        return .startWiFi(fallback: fallback)
    }
}
