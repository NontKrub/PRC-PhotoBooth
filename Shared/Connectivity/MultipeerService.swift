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
    public var activePeerName: String? = nil

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
    private var connectionAttemptID = 0
    private var lastHeartbeatReceived: Date = .distantPast
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var latestPreviewFrame: Data?
    private var previewDeliveryTask: Task<Void, Never>?

    public init(role: DeviceRole) {
        self.role = role
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
        stopHeartbeat()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionAttemptID &+= 1
        _session?.disconnect()
        let s = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        _session = s
        sessionReference.set(s, attemptID: connectionAttemptID)
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
        stopHeartbeat()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        _session?.disconnect()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
    }

    // MARK: - Reconnect with backoff

    private func scheduleReconnect() {
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard case .disconnected = connectionState else { return }
            resetPeer()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        lastHeartbeatReceived = Date()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: kHeartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sendControl(.heartbeat)
                if Date().timeIntervalSince(self.lastHeartbeatReceived) > kHeartbeatTimeout {
                    print("[MPC] heartbeat timeout — forcing reconnect")
                    self._session?.disconnect()
                    self.connectionState = .disconnected
                    self.scheduleReconnect()
                }
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
            self._session?.disconnect()
            self.connectionState = .disconnected
            self.activePeerName = nil
            self.scheduleReconnect()
            if self.role == .iPad { self.startBrowsing() }
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
        guard let active = activePeerName else { return session.connectedPeers }
        return session.connectedPeers.filter { $0.displayName == active }
    }

    // MARK: - Receive

    private func handleControlMessage(_ message: Message) {
        if case .heartbeat = message {
            lastHeartbeatReceived = Date()
            return
        }
        onControlMessage?(message)
    }

    private func enqueuePreviewFrame(_ jpegData: Data) {
        // Preview is disposable. Never let old frames build a queue ahead of
        // control messages; the next delivery uses only the newest frame.
        latestPreviewFrame = jpegData
        guard previewDeliveryTask == nil else { return }

        previewDeliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.previewDeliveryTask = nil
            guard let frame = self.latestPreviewFrame else { return }
            self.latestPreviewFrame = nil
            self.onPreviewFrame?(frame)
            if let pending = self.latestPreviewFrame {
                self.enqueuePreviewFrame(pending)
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
                if !connectedPeerNames.contains(name) { connectedPeerNames.append(name) }
                if activePeerName == nil { activePeerName = name }
                connectionState = .connected(peerName: activePeerName ?? name)
                peerName = activePeerName ?? name
                reconnectAttempt = 0
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                startHeartbeat()
                sendControl(.hello(role: role))
            case .connecting:
                // Do not downgrade a healthy connection while another peer is
                // negotiating in the background.
                if connectedPeerNames.isEmpty {
                    connectionState = .connecting
                    startConnectionTimeout()
                }
            case .notConnected:
                connectedPeerNames.removeAll { $0 == name }
                if activePeerName == name { activePeerName = connectedPeerNames.first }
                if connectedPeerNames.isEmpty {
                    connectionState = .disconnected
                    stopHeartbeat()
                    connectionTimeoutTask?.cancel()
                    connectionTimeoutTask = nil
                    scheduleReconnect()
                    if role == .iPad { startBrowsing() }
                }
            @unknown default: break
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let (channel, payload) = data.unpackedPacket() else { return }
        switch channel {
        case .control:
            guard let message = try? Message.decoded(from: payload) else { return }
            Task { @MainActor [weak self] in self?.handleControlMessage(message) }
        case .preview:
            Task { @MainActor [weak self] in self?.enqueuePreviewFrame(payload) }
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
