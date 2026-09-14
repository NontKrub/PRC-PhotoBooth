import Foundation
import CryptoKit
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Event readiness stress")
struct EventReadinessStressTests {
    @Test("500 deterministic customer sessions leave no stale state")
    @MainActor
    func fiveHundredCustomerSessions() {
        let stateMachine = SessionStateMachine()
        var messageGate = SessionMessageGate()
        var assetPump = BoothAssetRequestPump(maximumInFlight: 8)
        var random = DeterministicGenerator(seed: 0x51_4D_4D)
        var previousContext: SessionMessageContext?

        for sessionIndex in 0..<500 {
            let photoCount: Int
            switch sessionIndex % 3 {
            case 0: photoCount = 1
            case 1: photoCount = 4
            default: photoCount = 8
            }
            let sessionID = "soak-session-\(sessionIndex)"
            let config = EventConfig(
                eventID: "event-readiness",
                eventName: "Event Readiness",
                photoCount: photoCount,
                countdownSeconds: 1
            )

            stateMachine.startSession(config: config, sessionID: sessionID)
            messageGate.synchronize(sessionID: sessionID, sequence: 0)
            if let previousContext {
                let accepted = messageGate.accept(previousContext)
                #expect(!accepted)
            }

            let references = (0..<photoCount).map { photoIndex in
                stressAssetReference(
                    assetID: "\(sessionID)-asset-\(photoIndex)",
                    sessionID: sessionID,
                    kind: .reviewImage,
                    seed: UInt8(truncatingIfNeeded: sessionIndex + photoIndex)
                )
            }
            assetPump.reset()
            var cached = Set<BoothAssetReference>()
            while cached.count < references.count {
                let batch = assetPump.nextBatch(expected: references, cached: cached)
                #expect(!batch.isEmpty)
                for reference in batch {
                    assetPump.markCompleted(reference)
                    cached.insert(reference)
                }
            }
            #expect(assetPump.inFlight.isEmpty)

            for photoIndex in 0..<photoCount {
                let captureContext = SessionMessageContext(
                    sessionID: sessionID,
                    sequence: UInt64(photoIndex * 3 + 1)
                )
                let captureAccepted = messageGate.accept(captureContext)
                #expect(captureAccepted)
                previousContext = captureContext

                stateMachine.beginCountdown(photoIndex: photoIndex, captureAt: Date())
                stateMachine.tickCountdown()
                stateMachine.enterReview(
                    photoIndex: photoIndex,
                    thumbnailData: stressFixture(sessionIndex, photoIndex, attempt: 0),
                    reviewImageData: stressFixture(sessionIndex, photoIndex, attempt: 0)
                )

                if random.next() % 7 == 0 {
                    let retakeContext = SessionMessageContext(
                        sessionID: sessionID,
                        sequence: UInt64(photoIndex * 3 + 2)
                    )
                    let retakeAccepted = messageGate.accept(retakeContext)
                    #expect(retakeAccepted)
                    previousContext = retakeContext
                    stateMachine.retakeShot(photoIndex: photoIndex)
                    stateMachine.tickCountdown()
                    stateMachine.enterReview(
                        photoIndex: photoIndex,
                        thumbnailData: stressFixture(sessionIndex, photoIndex, attempt: 1),
                        reviewImageData: stressFixture(sessionIndex, photoIndex, attempt: 1)
                    )
                }

                let keepContext = SessionMessageContext(
                    sessionID: sessionID,
                    sequence: UInt64(photoIndex * 3 + 3)
                )
                let keepAccepted = messageGate.accept(keepContext)
                #expect(keepAccepted)
                previousContext = keepContext
                stateMachine.keepShot(photoIndex: photoIndex)
            }

            stateMachine.finishSession(qrPayload: "prc://soak/\(sessionID)")
            #expect(stateMachine.currentSessionID == sessionID)
            #expect(stateMachine.keptShots.count == photoCount)
            #expect(stateMachine.acceptedPhotoIndices.count == photoCount)
            if case .finished = stateMachine.phase {
                // Expected terminal state.
            } else {
                Issue.record("Session \(sessionID) did not finish")
            }
        }
    }

