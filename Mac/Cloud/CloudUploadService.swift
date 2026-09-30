import Foundation
import Darwin
import ImageIO
import CryptoKit

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
    let rollbackAliasBackup: String?
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
        self.rollbackAliasBackup = publishedVersionID.map { "\(publicAlias).rollback-\($0)" }
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
    var verifiedImage: Bool
    var imageWidth: Int?
    var imageHeight: Int?
    var bytesInspected: Int
    var finalURL: URL
}

protocol CloudPublicURLVerifying: Sendable {
    func verify(
        url: URL,
        expectedSHA256: Data,
        expectedByteCount: Int,
        timeout: TimeInterval
    ) async throws -> CloudHTTPVerification
}

struct URLSessionCloudPublicURLVerifier: CloudPublicURLVerifying {
    static let maximumInspectionBytes = 256 * 1024
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    func verify(
        url: URL,
        expectedSHA256: Data,
        expectedByteCount: Int,
        timeout: TimeInterval
    ) async throws -> CloudHTTPVerification {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              expectedSHA256.count == 32,
              expectedByteCount > 0 else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let redirectDelegate = RejectCloudVerificationRedirects()
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard let finalURL = response.url else { throw URLError(.badServerResponse) }
        let contentLengthHeader = response.value(forHTTPHeaderField: "Content-Length")
        let contentLength = contentLengthHeader.flatMap(Int.init)
        let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard response.statusCode == 200,
              finalURL == url,
              contentLengthHeader == nil || contentLength == expectedByteCount,
              contentEncoding == nil || contentEncoding == "identity" else {
            bytes.task.cancel()
            return CloudHTTPVerification(
                statusCode: response.statusCode,
                verifiedImage: false,
                imageWidth: nil,
                imageHeight: nil,
                bytesInspected: 0,
                finalURL: finalURL
            )
        }

        var inspectedData = Data()
        inspectedData.reserveCapacity(Self.maximumInspectionBytes)
        var chunk = Data()
        chunk.reserveCapacity(Self.networkChunkSize)
        let source = CGImageSourceCreateIncremental(nil)
        var dimensions: (width: Int, height: Int)?
        var hasher = SHA256()
        var bytesReceived = 0

        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            bytesReceived += data.count
            hasher.update(data: data)
            if dimensions == nil, inspectedData.count < Self.maximumInspectionBytes {
                let count = min(data.count, Self.maximumInspectionBytes - inspectedData.count)
                inspectedData.append(data.prefix(count))
                dimensions = imageDimensions(in: inspectedData, source: source)
            }
        }

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard bytesReceived + chunk.count < expectedByteCount else {
                    bytes.task.cancel()
                    return verification(
                        statusCode: response.statusCode,
                        dimensions: nil,
                        bytesInspected: bytesReceived + chunk.count,
                        finalURL: finalURL,
                        expectedSHA256: expectedSHA256,
                        actualSHA256: nil,
                        expectedByteCount: expectedByteCount
                    )
                }
                chunk.append(byte)
                if chunk.count == Self.networkChunkSize {
                    consume(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    if dimensions == nil, inspectedData.count == Self.maximumInspectionBytes {
                        bytes.task.cancel()
                        return verification(
                            statusCode: response.statusCode,
                            dimensions: nil,
                            bytesInspected: bytesReceived,
                            finalURL: finalURL,
                            expectedSHA256: expectedSHA256,
                            actualSHA256: nil,
                            expectedByteCount: expectedByteCount
                        )
                    }
                }
            }
            consume(chunk)
            if dimensions == nil {
                dimensions = imageDimensions(in: inspectedData, source: source, isFinal: true)
            } else {
                CGImageSourceUpdateData(source, inspectedData as CFData, true)
            }
            let actualSHA256 = Data(hasher.finalize())
            bytes.task.cancel()
            return verification(
                statusCode: response.statusCode,
                dimensions: dimensions,
                bytesInspected: bytesReceived,
                finalURL: finalURL,
                expectedSHA256: expectedSHA256,
                actualSHA256: actualSHA256,
                expectedByteCount: expectedByteCount
            )
        } catch {
            bytes.task.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func imageDimensions(
        in data: Data,
        source: CGImageSource,
        isFinal: Bool = false
    ) -> (width: Int, height: Int)? {
        CGImageSourceUpdateData(source, data as CFData, isFinal)
        guard CGImageSourceGetType(source) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else { return nil }
        return (width, height)
    }

    private func verification(
        statusCode: Int,
        dimensions: (width: Int, height: Int)?,
        bytesInspected: Int,
        finalURL: URL,
        expectedSHA256: Data,
        actualSHA256: Data?,
        expectedByteCount: Int
    ) -> CloudHTTPVerification {
        let verifiedImage = bytesInspected == expectedByteCount
            && dimensions != nil
            && actualSHA256 == expectedSHA256
        return CloudHTTPVerification(
            statusCode: statusCode,
            verifiedImage: verifiedImage,
            imageWidth: dimensions?.width,
            imageHeight: dimensions?.height,
            bytesInspected: bytesInspected,
            finalURL: finalURL
        )
    }

    private static let networkChunkSize = 64 * 1024
}

