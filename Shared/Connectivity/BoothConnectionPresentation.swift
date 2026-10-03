import Foundation

public enum BoothPreferredMacConnectionState: Sendable, Equatable {
    case none
    case connected
    case reconnecting
    case available
    case notConnected
}

public struct BoothPreferredMacPresentation: Sendable, Equatable {
    public let peerID: String?
    public let displayName: String
    public let state: BoothPreferredMacConnectionState

    public var isSecurelyConnected: Bool { state == .connected }

    public static func resolve(
        preferredPeerID: String?,
        trustedPeers: [TrustedBoothPeer],
        nearbyMacs: [BoothNearbyMacPresentation],
        connectionState: BoothConnectionState,
        connectedPeerID: String?,
        isAuthenticated: Bool,
        isSecureChannelEstablished: Bool,
        isReconnectInProgress: Bool,
        hasPreferredControlAttempt: Bool
    ) -> BoothPreferredMacPresentation {
        guard let preferredPeerID else {
            return BoothPreferredMacPresentation(
                peerID: nil,
                displayName: "No Mac selected",
                state: .none
            )
        }

        let trustedName = trustedPeers.first { $0.id == preferredPeerID }?.displayName
        let nearby = nearbyMacs.first { $0.id == preferredPeerID }
        let displayName = BoothPeerDisplayName.resolve(
            trustedName: trustedName,
            discoveredName: nearby?.displayName,
            deviceID: preferredPeerID,
            fallback: "Preferred Mac"
        )
        let transportConnected: Bool
        if case .connected = connectionState {
            transportConnected = true
        } else {
            transportConnected = false
        }

        let state: BoothPreferredMacConnectionState
        if transportConnected,
           connectedPeerID == preferredPeerID,
           isAuthenticated,
           isSecureChannelEstablished {
            state = .connected
        } else if hasPreferredControlAttempt
                    || (nearby != nil && (isReconnectInProgress || connectionState == .connecting))
                    || (transportConnected && connectedPeerID == preferredPeerID) {
            state = .reconnecting
        } else if nearby?.isStale == false {
            state = .available
        } else {
            state = .notConnected
        }

        return BoothPreferredMacPresentation(
            peerID: preferredPeerID,
            displayName: displayName,
            state: state
        )
    }
}

public struct BoothNearbyMacPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let appVersion: String
    public let protocolVersion: Int
    public let availableInterfaces: Set<BoothNetworkInterfacePolicy>
    public let isTrusted: Bool
    public let isPreferred: Bool
    public let isStale: Bool
}

/// A short UI-only cache keeps rows steady across discovery snapshots. It
/// never grants trust or makes a stale peer actionable.
public struct BoothDiscoveryPresentationCache: Sendable {
    public static let retentionInterval: TimeInterval = 12

    private struct Entry: Sendable {
        let id: String
        let displayName: String?
        let appVersion: String
        let protocolVersion: Int
        let availableInterfaces: Set<BoothNetworkInterfacePolicy>
        var isCurrent: Bool
        var lastSeenAt: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func update(_ discoveries: [BoothDiscoveredPeer], at now: Date = Date()) {
        for id in Array(entries.keys) {
            entries[id]?.isCurrent = false
        }

        for peer in discoveries where peer.role == .mac {
            let old = entries[peer.id]
            entries[peer.id] = Entry(
                id: peer.id,
                displayName: BoothPeerDisplayName.usable(peer.displayName, deviceID: peer.id)
                    ?? old?.displayName,
                appVersion: peer.appVersion,
                protocolVersion: peer.protocolVersion,
                availableInterfaces: peer.availableInterfaces,
                isCurrent: true,
                lastSeenAt: now
            )
        }
        pruneExpired(at: now)
    }

    public mutating func pruneExpired(at now: Date = Date()) {
        entries = entries.filter {
            now.timeIntervalSince($0.value.lastSeenAt) <= Self.retentionInterval
        }
    }

