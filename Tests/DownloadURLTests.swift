import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Download URL")
struct DownloadURLTests {
    @Test("falls back to the local server until cloud upload succeeds")
    func usesReachableURLWhenCloudUploadIsPending() {
        let url = BoothCoordinator.downloadURL(
            publicBaseURL: "https://photos.example",
            localBaseURL: "http://192.168.0.109:8585",
            token: "token",
            cloudUploadSucceeded: false
        )

        #expect(url == "http://192.168.0.109:8585/s/token/")
    }

    @Test("uses the public URL after cloud upload succeeds")
    func usesPublicURLAfterCloudUpload() {
        let url = BoothCoordinator.downloadURL(
            publicBaseURL: "https://photos.example/",
            localBaseURL: "http://192.168.0.109:8585",
            token: "token",
            cloudUploadSucceeded: true
        )

        #expect(url == "https://photos.example/s/token/")
    }
}