    @Test("eight-photo authoritative snapshot restores bounded assets after relaunch")
    @MainActor
    func eightPhotoRelaunchRestore() throws {
        let sessionID = "eight-photo-relaunch"
        let config = EventConfig(
            eventID: "event-readiness",
            eventName: "Event Readiness",
            photoCount: 8,
            countdownSeconds: 1
        )
        let reviewReferences = (0..<8).map { index in
            stressAssetReference(
                assetID: "review-\(index)",
                sessionID: sessionID,
                kind: .reviewImage,
                seed: UInt8(index)
            )
        }
        let promptReferences = (0..<8).map { index in
            stressAssetReference(
                assetID: "prompt-\(index)",
                sessionID: sessionID,
                kind: .promptImage,
                seed: UInt8(index + 20)
            )
        }
        let stripReference = stressAssetReference(
            assetID: "strip",
            sessionID: sessionID,
            kind: .stripThumbnail,
            seed: 40
        )
        let presentation = SessionPresentation(
            sessionID: sessionID,
            language: .english,
            templateDisplayName: "Event Readiness",
            filterID: .original,
            prompts: promptReferences.enumerated().map { index, reference in
                SessionPromptPresentation(
                    promptID: "prompt-\(index)",
                    photoIndex: index,
                    title: "Pose \(index + 1)",
                    subtitle: "Ready",
                    imageAsset: reference
                )
            }
        )
        let snapshot = SessionSyncSnapshot(
            config: config,
            sessionID: sessionID,
            phase: .review(photoIndex: 7),
            presentation: presentation,
            isMirrored: false,
            sequence: 88,
            reviewAsset: reviewReferences[7],
            stripAsset: stripReference,
            keptShotAssets: Dictionary(uniqueKeysWithValues: reviewReferences.enumerated().map { ($0.offset, $0.element) }),
            acceptedPhotoIndices: Array(0..<8),
            nextPhotoIndex: 7
        )

        let encoded = try Message.sessionSync(snapshot: snapshot).encoded()
        guard case .sessionSync(let restoredSnapshot) = try Message.decoded(from: encoded) else {
            Issue.record("Session sync did not decode")
            return
        }

        let restoredState = SessionStateMachine()
        restoredState.applyAuthoritativeSnapshot(
            sessionID: try #require(restoredSnapshot.sessionID),
            config: restoredSnapshot.config,
            phase: restoredSnapshot.phase,
            nextPhotoIndex: restoredSnapshot.nextPhotoIndex,
            acceptedPhotoIndices: Set(restoredSnapshot.acceptedPhotoIndices),
            deferredPhotoIndices: Set(restoredSnapshot.deferredPhotoIndices)
        )
        #expect(restoredState.currentSessionID == sessionID)
        #expect(restoredState.phase == .review(photoIndex: 7))
        #expect(restoredSnapshot.presentation?.prompts.count == 8)
        #expect(restoredSnapshot.keptShotAssets.count == 8)

        var expected = [reviewReferences[7], stripReference]
        expected.append(contentsOf: promptReferences)
        expected.append(contentsOf: reviewReferences)
        expected = expected.reduce(into: []) { result, reference in
            if !result.contains(reference) { result.append(reference) }
        }

        var pump = BoothAssetRequestPump(maximumInFlight: 8)
        var assembler = BoothAssetAssembler()
        var cached = Set<BoothAssetReference>()
        while cached.count < expected.count {
            let batch = pump.nextBatch(expected: expected, cached: cached)
            #expect(!batch.isEmpty)
            for reference in batch {
                let data = Data(repeating: reference.sha256.first ?? 0x01, count: 512)
                let chunks = try BoothAssetTransfer.chunks(
                    data: data,
                    reference: BoothAssetReference(
                        assetID: reference.assetID,
                        sessionID: reference.sessionID,
                        revision: reference.revision,
                        kind: reference.kind,
                        byteCount: data.count,
                        sha256: Data(CryptoKit.SHA256.hash(data: data))
                    ),
                    chunkSize: 128
                )
                for chunk in chunks.reversed() {
                    _ = try assembler.append(chunk)
                }
                pump.markCompleted(reference)
                cached.insert(reference)
            }
        }
        #expect(cached.count == expected.count)
        #expect(pump.inFlight.isEmpty)
    }

}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}

private func stressFixture(_ sessionIndex: Int, _ photoIndex: Int, attempt: Int) -> Data {
    Data([
        UInt8(truncatingIfNeeded: sessionIndex),
        UInt8(truncatingIfNeeded: photoIndex),
        UInt8(truncatingIfNeeded: attempt)
    ])
}

private func stressAssetReference(
    assetID: String,
    sessionID: String,
    kind: BoothAssetKind,
    seed: UInt8
) -> BoothAssetReference {
    let data = Data(repeating: seed, count: 512)
    return BoothAssetReference(
        assetID: assetID,
        sessionID: sessionID,
        revision: "stress-1",
        kind: kind,
        byteCount: data.count,
        sha256: Data(CryptoKit.SHA256.hash(data: data))
    )
}