    public func nearbyMacs(
        at now: Date = Date(),
        trustedPeers: [TrustedBoothPeer],
        preferredPeerID: String?
    ) -> [BoothNearbyMacPresentation] {
        let trustedByID = Dictionary(uniqueKeysWithValues: trustedPeers.map { ($0.id, $0) })
        return entries.values
            .filter { now.timeIntervalSince($0.lastSeenAt) <= Self.retentionInterval }
            .map { entry in
                let trusted = trustedByID[entry.id]
                return BoothNearbyMacPresentation(
                    id: entry.id,
                    displayName: BoothPeerDisplayName.resolve(
                        trustedName: trusted?.displayName,
                        discoveredName: entry.displayName,
                        deviceID: entry.id,
                        fallback: "Mac"
                    ),
                    appVersion: entry.appVersion,
                    protocolVersion: entry.protocolVersion,
                    availableInterfaces: entry.availableInterfaces,
                    isTrusted: trusted != nil,
                    isPreferred: preferredPeerID == entry.id,
                    isStale: !entry.isCurrent
                )
            }
            .sorted {
                if $0.isPreferred != $1.isPreferred { return $0.isPreferred }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }
}

public enum BoothPeerDisplayName {
    public static func resolve(
        trustedName: String?,
        discoveredName: String?,
        deviceID: String,
        fallback: String
    ) -> String {
        usable(trustedName, deviceID: deviceID)
            ?? usable(discoveredName, deviceID: deviceID)
            ?? fallback
    }

    public static func usable(_ name: String?, deviceID: String) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != deviceID,
              UUID(uuidString: trimmed) == nil,
              !looksLikeOpaqueIdentifier(trimmed) else { return nil }
        return trimmed
    }

    private static func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        guard value.count >= 24,
              !value.contains(where: { $0.isWhitespace }) else { return false }
        return value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

public struct BoothConnectionPresentation: Equatable, Sendable {
    public let stateText: String
    public let peerName: String?
    public let requestedTransport: String
    public let effectiveTransport: String
    public let fallbackText: String?
    public let controlConnected: Bool
    public let authenticated: Bool
    public let preferredPeerID: String?
    public let previewConnected: Bool
    public let lanHandshake: String
    public let ethernetAvailable: Bool
    public let wifiAvailable: Bool
    public let previewFPS: Double
    public let throughputBytesPerSecond: Double
    public let roundTripLatency: TimeInterval?
}

@MainActor
public enum BoothConnectionPresentationResolver {
    public static func resolve(_ status: BoothConnectionStatus) -> BoothConnectionPresentation {
        let controlConnected: Bool
        switch status.state {
        case .connected:
            controlConnected = true
        case .connecting, .disconnected:
            controlConnected = false
        }

        let stateText: String
        switch status.state {
        case .connected:
            stateText = "Connected"
        case .disconnected:
            stateText = "No iPad connected"
        case .connecting:
            switch status.routeState {
            case .connectingLAN:
                stateText = "Connecting via LAN"
            case .connectingWiFi:
                stateText = status.isFallbackActive ? "Connecting via Wi-Fi fallback" : "Connecting via Wi-Fi"
            case .connectedLAN, .connectedWiFi, .fallbackWiFi, .disconnected:
                stateText = "Connecting to iPad"
            }
        }

        let effectiveTransport: String
        switch status.effectiveNetwork {
        case .lan:
            effectiveTransport = "Ethernet"
        case .wifi:
            effectiveTransport = "Wi-Fi"
        case .unavailable:
            effectiveTransport = "Unavailable"
        }

        let fallbackText = status.isFallbackActive
            ? "Wi-Fi fallback active" + (status.fallbackReason.map { ": \($0)" } ?? "")
            : nil
        let authenticatedLANActive = controlConnected
            && status.isPeerAuthenticated
            && status.peerID == status.preferredPeerID
            && status.effectiveNetwork == .lan

        return BoothConnectionPresentation(
            stateText: stateText,
            peerName: status.peerDisplayName,
            requestedTransport: status.requestedNetwork == .lan ? "LAN" : "Wi-Fi",
            effectiveTransport: effectiveTransport,
            fallbackText: fallbackText,
            controlConnected: controlConnected,
            authenticated: status.isPeerAuthenticated,
            preferredPeerID: status.preferredPeerID,
            previewConnected: status.isPreviewChannelConnected,
            lanHandshake: handshakeText(status.lanHandshake),
            ethernetAvailable: status.isLANPathAvailable || authenticatedLANActive,
            wifiAvailable: status.isWiFiPathAvailable,
            previewFPS: status.previewDiagnostics.fps,
            throughputBytesPerSecond: status.previewDiagnostics.bytesPerSecond,
            roundTripLatency: status.roundTripLatency
        )
    }

    private static func handshakeText(_ state: BoothLANHandshakeState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .waiting: return "Waiting"
        case .ready: return "Ready"
        case .timeout: return "Timeout"
        case .failed: return "Failed"
        }
    }
}
