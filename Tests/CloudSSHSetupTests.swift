import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Cloud SSH setup")
struct CloudSSHSetupTests {
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
        #expect(updated.contains("IdentityFile /tmp/new"))
        #expect(updated.components(separatedBy: CloudSSHConfigFile.beginMarker).count == 2)
    }

    @Test("existing unmanaged alias is not overwritten")
    func detectsAliasConflict() {
        let config = CloudSSHConfiguration(alias: "nont-srv1", username: "nont", tunnelHostname: "ssh.nakrub.me")
        #expect(throws: CloudSSHConfigError.existingAlias("nont-srv1")) {
            try CloudSSHConfigFile.updatedContents(existing: "Host nont-srv1 backup\n    HostName old.example\n", configuration: config, keyPath: "/tmp/key")
        }
    }
}
