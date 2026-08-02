import Foundation

struct CloudUploadConfiguration: Sendable {
    static let defaultRemoteBasePath = "/bk1/prc/photobooth"

    var sshHost: String
    var remoteBasePath: String
    var publicBaseURL: String
}

struct CloudCommandResult: Sendable, Equatable {
    var exitCode: Int32
    var output: String
}

protocol CloudCommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CloudCommandResult
}

struct ProcessCloudCommandRunner: CloudCommandRunning {
    func run(executable: String, arguments: [String]) async throws -> CloudCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CloudCommandResult(
            exitCode: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

actor CloudUploadService {
    private let runner: any CloudCommandRunning

    init(runner: any CloudCommandRunning = ProcessCloudCommandRunner()) {
        self.runner = runner
    }

    func upload(
        manifest: SessionManifest,
        configuration: CloudUploadConfiguration
    ) async throws {
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw JobExecutionError.permanent("Session output directory is missing: \(directory.path)")
        }

        let remoteBase = configuration.remoteBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !configuration.sshHost.isEmpty,
              !remoteBase.isEmpty,
              !manifest.relativeDirectoryPath.hasPrefix("/"),
              !manifest.relativeDirectoryPath.split(separator: "/").contains("..") else {
            throw JobExecutionError.permanent("Cloud upload configuration or session path is invalid.")
        }

        let remoteDirectory = "/\(remoteBase)/\(manifest.relativeDirectoryPath)"
        let remoteSessions = "/\(remoteBase)/s"
        let hasGIF = manifest.gifFileName.map {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        } ?? false
        let page = cloudDownloadPageHTML(token: manifest.downloadToken, hasGIF: hasGIF)
        try page.write(
            to: directory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        try await run(
            label: "ssh mkdir remote directories",
            executable: "/usr/bin/ssh",
            arguments: [
                configuration.sshHost,
                "mkdir -p \(Self.shellQuoted(remoteDirectory)) \(Self.shellQuoted(remoteSessions))"
            ]
        )

        try await run(
            label: "rsync upload session",
            executable: "/usr/bin/rsync",
            arguments: [
                "-az",
                "--exclude", ".work",
                "-e", "ssh",
                directory.path + "/",
                "\(configuration.sshHost):\(Self.rsyncRemoteEscapedPath(remoteDirectory))/"
            ]
        )

        try await run(
            label: "ssh publish download link",
            executable: "/usr/bin/ssh",
            arguments: [
                configuration.sshHost,
                "ln -sfn \(Self.shellQuoted(remoteDirectory)) \(Self.shellQuoted("\(remoteSessions)/\(manifest.downloadToken)"))"
            ]
        )
    }

    private func run(label: String, executable: String, arguments: [String]) async throws {
        let result: CloudCommandResult
        do {
            result = try await runner.run(executable: executable, arguments: arguments)
        } catch {
            throw JobExecutionError.retryable(
                "Cloud upload \(label) could not start: \(error.localizedDescription)"
            )
        }
        guard result.exitCode == 0 else {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw JobExecutionError.retryable(
                "Cloud upload \(label) failed (exit \(result.exitCode)): \(output)"
            )
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func rsyncRemoteEscapedPath(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        return path.unicodeScalars.map { scalar in
            safe.contains(scalar) ? String(scalar) : "\\" + String(scalar)
        }.joined()
    }
}

private func cloudDownloadPageHTML(token: String, hasGIF: Bool) -> String {
    let gifLink = hasGIF
        ? #"<p><a href="/s/\#(token)/booth.gif" download="photobooth.gif">Save GIF</a></p>"#
        : ""
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>PRC Photo Booth — Your Photos</title></head>
    <body style="font-family:-apple-system,sans-serif;text-align:center;padding:2rem">
    <h1>✨ Your Photo Strip</h1>
    <img src="/s/\(token)/strip.png" alt="Photo Strip" style="max-width:90vw">
    <p><a href="/s/\(token)/strip.png" download="photobooth-strip.png">Save Strip</a></p>
    \(gifLink)
    </body>
    </html>
    """
}
