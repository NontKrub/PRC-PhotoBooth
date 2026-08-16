import Foundation
import Network

@MainActor
public final class NetworkBoothTransport: BoothTransport {
    private static let controlServiceType = "_prc-control._tcp"
    private static let previewServiceType = "_prc-preview._tcp"
    private static let previewIdentityCapability = "preview-identity"
    private static let heartbeatInterval: TimeInterval = 2
    private static let heartbeatTimeout: TimeInterval = 8

    public let role: DeviceRole
    public let connectionStatus: BoothConnectionStatus
    public private(set) var connectionState: BoothConnectionState = .disconnected
    public private(set) var peerName = ""
    public private(set) var connectedPeerNames: [String] = []
    public var activePeerName: String? {
        get { peerName.isEmpty ? nil : peerName }
        set { /* Network transport has one authoritative peer. */ }
    }
    public var onControlMessage: (@MainActor (Message) -> Void)?
    public var onPreviewFrame: (@MainActor (Data) -> Void)?

    private var requestedPreference: BoothNetworkPreference

    public var requestedNetworkPreference: BoothNetworkPreference {
        get { requestedPreference }
        set { requestedPreference = newValue }
    }

    private let deviceID = UUID().uuidString
    private var controlListener: NWListener?
    private var previewListener: NWListener?
    private var controlBrowser: NWBrowser?
    private var previewBrowser: NWBrowser?
    private var controlConnection: NWConnection?
    private var previewConnection: NWConnection?
    private var controlParser = BoothFrameParser()
    private var previewParser = BoothFrameParser()
    private var previewFrames = LatestFrameCoalescer()
    private var heartbeatTimer: Timer?
    private var lastControlMessageAt = Date.distantPast
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private var controlEndpointDescription: String?
    private var previewEndpointDescription: String?
    private var didReceiveHello = false
    private var expectedPeerDeviceID: String?
    private var previewPeerID: String?
    private var previewPeerSupportsIdentity = false
    private var didSendPreviewHello = false
    private var previewIdentityVerified = false
#if DEBUG
    private var previewMetricsStartedAt = Date()
    private var previewFramesSubmitted = 0
    private var previewFramesSent = 0
    private var previewCoalescedAtLastMetrics = 0
#endif

    public init(
        role: DeviceRole,
        networkPreference: BoothNetworkPreference = .wifi,
        connectionStatus: BoothConnectionStatus? = nil
    ) {
        self.role = role
        self.requestedPreference = networkPreference
        self.connectionStatus = connectionStatus ?? BoothConnectionStatus(requestedNetwork: networkPreference)
    }

