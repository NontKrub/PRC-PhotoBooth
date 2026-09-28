import Foundation
import Darwin

struct CloudUploadConfiguration: Sendable {
    static let defaultRemoteBasePath = "/bk1/prc/photobooth"

    var sshHost: String
    var remoteBasePath: String
    var publicBaseURL: String
}

extension CloudUploadConfiguration {
    init(snapshot: SessionCloudDeliverySnapshot) {
        self.init(
            sshHost: snapshot.sshHost,
            remoteBasePath: snapshot.remoteBasePath,
            publicBaseURL: snapshot.publicBaseURL
        )
    }
}

struct CloudSessionLayout: Sendable, Equatable {
    let route: CloudGuestRoute
    let stagingDirectory: String
    let publishedRoot: String
    let publishedDirectory: String?
    let publicAlias: String
    let publicAliasParentDirectory: String
    let verificationURL: URL?
    let sessionID: String

    init(
        manifest: SessionManifest,
        remoteRoot: String,
        publicBaseURL: URL? = nil,
        stripFileName: String = "strip.png",
        publishedVersionID: String? = nil
    ) throws {
        guard remoteRoot.hasPrefix("/"),
              !remoteRoot.split(separator: "/").contains(".."),
              Self.isSafeRemotePath(remoteRoot),
              Self.isSafeComponent(manifest.id) else {
            throw JobExecutionError.permanent("Cloud upload configuration or session path is invalid.")
        }
        let runID = manifest.origin == .soakTest ? manifest.soakRunID : nil
        if let runID, !Self.isSafeComponent(runID) {
            throw JobExecutionError.permanent("Soak cloud upload is missing a safe run identifier.")
        }
        if manifest.origin == .soakTest, runID == nil {
            throw JobExecutionError.permanent("Soak cloud upload is missing a safe run identifier.")
        }
        if let publishedVersionID, !Self.isSafeComponent(publishedVersionID) {
            throw JobExecutionError.permanent("Cloud publication version is invalid.")
        }

        let route: CloudGuestRoute
        do {
            route = try CloudGuestRoute.resolve(for: manifest)
        } catch {
            throw JobExecutionError.permanent("Cloud upload configuration or session path is invalid.")
        }

        let stagingDirectory: String
        let publishedRoot: String
        if let runID {
            stagingDirectory = "\(remoteRoot)/.soak/\(runID)/.staging/\(manifest.id)"
            publishedRoot = "\(remoteRoot)/.soak/\(runID)/.published"
        } else {
            stagingDirectory = "\(remoteRoot)/.staging/\(manifest.id)"
            publishedRoot = "\(remoteRoot)/.published"
        }

        let publicAlias = "\(remoteRoot)\(route.relativePath)"
        self.route = route
        self.stagingDirectory = stagingDirectory
        self.publishedRoot = publishedRoot
        self.publishedDirectory = publishedVersionID.map {
            "\(publishedRoot)/\(manifest.id)-\($0)"
        }
        self.publicAlias = publicAlias
        self.publicAliasParentDirectory = URL(fileURLWithPath: publicAlias).deletingLastPathComponent().path
        self.verificationURL = publicBaseURL.flatMap {
            route.childURL(stripFileName, baseURL: $0)
        }
        self.sessionID = manifest.id
    }

    private static func isSafeRemotePath(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !value.isEmpty
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
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
    static let maximumOutputBytes = 128 * 1024

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CloudCommandResult {
        let state = ProcessRunState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CloudCommandResult, Error>) in
                state.setContinuation(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.runProcess(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        state: state
                    )
                }
            }
        }, onCancel: {
            state.requestTermination(CancellationError())
        })
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        state: ProcessRunState
    ) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = BoundedProcessOutputBuffer(maximumBytes: maximumOutputBytes / 2)
        let stderr = BoundedProcessOutputBuffer(maximumBytes: maximumOutputBytes / 2)
        let readers = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdout, group: readers)
        drain(stderrPipe.fileHandleForReading, into: stderr, group: readers)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { process in
            readers.notify(queue: .global(qos: .utility)) {
                let result = CloudCommandResult(
                    exitCode: process.terminationStatus,
                    output: combinedOutput(stdout: stdout, stderr: stderr)
                )
                if let error = state.terminationError {
                    state.complete(.failure(error))
                } else {
                    state.complete(.success(result))
                }
            }
        }

        guard !state.isFinished else {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            return
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            state.complete(.failure(CloudCommandError.launchFailed(error.localizedDescription)))
            return
        }

        let processGroupConfigured = setpgid(process.processIdentifier, process.processIdentifier) == 0
        if state.install(process: process, processGroupConfigured: processGroupConfigured) {
            terminate(process, processGroupConfigured: processGroupConfigured)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [stdoutPipe, stderrPipe] in
            state.requestTermination(CloudCommandError.timedOut(timeout))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
            }
        }
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: BoundedProcessOutputBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                handle.closeFile()
                group.leave()
            }
            while true {
                do {
                    guard let data = try handle.read(upToCount: 16 * 1024), !data.isEmpty else { return }
                    buffer.append(data)
                } catch {
                    return
                }
            }
        }
    }

    fileprivate static func terminate(_ process: Process, processGroupConfigured: Bool) {
        let processID = process.processIdentifier
        if processGroupConfigured {
            _ = kill(-processID, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            if processGroupConfigured {
                _ = kill(-processID, SIGKILL)
            } else if process.isRunning {
                _ = kill(processID, SIGKILL)
            }
        }
    }

    private static func combinedOutput(
        stdout: BoundedProcessOutputBuffer,
        stderr: BoundedProcessOutputBuffer
    ) -> String {
        let stdoutText = stdout.string
        let stderrText = stderr.string
        switch (stdoutText.isEmpty, stderrText.isEmpty) {
        case (true, true): return ""
        case (false, true): return "stdout:\n\(stdoutText)"
        case (true, false): return "stderr:\n\(stderrText)"
        case (false, false): return "stdout:\n\(stdoutText)\nstderr:\n\(stderrText)"
        }
    }
}

