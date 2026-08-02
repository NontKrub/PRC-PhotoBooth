import Foundation
import Observation

enum CloudSSHSetupState: String, CaseIterable {
    case notStarted
    case incomplete
    case complete
    case skipped

    enum Event {
        case begin, succeed, fail, skip, reopen
    }

    func transitioning(for event: Event) -> CloudSSHSetupState {
        switch event {
        case .begin, .reopen:
            return self == .complete ? .complete : .incomplete
        case .succeed:
            return .complete
        case .fail:
            return .incomplete
        case .skip:
            return .skipped
        }
    }
}

enum CloudSSHRequirementID: String, CaseIterable, Identifiable {
    case homebrew, cloudflared, ssh, rsync, sshKey, sshConfig, accessLogin, serverConnection
    var id: String { rawValue }

    var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .cloudflared: "cloudflared"
        case .ssh: "OpenSSH"
        case .rsync: "rsync"
        case .sshKey: "Dedicated SSH key"
        case .sshConfig: "SSH configuration"
        case .accessLogin: "Cloudflare Access login"
        case .serverConnection: "Server connection"
        }
    }
}

struct CloudSSHRequirement: Identifiable {
    enum Status {
        case ready, needsSetup, unknown, failed
    }

    let id: CloudSSHRequirementID
    var status: Status
    var detail: String
}

struct CloudSSHConfiguration: Equatable {
    var alias: String = "nont-srv1"
    var username: String = "nont"
    var tunnelHostname: String = "ssh.nakrub.me"
}

enum CloudSSHConfigError: LocalizedError, Equatable {
    case invalidAlias
    case invalidUsername
    case invalidHostname
    case existingAlias(String)

    var errorDescription: String? {
        switch self {
        case .invalidAlias: "The SSH alias may only contain letters, numbers, dots, dashes, or underscores."
        case .invalidUsername: "The SSH username may only contain letters, numbers, dots, dashes, or underscores."
        case .invalidHostname: "Enter a valid Cloudflare tunnel hostname."
        case .existingAlias(let alias): "The SSH alias ‘\(alias)’ already exists outside PRC PhotoBooth’s managed configuration. Choose another alias or update it manually."
        }
    }
}

enum CloudSSHConfigFile {
    static let beginMarker = "# BEGIN PRC PhotoBooth Cloud SSH"
    static let endMarker = "# END PRC PhotoBooth Cloud SSH"

    static func validate(_ config: CloudSSHConfiguration) throws {
        let safeToken = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !config.alias.isEmpty,
              config.alias.unicodeScalars.allSatisfy({ safeToken.contains($0) }) else {
            throw CloudSSHConfigError.invalidAlias
        }
        guard !config.username.isEmpty,
              config.username.unicodeScalars.allSatisfy({ safeToken.contains($0) }) else {
            throw CloudSSHConfigError.invalidUsername
        }
        let safeHostname = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard config.tunnelHostname.contains("."),
              config.tunnelHostname.unicodeScalars.allSatisfy({ safeHostname.contains($0) }) else {
            throw CloudSSHConfigError.invalidHostname
        }
    }

    static func managedBlock(configuration: CloudSSHConfiguration, keyPath: String) -> String {
        """
        \(beginMarker)
        Host \(configuration.alias)
            HostName \(configuration.tunnelHostname)
            User \(configuration.username)
            ProxyCommand cloudflared access ssh --hostname \(configuration.tunnelHostname)
            IdentityFile \(keyPath)
            IdentitiesOnly yes
        \(endMarker)
        """
    }

    static func replacingManagedBlock(in contents: String, with block: String) -> String {
        var result = contents
        while let start = result.range(of: beginMarker),
              let end = result.range(of: endMarker, range: start.upperBound..<result.endIndex) {
            let replacementEnd = end.upperBound < result.endIndex ? result.index(after: end.upperBound) : end.upperBound
            result.removeSubrange(start.lowerBound..<replacementEnd)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? block + "\n" : result + "\n\n" + block + "\n"
    }

    static func hasUnmanagedAlias(_ alias: String, in contents: String) -> Bool {
        let unmanaged = replacingManagedBlock(in: contents, with: "")
        for rawLine in unmanaged.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let pieces = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard pieces.first?.lowercased() == "host" else { continue }
            if pieces.dropFirst().contains(where: { String($0).caseInsensitiveCompare(alias) == .orderedSame }) {
                return true
            }
        }
        return false
    }

    static func updatedContents(existing: String, configuration: CloudSSHConfiguration, keyPath: String) throws -> String {
        try validate(configuration)
        if hasUnmanagedAlias(configuration.alias, in: existing) {
            throw CloudSSHConfigError.existingAlias(configuration.alias)
        }
        return replacingManagedBlock(in: existing, with: managedBlock(configuration: configuration, keyPath: keyPath))
    }