    public func start() {
        shouldReconnect = true
        switch role {
        case .mac:
            startListener(channel: .control)
            startListener(channel: .preview)
        case .iPad:
            startBrowser(channel: .control)
            startBrowser(channel: .preview)
        }
    }

    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        controlBrowser?.cancel()
        previewBrowser?.cancel()
        controlBrowser = nil
        previewBrowser = nil
        controlListener?.cancel()
        previewListener?.cancel()
        controlListener = nil
        previewListener = nil
        controlConnection?.cancel()
        previewConnection?.cancel()
        controlConnection = nil
        previewConnection = nil
        previewFrames.reset()
        didReceiveHello = false
        expectedPeerDeviceID = nil
        resetPreviewIdentity()
        setDisconnected()
    }

    public func sendControl(_ message: Message) {
        send(message, on: controlConnection, channel: .control)
    }

    public func sendPreviewFrame(_ jpegData: Data) {
        previewFrames.enqueue(jpegData)
#if DEBUG
        previewFramesSubmitted += 1
#endif
        flushPreviewFrame()
        logPreviewMetricsIfNeeded()
    }

    private func startListener(channel: BoothTransportChannel) {
        if channel == .control, controlListener != nil { return }
        if channel == .preview, previewListener != nil { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            print("[Network] listener creation failed: \(error.localizedDescription)")
            return
        }
        listener.service = NWListener.Service(
            name: "PRC PhotoBooth \(channel == .control ? "Control" : "Preview") \(deviceID)",
            type: channel == .control ? Self.controlServiceType : Self.previewServiceType
        )
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[Network] listener failed: \(message)")
                if channel == .control { self.controlListener = nil } else { self.previewListener = nil }
                // XCTest and devices without local-network permission return
                // NoAuth. Retrying that state in a tight loop only burns CPU.
                guard !message.contains("NoAuth") else { return }
                self.scheduleReconnect()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection, channel: channel)
            }
        }
        listener.start(queue: .main)
        if channel == .control { controlListener = listener } else { previewListener = listener }
    }

    private func startBrowser(channel: BoothTransportChannel) {
        if channel == .control, controlBrowser != nil { return }
        if channel == .preview, previewBrowser != nil { return }
        let serviceType = channel == .control ? Self.controlServiceType : Self.previewServiceType
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let endpoint = self.endpointToConnect(from: results, channel: channel) else { return }
                self.connect(to: endpoint, channel: channel)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[Network] browser failed: \(message)")
                if channel == .control { self.controlBrowser = nil } else { self.previewBrowser = nil }
                if !message.contains("NoAuth") { self.scheduleReconnect() }
            }
        }
        browser.start(queue: .main)
        if channel == .control { controlBrowser = browser } else { previewBrowser = browser }
    }

    private func endpointToConnect(
        from results: Set<NWBrowser.Result>,
        channel: BoothTransportChannel
    ) -> NWEndpoint? {
        let endpoints = results.map(\.endpoint)
        guard !endpoints.isEmpty else { return nil }

        if channel == .preview {
            guard !peerName.isEmpty else { return nil }
            if let matching = endpoints.first(where: { serviceName(from: $0)?.contains(peerName) == true }) {
                return matching
            }
            return endpoints.count == 1 ? endpoints[0] : nil
        }

        if let expectedPeerDeviceID,
           let matching = endpoints.first(where: { serviceName(from: $0)?.contains(expectedPeerDeviceID) == true }) {
            return matching
        }
        return endpoints[0]
    }

    private func serviceName(from endpoint: NWEndpoint) -> String? {
        guard case let .service(name, _, _, _) = endpoint else { return nil }
        return name
    }

    private func accept(_ connection: NWConnection, channel: BoothTransportChannel) {
        if channel == .control {
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnection = connection
            controlEndpointDescription = connection.endpoint.debugDescription
            didReceiveHello = false
            controlParser = BoothFrameParser()
        } else {
            previewFrames.reset()
            previewConnection?.cancel()
            previewConnection = connection
            previewEndpointDescription = connection.endpoint.debugDescription
            previewParser = BoothFrameParser()
            resetPreviewIdentity()
        }
        configure(connection, channel: channel)
    }

    private func connect(to endpoint: NWEndpoint, channel: BoothTransportChannel) {
        if channel == .preview, peerName.isEmpty { return }
        let description = endpoint.debugDescription
        if channel == .control {
            guard controlConnection == nil || controlEndpointDescription != description else { return }
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnection = NWConnection(to: endpoint, using: .tcp)
            controlEndpointDescription = description
            didReceiveHello = false
            controlParser = BoothFrameParser()
            if let connection = controlConnection { configure(connection, channel: channel) }
        } else {
            guard previewConnection == nil || previewEndpointDescription != description else { return }
            previewFrames.reset()
            previewConnection?.cancel()
            previewConnection = NWConnection(to: endpoint, using: .tcp)
            previewEndpointDescription = description
            previewParser = BoothFrameParser()
            resetPreviewIdentity()
            if let connection = previewConnection { configure(connection, channel: channel) }
        }
    }

    private func configure(_ connection: NWConnection, channel: BoothTransportChannel) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self] in
                guard let self, let connection else { return }
                guard self.isCurrent(connection, channel: channel) else { return }
                switch state {
                case .ready:
                    if channel == .control {
                        self.connectionState = .connecting
                        self.receive(on: connection, channel: channel)
                        self.sendTransportHello()
                    } else {
                        self.receive(on: connection, channel: channel)
                        self.sendPreviewHello(on: connection)
                    }
                case .failed, .cancelled:
                    self.connectionDidClose(connection, channel: channel)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection, channel: BoothTransportChannel) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            let errorMessage = error?.localizedDescription
            let didFail = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(connection, channel: channel) else { return }
                if let data, !data.isEmpty {
                    self.receiveData(data, channel: channel)
                }
                if isComplete || didFail {
                    self.connectionDidClose(connection, channel: channel, reason: errorMessage)
                } else {
                    self.receive(on: connection, channel: channel)
                }
            }
        }
    }

    private func receiveData(_ data: Data, channel: BoothTransportChannel) {
        do {
            let frames: [BoothNetworkFrame]
            if channel == .control {
                frames = try controlParser.append(data)
            } else {
                frames = try previewParser.append(data)
            }
            if channel == .control { lastControlMessageAt = Date() }
            for frame in frames {
                guard frame.channel == channel || frame.channel == .heartbeat else {
                    continue
                }
                switch frame.channel {
                case .control:
                    guard let message = try? Message.decoded(from: frame.payload) else { continue }
                    handleControl(message)
                case .heartbeat:
                    if channel == .preview { handlePreviewHello(frame.payload) }
                case .preview:
                    guard previewIdentityVerified else { continue }
                    onPreviewFrame?(frame.payload)
                case .asset:
                    break
                }
            }
        } catch {
            print("[Network] invalid frame: \(error)")
            connectionDidClose(channel == .control ? controlConnection : previewConnection, channel: channel)
        }
    }

    private func handleControl(_ message: Message) {
        switch message {
        case .helloDetails(let hello):
            let expectedRole: DeviceRole = role == .mac ? .iPad : .mac
            guard hello.protocolVersion == BoothTransportHello.currentProtocolVersion,
                  hello.role == expectedRole else {
                print("[Network] rejected incompatible hello")
                connectionDidClose(controlConnection, channel: .control)
                return
            }
            didReceiveHello = true
            peerName = hello.deviceID
            expectedPeerDeviceID = hello.deviceID
            previewPeerSupportsIdentity = hello.capabilities.contains(Self.previewIdentityCapability)
            connectedPeerNames = [hello.deviceID]
            connectionState = .connected(peerName: hello.deviceID)
            reconnectAttempt = 0
            lastControlMessageAt = Date()
            startHeartbeat()
            validatePreviewIdentity()
            if role == .iPad, previewConnection == nil {
                // The preview browser may have received its first result before
                // control identified the Mac. Recreate it so that result is
                // evaluated against this exact peer ID.
                previewBrowser?.cancel()
                previewBrowser = nil
                startBrowser(channel: .preview)
            }
            onControlMessage?(.hello(role: hello.role))
        case .heartbeat:
            lastControlMessageAt = Date()
        default:
            guard didReceiveHello else { return }
            onControlMessage?(message)
        }
    }

    private func sendTransportHello() {
        send(
            .helloDetails(hello: BoothTransportHello(role: role, deviceID: deviceID)),
            on: controlConnection,
            channel: .control
        )
    }

    private func sendPreviewHello(on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(
            BoothTransportHello(role: role, deviceID: deviceID)
        ), let frame = try? BoothFrameEncoder.encode(channel: .heartbeat, payload: payload) else {
            connectionDidClose(connection, channel: .preview, reason: "preview hello encoding failed")
            return
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            Task { @MainActor [weak self] in
                guard let self, let connection,
                      self.isCurrent(connection, channel: .preview) else { return }
                if let error {
                    self.connectionDidClose(connection, channel: .preview, reason: error.localizedDescription)
                    return
                }
                self.didSendPreviewHello = true
                self.flushPreviewFrame()
            }
        })
    }

    private func handlePreviewHello(_ payload: Data) {
        guard let hello = try? JSONDecoder().decode(BoothTransportHello.self, from: payload) else {
            connectionDidClose(previewConnection, channel: .preview, reason: "invalid preview hello")
            return
        }
        let expectedRole: DeviceRole = role == .mac ? .iPad : .mac
        guard hello.protocolVersion == BoothTransportHello.currentProtocolVersion,
              hello.role == expectedRole else {
            connectionDidClose(previewConnection, channel: .preview, reason: "incompatible preview hello")
            return
        }
        previewPeerID = hello.deviceID
        validatePreviewIdentity()
    }

    private func validatePreviewIdentity() {
        guard didReceiveHello else { return }
        if !previewPeerSupportsIdentity {
            previewIdentityVerified = true
            flushPreviewFrame()
            return
        }
        guard let previewPeerID else { return }
        guard previewPeerID == peerName else {
            connectionDidClose(previewConnection, channel: .preview, reason: "preview peer does not match control peer")
            return
        }
        previewIdentityVerified = true
        flushPreviewFrame()
    }

    private func send(_ message: Message, on connection: NWConnection?, channel: BoothTransportChannel) {
        guard let connection else { return }
        guard let payload = try? message.encoded(),
              let frame = try? BoothFrameEncoder.encode(channel: channel, payload: payload) else { return }
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error { print("[Network] send failed: \(error.localizedDescription)") }
        })
    }

    private func flushPreviewFrame() {
        guard didSendPreviewHello,
              previewIdentityVerified,
              let connection = previewConnection,
              let jpeg = previewFrames.startNext() else { return }
        sendPreviewFrame(jpeg, on: connection)
    }

    private func sendPreviewFrame(_ jpeg: Data, on connection: NWConnection) {
        guard let frame = try? BoothFrameEncoder.encode(channel: .preview, payload: jpeg) else {
            let next = previewFrames.completeWrite()
            if let next { sendPreviewFrame(next, on: connection) }
            return
        }
#if DEBUG
        previewFramesSent += 1
#endif
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(connection, channel: .preview) else { return }
                if let error {
                    print("[Network] preview send failed: \(error.localizedDescription)")
                    self.previewFrames.resetWriteState()
                    self.connectionDidClose(connection, channel: .preview, reason: error.localizedDescription)
                    return
                }
                if let next = self.previewFrames.completeWrite() {
                    self.sendPreviewFrame(next, on: connection)
                }
                self.logPreviewMetricsIfNeeded()
            }
        })
    }

    private func logPreviewMetricsIfNeeded() {
#if DEBUG
        let now = Date()
        guard now.timeIntervalSince(previewMetricsStartedAt) >= 2 else { return }
        let state = previewIdentityVerified ? "ready" : "waiting"
        NSLog(
            "[Network] Preview state=%@ submitted=%d sent=%d coalesced=%d control=%@",
            state,
            previewFramesSubmitted,
            previewFramesSent,
            max(0, previewFrames.coalescedFrameCount - previewCoalescedAtLastMetrics),
            connectionStateLabel
        )
        previewMetricsStartedAt = now
        previewFramesSubmitted = 0
        previewFramesSent = 0
        previewCoalescedAtLastMetrics = previewFrames.coalescedFrameCount
#endif
    }

    private var connectionStateLabel: String {
        switch connectionState {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.didReceiveHello else { return }
                if Date().timeIntervalSince(self.lastControlMessageAt) > Self.heartbeatTimeout {
                    self.connectionDidClose(self.controlConnection, channel: .control, reason: "heartbeat timeout")
                } else {
                    self.sendControl(.heartbeat)
                }
            }
        }
    }

    private func connectionDidClose(_ connection: NWConnection?, channel: BoothTransportChannel, reason: String? = nil) {
        if let reason { print("[Network] \(channel) disconnected: \(reason)") }
        if channel == .control {
            guard connection == nil || connection === controlConnection else { return }
            controlConnection?.cancel()
            controlConnection = nil
            controlEndpointDescription = nil
            didReceiveHello = false
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            resetPreviewConnection()
            setDisconnected()
            scheduleReconnect()
        } else {
            guard connection == nil || connection === previewConnection else { return }
            previewConnection?.cancel()
            previewConnection = nil
            previewEndpointDescription = nil
            previewFrames.reset()
            resetPreviewIdentity()
            if role == .iPad {
                previewBrowser?.cancel()
                previewBrowser = nil
            }
            scheduleReconnect()
        }
    }

    private func isCurrent(_ connection: NWConnection, channel: BoothTransportChannel) -> Bool {
        channel == .control ? connection === controlConnection : connection === previewConnection
    }

    private func setDisconnected() {
        peerName = ""
        connectedPeerNames = []
        connectionState = .disconnected
    }

    private func resetPreviewConnection() {
        previewConnection?.cancel()
        previewConnection = nil
        previewEndpointDescription = nil
        previewFrames.reset()
        resetPreviewIdentity()
        if role == .iPad {
            previewBrowser?.cancel()
            previewBrowser = nil
        }
    }

    private func resetPreviewIdentity() {
        previewPeerID = nil
        previewPeerSupportsIdentity = false
        didSendPreviewHello = false
        previewIdentityVerified = false
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }
        let delays: [TimeInterval] = [0.5, 1, 2, 4, 5]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if self.role == .mac {
                if self.controlListener == nil { self.startListener(channel: .control) }
                if self.previewListener == nil { self.startListener(channel: .preview) }
            } else {
                if self.controlBrowser == nil { self.startBrowser(channel: .control) }
                if self.previewBrowser == nil { self.startBrowser(channel: .preview) }
            }
        }
    }
}
