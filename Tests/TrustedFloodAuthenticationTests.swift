import Foundation
import Darwin
import Network
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Trusted control authentication under finite flood")
struct TrustedFloodAuthenticationTests {
    @Test("fresh runtime authenticates stored-secret peer after finite flood from a new IPv4 address")
    func freshRuntimeAuthenticatesAfterFiniteHostileFloodWithoutEndpointHistory() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedFloodFresh.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedFloodFresh.iPad")
        let hostileQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedFloodFresh.Hostiles")
        let trustedAddress = try #require(nonLoopbackEthernetIPv4Address())
        let trustedParameters = NWParameters.tcp
        trustedParameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(trustedAddress),
            port: .any
        )
        let macRuntime = BoothNetworkTransportRuntime(
            queue: macQueue,
            admissionLimiter: BoothPreAuthAdmissionLimiter(
                identityProbeGlobalFailureThreshold: 5,
                identityProbeGlobalCooldown: 60
            )
        )
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Fresh Flood Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Trusted Flood iPad", role: .iPad)
        let trustedSecret = Data(repeating: 0x5C, count: 32)
        let spoofSecret = Data(repeating: 0xA3, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedFloodObserver()
        let iPadEvents = TrustedFloodObserver()
        let spoofEvents = TrustedFloodObserver()
        var hostileClients: [TrustedFloodLoopbackClient] = []

        // A new runtime models Mac restart: it has the persisted peer secret,
        // but no authenticated endpoint cache or prior limiter history.
        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: trustedSecret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in
            macEvents?.receive(event)
        }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: trustedSecret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in
            iPadEvents?.receive(event)
        }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord([
                    "deviceID": macIdentity.id,
                    "network": BoothNetworkPreference.wifi.rawValue,
                    "role": DeviceRole.mac.rawValue,
                    "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
                ])
            )
        )
        let port = try #require(await macEvents.waitForListener())

        defer {
            hostileClients.forEach { $0.cancel() }
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }

        // A real client claims the trusted iPad ID but has the wrong secret.
        let spoofQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.TrustedFloodFresh.Spoof")
        let spoofRuntime = BoothNetworkTransportRuntime(queue: spoofQueue)
        let spoofSecureChannel = BoothSecureChannel()
        let spoofWriter = BoothControlWritePump(queue: spoofQueue, secureChannel: spoofSecureChannel)
        spoofRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: spoofSecret],
            selectedPeerID: macIdentity.id,
            secureChannel: spoofSecureChannel,
            writer: spoofWriter
        ) { [weak spoofEvents] event in
            spoofEvents?.receive(event)
        }
        let spoofParameters = NWParameters.tcp
        spoofParameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        spoofRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: spoofParameters,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 1001
        )
        #expect(await macEvents.waitForRejectionCount(1, timeout: 5))
        #expect(spoofEvents.authenticationCount == 0)
        spoofRuntime.stopControlCore()
        spoofWriter.invalidate(generation: Int.max)
        let hostileConnectionBaseline = macRuntime.inboundControlConnectionCount()

        // Open 100 real TCP sockets from distinct ephemeral source ports and
        // leave them before protocol Hello. The runtime admits one normal
        // candidate and exactly one independent identity probe.
        for _ in 0..<100 {
            let client = TrustedFloodLoopbackClient(port: port)
            hostileClients.append(client)
            client.start(on: hostileQueue)
        }
        let allHostileConnectionsReachedListener = await waitForInboundConnections(
            macRuntime,
            expected: hostileConnectionBaseline + 100,
            timeout: 5
        )
        #expect(
            allHostileConnectionsReachedListener,
            "The listener did not process all 100 hostile sockets before the trusted peer started."
        )

        let saturatedLanes = await waitForLanes(
            macRuntime,
            expected: .init(
                normalCandidatePresent: true,
                identityProbePresent: true
            ),
            timeout: 3
        )
        let laneSnapshot = macRuntime.admissionLaneSnapshot()
        #expect(saturatedLanes)
        #expect(laneSnapshot.normalCandidatePresent)
        #expect(laneSnapshot.identityProbePresent)

        #expect(macRuntime.identityProbeCooldownIsActive())
        // Retry while the flood's candidates still occupy the normal and probe
        // lanes. Their queue-owned deadlines must release the probe opportunity
        // without MainActor help, then the changed-address peer must prove its
        // stored secret before the hostile clients are closed.
        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: NWEndpoint.Host(trustedAddress), port: port),
            parameters: trustedParameters,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 1002
        )

        let trustedConnectionReachedListener = await waitForInboundConnections(
            macRuntime,
            expected: hostileConnectionBaseline + 101,
            timeout: 5
        )
        #expect(trustedConnectionReachedListener)
        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 15))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))
        #expect(macEvents.authenticatedEndpointDescriptions.contains { $0.contains(trustedAddress) })
        hostileClients.forEach { $0.cancel() }
        #expect(spoofEvents.authenticationCount == 0)
        #expect(iPadEvents.authenticationCount == 1)
        #expect(macEvents.authenticationCount == 1)
    }

    @Test("trusted new-address HMAC uses probe lane while anonymous control slot is occupied")
    func trustedNewAddressAuthenticatesBesideAnonymousControlCandidate() async throws {
        let macQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.OccupiedSlot.Mac")
        let iPadQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.OccupiedSlot.iPad")
        let hostileQueue = DispatchQueue(label: "PRC-PhotoBooth.Tests.OccupiedSlot.Hostile")
        let trustedAddress = try #require(nonLoopbackEthernetIPv4Address())
        let macRuntime = BoothNetworkTransportRuntime(
            queue: macQueue,
            admissionLimiter: BoothPreAuthAdmissionLimiter(globalFailureThreshold: 1)
        )
        let iPadRuntime = BoothNetworkTransportRuntime(queue: iPadQueue)
        let macIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Occupied Slot Mac", role: .mac)
        let iPadIdentity = BoothDeviceIdentity(id: UUID().uuidString, displayName: "Trusted New Address iPad", role: .iPad)
        let secret = Data(repeating: 0x76, count: 32)
        let macSecureChannel = BoothSecureChannel()
        let iPadSecureChannel = BoothSecureChannel()
        let macWriter = BoothControlWritePump(queue: macQueue, secureChannel: macSecureChannel)
        let iPadWriter = BoothControlWritePump(queue: iPadQueue, secureChannel: iPadSecureChannel)
        let macEvents = TrustedFloodObserver()
        let iPadEvents = TrustedFloodObserver()
        macRuntime.configureControlCore(
            localIdentity: macIdentity,
            networkPreference: .wifi,
            trustedSecrets: [iPadIdentity.id: secret],
            selectedPeerID: iPadIdentity.id,
            secureChannel: macSecureChannel,
            writer: macWriter
        ) { [weak macEvents] event in macEvents?.receive(event) }
        iPadRuntime.configureControlCore(
            localIdentity: iPadIdentity,
            networkPreference: .wifi,
            trustedSecrets: [macIdentity.id: secret],
            selectedPeerID: macIdentity.id,
            secureChannel: iPadSecureChannel,
            writer: iPadWriter
        ) { [weak iPadEvents] event in iPadEvents?.receive(event) }
        _ = macRuntime.startControlListener(
            using: .tcp,
            port: nil,
            service: NWListener.Service(
                name: BoothBonjourServiceIdentity.serviceName(channel: .control, deviceID: macIdentity.id),
                type: "_prc-control._tcp",
                txtRecord: NWTXTRecord(["deviceID": macIdentity.id])
            )
        )
        let port = try #require(await macEvents.waitForListener())
        let anonymousClient = TrustedFloodLoopbackClient(port: port)
        defer {
            anonymousClient.cancel()
            iPadRuntime.stopControlCore()
            macRuntime.stopControlCore()
            iPadWriter.invalidate(generation: Int.max)
            macWriter.invalidate(generation: Int.max)
        }

        anonymousClient.start(on: hostileQueue)
        #expect(await waitForInboundConnections(macRuntime, expected: 1, timeout: 3))
        #expect(await waitForLanes(
            macRuntime,
            expected: .init(
                normalCandidatePresent: true,
                identityProbePresent: false
            ),
            timeout: 3
        ))

        // Force the global anonymous limiter over its threshold while the real
        // listener's normal candidate still occupies the control slot.
        let failedProbe = NWConnection(
            to: .hostPort(host: "192.0.2.77", port: NWEndpoint.Port(rawValue: 54_321)!),
            using: .tcp
        )
        let admission = try #require(macRuntime.admitInboundControlConnection(failedProbe).admission)
        #expect(admission.isIdentityProbe)
        macRuntime.abandonInboundControlAdmission(admission, connection: failedProbe)
        #expect(macRuntime.admissionLaneSnapshot().normalCandidatePresent)
        #expect(!macRuntime.admissionLaneSnapshot().identityProbePresent)

        let trustedParameters = NWParameters.tcp
        trustedParameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(trustedAddress),
            port: .any
        )
        iPadRuntime.startTrustedControlConnection(
            endpoint: .hostPort(host: NWEndpoint.Host(trustedAddress), port: port),
            parameters: trustedParameters,
            interface: .wifi,
            provenance: .localNetworkBonjour,
            generation: 2001
        )

        #expect(await iPadEvents.waitForAuthenticationCount(1, timeout: 5))
        #expect(await macEvents.waitForAuthenticationCount(1, timeout: 3))
        #expect(macEvents.authenticatedEndpointDescriptions.contains { $0.contains(trustedAddress) })
        #expect(macEvents.authenticationCount == 1)
    }

    private func waitForLanes(
        _ runtime: BoothNetworkTransportRuntime,
        expected: BoothNetworkTransportRuntime.AdmissionLaneSnapshot,
        timeout: TimeInterval
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if runtime.admissionLaneSnapshot() == expected { return true }
            await Task.yield()
        }
        return runtime.admissionLaneSnapshot() == expected
    }

    private func waitForInboundConnections(
        _ runtime: BoothNetworkTransportRuntime,
        expected: Int,
        timeout: TimeInterval
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if runtime.inboundControlConnectionCount() >= expected { return true }
            await Task.yield()
        }
        return runtime.inboundControlConnectionCount() >= expected
    }

    private func nonLoopbackEthernetIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = current {
            let entry = interface.pointee
            if let name = entry.ifa_name,
               String(cString: name).hasPrefix("en"),
               entry.ifa_flags & UInt32(IFF_UP) != 0,
               let socketAddress = entry.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_INET) {
                var address = UnsafeRawPointer(socketAddress)
                    .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let host = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
                    if !host.hasPrefix("169.254.") { return host }
                }
            }
            current = entry.ifa_next
        }
        return nil
    }
}

