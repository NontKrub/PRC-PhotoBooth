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
}