    static func managedConfiguration(from contents: String) -> CloudSSHConfiguration? {
        guard let start = contents.range(of: beginMarker),
              let end = contents.range(of: endMarker, range: start.upperBound..<contents.endIndex) else { return nil }
        let block = String(contents[start.upperBound..<end.lowerBound])
        var config = CloudSSHConfiguration()
        for rawLine in block.split(whereSeparator: \.isNewline) {
            let parts = rawLine.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "host": config.alias = String(parts[1])
            case "hostname": config.tunnelHostname = String(parts[1])
            case "user": config.username = String(parts[1])
            default: break
            }
        }
        return config
    }
}

@MainActor
@Observable
final class CloudSSHSetupService {
    private enum Keys {
        static let state = "cloudSSHSetupState"
        static let uploadEnabled = "cloudUploadEnabled"
        static let sshHost = "cloudSSHHost"
    }

    private let defaults: UserDefaults
    private let homeDirectory: URL
    private let fileManager: FileManager

    var state: CloudSSHSetupState
    var requirements: [CloudSSHRequirement] = []
    var configuration: CloudSSHConfiguration
    var publicKey: String = ""
    var progressMessage: String = ""
    var lastOutput: String = ""
    var isWorking = false

    var shouldPresentFirstRun: Bool {
        state == .notStarted || state == .incomplete
    }

    var statusDescription: String {
        switch state {
        case .complete: "Connected and ready for cloud uploads"
        case .skipped: "Setup skipped — cloud uploads are disabled"
        case .incomplete: "Setup needs attention — cloud uploads are disabled"
        case .notStarted: "Cloud SSH setup has not been completed"
        }
    }

    init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        if let saved = defaults.string(forKey: Keys.state), let savedState = CloudSSHSetupState(rawValue: saved) {
            state = savedState
        } else if defaults.object(forKey: Keys.sshHost) != nil {
            // A pre-setup version stored a host directly. Keep that installation working.
            state = .complete
            defaults.set(CloudSSHSetupState.complete.rawValue, forKey: Keys.state)
        } else {
            state = .notStarted
            defaults.set(false, forKey: Keys.uploadEnabled)
        }

