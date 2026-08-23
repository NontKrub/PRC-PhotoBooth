import Foundation

public struct BoothConnectionPresentation: Equatable, Sendable {
    public let stateText: String
    public let peerName: String?
    public let requestedTransport: String
    public let effectiveTransport: String
    public let fallbackText: String?
    public let controlConnected: Bool
    public let previewConnected: Bool
    public let lanHandshake: String
    public let ethernetAvailable: Bool
    public let wifiAvailable: Bool
    public let previewFPS: Double
    public let throughputBytesPerSecond: Double
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
        switch status.routeState {
        case .connectingLAN:
            stateText = "Connecting via LAN"
        case .connectingWiFi:
            stateText = status.isFallbackActive ? "Connecting via Wi-Fi fallback" : "Connecting via Wi-Fi"
        case .connectedLAN, .connectedWiFi, .fallbackWiFi:
            stateText = "Connected"
        case .disconnected:
            stateText = "No iPad connected"
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

        return BoothConnectionPresentation(
            stateText: stateText,
            peerName: status.peerDisplayName,
            requestedTransport: status.requestedNetwork == .lan ? "LAN" : "Wi-Fi",
            effectiveTransport: effectiveTransport,
            fallbackText: fallbackText,
            controlConnected: controlConnected,
            previewConnected: status.isPreviewChannelConnected,
            lanHandshake: handshakeText(status.lanHandshake),
            ethernetAvailable: status.isLANPathAvailable,
            wifiAvailable: status.isWiFiPathAvailable,
            previewFPS: status.previewDiagnostics.fps,
            throughputBytesPerSecond: status.previewDiagnostics.bytesPerSecond
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
