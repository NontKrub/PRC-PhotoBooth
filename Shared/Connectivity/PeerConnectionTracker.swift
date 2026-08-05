import Foundation

public struct PeerConnectionTracker<Peer: Hashable> {
    public enum VerificationResult: Equatable {
        case accepted
        case wrongRole
        case unknownTransportPeer
    }

    public let localRole: DeviceRole
    public private(set) var transportPeers: Set<Peer> = []
    public private(set) var verifiedPeers: [Peer: DeviceRole] = [:]
    public private(set) var activePeer: Peer?

    public init(localRole: DeviceRole) {
        self.localRole = localRole
    }

    public var expectedRemoteRole: DeviceRole {
        switch localRole {
        case .mac: return .iPad
        case .iPad: return .mac
        }
    }

    public var hasVerifiedPeer: Bool {
        activePeer != nil
    }

    public mutating func transportConnected(_ peer: Peer) {
        transportPeers.insert(peer)
    }

    public mutating func verifyHello(from peer: Peer, role: DeviceRole) -> VerificationResult {
        guard transportPeers.contains(peer) else { return .unknownTransportPeer }
        guard role == expectedRemoteRole else { return .wrongRole }

        verifiedPeers[peer] = role
        if activePeer == nil { activePeer = peer }
        return .accepted
    }

    public mutating func activate(_ peer: Peer) {
        guard transportPeers.contains(peer), verifiedPeers[peer] != nil else { return }
        activePeer = peer
    }

    public mutating func transportDisconnected(_ peer: Peer) {
        transportPeers.remove(peer)
        verifiedPeers.removeValue(forKey: peer)
        if activePeer == peer {
            activePeer = verifiedPeers.keys.first
        }
    }

    public mutating func reset() {
        transportPeers.removeAll()
        verifiedPeers.removeAll()
        activePeer = nil
    }
}
