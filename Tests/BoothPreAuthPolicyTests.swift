import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Booth Pre-Auth Policy & Watchdog")
struct BoothPreAuthPolicyTests {
    @Test("no Hello triggers timeout after bootstrap deadline")
    func noHelloTimesOutAfterBootstrapDeadline() {
        let start = Date()
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)

        // 4 seconds later: still awaiting hello, not timed out
        #expect(watchdog.checkTimeout(now: start.addingTimeInterval(4.0)) == nil)

        // 5 seconds later: timed out
        let timeoutReason = watchdog.checkTimeout(now: start.addingTimeInterval(5.1))
        #expect(timeoutReason != nil)
        #expect(timeoutReason?.contains("Bootstrap Hello deadline expired") == true)
        #expect(watchdog.phase.isTerminal)
    }

    @Test("valid Hello prevents bootstrap timeout and transitions phase")
    func validHelloTransitionsDeadline() {
        let start = Date()
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)

        // Valid Hello arrives after 3 seconds for pairing flow
        let helloTime = start.addingTimeInterval(3.0)
        let pairingExpiry = start.addingTimeInterval(120.0)
        watchdog.onValidHello(now: helloTime, isPairing: true, pairingExpiry: pairingExpiry)

        // After 6 seconds from start (past bootstrap 5s, but within interactive pairing)
        let sixSec = start.addingTimeInterval(6.0)
        #expect(watchdog.checkTimeout(now: sixSec) == nil)

        if case .interactivePairing(let inactivity, let expiry) = watchdog.phase {
            #expect(inactivity == helloTime.addingTimeInterval(watchdog.interactiveInactivityTimeout))
            #expect(expiry == pairingExpiry)
        } else {
            Issue.record("Expected interactivePairing phase")
        }
    }

    @Test("human waiting > 15 seconds during legitimate PIN flow is NOT disconnected")
    func humanWaitingOver15SecondsNotDisconnected() {
        let start = Date()
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)

        let pairingExpiry = start.addingTimeInterval(120.0)
        watchdog.onPairingSessionStarted(absoluteExpiry: pairingExpiry, now: start)

        // User spends 25 seconds reading and typing PIN
        let after25Seconds = start.addingTimeInterval(25.0)
        #expect(watchdog.checkTimeout(now: after25Seconds) == nil)

        // Progress made: PIN submitted after 25s
        watchdog.onInteractiveProgress(now: after25Seconds)

        // Another 20 seconds later (total 45s from start): still active
        let after45Seconds = start.addingTimeInterval(45.0)
        #expect(watchdog.checkTimeout(now: after45Seconds) == nil)
    }

    @Test("pairing cannot remain unauthenticated past absolute expiry")
    func pairingExpiresAtAbsoluteDeadline() {
        let start = Date()
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)

        let pairingExpiry = start.addingTimeInterval(120.0)
        watchdog.onPairingSessionStarted(absoluteExpiry: pairingExpiry, now: start)

        // User spams interaction at 40s, 80s, 110s
        watchdog.onInteractiveProgress(now: start.addingTimeInterval(40.0))
        watchdog.onInteractiveProgress(now: start.addingTimeInterval(80.0))
        watchdog.onInteractiveProgress(now: start.addingTimeInterval(110.0))

        // At 121 seconds: absolute expiry MUST trigger
        let expired = watchdog.checkTimeout(now: start.addingTimeInterval(121.0))
        #expect(expired != nil)
        #expect(expired?.contains("absolute deadline expired") == true)
    }

    @Test("pairing absolute expiry remains enforced during authentication")
    func pairingExpiryRemainsEnforcedDuringAuthentication() {
        let start = Date(timeIntervalSince1970: 90_000)
        let pairingExpiry = start.addingTimeInterval(120)
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)
        watchdog.onPairingSessionStarted(absoluteExpiry: pairingExpiry, now: start)

        // A valid admission proof can start authentication immediately before
        // pairing expiry. Authentication must not replace the pairing deadline.
        watchdog.onAuthenticationStarted(now: pairingExpiry.addingTimeInterval(-1))

        #expect(watchdog.checkTimeout(now: pairingExpiry) == "Pairing session absolute deadline expired.")
        #expect(watchdog.phase == .expired(reason: "Pairing session absolute deadline expired."))
    }

    @Test("pairing traffic requires an active interactive watchdog phase")
    func pairingTrafficRequiresActiveWatchdog() {
        let start = Date(timeIntervalSince1970: 70_000)
        let expiry = start.addingTimeInterval(120)
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)
        watchdog.onPairingSessionStarted(absoluteExpiry: expiry, now: start)

        #expect(BoothPreAuthProgressPolicy.canProcessPairingTraffic(watchdog, now: start))

        watchdog.onAuthenticationStarted(now: expiry.addingTimeInterval(1))
        #expect(!BoothPreAuthProgressPolicy.canProcessPairingTraffic(
            watchdog,
            now: expiry.addingTimeInterval(1)
        ))
        #expect(watchdog.phase == .expired(reason: "Pairing session absolute deadline expired."))
    }

    @Test("restarting pairing sessions cannot extend the connection absolute deadline")
    func restartedPairingSessionPreservesConnectionDeadline() {
        let start = Date(timeIntervalSince1970: 80_000)
        let originalExpiry = start.addingTimeInterval(120)
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)
        watchdog.onPairingSessionStarted(absoluteExpiry: originalExpiry, now: start)
        watchdog.onInteractiveProgress(now: start.addingTimeInterval(40))
        watchdog.onInteractiveProgress(now: start.addingTimeInterval(80))

        let restartedAt = start.addingTimeInterval(119)
        watchdog.onPairingSessionStarted(
            absoluteExpiry: restartedAt.addingTimeInterval(120),
            now: restartedAt
        )

        #expect(watchdog.nextDeadline() == originalExpiry)
        #expect(watchdog.checkTimeout(now: originalExpiry) == "Pairing session absolute deadline expired.")
        #expect(watchdog.phase == .expired(reason: "Pairing session absolute deadline expired."))

        let boundaryWatchdog = BoothPreAuthWatchdog(generation: 2, startTime: start)
        boundaryWatchdog.onPairingSessionStarted(absoluteExpiry: originalExpiry, now: start)
        #expect(!boundaryWatchdog.onPairingSessionStarted(
            absoluteExpiry: originalExpiry.addingTimeInterval(120),
            now: originalExpiry
        ))
        #expect(boundaryWatchdog.checkTimeout(now: originalExpiry) == "Pairing session absolute deadline expired.")
    }

    @Test("valid auth progress transitions deadlines correctly")
    func validAuthProgressTransitionsDeadlines() {
        let start = Date()
        let watchdog = BoothPreAuthWatchdog(generation: 1, startTime: start)

        watchdog.onValidHello(now: start.addingTimeInterval(2.0), isPairing: false)
        guard case .authenticating = watchdog.phase else {
            Issue.record("Expected authenticating phase")
            return
        }

        watchdog.onSecureNegotiationStarted(now: start.addingTimeInterval(5.0))
        guard case .secureChannelNegotiating = watchdog.phase else {
            Issue.record("Expected secureChannelNegotiating phase")
            return
        }

        watchdog.onAuthenticated()
        #expect(watchdog.phase == .authenticated)
        #expect(watchdog.nextDeadline() == nil)
        #expect(watchdog.checkTimeout(now: start.addingTimeInterval(1000.0)) == nil)
    }

    @Test("pre-auth admission limiter throttles repeated failures")
    func admissionLimiterThrottlesRepeatedFailures() {
        var limiter = BoothPreAuthAdmissionLimiter(
            failureThreshold: 3,
            baseCooldown: 2.0,
            maxCooldown: 10.0
        )
        let now = Date()
        let attacker = "192.168.1.150:54321"

        // Initially admitted
        #expect(limiter.shouldAdmit(endpointKey: attacker, now: now).admitted)

        // 1st failure
        limiter.recordFailure(endpointKey: attacker, now: now)
        #expect(limiter.shouldAdmit(endpointKey: attacker, now: now).admitted)

        // 2nd failure
        limiter.recordFailure(endpointKey: attacker, now: now.addingTimeInterval(1.0))
        #expect(limiter.shouldAdmit(endpointKey: attacker, now: now.addingTimeInterval(1.0)).admitted)

        // 3rd failure -> triggers cooldown
        limiter.recordFailure(endpointKey: attacker, now: now.addingTimeInterval(2.0))
        let check = limiter.shouldAdmit(endpointKey: attacker, now: now.addingTimeInterval(2.5))
        #expect(!check.admitted)
        #expect(check.reason?.contains("throttled") == true)

        // After cooldown expires (2.0s cooldown from 2.0s = 4.0s)
        let afterCooldown = now.addingTimeInterval(5.0)
        #expect(limiter.shouldAdmit(endpointKey: attacker, now: afterCooldown).admitted)
    }

    @Test("admission limiter storage remains bounded")
    func admissionLimiterStorageBounded() {
        var limiter = BoothPreAuthAdmissionLimiter(maxTrackedEndpoints: 10)
        let now = Date()

        for i in 0..<50 {
            limiter.recordFailure(endpointKey: "client-\(i)", now: now.addingTimeInterval(Double(i)))
            #expect(limiter.trackedEndpointCount <= 10)
        }
    }

    @Test("only accepted pairing messages count as watchdog progress")
    func pairingProgressRequiresAcceptance() throws {
        let now = Date(timeIntervalSince1970: 80_000)
        let absoluteExpiry = now.addingTimeInterval(120)
        let acceptedIntentWatchdog = BoothPreAuthWatchdog(generation: 1, startTime: now)
        acceptedIntentWatchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
        #expect(BoothPreAuthProgressPolicy.advance(
            acceptedIntentWatchdog,
            after: .startSession,
            now: now.addingTimeInterval(10)
        ))
        #expect(acceptedIntentWatchdog.nextDeadline() == now.addingTimeInterval(55))

        let reusedIntentWatchdog = BoothPreAuthWatchdog(generation: 5, startTime: now)
        reusedIntentWatchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
        #expect(BoothPreAuthProgressPolicy.advance(
            reusedIntentWatchdog,
            after: .reuseSession,
            now: now.addingTimeInterval(12)
        ))
        #expect(reusedIntentWatchdog.nextDeadline() == now.addingTimeInterval(57))

        let rejectedIntentWatchdog = BoothPreAuthWatchdog(generation: 2, startTime: now)
        rejectedIntentWatchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
        #expect(!BoothPreAuthProgressPolicy.advance(
            rejectedIntentWatchdog,
            after: .reject(reason: "rejected"),
            now: now.addingTimeInterval(10)
        ))
        #expect(rejectedIntentWatchdog.nextDeadline() == now.addingTimeInterval(45))

        let identity = BoothDeviceIdentity(id: "mac-1", displayName: "Booth", role: .mac)
        let transcript = Data("pairing transcript".utf8)

        var acceptedSession = try BoothPairingSession.make(macIdentity: identity, now: now)
        let acceptedProof = BoothPairingCrypto.makeAdmissionProof(
            code: acceptedSession.pin,
            transcript: transcript
        )
        let accepted = acceptedSession.validateAdmissionProof(
            acceptedProof,
            method: .pin,
            transcript: transcript,
            now: now
        )
        #expect(accepted == .accepted)
        let acceptedProofWatchdog = BoothPreAuthWatchdog(generation: 3, startTime: now)
        acceptedProofWatchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
        #expect(BoothPreAuthProgressPolicy.advance(
            acceptedProofWatchdog,
            after: accepted,
            now: now.addingTimeInterval(20)
        ))
        #expect(acceptedProofWatchdog.nextDeadline() == now.addingTimeInterval(65))

        var rejectedSession = try BoothPairingSession.make(macIdentity: identity, now: now)
        let rejected = rejectedSession.validateAdmissionProof(
            Data(repeating: 0, count: 32),
            method: .pin,
            transcript: transcript,
            now: now
        )
        #expect(rejected == .rejected(remainingAttempts: 4))
        let rejectedProofWatchdog = BoothPreAuthWatchdog(generation: 4, startTime: now)
        rejectedProofWatchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
        #expect(!BoothPreAuthProgressPolicy.advance(
            rejectedProofWatchdog,
            after: rejected,
            now: now.addingTimeInterval(20)
        ))
        #expect(rejectedProofWatchdog.nextDeadline() == now.addingTimeInterval(45))
        #expect(!BoothPreAuthProgressPolicy.advance(
            rejectedProofWatchdog,
            after: .expired,
            now: now.addingTimeInterval(20)
        ))
        #expect(!BoothPreAuthProgressPolicy.advance(
            rejectedProofWatchdog,
            after: .locked,
            now: now.addingTimeInterval(20)
        ))

        let expiredWatchdog = BoothPreAuthWatchdog(generation: 6, startTime: now)
        expiredWatchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
        #expect(expiredWatchdog.checkTimeout(now: absoluteExpiry) != nil)
        #expect(!BoothPreAuthProgressPolicy.advance(
            expiredWatchdog,
            after: .accepted,
            now: absoluteExpiry.addingTimeInterval(1)
        ))
        #expect(!BoothPreAuthProgressPolicy.advance(
            expiredWatchdog,
            after: .reuseSession,
            now: absoluteExpiry.addingTimeInterval(1)
        ))
        #expect(expiredWatchdog.phase.isTerminal)
        #expect(!expiredWatchdog.onPairingSessionStarted(
            absoluteExpiry: absoluteExpiry.addingTimeInterval(120),
            now: absoluteExpiry.addingTimeInterval(1)
        ))
    }

    @Test("stale watchdog timer generations and connections are ignored")
    func staleWatchdogTimerIsIgnored() {
        #expect(BoothPreAuthProgressPolicy.shouldRunTimerTick(
            expectedGeneration: 4,
            currentGeneration: 4,
            connectionIsCurrent: true
        ))
        #expect(!BoothPreAuthProgressPolicy.shouldRunTimerTick(
            expectedGeneration: 3,
            currentGeneration: 4,
            connectionIsCurrent: true
        ))
        #expect(!BoothPreAuthProgressPolicy.shouldRunTimerTick(
            expectedGeneration: 4,
            currentGeneration: 4,
            connectionIsCurrent: false
        ))
    }

    @Test("successful authentication clears limiter record")
    func successClearsLimiter() {
        var limiter = BoothPreAuthAdmissionLimiter()
        let now = Date()
        let peer = "192.168.1.200"

        limiter.recordFailure(endpointKey: peer, now: now)
        limiter.recordFailure(endpointKey: peer, now: now)
        #expect(limiter.trackedEndpointCount == 1)

        limiter.recordSuccess(endpointKey: peer)
        #expect(limiter.trackedEndpointCount == 0)
    }

    @Test("attacker flooding global limit does not block preferred candidate")
    func attackerFloodingDoesNotBlockPreferredCandidate() {
        var limiter = BoothPreAuthAdmissionLimiter(
            failureThreshold: 3,
            globalFailureThreshold: 30,
            reservedFailureThreshold: 5
        )
        let now = Date()

        // 50 invalid attacker attempts flood the global threshold
        for i in 0..<50 {
            limiter.recordFailure(endpointKey: "attacker-\(i)", isPreferredCandidate: false, now: now)
        }

        // Random anonymous client is blocked by the global failure limit
        let anonymousCheck = limiter.shouldAdmit(endpointKey: "anonymous-guest", isPreferredCandidate: false, now: now)
        #expect(!anonymousCheck.admitted)
        #expect(anonymousCheck.reason?.contains("Global pre-auth failure rate limit exceeded") == true)

        // Preferred iPad candidate with reserved lane is NOT blocked by global ceiling
        let preferredCheck = limiter.shouldAdmit(endpointKey: "preferred-ipad-192.168.4.2", isPreferredCandidate: true, now: now)
        #expect(preferredCheck.admitted)
        #expect(preferredCheck.reason == nil)
    }

    @Test("spoofed preferred candidate is throttled after exceeding reserved quota")
    func spoofedPreferredCandidateThrottledAfterQuota() {
        var limiter = BoothPreAuthAdmissionLimiter(
            failureThreshold: 3,
            baseCooldown: 2.0,
            maxCooldown: 10.0,
            reservedFailureThreshold: 3
        )
        let now = Date()
        let spoofedKey = "spoofed-preferred-candidate"

        // Initially admitted
        #expect(limiter.shouldAdmit(endpointKey: spoofedKey, isPreferredCandidate: true, now: now).admitted)

        // 1st failure
        limiter.recordFailure(endpointKey: spoofedKey, isPreferredCandidate: true, now: now)
        #expect(limiter.shouldAdmit(endpointKey: spoofedKey, isPreferredCandidate: true, now: now).admitted)

        // 2nd failure
        limiter.recordFailure(endpointKey: spoofedKey, isPreferredCandidate: true, now: now.addingTimeInterval(1.0))
        #expect(limiter.shouldAdmit(endpointKey: spoofedKey, isPreferredCandidate: true, now: now.addingTimeInterval(1.0)).admitted)

        // 3rd failure reaches reserved threshold -> triggers cooldown
        limiter.recordFailure(endpointKey: spoofedKey, isPreferredCandidate: true, now: now.addingTimeInterval(2.0))
        let throttledCheck = limiter.shouldAdmit(endpointKey: spoofedKey, isPreferredCandidate: true, now: now.addingTimeInterval(2.5))
        #expect(!throttledCheck.admitted)
        #expect(throttledCheck.reason?.contains("throttled") == true)
    }
}

