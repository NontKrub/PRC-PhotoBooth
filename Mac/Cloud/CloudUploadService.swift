import Foundation
import Darwin

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

enum CloudCommandError: LocalizedError, Sendable, Equatable {
    case launchFailed(String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "could not start: \(message)"
        case .timedOut(let timeout):
            return "timed out after \(Int(timeout)) seconds"
        }
    }
}

protocol CloudCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CloudCommandResult
}

struct ProcessCloudCommandRunner: CloudCommandRunning {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CloudCommandResult {
        try await withCheckedThrowingContinuation { continuation in
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
                    continuation.resume(throwing: CloudCommandError.launchFailed(error.localizedDescription))
                    return
                }

                let processID = process.processIdentifier
                let processGroupConfigured = setpgid(processID, processID) == 0
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.1)
                    if process.isRunning {
                        _ = kill(processGroupConfigured ? -processID : processID, SIGKILL)
                    }
                    process.waitUntilExit()
                    continuation.resume(throwing: CloudCommandError.timedOut(timeout))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CloudCommandResult(
                    exitCode: process.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}

struct CloudHTTPVerification: Sendable, Equatable {
    var statusCode: Int
    var contentLength: Int64
}

protocol CloudPublicURLVerifying: Sendable {
    func verify(url: URL, timeout: TimeInterval) async throws -> CloudHTTPVerification
}

struct URLSessionCloudPublicURLVerifier: CloudPublicURLVerifying {
    func verify(url: URL, timeout: TimeInterval) async throws -> CloudHTTPVerification {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let length = response.expectedContentLength > 0
            ? response.expectedContentLength
            : Int64(data.count)
        return CloudHTTPVerification(statusCode: response.statusCode, contentLength: length)
    }
}

actor CloudUploadService {
    private enum Timeout {
        static let ssh: TimeInterval = 30
        static let rsync: TimeInterval = 900
        static let verification: TimeInterval = 15
    }

    private let runner: any CloudCommandRunning
    private let verifier: any CloudPublicURLVerifying

    init(
        runner: any CloudCommandRunning = ProcessCloudCommandRunner(),
        verifier: any CloudPublicURLVerifying = URLSessionCloudPublicURLVerifier()
    ) {
        self.runner = runner
        self.verifier = verifier
    }

    func upload(
        manifest: SessionManifest,
        configuration: CloudUploadConfiguration
    ) async throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true).standardizedFileURL
        guard fileManager.fileExists(atPath: directory.path) else {
            throw JobExecutionError.permanent("Session output directory is missing: \(directory.path)")
        }

        let stripFileName = manifest.stripFileName ?? "strip.png"
        _ = try requiredFile(
            stripFileName,
            in: directory,
            message: "Local strip.png is missing; cannot re-upload."
        )
        if let gifFileName = manifest.gifFileName {
            _ = try requiredFile(
                gifFileName,
                in: directory,
                message: "Local \(gifFileName) is missing; cannot re-upload."
            )
        }

        let remoteBase = configuration.remoteBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let publicBase = configuration.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeHost(configuration.sshHost),
              isSafeRemotePath(remoteBase),
              !remoteBase.isEmpty,
              !remoteBase.split(separator: "/").contains(".."),
              !manifest.relativeDirectoryPath.hasPrefix("/"),
              !manifest.relativeDirectoryPath.split(separator: "/").contains(".."),
              isSafeComponent(manifest.id),
              isSafeComponent(manifest.downloadToken),
              let publicURL = URL(string: publicBase),
              ["http", "https"].contains(publicURL.scheme?.lowercased() ?? ""),
              publicURL.host != nil else {
            throw JobExecutionError.permanent("Cloud upload configuration or session path is invalid.")
        }

