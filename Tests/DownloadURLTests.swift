import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Download URL")
struct DownloadURLTests {
    @Test("cloud disabled uses the local server")
    func usesReachableURLWhenCloudUploadIsPending() {
        let url = BoothCoordinator.downloadURL(
            publicBaseURL: "https://photos.example",
            localBaseURL: "http://192.168.0.109:8585",
            token: "token",
            cloudUploadEnabled: false
        )

        #expect(url == "http://192.168.0.109:8585/s/token/")
    }

    @Test("cloud enabled uses the public URL before upload")
    func usesPublicURLWhenCloudEnabled() {
        let url = BoothCoordinator.downloadURL(
            publicBaseURL: "https://photos.example/",
            localBaseURL: "http://192.168.0.109:8585",
            token: "token",
            cloudUploadEnabled: true
        )

        #expect(url == "https://photos.example/s/token/")
    }
}
