import Foundation

/// Pure protocol state for the post-authentication secure-channel exchange.
/// NetworkBoothTransport owns sockets; this value owns only the negotiation
/// rules and the connection-generation boundary.
public enum BoothSecureNegotiationState: Equatable, Sendable {
    case idle
    case waitingForAuthoritativeHello
    case authoritativeHelloSent(sessionID: String)
    case responderHelloSent(sessionID: String)
    case configuring(sessionID: String)
    case waitingForReady(sessionID: String)
    case established(sessionID: String)
    case failed
}

public enum BoothSecureNegotiationAction: Equatable, Sendable {
    case sendHello(BoothSecureChannelHello)
    case configure
    case established
    case ignored
}

public enum BoothSecureNegotiationError: Error, Equatable, Sendable {
    case wrongRole
    case wrongPeer
    case malformedHello
    case conflictingHello
    case missingAuthoritativeHello
    case mismatchedSession
    case staleGeneration
}

public struct BoothSecureChannelNegotiator: Sendable {
    public let role: DeviceRole
    public let localDeviceID: String
    public private(set) var expectedPeerDeviceID: String?
    public private(set) var connectionGeneration: Int
    public private(set) var state: BoothSecureNegotiationState
    public private(set) var localHello: BoothSecureChannelHello?
    public private(set) var peerHello: BoothSecureChannelHello?
    public private(set) var readySent = false
    public private(set) var readyReceived = false

    public init(
        role: DeviceRole,
        localDeviceID: String,
        expectedPeerDeviceID: String? = nil,
        connectionGeneration: Int = 0
    ) {
        self.role = role
        self.localDeviceID = localDeviceID
        self.expectedPeerDeviceID = expectedPeerDeviceID
        self.connectionGeneration = connectionGeneration
        self.state = role == .mac ? .idle : .waitingForAuthoritativeHello
    }

    public mutating func reset(connectionGeneration: Int) {
        self.connectionGeneration = connectionGeneration
        localHello = nil
        peerHello = nil
        readySent = false
        readyReceived = false
        state = role == .mac ? .idle : .waitingForAuthoritativeHello
    }

    public mutating func setExpectedPeerDeviceID(_ deviceID: String?) {
        expectedPeerDeviceID = deviceID
    }

    public mutating func begin(generation: Int) throws -> BoothSecureNegotiationAction {
        guard generation == connectionGeneration else { throw BoothSecureNegotiationError.staleGeneration }
        guard role == .mac, localHello == nil else {
            throw BoothSecureNegotiationError.wrongRole
        }
        let hello = BoothSecureChannelHello(
            sessionID: UUID().uuidString,
            challenge: try BoothPairingCrypto.makeSecureChannelChallenge(),
            senderRole: .mac,
            senderDeviceID: localDeviceID,
            receiverDeviceID: expectedPeerDeviceID ?? ""
        )
        localHello = hello
        state = .authoritativeHelloSent(sessionID: hello.sessionID)
        return .sendHello(hello)
    }

    public mutating func receiveHello(
        _ hello: BoothSecureChannelHello,
        generation: Int
    ) throws -> [BoothSecureNegotiationAction] {
        guard generation == connectionGeneration else { return [.ignored] }
        let expectedRole: DeviceRole = role == .mac ? .iPad : .mac
        guard hello.isWellFormed, hello.senderRole == expectedRole else {
            state = .failed
            throw BoothSecureNegotiationError.malformedHello
        }
        guard hello.receiverDeviceID == localDeviceID,
              expectedPeerDeviceID == nil || hello.senderDeviceID == expectedPeerDeviceID else {
            state = .failed
            throw BoothSecureNegotiationError.wrongPeer
        }
        if let peerHello {
            guard peerHello == hello else {
                state = .failed
                throw BoothSecureNegotiationError.conflictingHello
            }
            return [.ignored]
        }

        if role == .mac {
            guard let localHello else {
                state = .failed
                throw BoothSecureNegotiationError.missingAuthoritativeHello
            }
            guard localHello.sessionID == hello.sessionID else {
                state = .failed
                throw BoothSecureNegotiationError.mismatchedSession
            }
            peerHello = hello
            state = .configuring(sessionID: hello.sessionID)
            return [.configure]
        }

        if let localHello {
            guard localHello.sessionID == hello.sessionID else {
                state = .failed
                throw BoothSecureNegotiationError.mismatchedSession
            }
            peerHello = hello
            state = .configuring(sessionID: hello.sessionID)
            return [.configure]
        }

        // The responder reuses the Mac's session ID. It never invents a
        // parallel secure session for the same authenticated connection.
        let responderHello = BoothSecureChannelHello(
            sessionID: hello.sessionID,
            challenge: try BoothPairingCrypto.makeSecureChannelChallenge(),
            senderRole: .iPad,
            senderDeviceID: localDeviceID,
            receiverDeviceID: hello.senderDeviceID
        )
        peerHello = hello
        localHello = responderHello
        state = .responderHelloSent(sessionID: hello.sessionID)
        state = .configuring(sessionID: hello.sessionID)
        return [.sendHello(responderHello), .configure]
    }

    public mutating func markReadySent(generation: Int) throws {
        guard generation == connectionGeneration else { throw BoothSecureNegotiationError.staleGeneration }
        guard let localHello, let peerHello else {
            throw BoothSecureNegotiationError.missingAuthoritativeHello
        }
        guard localHello.sessionID == peerHello.sessionID else {
            throw BoothSecureNegotiationError.mismatchedSession
        }
        readySent = true
        state = .waitingForReady(sessionID: localHello.sessionID)
    }

    public mutating func receiveReady(
        sessionID: String,
        generation: Int
    ) throws -> BoothSecureNegotiationAction {
        guard generation == connectionGeneration else { return .ignored }
        guard let localHello, let peerHello,
              sessionID == localHello.sessionID,
              sessionID == peerHello.sessionID else {
            state = .failed
            throw BoothSecureNegotiationError.mismatchedSession
        }
        if readyReceived { return .ignored }
        readyReceived = true
        guard readySent else { return .ignored }
        state = .established(sessionID: sessionID)
        return .established
    }

    public mutating func markEstablished(generation: Int) throws {
        guard generation == connectionGeneration else { throw BoothSecureNegotiationError.staleGeneration }
        guard let sessionID = localHello?.sessionID, readySent, readyReceived else {
            throw BoothSecureNegotiationError.missingAuthoritativeHello
        }
        state = .established(sessionID: sessionID)
    }
}