        let remoteRoot = "/\(remoteBase)"
        let stagingDirectory = "\(remoteRoot)/.staging/\(manifest.id)"
        let publishedRoot = "\(remoteRoot)/.published"
        let publishedDirectory = "\(publishedRoot)/\(manifest.id)-\(UUID().uuidString)"
        let remoteSessions = "\(remoteRoot)/s"
        let page = cloudDownloadPageHTML(
            token: manifest.downloadToken,
            hasGIF: manifest.gifFileName != nil
        )
        try page.write(
            to: directory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        _ = try requiredFile(
            "index.html",
            in: directory,
            message: "Local index.html could not be generated; cannot re-upload."
        )

        try await run(
            label: "ssh mkdir remote directories",
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                host: configuration.sshHost,
                command: "mkdir -p \(Self.shellQuoted(stagingDirectory)) \(Self.shellQuoted(publishedRoot)) \(Self.shellQuoted(remoteSessions))"
            ),
            timeout: Timeout.ssh
        )

        try await run(
            label: "rsync upload session",
            executable: "/usr/bin/rsync",
            arguments: [
                "-az",
                "--partial",
                "--partial-dir=.rsync-partial",
                "--timeout=60",
                "--exclude", ".work",
                "-e", Self.rsyncSSHCommand,
                directory.path + "/",
                "\(configuration.sshHost):\(Self.rsyncRemoteEscapedPath(stagingDirectory))/"
            ],
            timeout: Timeout.rsync
        )

        let remoteChecks = [
            "test -s \(Self.shellQuoted("\(stagingDirectory)/\(stripFileName)"))",
            "test -s \(Self.shellQuoted("\(stagingDirectory)/index.html"))"
        ]
        let gifCheck = manifest.gifFileName.map {
            "test -s \(Self.shellQuoted("\(stagingDirectory)/\($0)"))"
        }
        let publishCommand = (remoteChecks + (gifCheck.map { [$0] } ?? []) + [
            "mv \(Self.shellQuoted(stagingDirectory)) \(Self.shellQuoted(publishedDirectory))",
            "ln -sfn \(Self.shellQuoted(publishedDirectory)) \(Self.shellQuoted("\(remoteSessions)/\(manifest.downloadToken)"))"
        ]).joined(separator: " && ")
        try await run(
            label: "ssh publish download link",
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(host: configuration.sshHost, command: publishCommand),
            timeout: Timeout.ssh
        )

        let verificationURL = publicURL
            .appendingPathComponent("s")
            .appendingPathComponent(manifest.downloadToken)
            .appendingPathComponent(stripFileName)
        do {
            let verification = try await verifier.verify(url: verificationURL, timeout: Timeout.verification)
            guard verification.statusCode == 200, verification.contentLength > 0 else {
                throw JobExecutionError.retryable(
                    "Upload completed but public download verification failed: HTTP \(verification.statusCode) from \(verificationURL.path)"
                )
            }
        } catch let error as JobExecutionError {
            throw error
        } catch {
            throw JobExecutionError.retryable(
                "Upload completed but public download verification failed: \(error.localizedDescription)"
            )
        }
    }

    private func requiredFile(_ fileName: String, in directory: URL, message: String) throws -> URL {
        let url = directory.appendingPathComponent(fileName).standardizedFileURL
        guard !fileName.hasPrefix("/"),
              !fileName.split(separator: "/").contains(".."),
              url.path.hasPrefix(directory.path + "/"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.fileSize ?? 0 > 0 else {
            throw JobExecutionError.permanent(message)
        }
        return url
    }

    private func run(
        label: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws {
        let result: CloudCommandResult
        do {
            result = try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
        } catch {
            throw JobExecutionError.retryable(
                "Cloud upload \(label) \(error.localizedDescription)."
            )
        }
        guard result.exitCode == 0 else {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw JobExecutionError.retryable(
                "Cloud upload \(label) failed (exit \(result.exitCode))\(output.isEmpty ? "." : ": \(output)")"
            )
        }
    }

    private static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=20",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=2"
    ]

    private static let rsyncSSHCommand = "ssh " + sshOptions.joined(separator: " ")

    private static func sshArguments(host: String, command: String) -> [String] {
        sshOptions + [host, command]
    }

    private func isSafeHost(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func isSafeRemotePath(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func isSafeComponent(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !value.isEmpty
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
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
