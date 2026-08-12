import Testing
import Foundation
import Darwin

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
        let verifier = TestCloudURLVerifier()
        let service = CloudUploadService(runner: runner, verifier: verifier)
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
        #expect(commands[0].arguments.contains("booth-host"))
        #expect(commands[0].arguments.last?.contains("mkdir -p") == true)
        #expect(commands[0].arguments.contains("BatchMode=yes"))
        #expect(commands[0].arguments.contains("ConnectTimeout=20"))
        #expect(commands[1].arguments.contains("--exclude"))
        #expect(commands[1].arguments.contains(".work"))
        #expect(commands[1].arguments.contains("--partial"))
        #expect(commands[1].arguments.contains("--partial-dir=.rsync-partial"))
        #expect(commands[1].arguments.contains("--timeout=60"))
        #expect(commands[2].arguments.last?.contains("test -s") == true)
        #expect(commands[2].arguments.last?.contains("ln -sfn") == true)
        #expect(commands[2].arguments.last?.contains("/token") == true)
        #expect((await verifier.urls).first?.path == "/s/token/strip.png")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path))
    }

    @Test("returns command, exit status, and output on failure")
    func reportsStructuredCommandFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("strip.png"))
        let runner = TestCloudCommandRunner()
        await runner.failNext(exitCode: 23, output: "ssh timeout")
        let service = CloudUploadService(runner: runner)

        do {
            try await service.upload(
                manifest: makeManifest(directory: directory),
                configuration: CloudUploadConfiguration(
                    sshHost: "host",
                    remoteBasePath: "/srv/photos",
                    publicBaseURL: "https://photos.example"
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

    @Test("HTTP 503 keeps a successful transfer out of succeeded state")
    func rejectsUnavailablePublicDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("strip.png"))
        let runner = TestCloudCommandRunner()
        let verifier = TestCloudURLVerifier()
        await verifier.setResponse(statusCode: 503, contentLength: 0)
        let service = CloudUploadService(runner: runner, verifier: verifier)

        do {
            try await service.upload(
                manifest: makeManifest(directory: directory),
                configuration: CloudUploadConfiguration(
                    sshHost: "host",
                    remoteBasePath: "/srv/photos",
                    publicBaseURL: "https://photos.example"
                )
            )
            Issue.record("Expected public verification failure")
        } catch let error as JobExecutionError {
            guard case .retryable(let message) = error else {
                Issue.record("Expected retryable public verification error")
                return
            }
            #expect(message.contains("HTTP 503"))
            #expect(message.contains("/s/token/strip.png"))
        }
    }

    @Test("missing strip is an actionable permanent upload error")
    func rejectsMissingStrip() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = TestCloudCommandRunner()
        let service = CloudUploadService(runner: runner)

        do {
            try await service.upload(
                manifest: makeManifest(directory: directory),
                configuration: CloudUploadConfiguration(
                    sshHost: "host",
                    remoteBasePath: "/srv/photos",
                    publicBaseURL: "https://photos.example"
                )
            )
            Issue.record("Expected missing strip failure")
        } catch let error as JobExecutionError {
            guard case .permanent(let message) = error else {
                Issue.record("Expected permanent missing-file error")
                return
            }
            #expect(message == "Local strip.png is missing; cannot re-upload.")
        }
        #expect((await runner.commands).isEmpty)
    }

    @Test("an interrupted rsync can retry without changing local outputs")
    func interruptedTransferCanRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let strip = directory.appendingPathComponent("strip.png")
        let original = Data([4, 5, 6])
        try original.write(to: strip)
        let runner = TestCloudCommandRunner()
        await runner.failCommand(at: 1, exitCode: 23, output: "connection unexpectedly closed")
        let verifier = TestCloudURLVerifier()
        let service = CloudUploadService(runner: runner, verifier: verifier)
        let configuration = CloudUploadConfiguration(
            sshHost: "host",
            remoteBasePath: "/srv/photos",
            publicBaseURL: "https://photos.example"
        )
        let manifest = makeManifest(directory: directory)

        do {
            try await service.upload(manifest: manifest, configuration: configuration)
            Issue.record("Expected interrupted transfer")
        } catch is JobExecutionError {
            // Expected: the queue will retry this job.
        }
        try await service.upload(manifest: manifest, configuration: configuration)

        let commands = await runner.commands
        #expect(commands[1].arguments.contains("--partial"))
        #expect(commands[3].arguments.contains("--partial"))
        #expect(commands[1].arguments.last == commands[3].arguments.last)
        #expect(try Data(contentsOf: strip) == original)
    }

    @Test("process runner terminates a command that exceeds its timeout")
    func processRunnerTimesOut() async throws {
        do {
            _ = try await ProcessCloudCommandRunner().run(
                executable: "/bin/sleep",
                arguments: ["2"],
                timeout: 0.1
            )
            Issue.record("Expected process timeout")
        } catch let error as CloudCommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timed out command error")
                return
            }
        }
    }

    @Test("process runner drains large stdout without timing out")
    func processRunnerDrainsLargeStdout() async throws {
        let result = try await ProcessCloudCommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero"],
            timeout: 2
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("[output truncated]"))
        #expect(result.output.utf8.count <= ProcessCloudCommandRunner.maximumOutputBytes + 128)
    }

    @Test("process runner drains large stderr without timing out")
    func processRunnerDrainsLargeStderr() async throws {
        let result = try await ProcessCloudCommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero 1>&2"],
            timeout: 2
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("[output truncated]"))
        #expect(result.output.utf8.count <= ProcessCloudCommandRunner.maximumOutputBytes + 128)
    }

    @Test("cancelling a process runner terminates the child promptly")
    func processRunnerCancelsPromptly() async throws {
        let startedAt = Date()
        let task = Task {
            try await ProcessCloudCommandRunner().run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 2"],
                timeout: 10
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected process cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test("cancelling a process runner terminates process-group children")
    func processRunnerCancelsProcessGroupChildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRC-Cloud-child-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let quotedPIDFile = "'\(pidFile.path)'"

        let task = Task {
            try await ProcessCloudCommandRunner().run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 10 & child=$!; echo $child > \(quotedPIDFile); wait $child"],
                timeout: 20
            )
        }
        try await waitForFile(pidFile)
        let childPID = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        _ = try? await task.value

        for _ in 0..<20 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(childPID, 0) != 0)
    }
}

