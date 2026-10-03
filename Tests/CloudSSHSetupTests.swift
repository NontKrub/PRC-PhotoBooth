import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Cloud SSH setup")
struct CloudSSHSetupTests {
    @Test("uses a chosen event folder and falls back to Pictures")
    func resolvesEventFolder() {
        let fallback = URL(fileURLWithPath: "/Users/test/Pictures/PRC-PhotoBooth", isDirectory: true)

        #expect(BoothCoordinator.eventFolderURL(storedPath: "/Volumes/Events", fallback: fallback)
            == URL(fileURLWithPath: "/Volumes/Events", isDirectory: true))
        #expect(BoothCoordinator.eventFolderURL(storedPath: nil, fallback: fallback) == fallback)
        #expect(BoothCoordinator.eventFolderURL(storedPath: "", fallback: fallback) == fallback)
    }

    @Test("setup state transitions cover first run, retry, skip, and reopen")
    func stateTransitions() {
        #expect(CloudSSHSetupState.notStarted.transitioning(for: .begin) == .incomplete)
        #expect(CloudSSHSetupState.incomplete.transitioning(for: .succeed) == .complete)
        #expect(CloudSSHSetupState.incomplete.transitioning(for: .skip) == .skipped)
        #expect(CloudSSHSetupState.skipped.transitioning(for: .reopen) == .incomplete)
        #expect(CloudSSHSetupState.complete.transitioning(for: .reopen) == .complete)
    }

    @Test("managed SSH block is idempotent and keeps unrelated hosts")
    func managedBlockReplacement() throws {
        let config = CloudSSHConfiguration(alias: "nont-srv1", username: "nont", tunnelHostname: "ssh.nakrub.me")
        let existing = "Host personal\n    HostName example.com\n\n" + CloudSSHConfigFile.managedBlock(configuration: config, keyPath: "/tmp/old")
        let updated = try CloudSSHConfigFile.updatedContents(existing: existing, configuration: config, keyPath: "/tmp/new")

        #expect(updated.contains("Host personal"))
        #expect(updated.contains("IdentityFile \"/tmp/new\""))
        #expect(updated.components(separatedBy: CloudSSHConfigFile.beginMarker).count == 2)
    }

    @Test("OpenSSH parses an IdentityFile path with spaces as one path")
    func identityFileWithSpacesParses() throws {
        let configuration = CloudSSHConfiguration(
            alias: "prc-portability-probe",
            username: "test",
            tunnelHostname: "example.test"
        )
        let keyPath = "/tmp/PRC Photo Booth/id_ed25519"
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRC-SSH-Config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: configURL) }
        let config = CloudSSHConfigFile.managedBlock(configuration: configuration, keyPath: keyPath)
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", configURL.path, configuration.alias]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(output.contains("identityfile \(keyPath)\n"))
    }

    @Test("SSH host key failures require operator verification")
    func hostKeyFailuresStayFailClosed() {
        let unknown = CloudSSHSetupDiagnostic.hostKeyFailureMessage(for: "Host key verification failed.")
        #expect(unknown?.contains("Verify the server fingerprint") == true)
        #expect(unknown?.contains("accept only the matching fingerprint") == true)
        #expect(CloudSSHSetupDiagnostic.hostKeyFailureMessage(
            for: "No ED25519 host key is known for [example.com]:22 and you have requested strict checking."
        ) != nil)

        let changed = CloudSSHSetupDiagnostic.hostKeyFailureMessage(
            for: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"
        )
        #expect(changed?.contains("Verify its new fingerprint") == true)
        #expect(CloudSSHSetupDiagnostic.hostKeyFailureMessage(for: "Permission denied (publickey).") == nil)
    }

    @Test("setup recovers a missing public key from raw ssh-keygen stdout")
    @MainActor
    func setupRecoversMissingPublicKey() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRC Photo Booth Key Recovery \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        let privateKey = sshDirectory.appendingPathComponent("prc_photobooth_ed25519")
        let generated = try await ProcessCloudCommandRunner().run(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-t", "ed25519", "-f", privateKey.path, "-N", "", "-C", "PRC PhotoBooth test"],
            timeout: 10
        )
        #expect(generated.exitCode == 0)
        let expectedPublicKey = try String(contentsOf: privateKey.appendingPathExtension("pub"), encoding: .utf8)
        try FileManager.default.removeItem(at: privateKey.appendingPathExtension("pub"))
        let defaultsName = "CloudSSHSetupTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let setup = CloudSSHSetupService(defaults: defaults, homeDirectory: homeDirectory)

        #expect(try await setup.ensureKeyPair())
        let recoveredPublicKey = try String(contentsOf: privateKey.appendingPathExtension("pub"), encoding: .utf8)
        #expect(recoveredPublicKey == expectedPublicKey)

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        verify.arguments = ["-lf", privateKey.appendingPathExtension("pub").path]
        let outputPipe = Pipe()
        verify.standardOutput = outputPipe
        verify.standardError = outputPipe
        try verify.run()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        verify.waitUntilExit()
        #expect(verify.terminationStatus == 0)
        #expect(output.contains("ED25519"))
    }

    @Test("SSH setup command drains large stdout and stderr")
    func setupCommandDrainsLargeOutput() async {
        let result = await runCloudSSHSetupCommand(
            "/bin/sh",
            ["-c", "head -c 200000 /dev/zero; head -c 200000 /dev/zero >&2"],
            timeout: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("stdout:\n"))
        #expect(result.output.contains("stderr:\n"))
        #expect(result.output.contains("[output truncated]"))
        #expect(result.output.utf8.count <= ProcessCloudCommandRunner.maximumOutputBytes + 128)
    }

    @Test("existing unmanaged alias is not overwritten")
    func detectsAliasConflict() {
        let config = CloudSSHConfiguration(alias: "nont-srv1", username: "nont", tunnelHostname: "ssh.nakrub.me")
        #expect(throws: CloudSSHConfigError.existingAlias("nont-srv1")) {
            try CloudSSHConfigFile.updatedContents(existing: "Host nont-srv1 backup\n    HostName old.example\n", configuration: config, keyPath: "/tmp/key")
        }
    }
}