// This delegate has no mutable state; rejecting redirects keeps verification
// tied to the configured public strip URL and avoids fetching login pages.
final class RejectCloudVerificationRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor CloudUploadService {
    private enum Timeout {
        static let ssh: TimeInterval = 30
        static let rsync: TimeInterval = 900
        static let verification: TimeInterval = 120
    }

    private let runner: any CloudCommandRunning
    private let verifier: any CloudPublicURLVerifying
    private var activePublications: Set<String> = []

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
        let stripURL = try requiredFile(
            stripFileName,
            in: directory,
            message: "Local strip.png is missing; cannot re-upload."
        )
        let expectedStrip = try fileIntegrity(at: stripURL)
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
        guard activePublications.insert(layout.publicAlias).inserted else {
            throw JobExecutionError.retryable("Cloud publication is already running for this public route.")
        }
        defer { activePublications.remove(layout.publicAlias) }
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
        let stagedStripPath = "\(layout.stagingDirectory)/\(stripFileName)"
        let checksumResult = try await run(
            label: "verify staged strip checksum",
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                host: configuration.sshHost,
                command: "sha256sum -- \(Self.shellQuoted(stagedStripPath)) && wc -c < \(Self.shellQuoted(stagedStripPath))"
            ),
            timeout: Timeout.ssh
        )
        guard remoteFileMatches(
            checksumResult.output,
            expectedSHA256: expectedStrip.sha256,
            expectedByteCount: expectedStrip.byteCount
        ) else {
            throw JobExecutionError.retryable("Cloud upload remote checksum did not match the local strip.")
        }

        let backupPreparation: [String]
        if let backup = layout.rollbackAliasBackup {
            backupPreparation = [
                "if [ -L \(Self.shellQuoted(layout.publicAlias)) ]; then cp -P -- \(Self.shellQuoted(layout.publicAlias)) \(Self.shellQuoted(backup)); elif [ -e \(Self.shellQuoted(layout.publicAlias)) ]; then exit 1; else rm -f -- \(Self.shellQuoted(backup)); fi"
            ]
        } else {
            backupPreparation = []
        }
        let publishCommand = (remoteChecks + (gifCheck.map { [$0] } ?? []) + backupPreparation + [
            "mv \(Self.shellQuoted(layout.stagingDirectory)) \(Self.shellQuoted(publishedDirectory))",
            "ln -sfn \(Self.shellQuoted(publishedDirectory)) \(Self.shellQuoted(layout.publicAlias))"
        ]).joined(separator: " && ")
        do {
            try await run(
                label: "ssh publish download link",
                executable: "/usr/bin/ssh",
                arguments: Self.sshArguments(host: configuration.sshHost, command: publishCommand),
                timeout: Timeout.ssh
            )
        } catch {
            await restorePreviousPublicAlias(
                layout: layout,
                publishedDirectory: publishedDirectory,
                configuration: configuration
            )
            throw error
        }

        do {
            let verification = try await verifier.verify(
                url: verificationURL,
                expectedSHA256: expectedStrip.sha256,
                expectedByteCount: expectedStrip.byteCount,
                timeout: Timeout.verification
            )
            guard verification.statusCode == 200,
                  verification.finalURL == verificationURL,
                  verification.verifiedImage,
                  let width = verification.imageWidth,
                  width > 0,
                  let height = verification.imageHeight,
                  height > 0,
                  verification.bytesInspected == expectedStrip.byteCount else {
                throw JobExecutionError.retryable(
                    "Upload completed but public image integrity verification failed: HTTP \(verification.statusCode) from \(verificationURL.path)"
                )
            }
            let currentStrip = try fileIntegrity(at: stripURL)
            guard currentStrip == expectedStrip else {
                throw JobExecutionError.retryable("The local strip changed during cloud publication verification.")
            }
            _ = try await run(
                label: "verify public alias target",
                executable: "/usr/bin/ssh",
                arguments: Self.sshArguments(
                    host: configuration.sshHost,
                    command: "test -L \(Self.shellQuoted(layout.publicAlias)) && [ \"$(readlink \(Self.shellQuoted(layout.publicAlias)))\" = \(Self.shellQuoted(publishedDirectory)) ]"
                ),
                timeout: Timeout.ssh
            )
        } catch let error as JobExecutionError {
            await restorePreviousPublicAlias(
                layout: layout,
                publishedDirectory: publishedDirectory,
                configuration: configuration
            )
            throw error
        } catch is CancellationError {
            await restorePreviousPublicAlias(
                layout: layout,
                publishedDirectory: publishedDirectory,
                configuration: configuration
            )
            throw CancellationError()
        } catch {
            await restorePreviousPublicAlias(
                layout: layout,
                publishedDirectory: publishedDirectory,
                configuration: configuration
            )
            if Task.isCancelled { throw CancellationError() }
            throw JobExecutionError.retryable(
                "Upload completed but public download verification failed: \(error.localizedDescription)"
            )
        }

        // Verification makes this publication authoritative. Backup cleanup is
        // best effort: an SSH timeout may mean rm ran remotely, so rolling back
        // after that ambiguous result could remove the only public copy.
        if let backup = layout.rollbackAliasBackup {
            do {
                let result = try await runner.run(
                    executable: "/usr/bin/ssh",
                    arguments: Self.sshArguments(
                        host: configuration.sshHost,
                        command: "rm -f -- \(Self.shellQuoted(backup))"
                    ),
                    timeout: Timeout.ssh
                )
                if result.exitCode != 0 {
                    NSLog("[Cloud] Verified publication backup cleanup failed (exit %d).", result.exitCode)
                }
            } catch {
                NSLog("[Cloud] Verified publication backup cleanup was not confirmed: \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()

        let cleanupCommand = cleanupPublishedVersionsCommand(
            publishedRoot: layout.publishedRoot,
            sessionID: layout.sessionID,
            publicAlias: layout.publicAlias,
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

    private func fileIntegrity(at url: URL) throws -> (sha256: Data, byteCount: Int) {
        let fileManager = FileManager.default
        guard let initial = try? fileManager.attributesOfItem(atPath: url.path),
              let initialSize = initial[.size] as? NSNumber,
              let byteCount = Int(exactly: initialSize.int64Value),
              byteCount > 0,
              let initialDate = initial[.modificationDate] as? Date else {
            throw JobExecutionError.retryable("Cloud publication could not inspect the local strip file.")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var bytesRead = 0
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                bytesRead += chunk.count
                guard bytesRead <= byteCount else {
                    throw JobExecutionError.retryable("The local strip changed while it was being hashed.")
                }
                hasher.update(data: chunk)
            }
            let final = try fileManager.attributesOfItem(atPath: url.path)
            guard bytesRead == byteCount,
                  final[.size] as? NSNumber == initialSize,
                  final[.modificationDate] as? Date == initialDate else {
                throw JobExecutionError.retryable("The local strip changed while it was being hashed.")
            }
            return (Data(hasher.finalize()), byteCount)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as JobExecutionError {
            throw error
        } catch {
            throw JobExecutionError.retryable("Could not hash the local strip: \(error.localizedDescription)")
        }
    }

    private func remoteFileMatches(
        _ output: String,
        expectedSHA256: Data,
        expectedByteCount: Int
    ) -> Bool {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count >= 2,
              let actualSize = Int(lines[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let hashFields = lines[0].split(whereSeparator: \.isWhitespace)
        guard let actualHash = hashFields.first,
              actualHash.count == 64 else { return false }
        return actualHash.lowercased() == expectedSHA256.map { String(format: "%02x", $0) }.joined()
            && actualSize == expectedByteCount
    }

    private func restorePreviousPublicAlias(
        layout: CloudSessionLayout,
        publishedDirectory: String,
        configuration: CloudUploadConfiguration
    ) async {
        guard let backup = layout.rollbackAliasBackup else { return }
        let alias = Self.shellQuoted(layout.publicAlias)
        let currentPublication = Self.shellQuoted(publishedDirectory)
        let backupLink = Self.shellQuoted(backup)
        let command = "if [ -L \(alias) ] && [ \"$(readlink \(alias))\" = \(currentPublication) ]; then if [ -L \(backupLink) ]; then mv -f -- \(backupLink) \(alias) || exit 1; else rm -f -- \(alias) || exit 1; fi; elif [ ! -e \(alias) ] && [ ! -L \(alias) ] && [ -L \(backupLink) ]; then mv -f -- \(backupLink) \(alias) || exit 1; else rm -f -- \(backupLink); fi; if [ ! -L \(alias) ] || [ \"$(readlink \(alias))\" != \(currentPublication) ]; then rm -rf -- \(currentPublication); fi"
        do {
            // Alias rollback is bounded cleanup, so it still runs after task cancellation.
            let result = try await runner.run(
                executable: "/usr/bin/ssh",
                arguments: Self.sshArguments(host: configuration.sshHost, command: command),
                timeout: Timeout.ssh
            )
            if result.exitCode != 0 {
                NSLog("[Cloud] Alias rollback command failed (exit %d): %@", result.exitCode, result.output)
            }
        } catch {
            NSLog("[Cloud] Failed publication could not restore the previous public alias: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func run(
        label: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CloudCommandResult {
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
        return result
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
        publicAlias: String? = nil,
        keeping publishedDirectory: String? = nil
    ) -> String {
        var parts = [
            "find \(Self.shellQuoted(publishedRoot)) -maxdepth 1 -mindepth 1 -type d",
            "-name \(Self.shellQuoted("\(sessionID)-*"))"
        ]
        if let publishedDirectory {
            parts.append("! -path \(Self.shellQuoted(publishedDirectory))")
        }
        let currentAliasTarget = publicAlias.map {
            "current_alias_target=$(readlink \(Self.shellQuoted($0)) 2>/dev/null || true);"
        } ?? ""
        if publicAlias != nil {
            parts.append("! -path \"$current_alias_target\"")
        }
        parts.append("-exec rm -rf -- {} +")
        return "if [ -d \(Self.shellQuoted(publishedRoot)) ]; then \(currentAliasTarget) \(parts.joined(separator: " ")); fi"
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
