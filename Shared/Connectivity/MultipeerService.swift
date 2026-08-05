import Foundation
import MultipeerConnectivity
import Observation
#if os(iOS)
import UIKit
#endif

public let kMCServiceType = "prc-photobooth"
private let kHeartbeatInterval: TimeInterval = 5
private let kHeartbeatTimeout:  TimeInterval = 18
private let kConnectionTimeout: TimeInterval = 35
private let kHandshakeTimeout: TimeInterval = 10

private final class SessionReference: @unchecked Sendable {
    private let lock = NSLock()
    private var session: MCSession?
    private var attemptID = 0

    func set(_ session: MCSession?, attemptID: Int) {
        lock.lock()
        self.session = session
        self.attemptID = attemptID
        lock.unlock()
    }

    func get() -> MCSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func attemptID(for session: MCSession) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return self.session === session ? attemptID : nil
    }
}

@MainActor
@Observable
public final class MultipeerService: NSObject {
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(peerName: String)
    }

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var peerName: String = ""
    public private(set) var connectedPeerNames: [String] = []
    public var activePeerName: String? {
        get { peerTracker.activePeer }
        set {
            guard let newValue,
                  peerTracker.verifiedPeers[newValue] != nil else { return }
            peerTracker.activate(newValue)
            refreshVerifiedPeerState()
            startHeartbeat()
        }
    }

    // Control packets are decoded before hopping to the main actor. Preview
    // packets are disposable and coalesced so they cannot starve controls.
    public var onControlMessage: (@MainActor (Message) -> Void)?
    public var onPreviewFrame:   (@MainActor (Data) -> Void)?

    public let role: DeviceRole

    private let myPeerID: MCPeerID
    private var _session: MCSession?
    nonisolated private let sessionReference = SessionReference()

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var heartbeatTimer: Timer?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var handshakeTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var connectionAttemptID = 0
    private var lastHeartbeatReceived: Date = .distantPast
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var peerTracker: PeerConnectionTracker<String>
    private var latestPreviewFrame: (peer: String, data: Data)?
    private var previewDeliveryTask: Task<Void, Never>?

    public init(role: DeviceRole) {
        self.role = role
        self.peerTracker = PeerConnectionTracker(localRole: role)
        #if os(macOS)
        let name = Host.current().localizedName ?? "PRC-Mac"
        #else
        let name = UIDevice.current.name
        #endif
        myPeerID = MCPeerID(displayName: name)
        super.init()
        resetPeer()
    }

    // MARK: - Session lifecycle

    private func resetPeer() {
        stopDiscovery()
        clearConnectionState()

        connectionAttemptID &+= 1
        let oldSession = _session
        _session = nil
        sessionReference.set(nil, attemptID: connectionAttemptID)
        oldSession?.disconnect()

        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        _session = session
        sessionReference.set(session, attemptID: connectionAttemptID)

        switch role {
        case .mac:  startAdvertising()
        case .iPad: startBrowsing()
        }
    }

    private func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
    }

    private func startDiscovery() {
        switch role {
        case .mac:  startAdvertising()
        case .iPad: startBrowsing()
        }
    }

    private func startAdvertising() {
        advertiser?.stopAdvertisingPeer()
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: kMCServiceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
    }

    private func startBrowsing() {
        browser?.stopBrowsingForPeers()
        let brw = MCNearbyServiceBrowser(peer: myPeerID, serviceType: kMCServiceType)
        brw.delegate = self
        brw.startBrowsingForPeers()
        browser = brw
    }

    public func disconnect() {
        stopDiscovery()
        clearConnectionState()
        connectionAttemptID &+= 1
        let oldSession = _session
        _session = nil
        sessionReference.set(nil, attemptID: connectionAttemptID)
        oldSession?.disconnect()
    }

    private func clearConnectionState(cancelReconnect: Bool = true) {
        stopHeartbeat()

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil

        handshakeTimeoutTasks.values.forEach { $0.cancel() }
        handshakeTimeoutTasks.removeAll()

        if cancelReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        previewDeliveryTask?.cancel()
        previewDeliveryTask = nil
        latestPreviewFrame = nil

        peerTracker.reset()
        connectedPeerNames = []
        peerName = ""
        connectionState = .disconnected
        lastHeartbeatReceived = .distantPast
    }

    private func invalidateCurrentSession() {
        connectionAttemptID &+= 1
        let oldSession = _session
        _session = nil
        sessionReference.set(nil, attemptID: connectionAttemptID)
        oldSession?.disconnect()
    }

    // MARK: - Reconnect with backoff

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1

        print("[MPC] scheduling reconnect in \(delay)s")
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                self.reconnectTask = nil
                return
            }
            guard !Task.isCancelled, case .disconnected = self.connectionState else {
                self.reconnectTask = nil
                return
            }
            self.reconnectTask = nil
            resetPeer()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard peerTracker.activePeer != nil else {
            stopHeartbeat()
            return
        }

        lastHeartbeatReceived = Date()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: kHeartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let activePeer = self.peerTracker.activePeer else {
                    self.stopHeartbeat()
                    return
                }

                if Date().timeIntervalSince(self.lastHeartbeatReceived) > kHeartbeatTimeout {
                    print("[MPC] heartbeat timeout: \(activePeer)")
                    self.stopDiscovery()
                    self.clearConnectionState()
                    self.invalidateCurrentSession()
                    self.scheduleReconnect()
                    return
                }

                self.sendControl(.heartbeat)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func startConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        let attemptID = connectionAttemptID
        connectionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(kConnectionTimeout))
            guard !Task.isCancelled,
                  let self,
                  self.connectionAttemptID == attemptID,
                  self.connectionState == .connecting
            else { return }

            print("[MPC] connection timed out — retrying discovery")
            self.stopDiscovery()
            self.clearConnectionState()
            self.invalidateCurrentSession()
            self.scheduleReconnect()
        }
    }

    // MARK: - Send

    public func sendControl(_ message: Message) {
        guard let session = _session else { return }
        let targets = targetPeers(from: session)
        guard !targets.isEmpty else { return }
        do {
            let payload = try message.encoded().packedAsControl()
            try session.send(payload, toPeers: targets, with: .reliable)
        } catch { print("[MPC] send error: \(error)") }
    }

    public func sendPreviewFrame(_ jpegData: Data) {
        guard let session = _session else { return }
        let targets = targetPeers(from: session)
        guard !targets.isEmpty else { return }
        try? session.send(jpegData.packedAsPreview(), toPeers: targets, with: .unreliable)
    }

    private func targetPeers(from session: MCSession) -> [MCPeerID] {
        guard let activePeer = peerTracker.activePeer,
              peerTracker.verifiedPeers[activePeer] != nil else { return [] }
        return session.connectedPeers.filter { $0.displayName == activePeer }
    }

    // MARK: - Receive

    private func refreshVerifiedPeerState() {
        connectedPeerNames = peerTracker.verifiedPeers.keys.sorted()

        guard let activePeerName = peerTracker.activePeer else {
            peerName = ""
            connectionState = .disconnected
            return
        }

        peerName = activePeerName
        connectionState = .connected(peerName: activePeerName)
    }

    private func cancelHandshakeTimeout(for peerName: String) {
        handshakeTimeoutTasks[peerName]?.cancel()
        handshakeTimeoutTasks[peerName] = nil
    }

    private func startHandshakeTimeout(for peerName: String, attemptID: Int) {
        cancelHandshakeTimeout(for: peerName)
        handshakeTimeoutTasks[peerName] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(kHandshakeTimeout))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.connectionAttemptID == attemptID,
                  let session = self._session,
                  self.sessionReference.attemptID(for: session) == attemptID,
                  self.peerTracker.transportPeers.contains(peerName),
                  self.peerTracker.verifiedPeers[peerName] == nil else { return }

            self.handshakeTimeoutTasks[peerName] = nil
            print("[MPC] handshake timeout: \(peerName)")
            self.removePeer(peerName, from: session)
        }
    }

    private func removePeer(_ peerName: String, from session: MCSession? = nil) {
        let wasActive = peerTracker.activePeer == peerName
        cancelHandshakeTimeout(for: peerName)
        if let peerID = session?.connectedPeers.first(where: { $0.displayName == peerName }) {
            session?.cancelConnectPeer(peerID)
        }
        peerTracker.transportDisconnected(peerName)

        guard peerTracker.hasVerifiedPeer else {
            if wasActive { print("[MPC] active peer disconnected: \(peerName)") }
            clearConnectionState(cancelReconnect: false)
            startDiscovery()
            scheduleReconnect()
            return
        }

        refreshVerifiedPeerState()
        if wasActive {
            previewDeliveryTask?.cancel()
            previewDeliveryTask = nil
            latestPreviewFrame = nil
            startHeartbeat()
        }
    }

    private func handleControlMessage(_ message: Message, from peerName: String) {
        if case .hello(let remoteRole) = message {
            switch peerTracker.verifyHello(from: peerName, role: remoteRole) {
            case .accepted:
                cancelHandshakeTimeout(for: peerName)
                refreshVerifiedPeerState()
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                reconnectAttempt = 0
                reconnectTask?.cancel()
                reconnectTask = nil
                startHeartbeat()
                print("[MPC] verified peer: \(peerName), role: \(remoteRole)")
                if peerTracker.activePeer == peerName {
                    onControlMessage?(message)
                }
            case .wrongRole:
                print("[MPC] rejected hello from \(peerName): wrong role")
                removePeer(peerName, from: _session)
            case .unknownTransportPeer:
                print("[MPC] ignored hello from unknown transport peer: \(peerName)")
            }
            return
        }

        guard peerTracker.activePeer == peerName else { return }
        if case .heartbeat = message {
            lastHeartbeatReceived = Date()
            return
        }
        onControlMessage?(message)
    }

    private func enqueuePreviewFrame(_ jpegData: Data, from peerName: String) {
        guard peerTracker.activePeer == peerName else { return }

        // Preview is disposable. Never let old frames build a queue ahead of
        // control messages; the next delivery uses only the newest frame.
        latestPreviewFrame = (peerName, jpegData)
        guard previewDeliveryTask == nil else { return }

        previewDeliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.previewDeliveryTask = nil
            guard !Task.isCancelled,
                  let frame = self.latestPreviewFrame else { return }
            self.latestPreviewFrame = nil
            guard self.peerTracker.activePeer == frame.peer else { return }
            self.onPreviewFrame?(frame.data)
            if let pending = self.latestPreviewFrame {
                self.enqueuePreviewFrame(pending.data, from: pending.peer)
            }
        }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerService: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        guard let attemptID = sessionReference.attemptID(for: session) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A replacement session can still emit its final callbacks after
            // resetPeer() has installed a new one. Ignore those stale events.
            guard self.connectionAttemptID == attemptID else { return }
            switch state {
            case .connected:
                peerTracker.transportConnected(name)
                print("[MPC] transport connected: \(name)")
                if !peerTracker.hasVerifiedPeer {
                    connectionState = .connecting
                    startConnectionTimeout()
                }
                startHandshakeTimeout(for: name, attemptID: attemptID)
                sendHello(to: name)
            case .connecting:
                // Do not downgrade a healthy connection while another peer is
                // negotiating in the background.
                if !peerTracker.hasVerifiedPeer {
                    connectionState = .connecting
                    startConnectionTimeout()
                }
            case .notConnected:
                removePeer(name)
            @unknown default: break
            }
        }
    }

    private func sendHello(to peerName: String) {
        guard let session = _session,
              let peerID = session.connectedPeers.first(where: { $0.displayName == peerName }) else { return }

        do {
            let payload = try Message.hello(role: role).encoded().packedAsControl()
            try session.send(payload, toPeers: [peerID], with: .reliable)
            print("[MPC] sent hello to: \(peerName)")
        } catch {
            print("[MPC] hello send failed: \(error)")
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let attemptID = sessionReference.attemptID(for: session) else { return }
        let peerName = peerID.displayName
        guard let (channel, payload) = data.unpackedPacket() else { return }
        switch channel {
        case .control:
            guard let message = try? Message.decoded(from: payload) else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionAttemptID == attemptID else { return }
                self.handleControlMessage(message, from: peerName)
            }
        case .preview:
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionAttemptID == attemptID else { return }
                self.enqueuePreviewFrame(payload, from: peerName)
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, sessionReference.get())
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerService: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let session = sessionReference.get() else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[MPC Browser] \(error)")
    }
}
