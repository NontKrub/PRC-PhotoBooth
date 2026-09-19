import CryptoKit
import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("BoothAssetAssembler eviction")
struct AssetAssemblerEvictionTests {
    @Test("stale partial assemblies are evicted and stop blocking new assets")
    func evictsStalePartials() throws {
        var assembler = BoothAssetAssembler()
        let start = Date()
        for index in 0..<BoothAssetTransfer.maximumConcurrentAssets {
            let chunk = makeChunk(assetID: "stale-\(index)", index: 0, count: 2)
            #expect(try assembler.append(chunk, now: start) == nil)
        }
        let fresh = makeChunk(assetID: "fresh", index: 0, count: 2)
        #expect(throws: BoothAssetTransferError.tooManyConcurrentAssets) {
            try assembler.append(fresh, now: start)
        }
        let later = start.addingTimeInterval(BoothAssetAssembler.assemblyLifetime + 1)
        #expect(try assembler.append(fresh, now: later) == nil)
    }

    private func makeChunk(assetID: String, index: Int, count: Int) -> BoothAssetChunk {
        let data = Data(repeating: UInt8(index + 1), count: 2)
        let totalBytes = count * 2
        let payload = Data((0..<count).flatMap { _ in data })
        let reference = BoothAssetReference(
            assetID: assetID,
            revision: "v1",
            kind: .reviewImage,
            byteCount: totalBytes,
            sha256: Data(SHA256.hash(data: payload))
        )
        return BoothAssetChunk(
            metadata: BoothAssetChunkMetadata(
                assetID: assetID,
                revision: "v1",
                kind: .reviewImage,
                index: index,
                count: count,
                totalBytes: totalBytes,
                sha256: reference.sha256
            ),
            data: data
        )
    }
}
