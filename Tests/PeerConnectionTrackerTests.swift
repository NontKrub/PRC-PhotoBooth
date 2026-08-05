import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Peer connection tracker")
struct PeerConnectionTrackerTests {
    @Test
    func transportConnectionDoesNotVerifyPeer() {
        var tracker = PeerConnectionTracker<Int>(localRole: .mac)

        tracker.transportConnected(1)

        #expect(tracker.transportPeers == [1])
        #expect(tracker.verifiedPeers.isEmpty)
        #expect(tracker.activePeer == nil)
    }

    @Test
    func macAcceptsIPadHello() {
        var tracker = PeerConnectionTracker<Int>(localRole: .mac)
        tracker.transportConnected(1)

        let result = tracker.verifyHello(from: 1, role: .iPad)

        #expect(result == .accepted)
        #expect(tracker.verifiedPeers[1] == .iPad)
        #expect(tracker.activePeer == 1)
    }

    @Test
    func ipadAcceptsMacHello() {
        var tracker = PeerConnectionTracker<Int>(localRole: .iPad)
        tracker.transportConnected(1)

        let result = tracker.verifyHello(from: 1, role: .mac)

        #expect(result == .accepted)
        #expect(tracker.verifiedPeers[1] == .mac)
        #expect(tracker.activePeer == 1)
    }

    @Test
    func sameRoleHelloIsRejected() {
        var macTracker = PeerConnectionTracker<Int>(localRole: .mac)
        macTracker.transportConnected(1)
        var ipadTracker = PeerConnectionTracker<Int>(localRole: .iPad)
        ipadTracker.transportConnected(1)

        #expect(macTracker.verifyHello(from: 1, role: .mac) == .wrongRole)
        #expect(ipadTracker.verifyHello(from: 1, role: .iPad) == .wrongRole)
        #expect(macTracker.verifiedPeers.isEmpty)
        #expect(ipadTracker.verifiedPeers.isEmpty)
    }

    @Test
    func helloFromUnknownTransportPeerIsRejected() {
        var tracker = PeerConnectionTracker<Int>(localRole: .mac)

        let result = tracker.verifyHello(from: 1, role: .iPad)

        #expect(result == .unknownTransportPeer)
        #expect(tracker.activePeer == nil)
    }

    @Test
    func disconnectingOnlyVerifiedPeerClearsActivePeer() {
        var tracker = PeerConnectionTracker<Int>(localRole: .mac)
        tracker.transportConnected(1)
        _ = tracker.verifyHello(from: 1, role: .iPad)

        tracker.transportDisconnected(1)

        #expect(tracker.transportPeers.isEmpty)
        #expect(tracker.verifiedPeers.isEmpty)
        #expect(tracker.activePeer == nil)
    }

    @Test
    func disconnectingActivePeerPromotesBackup() {
        var tracker = PeerConnectionTracker<Int>(localRole: .mac)
        tracker.transportConnected(1)
        tracker.transportConnected(2)
        _ = tracker.verifyHello(from: 1, role: .iPad)
        _ = tracker.verifyHello(from: 2, role: .iPad)

        tracker.transportDisconnected(1)

        #expect(tracker.activePeer == 2)
        #expect(tracker.verifiedPeers[2] == .iPad)
    }

    @Test
    func resetClearsTransportAndVerificationState() {
        var tracker = PeerConnectionTracker<Int>(localRole: .mac)
        tracker.transportConnected(1)
        tracker.transportConnected(2)
        _ = tracker.verifyHello(from: 1, role: .iPad)
        _ = tracker.verifyHello(from: 2, role: .iPad)

        tracker.reset()

        #expect(tracker.transportPeers.isEmpty)
        #expect(tracker.verifiedPeers.isEmpty)
        #expect(tracker.activePeer == nil)
    }
}