        let configURL = homeDirectory.appendingPathComponent(".ssh/config")
        if let text = try? String(contentsOf: configURL, encoding: .utf8),
           let savedConfig = CloudSSHConfigFile.managedConfiguration(from: text) {
            configuration = savedConfig
        } else {
            configuration = CloudSSHConfiguration(alias: defaults.string(forKey: Keys.sshHost) ?? "nont-srv1", username: "nont", tunnelHostname: "ssh.nakrub.me")
        }
        refreshChecks()
    }

    func reopen() {
        if state != .complete { state = state.transitioning(for: .reopen) }
        refreshChecks()
    }

    func skip() {
        state = state.transitioning(for: .skip)
        defaults.set(state.rawValue, forKey: Keys.state)
        defaults.set(false, forKey: Keys.uploadEnabled)
    }

    func refreshChecks() {
        publicKey = (try? String(contentsOf: publicKeyURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configContents = (try? String(contentsOf: sshConfigURL, encoding: .utf8)) ?? ""
        let managedMatches = CloudSSHConfigFile.managedConfiguration(from: configContents) == configuration
        requirements = [
            requirement(.homebrew, executablePath(named: "brew") != nil, "Required to install cloudflared automatically."),
            requirement(.cloudflared, executablePath(named: "cloudflared") != nil, "Used as the Cloudflare Access SSH proxy."),
            requirement(.ssh, fileManager.isExecutableFile(atPath: "/usr/bin/ssh"), "macOS system SSH client."),
            requirement(.rsync, fileManager.isExecutableFile(atPath: "/usr/bin/rsync"), "Used to upload completed sessions."),
            requirement(.sshKey, fileManager.fileExists(atPath: privateKeyURL.path) && !publicKey.isEmpty, "Stored at \(privateKeyURL.path)."),
            requirement(.sshConfig, managedMatches, "Adds a managed Cloudflare Access SSH alias without changing other hosts."),
            CloudSSHRequirement(id: .accessLogin,
                                status: state == .complete ? .ready : .unknown,
                                detail: state == .complete ? "Cloudflare Access was verified through the SSH tunnel." : "Verified as part of the SSH connection test."),
            CloudSSHRequirement(id: .serverConnection, status: state == .complete ? .ready : .unknown, detail: state == .complete ? "Last connection test succeeded." : "A successful SSH test is required.")
        ]
    }

    func prepareAuthenticateAndTest() async {
        guard !isWorking else { return }
        isWorking = true
        lastOutput = ""
        state = state.transitioning(for: .begin)
        defaults.set(false, forKey: Keys.uploadEnabled)
        defer {
            isWorking = false
            refreshChecks()
        }

        do {
            try CloudSSHConfigFile.validate(configuration)
            try await installPrerequisitesIfNeeded()
            let createdNewKey = try await ensureKeyPair()
            try writeSSHConfig()
            if createdNewKey {
                state = state.transitioning(for: .fail)
                defaults.set(state.rawValue, forKey: Keys.state)
                progressMessage = "Your PhotoBooth SSH key is ready. Add the public key below to the server’s authorized_keys, then choose Set Up & Test again."
                return
            }
            try await testConnection()
            defaults.set(configuration.alias, forKey: Keys.sshHost)
            defaults.set(true, forKey: Keys.uploadEnabled)
            state = state.transitioning(for: .succeed)
            defaults.set(state.rawValue, forKey: Keys.state)
            progressMessage = "Connected to \(configuration.alias). Cloud uploads are enabled."
        } catch {
            state = state.transitioning(for: .fail)
            defaults.set(state.rawValue, forKey: Keys.state)
            defaults.set(false, forKey: Keys.uploadEnabled)
            progressMessage = error.localizedDescription
        }
    }

    private var sshDirectoryURL: URL { homeDirectory.appendingPathComponent(".ssh") }
    private var privateKeyURL: URL { sshDirectoryURL.appendingPathComponent("prc_photobooth_ed25519") }
    private var publicKeyURL: URL { sshDirectoryURL.appendingPathComponent("prc_photobooth_ed25519.pub") }
    private var sshConfigURL: URL { sshDirectoryURL.appendingPathComponent("config") }

    private func requirement(_ id: CloudSSHRequirementID, _ isReady: Bool, _ detail: String) -> CloudSSHRequirement {
        CloudSSHRequirement(id: id, status: isReady ? .ready : .needsSetup, detail: detail)
    }

    private func executablePath(named name: String) -> String? {
        let standard = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let path = standard.first(where: { fileManager.isExecutableFile(atPath: $0) }) { return path }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return paths.map { String($0) + "/\(name)" }.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private func installPrerequisitesIfNeeded() async throws {
        if executablePath(named: "brew") == nil {
            progressMessage = "Installing Homebrew…"
            let script = "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            let result = await runCommand("/bin/bash", ["-c", script], timeout: 600)
            try requireSuccess(result, action: "Homebrew installation")
        }
        guard let brew = executablePath(named: "brew") else {
            throw SetupError("Homebrew was not found after installation. Restart the app and try again.")
        }
        if executablePath(named: "cloudflared") == nil {
            progressMessage = "Installing cloudflared…"
            let result = await runCommand(brew, ["install", "cloudflared"], timeout: 300)
            try requireSuccess(result, action: "cloudflared installation")
        }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/ssh") else { throw SetupError("macOS OpenSSH is unavailable.") }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/rsync") else { throw SetupError("macOS rsync is unavailable.") }
    }

    private func ensureKeyPair() async throws -> Bool {
        try fileManager.createDirectory(at: sshDirectoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDirectoryURL.path)
        var createdNewKey = false
        if !fileManager.fileExists(atPath: privateKeyURL.path) {
            progressMessage = "Generating a dedicated PhotoBooth SSH key…"
            let result = await runCommand("/usr/bin/ssh-keygen", ["-t", "ed25519", "-f", privateKeyURL.path, "-N", "", "-C", "PRC PhotoBooth"], timeout: 20)
            try requireSuccess(result, action: "SSH-key generation")
            createdNewKey = true
        }
        if !fileManager.fileExists(atPath: publicKeyURL.path) {
            let result = await runCommand("/usr/bin/ssh-keygen", ["-y", "-f", privateKeyURL.path], timeout: 20)
            try requireSuccess(result, action: "public-key recovery")
            try (result.output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: publicKeyURL, atomically: true, encoding: .utf8)
            createdNewKey = true
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
        return createdNewKey
    }

    private func writeSSHConfig() throws {
        progressMessage = "Configuring the Cloudflare Access SSH alias…"
        let old = (try? String(contentsOf: sshConfigURL, encoding: .utf8)) ?? ""
        let new = try CloudSSHConfigFile.updatedContents(existing: old, configuration: configuration, keyPath: privateKeyURL.path)
        try new.write(to: sshConfigURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sshConfigURL.path)
    }

    private func testConnection() async throws {
        progressMessage = "Verifying Cloudflare Access and SSH connection to \(configuration.alias)…"
        let result = await runCommand("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", configuration.alias, "echo OK"], timeout: 25)
        lastOutput = result.output
        guard result.exitCode == 0, result.output.contains("OK") else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError("Connection test failed. Add the displayed public key to the server’s authorized_keys, then retry.\(detail.isEmpty ? "" : "\n\n\(detail)")")
        }
    }

    private func requireSuccess(_ result: CommandResult, action: String) throws {
        guard result.exitCode == 0 else {
            lastOutput = result.output
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError("\(action) failed\(output.isEmpty ? "." : ": \(output)")")
        }
    }
}

private struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(exitCode: -1, output: error.localizedDescription))
                return
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(exitCode: -1, output: "Timed out after \(Int(timeout)) seconds.\n\(output)"))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: CommandResult(exitCode: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
        }
    }
}
