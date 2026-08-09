import Foundation
import Network

@MainActor
public final class NetworkBoothTransport: BoothTransport {
    private static let controlServiceType = "_prc-control._tcp"
    private static let previewServiceType = "_prc-preview._tcp"
    private static let heartbeatInterval: TimeInterval = 2
    private static let heartbeatTimeout: TimeInterval = 8

    public let role: DeviceRole
    public private(set) var connectionState: BoothConnectionState = .disconnected
    public private(set) var peerName = ""
    public private(set) var connectedPeerNames: [String] = []
    public var activePeerName: String? {
        get { peerName.isEmpty ? nil : peerName }
        set { /* Network transport has one authoritative peer. */ }
    }
    public var onControlMessage: (@MainActor (Message) -> Void)?
    public var onPreviewFrame: (@MainActor (Data) -> Void)?

    private let deviceID = UUID().uuidString
    private var controlListener: NWListener?
    private var previewListener: NWListener?
    private var controlBrowser: NWBrowser?
    private var previewBrowser: NWBrowser?
    private var controlConnection: NWConnection?
    private var previewConnection: NWConnection?
    private var controlParser = BoothFrameParser()
    private var previewParser = BoothFrameParser()
    private var previewWriteInFlight = false
    private var pendingPreviewFrame: Data?
    private var heartbeatTimer: Timer?
    private var lastMessageAt = Date.distantPast
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private var controlEndpointDescription: String?
    private var previewEndpointDescription: String?
    private var didReceiveHello = false

    public init(role: DeviceRole) {
        self.role = role
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
        pendingPreviewFrame = nil
        previewWriteInFlight = false
        didReceiveHello = false
        setDisconnected()
    }

    public func sendControl(_ message: Message) {
        send(message, on: controlConnection, channel: .control)
    }

    public func sendPreviewFrame(_ jpegData: Data) {
        pendingPreviewFrame = jpegData
        flushPreviewFrame()
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
            name: "PRC PhotoBooth \(channel == .control ? "Control" : "Preview")",
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
            guard let endpoint = results.first?.endpoint else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
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

    private func accept(_ connection: NWConnection, channel: BoothTransportChannel) {
        if channel == .control {
            controlConnection?.cancel()
            controlConnection = connection
            controlEndpointDescription = connection.endpoint.debugDescription
            didReceiveHello = false
            controlParser = BoothFrameParser()
        } else {
            previewConnection?.cancel()
            previewConnection = connection
            previewEndpointDescription = connection.endpoint.debugDescription
            previewParser = BoothFrameParser()
        }
        configure(connection, channel: channel)
    }

    private func connect(to endpoint: NWEndpoint, channel: BoothTransportChannel) {
        let description = endpoint.debugDescription
        if channel == .control {
            guard controlConnection == nil || controlEndpointDescription != description else { return }
            controlConnection?.cancel()
            controlConnection = NWConnection(to: endpoint, using: .tcp)
            controlEndpointDescription = description
            didReceiveHello = false
            controlParser = BoothFrameParser()
            if let connection = controlConnection { configure(connection, channel: channel) }
        } else {
            guard previewConnection == nil || previewEndpointDescription != description else { return }
            previewConnection?.cancel()
            previewConnection = NWConnection(to: endpoint, using: .tcp)
            previewEndpointDescription = description
            previewParser = BoothFrameParser()
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
            lastMessageAt = Date()
            for frame in frames {
                guard frame.channel == channel || (channel == .control && frame.channel == .heartbeat) else {
                    continue
                }
                switch frame.channel {
                case .control:
                    guard let message = try? Message.decoded(from: frame.payload) else { continue }
                    handleControl(message)
                case .heartbeat:
                    break
                case .preview:
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
            connectedPeerNames = [hello.deviceID]
            connectionState = .connected(peerName: hello.deviceID)
            reconnectAttempt = 0
            lastMessageAt = Date()
            startHeartbeat()
            onControlMessage?(.hello(role: hello.role))
        case .heartbeat:
            lastMessageAt = Date()
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

    private func send(_ message: Message, on connection: NWConnection?, channel: BoothTransportChannel) {
        guard let connection else { return }
        guard let payload = try? message.encoded(),
              let frame = try? BoothFrameEncoder.encode(channel: channel, payload: payload) else { return }
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error { print("[Network] send failed: \(error.localizedDescription)") }
        })
    }

    private func flushPreviewFrame() {
        guard !previewWriteInFlight,
              let connection = previewConnection,
              let jpeg = pendingPreviewFrame else { return }
        pendingPreviewFrame = nil
        previewWriteInFlight = true
        guard let frame = try? BoothFrameEncoder.encode(channel: .preview, payload: jpeg) else {
            previewWriteInFlight = false
            return
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error { print("[Network] preview send failed: \(error.localizedDescription)") }
                self.previewWriteInFlight = false
                self.flushPreviewFrame()
            }
        })
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.didReceiveHello else { return }
                if Date().timeIntervalSince(self.lastMessageAt) > Self.heartbeatTimeout {
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
            setDisconnected()
            scheduleReconnect()
        } else {
            guard connection == nil || connection === previewConnection else { return }
            previewConnection?.cancel()
            previewConnection = nil
            previewEndpointDescription = nil
            previewWriteInFlight = false
            flushPreviewFrame()
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
