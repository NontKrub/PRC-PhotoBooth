import Foundation
import Network
#if os(iOS)
import UIKit
#endif

@MainActor
public final class NetworkBoothTransport: BoothTransport {
    public static let lanHandshakeTimeout: TimeInterval = 5
    private static let reconnectDelays: [TimeInterval] = [0.5, 1, 2, 4, 5]
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
    private var routeMachine: BoothNetworkRouteMachine
    private var activeInterface: BoothNetworkInterfacePolicy?
    private var fallbackActive = false
    private var fallbackReason: String?

    public var requestedNetworkPreference: BoothNetworkPreference {
        get { requestedPreference }
        set {
            guard requestedPreference != newValue else { return }
            let oldValue = requestedPreference
            requestedPreference = newValue
            fallbackActive = false
            fallbackReason = nil
            print("[NetworkRoute] Preference changed: \(oldValue.rawValue) -> \(newValue.rawValue)")
            let command = routeMachine.preferenceChanged(
                to: newValue,
                lanAvailable: pathAvailable(.wiredEthernet),
                wifiAvailable: pathAvailable(.wifi)
            )
            apply(command, reason: nil)
        }
    }

    private let deviceID = UUID().uuidString
    private let deviceName: String
    private var controlListener: NWListener?
    private var previewListener: NWListener?
    private var controlBrowser: NWBrowser?
    private var previewBrowser: NWBrowser?
    private var wifiRouteDiscoveryBrowser: NWBrowser?
    private var lanRouteDiscoveryBrowser: NWBrowser?
    private var routeDiscoverySelection = BoothRouteDiscoverySelection()
    private var callbackGate = BoothTransportCallbackGate()
    private var controlConnection: NWConnection?
    private var previewConnection: NWConnection?
    private var controlParser = BoothFrameParser()
    private var previewParser = BoothFrameParser()
    private var previewFrames = LatestFrameCoalescer()
    private var heartbeatTimer: Timer?
    private var lanHandshakeTask: Task<Void, Never>?
    private var lastControlMessageAt = Date.distantPast
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private var controlEndpointDescription: String?
    private var previewEndpointDescription: String?
    private var didReceiveHello = false
    private var peerDeviceID: String?
    private var expectedPeerDeviceID: String?
    private var previewPeerID: String?
    private var previewPeerSupportsIdentity = false
    private var didSendPreviewHello = false
    private var previewIdentityVerified = false
    private var lanPathMonitor: NWPathMonitor?
    private var wifiPathMonitor: NWPathMonitor?
    private var didReceiveLANPathUpdate = false
    private var didReceiveWiFiPathUpdate = false
    private var isLANPathAvailable = false
    private var isWiFiPathAvailable = false
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
        self.routeMachine = BoothNetworkRouteMachine(preference: networkPreference)
        self.connectionStatus = connectionStatus ?? BoothConnectionStatus(requestedNetwork: networkPreference)
        self.deviceName = Self.localDeviceName(for: role)
    }

    public func start() {
        shouldReconnect = true
        reconnectAttempt = 0
        routeMachine = BoothNetworkRouteMachine(preference: requestedPreference)
        startPathMonitors()

        if role == .iPad {
            startRouteDiscovery()
        } else {
            let lanAvailable = pathAvailable(.wiredEthernet)
            let wifiAvailable = pathAvailable(.wifi)
            let command = routeMachine.start(
                lanAvailable: requestedPreference == .lan ? lanAvailable : false,
                wifiAvailable: wifiAvailable
            )
            apply(command, reason: nil)
        }
    }

    public func disconnect() {
        shouldReconnect = false
        cancelRouteDiscovery()
        stopPathMonitors()
        tearDownActiveTransport()
        fallbackActive = false
        fallbackReason = nil
        routeMachine = BoothNetworkRouteMachine(preference: requestedPreference)
        publishStatus()
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

    private enum PathKind {
        case wifi
        case wiredEthernet
    }

    private func makeParameters(for interface: BoothNetworkInterfacePolicy) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = switch interface {
        case .wifi: .wifi
        case .wiredEthernet: .wiredEthernet
        }
        return parameters
    }

    private func pathAvailable(_ kind: PathKind) -> Bool {
        switch kind {
        case .wifi:
            return didReceiveWiFiPathUpdate ? isWiFiPathAvailable : true
        case .wiredEthernet:
            return didReceiveLANPathUpdate ? isLANPathAvailable : true
        }
    }

    private func startPathMonitors() {
        stopPathMonitors()
        didReceiveLANPathUpdate = false
        didReceiveWiFiPathUpdate = false

        let lanMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        lanMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleLANPathUpdate(path.status == .satisfied)
            }
        }
        lanMonitor.start(queue: DispatchQueue(label: "PRC-PhotoBooth.WiredEthernetPath"))
        lanPathMonitor = lanMonitor

        let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleWiFiPathUpdate(path.status == .satisfied)
            }
        }
        wifiMonitor.start(queue: DispatchQueue(label: "PRC-PhotoBooth.WiFiPath"))
        wifiPathMonitor = wifiMonitor
    }

    private func stopPathMonitors() {
        lanPathMonitor?.cancel()
        wifiPathMonitor?.cancel()
        lanPathMonitor = nil
        wifiPathMonitor = nil
    }

    private func handleLANPathUpdate(_ available: Bool) {
        didReceiveLANPathUpdate = true
        isLANPathAvailable = available
        publishPathAvailability()
        guard activeInterface == .wiredEthernet else { return }
        guard !available else {
            print("[NetworkRoute] Wired Ethernet path available")
            return
        }
        if role == .iPad || requestedPreference == .lan {
            activateWiFiFallback(reason: "LAN unavailable")
        }
    }

    private func handleWiFiPathUpdate(_ available: Bool) {
        didReceiveWiFiPathUpdate = true
        isWiFiPathAvailable = available
        publishPathAvailability()
        guard activeInterface == .wifi, !available else { return }

        if role == .iPad {
            startRouteDiscovery()
            return
        }

        let command = routeMachine.wifiPathChanged(
            isAvailable: false,
            lanAvailable: pathAvailable(.wiredEthernet)
        )
        apply(command, reason: command == .startLAN ? "Wi-Fi unavailable" : nil)
    }

    private func apply(_ command: BoothNetworkRouteCommand, reason: String?) {
        switch command {
        case .startLAN:
            startTransport(using: .wiredEthernet, fallback: false, reason: reason)
        case .startWiFi(let fallback):
            startTransport(using: .wifi, fallback: fallback, reason: reason)
        case .unavailable:
            cancelRouteDiscovery()
            tearDownActiveTransport()
            fallbackActive = false
            fallbackReason = reason
            publishStatus()
            print("[NetworkRoute] No network connection")
        case .none:
            break
        }
    }

    private func activateWiFiFallback(reason: String) {
        guard activeInterface != .wifi else { return }
        let command = routeMachine.lanPathChanged(
            isAvailable: false,
            wifiAvailable: pathAvailable(.wifi)
        )
        guard command != .none else { return }
        print("[NetworkRoute] Falling back to Wi-Fi")
        apply(command, reason: reason)
    }

    private func handleLANHandshakeFailure(reason: String) {
        guard activeInterface == .wiredEthernet else { return }
        lanHandshakeTask?.cancel()
        lanHandshakeTask = nil
        print("[NetworkRoute] LAN handshake timed out after \(Self.lanHandshakeTimeout)s")
        let command = routeMachine.lanHandshakeTimedOut(wifiAvailable: pathAvailable(.wifi))
        if command == .unavailable {
            apply(command, reason: reason)
        } else {
            print("[NetworkRoute] Falling back to Wi-Fi")
            apply(command, reason: reason)
        }
    }

    private func startTransport(
        using interface: BoothNetworkInterfacePolicy,
        fallback: Bool,
        reason: String?,
        discoveredControlBrowser: NWBrowser? = nil
    ) {
        guard shouldReconnect else { return }
        cancelRouteDiscovery(keeping: discoveredControlBrowser)
        tearDownActiveTransport()
        activeInterface = interface
        fallbackActive = fallback
        fallbackReason = fallback ? (reason ?? "LAN unavailable") : nil
        connectionState = role == .mac ? .disconnected : .connecting
        publishStatus()

        if let discoveredControlBrowser {
            controlBrowser = discoveredControlBrowser
            configure(discoveredControlBrowser, channel: .control, interface: interface)
        }

        print("[NetworkRoute] Starting \(interface == .wiredEthernet ? "LAN" : "Wi-Fi") transport")
        switch role {
        case .mac:
            startListener(channel: .control)
            startListener(channel: .preview)
        case .iPad:
            if controlBrowser == nil { startBrowser(channel: .control) }
            startBrowser(channel: .preview)
        }

        if interface == .wiredEthernet {
            lanHandshakeTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.lanHandshakeTimeout))
                } catch {
                    return
                }
                guard let self,
                      self.activeInterface == .wiredEthernet,
                      self.shouldReconnect,
                      !self.didReceiveHello else { return }
                self.handleLANHandshakeFailure(reason: "No valid iPad hello")
            }
        }
    }

    private func startRouteDiscovery() {
        guard role == .iPad, shouldReconnect else { return }
        cancelRouteDiscovery()
        tearDownActiveTransport()
        routeMachine = BoothNetworkRouteMachine(preference: requestedPreference)
        connectionState = .connecting
        publishStatus()
        startRouteDiscoveryBrowser(on: .wifi)
        startRouteDiscoveryBrowser(on: .wiredEthernet)
    }

    private func startRouteDiscoveryBrowser(on interface: BoothNetworkInterfacePolicy) {
        let browser = NWBrowser(
            for: .bonjour(type: Self.controlServiceType, domain: nil),
            using: makeParameters(for: interface)
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.isCurrentRouteDiscoveryBrowser(browser, interface: interface),
                      let endpoint = results.first?.endpoint,
                      self.routeDiscoverySelection.select(interface) else { return }
                if interface == .wiredEthernet {
                    _ = self.routeMachine.beginLANAttempt()
                } else {
                    _ = self.routeMachine.startWiFiAttempt(wifiAvailable: true, fallback: false)
                }
                self.startTransport(
                    using: interface,
                    fallback: false,
                    reason: nil,
                    discoveredControlBrowser: browser
                )
                self.connect(to: endpoint, channel: .control)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.isCurrentRouteDiscoveryBrowser(browser, interface: interface) else { return }
                print("[NetworkRoute] \(interface.rawValue) discovery failed: \(error.localizedDescription)")
                if interface == .wifi {
                    self.wifiRouteDiscoveryBrowser = nil
                } else {
                    self.lanRouteDiscoveryBrowser = nil
                }
                self.scheduleReconnect()
            }
        }
        browser.start(queue: .main)
        if interface == .wifi {
            wifiRouteDiscoveryBrowser = browser
        } else {
            lanRouteDiscoveryBrowser = browser
        }
    }

    private func cancelRouteDiscovery(keeping browser: NWBrowser? = nil) {
        if wifiRouteDiscoveryBrowser !== browser { wifiRouteDiscoveryBrowser?.cancel() }
        if lanRouteDiscoveryBrowser !== browser { lanRouteDiscoveryBrowser?.cancel() }
        wifiRouteDiscoveryBrowser = nil
        lanRouteDiscoveryBrowser = nil
        routeDiscoverySelection.reset()
    }

    private func isCurrentRouteDiscoveryBrowser(
        _ browser: NWBrowser,
        interface: BoothNetworkInterfacePolicy
    ) -> Bool {
        interface == .wifi
            ? browser === wifiRouteDiscoveryBrowser
            : browser === lanRouteDiscoveryBrowser
    }

    private func tearDownActiveTransport() {
        activeInterface = nil
        callbackGate.invalidate()
        reconnectTask?.cancel()
        reconnectTask = nil
        lanHandshakeTask?.cancel()
        lanHandshakeTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        cancelTransportObjects()
        peerName = ""
        connectedPeerNames = []
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        connectionState = .disconnected
    }

    private func cancelTransportObjects() {
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
        controlEndpointDescription = nil
        previewEndpointDescription = nil
        controlParser = BoothFrameParser()
        previewParser = BoothFrameParser()
        previewFrames.reset()
        didReceiveHello = false
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        resetPreviewIdentity()
    }

    private func startListener(channel: BoothTransportChannel) {
        guard let activeInterface else { return }
        if channel == .control, controlListener != nil { return }
        if channel == .preview, previewListener != nil { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: makeParameters(for: activeInterface))
        } catch {
            print("[Network] listener creation failed: \(error.localizedDescription)")
            if activeInterface == .wiredEthernet { handleLANHandshakeFailure(reason: error.localizedDescription) }
            return
        }
        let interfaceAtStart = activeInterface
        listener.service = NWListener.Service(
            name: "PRC PhotoBooth \(channel == .control ? "Control" : "Preview") \(deviceID)",
            type: channel == .control ? Self.controlServiceType : Self.previewServiceType
        )
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed(let error) = state else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self, weak listener] in
                guard let self, let listener,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(listener, channel: channel) else { return }
                print("[Network] listener failed: \(message)")
                if channel == .control { self.controlListener = nil } else { self.previewListener = nil }
                if interfaceAtStart == .wiredEthernet {
                    self.handleLANHandshakeFailure(reason: message)
                } else if !message.contains("NoAuth") {
                    self.scheduleReconnect()
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor [weak self, weak listener] in
                guard let self, let listener,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(listener, channel: channel) else {
                    connection.cancel()
                    return
                }
                self.accept(connection, channel: channel)
            }
        }
        listener.start(queue: .main)
        if channel == .control { controlListener = listener } else { previewListener = listener }
    }

    private func startBrowser(channel: BoothTransportChannel) {
        guard let activeInterface else { return }
        if channel == .control, controlBrowser != nil { return }
        if channel == .preview, previewBrowser != nil { return }
        let serviceType = channel == .control ? Self.controlServiceType : Self.previewServiceType
        let interfaceAtStart = activeInterface
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: makeParameters(for: activeInterface)
        )
        configure(browser, channel: channel, interface: activeInterface)
        browser.start(queue: .main)
        if channel == .control { controlBrowser = browser } else { previewBrowser = browser }
    }

    private func configure(
        _ browser: NWBrowser,
        channel: BoothTransportChannel,
        interface interfaceAtStart: BoothNetworkInterfacePolicy
    ) {
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(browser, channel: channel),
                      let endpoint = self.endpointToConnect(from: results, channel: channel) else { return }
                self.connect(to: endpoint, channel: channel)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard case .failed(let error) = state else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(browser, channel: channel) else { return }
                print("[Network] browser failed: \(message)")
                if channel == .control { self.controlBrowser = nil } else { self.previewBrowser = nil }
                if interfaceAtStart == .wiredEthernet {
                    self.handleLANHandshakeFailure(reason: message)
                } else if !message.contains("NoAuth") {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func endpointToConnect(
        from results: Set<NWBrowser.Result>,
        channel: BoothTransportChannel
    ) -> NWEndpoint? {
        let endpoints = results.map(\.endpoint)
        guard !endpoints.isEmpty else { return nil }
        if channel == .preview {
            guard let expectedPeerDeviceID else { return nil }
            return endpoints.first { serviceName(from: $0)?.contains(expectedPeerDeviceID) == true }
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
        guard activeInterface != nil else {
            connection.cancel()
            return
        }
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
        guard let activeInterface else { return }
        if channel == .preview, expectedPeerDeviceID == nil { return }
        let description = endpoint.debugDescription
        if channel == .control {
            guard controlConnection == nil || controlEndpointDescription != description else { return }
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnection = NWConnection(to: endpoint, using: makeParameters(for: activeInterface))
            controlEndpointDescription = description
            didReceiveHello = false
            controlParser = BoothFrameParser()
            if let connection = controlConnection { configure(connection, channel: channel) }
        } else {
            guard previewConnection == nil || previewEndpointDescription != description else { return }
            previewFrames.reset()
            previewConnection?.cancel()
            previewConnection = NWConnection(to: endpoint, using: makeParameters(for: activeInterface))
            previewEndpointDescription = description
            previewParser = BoothFrameParser()
            resetPreviewIdentity()
            if let connection = previewConnection { configure(connection, channel: channel) }
        }
    }

    private func configure(_ connection: NWConnection, channel: BoothTransportChannel) {
        let generationAtStart = callbackGate.generation
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self] in
                guard let self, let connection else { return }
                guard self.callbackGate.accepts(generationAtStart),
                      self.isCurrent(connection, channel: channel) else { return }
                switch state {
                case .ready:
                    if channel == .control {
                        self.connectionState = .connecting
                        self.publishStatus()
                        self.receive(on: connection, channel: channel)
                        self.sendTransportHello()
                    } else {
                        self.receive(on: connection, channel: channel)
                        self.sendPreviewHello(on: connection)
                    }
                case .failed, .cancelled:
                    self.connectionDidClose(connection, channel: channel)
                default:
                    break
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
                if let data, !data.isEmpty { self.receiveData(data, channel: channel) }
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
            let frames = try channel == .control
                ? controlParser.append(data)
                : previewParser.append(data)
            if channel == .control { lastControlMessageAt = Date() }
            for frame in frames {
                guard frame.channel == channel || frame.channel == .heartbeat else { continue }
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
            lanHandshakeTask?.cancel()
            lanHandshakeTask = nil
            peerDeviceID = hello.deviceID
            peerName = hello.deviceName.isEmpty ? hello.deviceID : hello.deviceName
            expectedPeerDeviceID = hello.deviceID
            previewPeerSupportsIdentity = hello.capabilities.contains(Self.previewIdentityCapability)
            connectedPeerNames = [peerName]
            connectionState = .connected(peerName: peerName)
            reconnectAttempt = 0
            lastControlMessageAt = Date()
            if activeInterface == .wiredEthernet {
                _ = routeMachine.lanHandshakeSucceeded(peer: peerName)
            } else {
                _ = routeMachine.wifiConnected(peer: peerName, fallback: fallbackActive)
            }
            publishStatus()
            startHeartbeat()
            validatePreviewIdentity()
            if role == .iPad, previewConnection == nil {
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
            .helloDetails(hello: BoothTransportHello(
                role: role,
                deviceID: deviceID,
                deviceName: deviceName
            )),
            on: controlConnection,
            channel: .control
        )
    }

    private func sendPreviewHello(on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(
            BoothTransportHello(role: role, deviceID: deviceID, deviceName: deviceName)
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
        guard previewPeerID == expectedPeerDeviceID else {
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
                guard let self, self.isCurrent(connection, channel: .preview) else { return }
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
            guard let connection, connection === controlConnection else { return }
            if role == .iPad {
                startRouteDiscovery()
                return
            }
            let command = routeMachine.transportDisconnected(
                lanAvailable: pathAvailable(.wiredEthernet),
                wifiAvailable: pathAvailable(.wifi)
            )
            apply(command, reason: command == .startWiFi(fallback: true) ? "LAN unavailable" : nil)
        } else {
            guard let connection, connection === previewConnection else { return }
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

    private func isCurrent(_ listener: NWListener, channel: BoothTransportChannel) -> Bool {
        channel == .control ? listener === controlListener : listener === previewListener
    }

    private func isCurrent(_ browser: NWBrowser, channel: BoothTransportChannel) -> Bool {
        channel == .control ? browser === controlBrowser : browser === previewBrowser
    }

    private func publishStatus() {
        connectionStatus.publish(
            requestedNetwork: requestedPreference,
            state: connectionState,
            peerID: peerDeviceID,
            peerDisplayName: peerName.isEmpty ? nil : peerName,
            routeState: routeMachine.state,
            effectiveNetwork: routeMachine.effectiveTransport,
            fallbackReason: fallbackActive ? fallbackReason : nil,
            isLANPathAvailable: isLANPathAvailable,
            isWiFiPathAvailable: isWiFiPathAvailable
        )
    }

    private func publishPathAvailability() {
        connectionStatus.publishPathAvailability(lan: isLANPathAvailable, wifi: isWiFiPathAvailable)
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
        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if self.role == .iPad, self.activeInterface == nil {
                self.startRouteDiscovery()
                return
            }
            guard self.activeInterface != nil else { return }
            if self.role == .mac {
                if self.controlListener == nil { self.startListener(channel: .control) }
                if self.previewListener == nil { self.startListener(channel: .preview) }
            } else {
                if self.controlBrowser == nil { self.startBrowser(channel: .control) }
                if self.previewBrowser == nil { self.startBrowser(channel: .preview) }
            }
        }
    }

    private static func localDeviceName(for role: DeviceRole) -> String {
#if os(iOS)
        return UIDevice.current.name
#else
        return Host.current().localizedName ?? (role == .mac ? "PRC Mac" : "iPad")
#endif
    }
}
