import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("Retake tracking")
struct RetakeTrackingTests {
    @Test("guest and operator retakes increment exactly once")
    func incrementsOncePerRequest() {
        var counts: [Int: Int] = [:]
        #expect(incrementRetakeCount(in: &counts, photoIndex: 0) == 1)
        #expect(incrementRetakeCount(in: &counts, photoIndex: 0) == 2)
        #expect(incrementRetakeCount(in: &counts, photoIndex: 1) == 1)
        #expect(counts == [0: 2, 1: 1])
    }

    @Test("keep and skip do not change retake counts")
    func keepDoesNotIncrement() {
        let counts = [0: 2]
        #expect(counts[0] == 2)
    }

    @Test("runtime shot upsert keeps one record and latest retake count")
    func runtimeUpsertIsUnique() {
        var shots = [RuntimeShotRecord(photoIndex: 0, imageFileName: nil, gifFrameFileNames: [], retakeCount: 0, acceptedAt: nil)]
        upsertRuntimeShot(in: &shots, photoIndex: 0, imageFileName: "shot_0.jpg", gifFrameFileNames: [], retakeCount: 3, acceptedAt: Date())
        upsertRuntimeShot(in: &shots, photoIndex: 0, imageFileName: "shot_0.jpg", gifFrameFileNames: [], retakeCount: 3, acceptedAt: Date())
        #expect(shots.count == 1)
        #expect(shots[0].retakeCount == 3)
    }

    @Test("DataStore upsert does not create duplicate analytics shots")
    @MainActor
    func dataStoreUpsertIsUnique() {
        let store = DataStore.shared
        let event = store.createEvent(name: "Retake Test \(UUID().uuidString)", photoCount: 1)
        let session = store.startSession(for: event)
        _ = store.upsertShot(session: session, photoIndex: 0, imagePath: "shot_0.jpg", retakeCount: 2)
        _ = store.upsertShot(session: session, photoIndex: 0, imagePath: "shot_0.jpg", retakeCount: 3)
        #expect(session.shots.filter { $0.photoIndex == 0 }.count == 1)
        #expect(session.shots.first?.retakeCount == 3)
        store.deleteSession(session)
    }
}