private final class BoundedProcessOutputBuffer: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var string: String {
        lock.lock()
        let snapshot = data
        let wasTruncated = truncated
        lock.unlock()
        let text = String(data: snapshot, encoding: .utf8) ?? ""
        return wasTruncated ? "[output truncated]\n\(text)" : text
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > maximumBytes {
            data = Data(data.suffix(maximumBytes))
            truncated = true
        }
        lock.unlock()
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var processGroupConfigured = false
    private var finished = false
    private var terminalError: Error?
    private var continuation: CheckedContinuation<CloudCommandResult, Error>?
    private var pendingResult: Result<CloudCommandResult, Error>?

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var terminationError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }

    func setContinuation(_ continuation: CheckedContinuation<CloudCommandResult, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            resume(continuation, with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func install(process: Process, processGroupConfigured: Bool) -> Bool {
        lock.lock()
        self.process = process
        self.processGroupConfigured = processGroupConfigured
        let shouldTerminate = finished || terminalError != nil
        lock.unlock()
        return shouldTerminate
    }

    func requestTermination(_ error: Error) {
        var processToTerminate: (Process, Bool)?
        var finishImmediately = false

        lock.lock()
        guard !finished, terminalError == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        if let process {
            if process.isRunning || processGroupConfigured {
                processToTerminate = (process, processGroupConfigured)
            }
        } else {
            finishImmediately = true
        }
        lock.unlock()

        if let (process, processGroupConfigured) = processToTerminate {
            ProcessCloudCommandRunner.terminate(process, processGroupConfigured: processGroupConfigured)
        } else if finishImmediately {
            complete(.failure(error))
        }
    }

    func complete(_ result: Result<CloudCommandResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            resume(continuation, with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<CloudCommandResult, Error>,
        with result: Result<CloudCommandResult, Error>
    ) {
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
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
              isSafeComponent(manifest.downloadToken),
              let validatedPublicBase = ValidatedPublicGuestBaseURL(string: publicBase) else {
            throw JobExecutionError.permanent("Cloud upload configuration or session path is invalid.")
        }
        let publicURL = validatedPublicBase.url

        let remoteRoot = "/\(remoteBase)"
        let layout = try CloudSessionLayout(
            manifest: manifest,
            remoteRoot: remoteRoot,
            publicBaseURL: publicURL,
            stripFileName: stripFileName,
            publishedVersionID: UUID().uuidString
        )
        guard let publishedDirectory = layout.publishedDirectory,
              let verificationURL = layout.verificationURL else {
            throw JobExecutionError.permanent("Cloud publication route could not be constructed.")
        }
        let page = cloudDownloadPageHTML(
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
                command: "mkdir -p \(Self.shellQuoted(layout.stagingDirectory)) \(Self.shellQuoted(layout.publishedRoot)) \(Self.shellQuoted(layout.publicAliasParentDirectory))"
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
                "\(configuration.sshHost):\(Self.rsyncRemoteEscapedPath(layout.stagingDirectory))/"
            ],
            timeout: Timeout.rsync
        )

        let remoteChecks = [
            "test -s \(Self.shellQuoted("\(layout.stagingDirectory)/\(stripFileName)"))",
            "test -s \(Self.shellQuoted("\(layout.stagingDirectory)/index.html"))"
        ]
        let gifCheck = manifest.gifFileName.map {
            "test -s \(Self.shellQuoted("\(layout.stagingDirectory)/\($0)"))"
        }
        let publishCommand = (remoteChecks + (gifCheck.map { [$0] } ?? []) + [
            "mv \(Self.shellQuoted(layout.stagingDirectory)) \(Self.shellQuoted(publishedDirectory))",
            "ln -sfn \(Self.shellQuoted(publishedDirectory)) \(Self.shellQuoted(layout.publicAlias))"
        ]).joined(separator: " && ")
        try await run(
            label: "ssh publish download link",
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(host: configuration.sshHost, command: publishCommand),
            timeout: Timeout.ssh
        )

        do {
            let verification = try await verifier.verify(url: verificationURL, timeout: Timeout.verification)
            guard verification.statusCode == 200, verification.contentLength > 0 else {
                throw JobExecutionError.retryable(
                    "Upload completed but public download verification failed: HTTP \(verification.statusCode) from \(verificationURL.path)"
                )
            }
        } catch let error as JobExecutionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw JobExecutionError.retryable(
                "Upload completed but public download verification failed: \(error.localizedDescription)"
            )
        }
        try Task.checkCancellation()

        let cleanupCommand = cleanupPublishedVersionsCommand(
            publishedRoot: layout.publishedRoot,
            sessionID: layout.sessionID,
            keeping: publishedDirectory
        )
        do {
            try await run(
                label: "clean stale published versions",
                executable: "/usr/bin/ssh",
                arguments: Self.sshArguments(host: configuration.sshHost, command: cleanupCommand),
                timeout: Timeout.ssh
            )
        } catch {
            if Task.isCancelled { throw error }
            NSLog("[Cloud] Cloud upload succeeded, but stale remote versions could not be cleaned: \(error.localizedDescription)")
        }
    }

    func removeSoakArtifacts(
        manifest: SessionManifest,
        configuration: CloudUploadConfiguration
    ) async throws {
        let remoteBase = configuration.remoteBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard manifest.origin == .soakTest,
              isSafeHost(configuration.sshHost),
              isSafeRemotePath(remoteBase),
              !remoteBase.isEmpty,
              !remoteBase.split(separator: "/").contains("..") else {
            throw JobExecutionError.permanent("Refusing cloud cleanup for an invalid soak session path.")
        }

        let remoteRoot = "/\(remoteBase)"
        let layout: CloudSessionLayout
        do {
            layout = try CloudSessionLayout(manifest: manifest, remoteRoot: remoteRoot)
        } catch {
            throw JobExecutionError.permanent("Refusing cloud cleanup for an invalid soak session path.")
        }
        let command = [
            "if [ -e \(Self.shellQuoted(layout.publicAlias)) ] || [ -L \(Self.shellQuoted(layout.publicAlias)) ]; then rm -f -- \(Self.shellQuoted(layout.publicAlias)); fi",
            "rm -rf -- \(Self.shellQuoted(layout.stagingDirectory))",
            cleanupPublishedVersionsCommand(publishedRoot: layout.publishedRoot, sessionID: layout.sessionID)
        ].joined(separator: " && ")
        try await run(
            label: "clean isolated soak cloud artifacts",
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(host: configuration.sshHost, command: command),
            timeout: Timeout.ssh
        )
    }

    func hideSoakAlias(
        manifest: SessionManifest,
        configuration: CloudUploadConfiguration
    ) async throws {
        let remoteBase = configuration.remoteBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard manifest.origin == .soakTest,
              isSafeHost(configuration.sshHost),
              isSafeRemotePath(remoteBase),
              !remoteBase.isEmpty,
              !remoteBase.split(separator: "/").contains("..") else {
            throw JobExecutionError.permanent("Refusing cloud route cleanup for an invalid soak session path.")
        }
        let layout: CloudSessionLayout
        do {
            layout = try CloudSessionLayout(manifest: manifest, remoteRoot: "/\(remoteBase)")
        } catch {
            throw JobExecutionError.permanent("Refusing cloud route cleanup for an invalid soak session path.")
        }
        let command = "if [ -e \(Self.shellQuoted(layout.publicAlias)) ] || [ -L \(Self.shellQuoted(layout.publicAlias)) ]; then rm -f -- \(Self.shellQuoted(layout.publicAlias)); fi"
        try await run(
            label: "depublish isolated soak cloud route",
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(host: configuration.sshHost, command: command),
            timeout: Timeout.ssh
        )
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
            try Task.checkCancellation()
            result = try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
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

    private func cleanupPublishedVersionsCommand(
        publishedRoot: String,
        sessionID: String,
        keeping publishedDirectory: String? = nil
    ) -> String {
        var parts = [
            "find \(Self.shellQuoted(publishedRoot)) -maxdepth 1 -mindepth 1 -type d",
            "-name \(Self.shellQuoted("\(sessionID)-*"))"
        ]
        if let publishedDirectory {
            parts.append("! -path \(Self.shellQuoted(publishedDirectory))")
        }
        parts.append("-exec rm -rf -- {} +")
        return "if [ -d \(Self.shellQuoted(publishedRoot)) ]; then \(parts.joined(separator: " ")); fi"
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

private func cloudDownloadPageHTML(hasGIF: Bool) -> String {
    let gifLink = hasGIF
        ? #"<p><a href="booth.gif" download="photobooth.gif">Save GIF</a></p>"#
        : ""
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>PRC Photo Booth — Your Photos</title></head>
    <body style="font-family:-apple-system,sans-serif;text-align:center;padding:2rem">
    <h1>✨ Your Photo Strip</h1>
    <img src="strip.png" alt="Photo Strip" style="max-width:90vw">
    <p><a href="strip.png" download="photobooth-strip.png">Save Strip</a></p>
    \(gifLink)
    </body>
    </html>
    """
}