private actor TestCloudCommandRunner: CloudCommandRunning {
    struct Command: Sendable {
        var executable: String
        var arguments: [String]
    }

    private(set) var commands: [Command] = []
    private var nextResult: CloudCommandResult?
    private var failures: [Int: CloudCommandResult] = [:]

    func failNext(exitCode: Int32, output: String) {
        nextResult = CloudCommandResult(exitCode: exitCode, output: output)
    }

    func failCommand(at index: Int, exitCode: Int32, output: String) {
        failures[index] = CloudCommandResult(exitCode: exitCode, output: output)
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CloudCommandResult {
        let index = commands.count
        commands.append(Command(executable: executable, arguments: arguments))
        defer { nextResult = nil }
        return failures.removeValue(forKey: index)
            ?? nextResult
            ?? CloudCommandResult(exitCode: 0, output: "")
    }
}

private actor TestCloudURLVerifier: CloudPublicURLVerifying {
    private(set) var urls: [URL] = []
    private var response = CloudHTTPVerification(statusCode: 200, contentLength: 1)

    func setResponse(statusCode: Int, contentLength: Int64) {
        response = CloudHTTPVerification(statusCode: statusCode, contentLength: contentLength)
    }

    func verify(url: URL, timeout: TimeInterval) async throws -> CloudHTTPVerification {
        urls.append(url)
        return response
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

private func waitForFile(_ url: URL) async throws {
    for _ in 0..<40 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw CocoaError(.fileNoSuchFile)
}