private final class TrustedFloodObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let listenerReady = DispatchSemaphore(value: 0)
    private let authenticationChanged = DispatchSemaphore(value: 0)
    private let rejectionChanged = DispatchSemaphore(value: 0)
    private var listenerPort: NWEndpoint.Port?
    private var authenticationGenerations: [Int] = []
    private var authenticatedEndpoints: [String] = []
    private var rejectionReasons: [String] = []

    func receive(_ event: BoothNetworkTransportRuntime.ControlCoreEvent) {
        switch event {
        case .listenerReady(_, let port, _):
            lock.lock()
            listenerPort = port
            lock.unlock()
            listenerReady.signal()
        case .trustedAuthenticated(let generation, let endpointDescription, _, _, _, _, _, _):
            lock.lock()
            authenticationGenerations.append(generation)
            authenticatedEndpoints.append(endpointDescription)
            lock.unlock()
            authenticationChanged.signal()
        case .rejected(_, let reason):
            lock.lock()
            rejectionReasons.append(reason)
            lock.unlock()
            rejectionChanged.signal()
        default:
            break
        }
    }

    func waitForListener(timeout: TimeInterval = 5) async -> NWEndpoint.Port? {
        guard await Task.detached(priority: .utility, operation: { [self] in
            waitForSemaphore(listenerReady, timeout: timeout)
        }).value else { return nil }
        return listenerPortSnapshot()
    }

    private func listenerPortSnapshot() -> NWEndpoint.Port? {
        lock.lock()
        defer { lock.unlock() }
        return listenerPort
    }

    func waitForRejectionCount(_ count: Int, timeout: TimeInterval) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForRejectionCountBlocking(count, timeout: timeout)
        }.value
    }

    private func waitForRejectionCountBlocking(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while true {
            lock.lock()
            let hasEnough = rejectionReasons.filter {
                $0.contains("Stored-secret authentication failed")
            }.count >= count
            lock.unlock()
            if hasEnough { return true }
            guard rejectionChanged.wait(timeout: deadline) == .success else { return false }
        }
    }

    func waitForAuthenticationCount(_ count: Int, timeout: TimeInterval) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForAuthenticationCountBlocking(count, timeout: timeout)
        }.value
    }

    private func waitForAuthenticationCountBlocking(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while true {
            if authenticationCount >= count { return true }
            guard authenticationChanged.wait(timeout: deadline) == .success else {
                return authenticationCount >= count
            }
        }
    }

    var authenticationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authenticationGenerations.count
    }

    var authenticatedEndpointDescriptions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedEndpoints
    }
}

private final class TrustedFloodLoopbackClient {
    private let connection: NWConnection

    init(port: NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        connection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port),
            using: parameters
        )
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}
