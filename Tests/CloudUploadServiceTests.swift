import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("CloudUploadService")
struct CloudUploadServiceTests {
    @Test("creates remote directories, excludes work files, and publishes token link")
    func uploadsExpectedCommands() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("strip.png"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".work"),
            withIntermediateDirectories: true
        )
        try Data([2]).write(to: directory.appendingPathComponent(".work/should-not-upload"))

        let runner = TestCloudCommandRunner()
        let service = CloudUploadService(runner: runner)
        try await service.upload(
            manifest: makeManifest(directory: directory),
            configuration: CloudUploadConfiguration(
                sshHost: "booth-host",
                remoteBasePath: "/srv/photos",
                publicBaseURL: "https://photos.example"
            )
        )

        let commands = await runner.commands
        #expect(commands.count == 3)
        #expect(commands[0].arguments[0] == "booth-host")
        #expect(commands[0].arguments[1].contains("mkdir -p"))
        #expect(commands[1].arguments.contains("--exclude"))
        #expect(commands[1].arguments.contains(".work"))
        #expect(commands[2].arguments[1].contains("ln -sfn"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path))
    }

    @Test("returns command, exit status, and output on failure")
    func reportsStructuredCommandFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = TestCloudCommandRunner()
        await runner.failNext(exitCode: 23, output: "ssh timeout")
        let service = CloudUploadService(runner: runner)

        do {
            try await service.upload(
                manifest: makeManifest(directory: directory),
                configuration: CloudUploadConfiguration(
                    sshHost: "host",
                    remoteBasePath: "/srv/photos",
                    publicBaseURL: ""
                )
            )
            Issue.record("Expected cloud command failure")
        } catch let error as JobExecutionError {
            if case .retryable(let message) = error {
                #expect(message.contains("ssh mkdir remote directories"))
                #expect(message.contains("exit 23"))
                #expect(message.contains("ssh timeout"))
            } else {
                Issue.record("Expected retryable cloud error")
            }
        }
    }
}

private actor TestCloudCommandRunner: CloudCommandRunning {
    struct Command: Sendable {
        var executable: String
        var arguments: [String]
    }

    private(set) var commands: [Command] = []
    private var nextResult: CloudCommandResult?

    func failNext(exitCode: Int32, output: String) {
        nextResult = CloudCommandResult(exitCode: exitCode, output: output)
    }

    func run(executable: String, arguments: [String]) async throws -> CloudCommandResult {
        commands.append(Command(executable: executable, arguments: arguments))
        defer { nextResult = nil }
        return nextResult ?? CloudCommandResult(exitCode: 0, output: "")
    }
}

private func makeManifest(directory: URL) -> SessionManifest {
    let config = EventConfig(eventID: "event", eventName: "Event", photoCount: 1)
    return SessionManifest(
        schemaVersion: SessionManifest.currentSchemaVersion,
        id: "session",
        eventID: config.eventID,
        eventName: config.eventName,
        eventConfig: config,
        startedAt: Date(),
        completedAt: nil,
        cancelledAt: nil,
        status: .completed,
        nextPhotoIndex: 1,
        outputRootPath: directory.deletingLastPathComponent().path,
        relativeDirectoryPath: "Event/session",
        absoluteDirectoryPath: directory.path,
        frameSnapshotFileName: nil,
        stripFileName: "strip.png",
        gifFileName: nil,
        downloadToken: "token",
        shots: [],
        lastError: nil,
        updatedAt: Date()
    )
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-Cloud-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
