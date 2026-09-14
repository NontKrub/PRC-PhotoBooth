import Foundation
import Combine
import CryptoKit
import CoreImage
import CoreGraphics
import SwiftUI
import UIKit

// iPad-side coordinator — receives messages from Mac, drives local UI state.
@MainActor
final class iPadViewModel: ObservableObject {
    static let assetResponseDeadline: TimeInterval = 5

    let multipeer: BoothTransport
    let stateMachine: SessionStateMachine

    @Published var latestPreviewImage: CGImage?
    @Published var eventConfig: EventConfig = EventConfig()
    @Published var experienceCatalog: CustomerExperienceCatalog?
    @Published var experienceAssets: [String: CGImage] = [:]
    @Published var selectedTemplateID: String?
    @Published var selectedFilterID: PhotoFilterID?
    @Published var selectedLanguage: CustomerLanguage = .english
    @Published var sessionPresentation: SessionPresentation?
    @Published var promptImages: [String: CGImage] = [:]
    @Published private(set) var isSessionRequestPending = false
    @Published private(set) var reviewDecisionPending = false
    @Published private(set) var recoveryActionPending = false
    @Published private(set) var finishRequestPending = false
    @Published var sessionRequestError: String?
    @Published private(set) var assetRecoveryStatus: BoothAssetRecoveryStatus = .idle
    @Published var stripThumbImage: CGImage?
    @Published var isMirrored = false
    @Published var isBoothPaused = false

    private var pendingPreviewJPEG: Data?
    private var previewDecodeTask: Task<Void, Never>?
    private var previewStaleTask: Task<Void, Never>?
    private var lastPreviewFrameAt: Date?
#if DEBUG
    private var previewMetricsStartedAt = Date()
    private var previewFramesReceived = 0
    private var previewFramesCoalesced = 0
    private var previewFramesDisplayed = 0
#endif
    private var sessionRequestTimeoutTask: Task<Void, Never>?
    private var reviewDecisionTimeoutTask: Task<Void, Never>?
    private var recoveryActionTimeoutTask: Task<Void, Never>?
    private var finishRequestTimeoutTask: Task<Void, Never>?
    private var transientRequestGeneration: UInt64 = 0
    private var countdownTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var sessionMessageGate = SessionMessageGate()
    private let assetReceivePipeline = BoothAssetReceivePipeline()
    private var assetProcessingGeneration: UInt64 = 0
    private var assetRequestPump = BoothAssetRequestPump()
    private var receivedAssets: [String: Data] = [:]
    private var receivedAssetReferences: [String: BoothAssetReference] = [:]
    private var expectedAssetReferences: [String: BoothAssetReference] = [:]
    private var expectedAssetOrder: [BoothAssetReference] = []
    private var assetRetryTracker = BoothAssetRetryTracker()
    private var assetReadyAwaitingNewGeneration = false
    private var reviewAssetIndices: [String: Int] = [:]
    private var assetResponseDeadlineTasks: [BoothAssetReference: Task<Void, Never>] = [:]
    private var assetResponseDeadlineTokens: [BoothAssetReference: UInt64] = [:]
    private var nextAssetResponseDeadlineToken: UInt64 = 0
    private var assetResponseDeadlines = BoothAssetResponseDeadlineRegistry()
    private var lastAssetRecycleGeneration: Int?
#if DEBUG
    @Published private(set) var demoKioskMode = false
#endif

    private var observationCancellables = Set<AnyCancellable>()

    var networkTransport: NetworkBoothTransport? { multipeer as? NetworkBoothTransport }
    var connectionStatus: BoothConnectionStatus { multipeer.connectionStatus }
    var canChangeConnection: Bool { stateMachine.phase == .idle }
    var isBoothSessionActive: Bool {
        if case .idle = stateMachine.phase { return false }
        return true
    }
    var shouldShowReconnectOverlay: Bool {
        guard isBoothSessionActive, !isAuthoritativeControlReady else { return false }
#if DEBUG
        if demoKioskMode { return false }
#endif
        return true
    }
    var isAuthoritativeControlReady: Bool {
        guard case .connected = connectionStatus.state else { return false }
        guard networkTransport != nil else { return true }
        let isFresh = connectionStatus.lastControlActivityAt.map {
            Date().timeIntervalSince($0) < 10
        } ?? false
        return connectionStatus.isPeerAuthenticated
            && connectionStatus.isSecureChannelEstablished
            && isFresh
    }
    var isBoothFullyReady: Bool {
        guard isAuthoritativeControlReady else { return false }
        guard networkTransport != nil else { return true }
        return connectionStatus.isPreviewChannelConnected
            && connectionStatus.isAssetChannelReady
    }
    var isReviewMediaReady: Bool {
        guard case .review = stateMachine.phase,
              let data = stateMachine.reviewImageData else { return false }
        return Self.cgImage(from: data) != nil
    }
    var isReviewMediaMissing: Bool {
        guard case .review = stateMachine.phase else { return false }
        return !isReviewMediaReady
    }
    var isConnectionReady: Bool {
        isBoothFullyReady
    }

    func renameDevice(_ name: String) {
        guard canChangeConnection else { return }
        networkTransport?.renameLocalDevice(name)
    }

    func connect(to peerID: String) {
        guard canChangeConnection else { return }
        networkTransport?.connectToPeer(peerID)
    }

    func requestPairing(with peerID: String) {
        guard canChangeConnection else { return }
        networkTransport?.requestPairing(with: peerID)
    }

    func retryPairing(with peerID: String) {
        guard canChangeConnection else { return }
        networkTransport?.retryPairing(with: peerID)
    }

    func pair(peerID: String, pin: String) {
        guard canChangeConnection else { return }
        networkTransport?.pairWithPIN(peerID: peerID, pin: pin)
    }

    func pair(qrPayload: BoothPairingQRCodePayload) {
        guard canChangeConnection else { return }
        networkTransport?.pairWithQRCode(qrPayload)
    }

    func forget(peerID: String) {
        guard canChangeConnection else { return }
        networkTransport?.forgetPeer(peerID)
    }

    func refreshNearbyMacs() {
        guard canChangeConnection else { return }
        networkTransport?.restart()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase != .active {
            previewDecodeTask?.cancel()
            previewDecodeTask = nil
            latestPreviewImage = nil
            pendingPreviewJPEG = nil
            lastPreviewFrameAt = nil
        }
        guard phase == .active, connectionRecoveryTask == nil else { return }
        let recoveryAction = BoothForegroundRecoveryAction.action(
            controlReady: isAuthoritativeControlReady,
            previewReady: networkTransport == nil || connectionStatus.isPreviewChannelConnected,
            assetReady: networkTransport == nil || connectionStatus.isAssetChannelReady
        )
        guard recoveryAction == .restartControl else { return }
        connectionRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.multipeer.restart()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.connectionRecoveryTask = nil
        }
    }

    init() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--legacy-multipeer") {
            multipeer = MultipeerService(role: .iPad)
        } else {
            multipeer = NetworkBoothTransport(role: .iPad)
        }
#else
        multipeer = NetworkBoothTransport(role: .iPad)
#endif
        stateMachine = SessionStateMachine()
        stateMachine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observationCancellables)
        multipeer.connectionStatus.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observationCancellables)
        setupHandlers()
        multipeer.start()
        startPreviewStaleMonitor()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-kiosk") {
            demoKioskMode = true
            DemoKioskDriver.install(on: self)
        }
#endif
    }

    // MARK: - Handlers

    private func setupHandlers() {
        multipeer.onControlMessage = { [weak self] msg in
            self?.handleMessage(msg)
        }
        multipeer.onAssetChunk = { [weak self] chunk in
            self?.handleAssetChunk(chunk)
        }
        multipeer.onTransportEvent = { [weak self] event in
            guard let self,
                  event.channel == String(describing: BoothTransportChannel.asset) else { return }
            switch event.kind {
            case .transportReady:
                let transition = self.assetRetryTracker.activate(
                    generation: self.assetGeneration(for: event),
                    missing: self.missingExpectedAssets()
                )
                guard transition != .stale else { return }
                self.assetReadyAwaitingNewGeneration = false
                if transition != .duplicate {
                    self.cancelAssetResponseDeadlines()
                    self.assetRequestPump.clearInFlight()
                    self.lastAssetRecycleGeneration = nil
                }
                self.requestMissingExpectedAssets()
                if transition == .advanced,
                   !self.missingExpectedAssets().isEmpty,
                   self.assetRecoveryStatus == .restoring {
                    self.assetRecoveryStatus = .connectionRecovered
                }
            case .transportDisconnected:
                guard self.assetRetryTracker.acceptsDisconnect(generation: event.generation) else { return }
                self.cancelAssetResponseDeadlines()
                self.assetReadyAwaitingNewGeneration = true
                if !self.missingExpectedAssets().isEmpty,
                   self.assetRecoveryStatus == .idle {
                    self.assetRecoveryStatus = .restoring
                }
                self.resetAssetProcessing()
                self.assetRequestPump.clearInFlight()
            default:
                break
            }
        }
        multipeer.onPreviewFrame = { [weak self] jpegData in
            guard let self else { return }
            self.updatePreview(jpegData)
        }
    }

    private var currentSessionMessageContext: SessionMessageContext? {
        guard let sessionID = sessionMessageGate.currentSessionID else { return nil }
        return SessionMessageContext(
            sessionID: sessionID,
            sequence: sessionMessageGate.latestAcceptedSequence
        )
    }

    private func accept(_ context: SessionMessageContext, message: String) -> Bool {
        guard sessionMessageGate.accept(context) else {
#if DEBUG
            NSLog(
                "[Session] Ignored stale %@: session=%@ current=%@ sequence=%llu latest=%llu",
                message,
                context.sessionID,
                sessionMessageGate.currentSessionID ?? "none",
                context.sequence,
                sessionMessageGate.latestAcceptedSequence
            )
#endif
            return false
        }
        return true
    }

    private func acceptSessionChange(_ context: SessionMessageContext, message: String) -> Bool {
        guard sessionMessageGate.currentSessionID == nil || context.sequence > sessionMessageGate.latestAcceptedSequence else {
#if DEBUG
            NSLog(
                "[Session] Ignored stale %@: session=%@ current=%@ sequence=%llu latest=%llu",
                message,
                context.sessionID,
                sessionMessageGate.currentSessionID ?? "none",
                context.sequence,
                sessionMessageGate.latestAcceptedSequence
            )
#endif
            return false
        }
        sessionMessageGate.synchronize(sessionID: context.sessionID, sequence: context.sequence)
        return true
    }

    private func handleMessage(_ msg: Message) {
        switch msg {
        case .sessionSync(let snapshot):
            applySessionSync(snapshot)

        case .boothPaused(let isPaused):
            isBoothPaused = isPaused

        case .eventConfig(let config):
            eventConfig = config
            stateMachine.config = config

        case .eventExperienceCatalog(let catalog):
            guard stateMachine.phase == .idle
                || stateMachine.phase == .selectingExperience
                || stateMachine.phase == .readyToStart else { break }
            let sameRevision = experienceCatalog?.eventID == catalog.eventID
                && experienceCatalog?.revision == catalog.revision
            experienceCatalog = catalog
            if !sameRevision {
                experienceAssets = [:]
                selectedTemplateID = nil
                selectedFilterID = nil
            }
            applyCatalogDefaults(preserveLanguage: sameRevision)

        case .eventExperienceAsset(let packet):
            guard let catalog = experienceCatalog,
                  packet.eventID == catalog.eventID,
                  packet.revision == catalog.revision,
                  packet.kind == .templatePreview,
                  let image = Self.cgImage(from: packet.jpegData) else { break }
            experienceAssets[packet.assetID] = image

        case .setMirrored(let mirrored):
            isMirrored = mirrored

        case .sessionStart(let context):
            guard let context,
                  acceptSessionChange(context, message: "sessionStart") else { break }
            cancelCountdown()
            clearSessionMedia()
            stateMachine.startSession(config: eventConfig, sessionID: context.sessionID)

        case .sessionRequestRejected(let reason):
            cancelCountdown()
            clearTransientRequestState()
            setSessionRequestError(reason)
            stateMachine.beginSelectingExperience()

        case .sessionPrepared(let config, let presentation, let context):
            guard acceptSessionChange(context, message: "sessionPrepared") else { break }
            cancelCountdown()
            clearSessionMedia()
            eventConfig = config
            stateMachine.startSession(config: config, sessionID: presentation.sessionID)
            sessionPresentation = presentation
            registerExpectedAssets(in: presentation)
            requestMissingExpectedAssets()
            selectedLanguage = presentation.language
            installPresentationImages(presentation)

        case .beginCountdown(let context, let descriptor):
            guard accept(context, message: "beginCountdown") else { break }
            clearTransientRequestState()
            stateMachine.applyAuthoritativePhase(
                .countdown(photoIndex: descriptor.photoIndex, secondsRemaining: max(0, Int(ceil(descriptor.captureAt.timeIntervalSinceNow)))),
                countdownDeadline: descriptor.captureAt
            )
            runCountdown(descriptor)

        case .shotCaptured(let context, let index, let thumbData):
            guard accept(context, message: "shotCaptured") else { break }
            cancelCountdown()
            clearTransientRequestState()
            stateMachine.applyAuthoritativePhase(.captured(photoIndex: index))
            let historyThumbnail = ReviewImageEncoder.thumbnailData(from: thumbData) ?? thumbData
            stateMachine.enterReview(
                photoIndex: index,
                thumbnailData: historyThumbnail,
                reviewImageData: thumbData
            )

        case .shotCapturedAsset(let context, let index, let asset):
            guard accept(context, message: "shotCapturedAsset") else { break }
            cancelCountdown()
            clearTransientRequestState()
            registerExpectedAsset(asset)
            reviewAssetIndices[asset.assetID] = index
            stateMachine.applyAuthoritativePhase(.captured(photoIndex: index))
            if let data = cachedAsset(for: asset) {
                installReviewAsset(asset, photoIndex: index, data: data)
            }
            requestMissingExpectedAssets()

        case .captureRecovery(let context, let index, let failure):
            guard accept(context, message: "captureRecovery") else { break }
            cancelCountdown()
            clearTransientRequestState()
            stateMachine.applyAuthoritativePhase(.captureRecovery(photoIndex: index, failure: failure))

        case .reviewDecision(let context, let action):
            guard accept(context, message: "reviewDecision") else { break }
            guard case .review(let idx) = stateMachine.phase else { break }
            let customerAction: CustomerDisplayAction = action == .keep
                ? .keep(photoIndex: idx)
                : .retake(photoIndex: idx)
            guard CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else { break }
            clearTransientRequestState()
            switch action {
            case .keep: stateMachine.keepShot(photoIndex: idx)
            case .retake: stateMachine.retakeShot(photoIndex: idx)
            }

        case .sessionFinished(let context, let qr, let stripData, _):
            guard accept(context, message: "sessionFinished") else { break }
            cancelCountdown()
            clearTransientRequestState()
            stripThumbImage = stripData.flatMap(Self.cgImage(from:))
            stateMachine.applyAuthoritativePhase(.finished(qrPayload: qr))

        case .sessionFinishedAssets(let context, let qr, let stripAsset, _):
            guard accept(context, message: "sessionFinishedAssets") else { break }
            cancelCountdown()
            clearTransientRequestState()
            stripThumbImage = nil
            if let stripAsset { registerExpectedAsset(stripAsset) }
            if let stripAsset, let data = cachedAsset(for: stripAsset) {
                stripThumbImage = Self.cgImage(from: data)
            }
            stateMachine.applyAuthoritativePhase(.finished(qrPayload: qr))
            requestMissingExpectedAssets()

        case .assetUnavailable(let reference, _):
            guard expectedAssetReferences[reference.assetID] == reference else { break }
            assetRequestPump.markUnavailable(reference)
            assetRetryTracker.remove(reference)
            assetRecoveryStatus = .operatorRecoveryRequired
            sessionRequestError = nil
            requestMissingExpectedAssets()

        case .operatorOverride(let context, let action):
            if let context {
                guard accept(context, message: "operatorOverride") else { break }
            } else if !stateMachine.currentSessionID.isEmpty {
                break
            }
            clearTransientRequestState()
            if case .cancelSession = action { cancelCountdown() }
            stateMachine.operatorOverride(action)

        default: break
        }
    }

    private func clearSessionMedia() {
        clearTransientRequestState()
        previewDecodeTask?.cancel()
        previewDecodeTask = nil
        pendingPreviewJPEG = nil
        lastPreviewFrameAt = nil
        latestPreviewImage = nil
        sessionPresentation = nil
        promptImages = [:]
        stripThumbImage = nil
        receivedAssets = [:]
        receivedAssetReferences = [:]
        expectedAssetReferences = [:]
        expectedAssetOrder = []
        assetRetryTracker.resetForSession()
        assetReadyAwaitingNewGeneration = false
        assetRecoveryStatus = .idle
        reviewAssetIndices = [:]
        lastAssetRecycleGeneration = nil
        resetAssetProcessing()
        assetRequestPump.reset()
    }

    private func clearTransientRequestState() {
        transientRequestGeneration &+= 1
        sessionRequestTimeoutTask?.cancel()
        reviewDecisionTimeoutTask?.cancel()
        recoveryActionTimeoutTask?.cancel()
        finishRequestTimeoutTask?.cancel()
        sessionRequestTimeoutTask = nil
        reviewDecisionTimeoutTask = nil
        recoveryActionTimeoutTask = nil
        finishRequestTimeoutTask = nil
        isSessionRequestPending = false
        reviewDecisionPending = false
        recoveryActionPending = false
        finishRequestPending = false
        sessionRequestError = nil
    }

    private func setSessionRequestError(_ message: String) {
        sessionRequestError = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func beginTransientRequest() -> UInt64 {
        clearTransientRequestState()
        return transientRequestGeneration
    }

    private func registerExpectedAsset(_ reference: BoothAssetReference) {
        if let previous = expectedAssetReferences[reference.assetID], previous != reference {
            receivedAssets.removeValue(forKey: reference.assetID)
            receivedAssetReferences.removeValue(forKey: reference.assetID)
            assetRequestPump.markCompleted(previous)
            assetRetryTracker.remove(previous)
        }
        if let index = expectedAssetOrder.firstIndex(where: { $0.assetID == reference.assetID }) {
            expectedAssetOrder[index] = reference
        } else {
            expectedAssetOrder.append(reference)
        }
        expectedAssetReferences[reference.assetID] = reference
    }

    private func registerExpectedAssets(in presentation: SessionPresentation) {
        for prompt in presentation.prompts {
            if let imageAsset = prompt.imageAsset {
                registerExpectedAsset(imageAsset)
            }
        }
    }

    private func cachedAsset(for reference: BoothAssetReference) -> Data? {
        guard receivedAssetReferences[reference.assetID] == reference,
              let data = receivedAssets[reference.assetID],
              data.count == reference.byteCount else { return nil }
        return data
    }

    private func resetAssetProcessing() {
        cancelAssetResponseDeadlines()
        assetProcessingGeneration &+= 1
        let generation = assetProcessingGeneration
        let pipeline = assetReceivePipeline
        Task { await pipeline.reset(to: generation) }
    }

    private func requestMissingAssets(for snapshot: SessionSyncSnapshot) {
        var references: [BoothAssetReference] = []
        var seen = Set<BoothAssetReference>()
        func append(_ reference: BoothAssetReference) {
            guard seen.insert(reference).inserted else { return }
            references.append(reference)
        }

        if let reviewAsset = snapshot.reviewAsset { append(reviewAsset) }
        if let stripAsset = snapshot.stripAsset { append(stripAsset) }
        if let presentation = snapshot.presentation {
            for reference in presentation.prompts.compactMap(\.imageAsset) {
                append(reference)
            }
        }
        for index in snapshot.keptShotAssets.keys.sorted() {
            if let reference = snapshot.keptShotAssets[index] {
                append(reference)
            }
        }
        replaceExpectedAssets(with: references)
        requestMissingExpectedAssets()
    }

    private func assetGeneration(for event: BoothTransportDiagnosticEvent) -> Int {
        if let generation = event.generation { return generation }
        if assetReadyAwaitingNewGeneration {
            return (assetRetryTracker.currentGeneration ?? -1) + 1
        }
        return assetRetryTracker.currentGeneration ?? 0
    }

    private func missingExpectedAssets() -> Set<BoothAssetReference> {
        Set(expectedAssetOrder.filter { cachedAsset(for: $0) == nil })
    }

    private func requestMissingExpectedAssets() {
        let missing = missingExpectedAssets()
        var cached = Set<BoothAssetReference>()
        for reference in expectedAssetOrder where cachedAsset(for: reference) != nil {
            cached.insert(reference)
        }
        let requestable = expectedAssetOrder.filter {
            missing.contains($0) && assetRetryTracker.canRequest($0)
        }
        let batch = assetRequestPump.nextBatch(expected: requestable, cached: cached)
        if missing.isEmpty {
            cancelAssetResponseDeadlines()
            assetRecoveryStatus = .idle
        } else if assetRecoveryStatus != .operatorRecoveryRequired,
                  requestable.contains(where: { assetRetryTracker.canRequest($0) }) {
            assetRecoveryStatus = .restoring
        } else if assetRecoveryStatus != .operatorRecoveryRequired {
            assetRecoveryStatus = .reconnectRequired
        }
        guard !batch.isEmpty else { return }
        let processingGeneration = assetProcessingGeneration
        let sessionID = sessionMessageGate.currentSessionID
        let channelGeneration = assetRetryTracker.currentGeneration ?? 0
        multipeer.sendControl(.assetRequest(references: batch)) { [weak self] outcome in
            guard let self else { return }
            guard self.assetProcessingGeneration == processingGeneration,
                  self.sessionMessageGate.currentSessionID == sessionID,
                  self.assetRetryTracker.currentGeneration == channelGeneration else { return }
            guard outcome == .sent else {
                self.assetRequestPump.markSendFailed(batch)
                self.handleAssetFailure(batch, channelGeneration: channelGeneration)
                return
            }
            let outstanding = batch.filter { self.assetRequestPump.inFlight.contains($0) }
            self.armAssetResponseDeadline(
                for: outstanding,
                channelGeneration: channelGeneration,
                processingGeneration: processingGeneration,
                sessionID: sessionID
            )
        }
    }

    private func replaceExpectedAssets(with references: [BoothAssetReference]) {
        var unique: [BoothAssetReference] = []
        var seen = Set<BoothAssetReference>()
        for reference in references where seen.insert(reference).inserted {
            unique.append(reference)
        }
        let next = Dictionary(unique.map { ($0.assetID, $0) }, uniquingKeysWith: { _, latest in latest })
        guard next != expectedAssetReferences || unique != expectedAssetOrder else { return }

        cancelAssetResponseDeadlines()
        for previous in expectedAssetReferences.values where next[previous.assetID] != previous {
            receivedAssets.removeValue(forKey: previous.assetID)
            receivedAssetReferences.removeValue(forKey: previous.assetID)
            reviewAssetIndices.removeValue(forKey: previous.assetID)
            assetRequestPump.markCompleted(previous)
        }
        expectedAssetReferences = next
        expectedAssetOrder = unique
        assetRetryTracker.retain(expected: Set(unique))
    }

    private func installPresentationImages(_ presentation: SessionPresentation) {
        promptImages = presentation.prompts.reduce(into: [String: CGImage]()) { result, prompt in
            if let data = prompt.imageData, let image = Self.cgImage(from: data) {
                result[prompt.promptID] = image
            }
            if let asset = prompt.imageAsset,
               let data = cachedAsset(for: asset),
               let image = Self.cgImage(from: data) {
                result[prompt.promptID] = image
            }
        }
    }

    private func handleAssetChunk(_ chunk: BoothAssetChunk) {
        let activeSessionID = sessionMessageGate.currentSessionID
        guard chunk.metadata.sessionID == nil || chunk.metadata.sessionID == activeSessionID else { return }
        if cachedAsset(for: chunk.metadata.reference) != nil { return }
        if let expected = expectedAssetReferences[chunk.metadata.assetID] {
            guard expected == chunk.metadata.reference else { return }
        } else {
            guard chunk.metadata.sessionID == nil,
                  chunk.metadata.kind == .templatePreview else { return }
        }
        let generation = assetProcessingGeneration
        let pipeline = assetReceivePipeline
        Task { [weak self, pipeline] in
            do {
                guard let (reference, data) = try await pipeline.append(
                    chunk,
                    generation: generation
                ) else { return }
                let image = await Task.detached(priority: .userInitiated) {
                    Self.cgImage(from: data)
                }.value
                guard let self else { return }
                guard let image else {
                    await self.rejectAsset(
                        chunk.metadata.reference,
                        generation: generation
                    )
                    return
                }
                self.applyCompletedAsset(
                    reference: reference,
                    data: data,
                    image: image,
                    activeSessionID: activeSessionID,
                    generation: generation
                )
            } catch {
                guard let self else { return }
                await self.rejectAsset(
                    chunk.metadata.reference,
                    generation: generation
                )
            }
        }
    }

    private func applyCompletedAsset(
        reference: BoothAssetReference,
        data: Data,
        image: CGImage?,
        activeSessionID: String?,
        generation: UInt64
    ) {
        guard generation == assetProcessingGeneration,
              reference.sessionID == nil || reference.sessionID == activeSessionID else { return }
        if let expected = expectedAssetReferences[reference.assetID], expected != reference { return }
        if cachedAsset(for: reference) != nil { return }
        assetRequestPump.markCompleted(reference)
        assetRetryTracker.markCompleted(reference)
        receivedAssets[reference.assetID] = data
        receivedAssetReferences[reference.assetID] = reference
        cancelAssetResponseDeadline(for: reference)
        switch reference.kind {
        case .templatePreview:
            if let image { experienceAssets[reference.assetID] = image }
        case .promptImage:
            if let image {
                for prompt in sessionPresentation?.prompts ?? []
                where prompt.imageAsset?.assetID == reference.assetID {
                    promptImages[prompt.promptID] = image
                }
            }
        case .reviewImage:
            if let index = reviewAssetIndices[reference.assetID] {
                installReviewAsset(reference, photoIndex: index, data: data)
            }
        case .stripThumbnail:
            guard reference.sessionID == activeSessionID,
                  case .finished = stateMachine.phase else { break }
            stripThumbImage = image
        case .gifThumbnail:
            break
        }
        requestMissingExpectedAssets()
    }

    private func cancelAssetResponseDeadline(for reference: BoothAssetReference) {
        assetResponseDeadlines.cancel(reference)
        assetResponseDeadlineTokens.removeValue(forKey: reference)
        assetResponseDeadlineTasks.removeValue(forKey: reference)?.cancel()
    }

    private func cancelAssetResponseDeadlines() {
        assetResponseDeadlines.reset()
        assetResponseDeadlineTokens.removeAll()
        assetResponseDeadlineTasks.values.forEach { $0.cancel() }
        assetResponseDeadlineTasks.removeAll()
    }

    private func armAssetResponseDeadline(
        for references: [BoothAssetReference],
        channelGeneration: Int,
        processingGeneration: UInt64,
        sessionID: String?
    ) {
        guard !references.isEmpty else { return }
        assetResponseDeadlines.arm(references)
        for reference in references {
            nextAssetResponseDeadlineToken &+= 1
            let token = nextAssetResponseDeadlineToken
            assetResponseDeadlineTasks[reference]?.cancel()
            assetResponseDeadlineTokens[reference] = token
            assetResponseDeadlineTasks[reference] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.assetResponseDeadline))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.assetResponseDeadlineTokens[reference] == token,
                      self.assetResponseDeadlines.contains(reference) else { return }
                self.assetResponseDeadlineTokens.removeValue(forKey: reference)
                self.assetResponseDeadlines.cancel(reference)
                self.assetResponseDeadlineTasks.removeValue(forKey: reference)
                self.handleAssetResponseDeadline(
                    references: [reference],
                    channelGeneration: channelGeneration,
                    processingGeneration: processingGeneration,
                    sessionID: sessionID
                )
            }
        }
    }

    private func handleAssetResponseDeadline(
        references: [BoothAssetReference],
        channelGeneration: Int,
        processingGeneration: UInt64,
        sessionID: String?
    ) {
        guard processingGeneration == assetProcessingGeneration,
              sessionMessageGate.currentSessionID == sessionID,
              assetRetryTracker.currentGeneration == channelGeneration else { return }
        let missing = missingExpectedAssets()
        let timedOut = references.filter {
            missing.contains($0) && assetRequestPump.inFlight.contains($0)
        }
        guard !timedOut.isEmpty else { return }
        assetRequestPump.markSendFailed(timedOut)
        handleAssetFailure(timedOut, channelGeneration: channelGeneration)
    }

    private func handleAssetFailure(
        _ references: [BoothAssetReference],
        channelGeneration: Int
    ) {
        var canRetryAll = true
        for reference in references {
            canRetryAll = assetRetryTracker.recordFailure(
                reference,
                generation: channelGeneration
            ) && canRetryAll
        }
        if canRetryAll {
            assetRecoveryStatus = .restoring
            requestMissingExpectedAssets()
            return
        }

        let canRecycle = references.contains {
            assetRetryTracker.shouldRecycleCurrentGeneration($0)
        }
        guard canRecycle else {
            assetRecoveryStatus = .operatorRecoveryRequired
            sessionRequestError = nil
            return
        }
        assetRecoveryStatus = .reconnectRequired
        guard lastAssetRecycleGeneration != channelGeneration else { return }
        lastAssetRecycleGeneration = channelGeneration
        guard networkTransport != nil else {
            assetRecoveryStatus = .operatorRecoveryRequired
            return
        }
        multipeer.recycleAssetChannel()
    }

    private func rejectAsset(_ reference: BoothAssetReference, generation: UInt64) async {
        guard generation == assetProcessingGeneration,
              reference.sessionID == nil || reference.sessionID == sessionMessageGate.currentSessionID else { return }
        await assetReceivePipeline.resetCurrent(generation: generation)
        guard generation == assetProcessingGeneration,
              reference.sessionID == nil || reference.sessionID == sessionMessageGate.currentSessionID else { return }
        // ponytail: the assembler is generation-scoped; replay every in-flight reference after a reset. Split per-reference assemblers only if concurrent asset memory is measured as a bottleneck.
        cancelAssetResponseDeadlines()
        assetRequestPump.clearInFlight()
        receivedAssets.removeValue(forKey: reference.assetID)
        receivedAssetReferences.removeValue(forKey: reference.assetID)
        let channelGeneration = assetRetryTracker.currentGeneration ?? 0
        handleAssetFailure([reference], channelGeneration: channelGeneration)
    }

    private func installReviewAsset(
        _ reference: BoothAssetReference,
        photoIndex: Int,
        data: Data
    ) {
        guard reference.sessionID == sessionMessageGate.currentSessionID,
              let currentSessionID = sessionMessageGate.currentSessionID else { return }
        let phase: BoothPhase
        switch stateMachine.phase {
        case .captured(let index) where index == photoIndex,
             .review(let index) where index == photoIndex:
            phase = .review(photoIndex: photoIndex)
        default:
            return
        }
        var keptShots = stateMachine.keptShots
        keptShots[photoIndex] = ReviewImageEncoder.thumbnailData(from: data) ?? data
        stateMachine.applyAuthoritativeSnapshot(
            sessionID: currentSessionID,
            config: eventConfig,
            phase: phase,
            keptShots: keptShots,
            reviewImageData: data,
            nextPhotoIndex: stateMachine.nextPhotoIndex,
            countdownDeadline: nil,
            acceptedPhotoIndices: stateMachine.acceptedPhotoIndices,
            deferredPhotoIndices: stateMachine.deferredPhotoIndices
        )
    }

    private func applySessionSync(_ snapshot: SessionSyncSnapshot) {
        clearTransientRequestState()
        let previousSessionID = sessionMessageGate.currentSessionID
        if previousSessionID != snapshot.sessionID || snapshot.sessionID == nil {
            clearSessionMedia()
        }
        cancelCountdown()
        sessionMessageGate.synchronize(sessionID: snapshot.sessionID, sequence: snapshot.sequence)
        eventConfig = snapshot.config
        stateMachine.config = snapshot.config
        selectedLanguage = snapshot.presentation?.language ?? snapshot.config.customerLanguage
        sessionPresentation = snapshot.presentation
        resetAssetProcessing()
        requestMissingAssets(for: snapshot)
        if let presentation = snapshot.presentation { installPresentationImages(presentation) }
        isMirrored = snapshot.isMirrored
        isBoothPaused = snapshot.isBoothPaused
        guard let sessionID = snapshot.sessionID else {
            stateMachine.reset()
            return
        }
        var keptShots = snapshot.keptShots
        var reviewImageData: Data?
        if case .review(let index) = snapshot.phase {
            if let reviewAsset = snapshot.reviewAsset {
                reviewAssetIndices[reviewAsset.assetID] = index
                if let data = cachedAsset(for: reviewAsset) {
                    reviewImageData = data
                    keptShots[index] = ReviewImageEncoder.thumbnailData(from: data) ?? data
                }
            } else if let data = snapshot.reviewThumbnailData {
                reviewImageData = data
                keptShots[index] = ReviewImageEncoder.thumbnailData(from: data) ?? data
            }
        }
        for (index, reference) in snapshot.keptShotAssets {
            if let data = cachedAsset(for: reference) {
                keptShots[index] = ReviewImageEncoder.thumbnailData(from: data) ?? data
            }
        }
        stateMachine.applyAuthoritativeSnapshot(
            sessionID: sessionID,
            config: snapshot.config,
            phase: snapshot.phase,
            keptShots: keptShots,
            reviewImageData: reviewImageData,
            nextPhotoIndex: snapshot.nextPhotoIndex,
            countdownDeadline: snapshot.countdown?.captureAt,
            acceptedPhotoIndices: Set(snapshot.acceptedPhotoIndices),
            deferredPhotoIndices: Set(snapshot.deferredPhotoIndices)
        )
        if case .finished = snapshot.phase {
            stripThumbImage = nil
            if let stripAsset = snapshot.stripAsset,
               let data = cachedAsset(for: stripAsset) {
                stripThumbImage = Self.cgImage(from: data)
            } else if let data = snapshot.stripThumbnailData {
                stripThumbImage = Self.cgImage(from: data)
            }
        }
        if let presentation = snapshot.presentation { installPresentationImages(presentation) }
        if let reviewAsset = snapshot.reviewAsset,
           let index = reviewAssetIndices[reviewAsset.assetID],
           let data = cachedAsset(for: reviewAsset) {
            installReviewAsset(reviewAsset, photoIndex: index, data: data)
        }
        if let countdown = snapshot.countdown {
            runCountdown(countdown)
        }
    }

    private func runCountdown(_ descriptor: CountdownDescriptor) {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                stateMachine.updateCountdown(at: Date())
                guard descriptor.captureAt > Date() else {
                    countdownTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func updatePreview(_ jpegData: Data) {
        if pendingPreviewJPEG != nil, previewDecodeTask != nil {
#if DEBUG
            previewFramesCoalesced += 1
#endif
        }
        pendingPreviewJPEG = jpegData
        lastPreviewFrameAt = Date()
#if DEBUG
        previewFramesReceived += 1
#endif
        guard previewDecodeTask == nil else { return }

        previewDecodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.previewDecodeTask = nil }
            while let jpeg = self.pendingPreviewJPEG {
                self.pendingPreviewJPEG = nil
                let image = await Task.detached(priority: .userInitiated) {
                    Self.cgImage(from: jpeg)
                }.value
                guard !Task.isCancelled else { return }
                if let image {
                    self.latestPreviewImage = image
#if DEBUG
                    self.previewFramesDisplayed += 1
#endif
                }
            }
            self.logPreviewMetricsIfNeeded()
        }
    }

    private func startPreviewStaleMonitor() {
        previewStaleTask?.cancel()
        previewStaleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard let lastPreviewFrameAt = self.lastPreviewFrameAt,
                      Date().timeIntervalSince(lastPreviewFrameAt) > 3 else { continue }
                self.lastPreviewFrameAt = nil
                self.latestPreviewImage = nil
            }
        }
    }

    private func logPreviewMetricsIfNeeded() {
#if DEBUG
        let now = Date()
        guard now.timeIntervalSince(previewMetricsStartedAt) >= 2 else { return }
        NSLog(
            "[iPad] Preview state=%@ received=%d coalesced=%d displayed=%d",
            String(describing: multipeer.connectionState),
            previewFramesReceived,
            previewFramesCoalesced,
            previewFramesDisplayed
        )
        previewMetricsStartedAt = now
        previewFramesReceived = 0
        previewFramesCoalesced = 0
        previewFramesDisplayed = 0
#endif
    }

    private nonisolated static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Customer decisions

    func customerTappedToBegin() {
        guard CustomerDisplayWorkflow.canApply(.begin, in: stateMachine.phase) else { return }
        if requiresExperienceSelection {
            beginExperienceSelection()
        } else {
            applyCatalogDefaults(preserveLanguage: false)
            requestMacToStartSession()
        }
    }

    func customerTappedStart() {
        guard !isSessionRequestPending,
              CustomerDisplayWorkflow.canApply(.start, in: stateMachine.phase) else { return }
        requestMacToStartSession()
    }

    private func requestMacToStartSession() {
        guard !isSessionRequestPending else { return }
#if DEBUG
        if demoKioskMode {
            DemoKioskDriver.startSession(on: self)
            return
        }
#endif
        guard let catalog = experienceCatalog else {
            let generation = beginTransientRequest()
            isSessionRequestPending = true
            multipeer.sendControl(.sessionStart(context: nil)) { [weak self] outcome in
                guard let self,
                      self.transientRequestGeneration == generation,
                      outcome != .sent else { return }
                self.isSessionRequestPending = false
                self.setSessionRequestError("The booth is not connected. Please try again.")
            }
            armSessionRequestTimeout(generation: generation)
            return
        }
        guard let templateID = selectedTemplateID,
              let filterID = selectedFilterID else {
            beginExperienceSelection()
            return
        }
        let selection = CustomerSessionSelection(
            eventID: catalog.eventID,
            experienceRevision: catalog.revision,
            templateID: templateID,
            filterID: filterID,
            language: selectedLanguage
        )
        let generation = beginTransientRequest()
        isSessionRequestPending = true
        multipeer.sendControl(.customerSessionRequest(selection: selection)) { [weak self] outcome in
            guard let self,
                  self.transientRequestGeneration == generation,
                  outcome != .sent else { return }
            self.isSessionRequestPending = false
            self.setSessionRequestError("The booth is not connected. Please try again.")
        }
        armSessionRequestTimeout(generation: generation)
    }

    private func armSessionRequestTimeout(generation: UInt64) {
        sessionRequestTimeoutTask?.cancel()
        sessionRequestTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.transientRequestGeneration == generation,
                  self.isSessionRequestPending else { return }
            self.sessionRequestTimeoutTask = nil
            self.isSessionRequestPending = false
            self.setSessionRequestError(LocalizedText(
                english: "The operator did not respond. Please try again.",
                thai: "ผู้ควบคุมไม่ตอบสนอง กรุณาลองอีกครั้ง"
            ).value(for: self.selectedLanguage))
        }
    }

    var requiresExperienceSelection: Bool {
        guard let catalog = experienceCatalog else { return false }
        return (catalog.templates.count > 1 && catalog.guestTemplateSelectionEnabled)
            || (catalog.allowedFilterIDs.count > 1 && catalog.guestFilterSelectionEnabled)
            || catalog.guestLanguageSelectionEnabled
    }

    func beginExperienceSelection() {
        guard experienceCatalog != nil else { return }
        applyCatalogDefaults(preserveLanguage: true)
        stateMachine.beginSelectingExperience()
    }

    func selectTemplate(_ id: String) {
        guard experienceCatalog?.templates.contains(where: { $0.id == id }) == true else { return }
        selectedTemplateID = id
    }

    func selectFilter(_ filter: PhotoFilterID) {
        guard experienceCatalog?.allowedFilterIDs.contains(filter) == true else { return }
        selectedFilterID = filter
    }

    func selectLanguage(_ language: CustomerLanguage) {
        guard experienceCatalog?.guestLanguageSelectionEnabled == true || language == experienceCatalog?.defaultLanguage else { return }
        selectedLanguage = language
    }

    func confirmExperienceSelection() {
        guard CustomerDisplayWorkflow.canApply(.confirmSelection, in: stateMachine.phase),
              let catalog = experienceCatalog,
              let templateID = selectedTemplateID,
              let filterID = selectedFilterID,
              catalog.templates.contains(where: { $0.id == templateID }),
              catalog.allowedFilterIDs.contains(filterID) else { return }
        let option = catalog.templates.first { $0.id == templateID }
        eventConfig = EventConfig(
            eventID: catalog.eventID,
            eventName: catalog.eventName,
            photoCount: option?.photoCount ?? eventConfig.photoCount,
            countdownSeconds: eventConfig.countdownSeconds,
            canvasWidth: eventConfig.canvasWidth,
            canvasHeight: eventConfig.canvasHeight,
            slots: eventConfig.slots,
            templateID: templateID,
            templateName: option?.name ?? LocalizedText(),
            selectedFilterID: filterID,
            customerLanguage: selectedLanguage,
            gifQualityPreset: eventConfig.gifQualityPreset
        )
#if DEBUG
        if demoKioskMode {
            stateMachine.startSession(config: eventConfig)
            return
        }
#endif
        requestMacToStartSession()
    }

    func returnToExperienceSelection() {
        guard CustomerDisplayWorkflow.canApply(.back, in: stateMachine.phase) else { return }
        beginExperienceSelection()
    }

    func currentPrompt(for photoIndex: Int) -> SessionPromptPresentation? {
        sessionPresentation?.prompts.first { $0.photoIndex == photoIndex }
    }

    func captureFraming(for photoIndex: Int) -> CaptureFramingGeometry? {
        CaptureFramingGeometry.framing(for: photoIndex, in: eventConfig)
    }

    private func applyCatalogDefaults(preserveLanguage: Bool) {
        guard let catalog = experienceCatalog else { return }
        if selectedTemplateID == nil || !catalog.templates.contains(where: { $0.id == selectedTemplateID }) {
            selectedTemplateID = catalog.templates.contains(where: { $0.id == catalog.defaultTemplateID })
                ? catalog.defaultTemplateID
                : catalog.templates.first?.id
        }
        if selectedFilterID == nil || !catalog.allowedFilterIDs.contains(selectedFilterID!) {
            selectedFilterID = catalog.defaultFilterID
        }
        if !preserveLanguage || !catalog.guestLanguageSelectionEnabled {
            selectedLanguage = catalog.defaultLanguage
        }
    }

    private func armReviewDecisionTimeout(generation: UInt64) {
        reviewDecisionTimeoutTask?.cancel()
        reviewDecisionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.transientRequestGeneration == generation,
                  self.reviewDecisionPending else { return }
            self.reviewDecisionTimeoutTask = nil
            self.reviewDecisionPending = false
            self.setSessionRequestError("The booth did not confirm that choice. Please try again.")
        }
    }

    private func armRecoveryActionTimeout(generation: UInt64) {
        recoveryActionTimeoutTask?.cancel()
        recoveryActionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.transientRequestGeneration == generation,
                  self.recoveryActionPending else { return }
            self.recoveryActionTimeoutTask = nil
            self.recoveryActionPending = false
            self.setSessionRequestError("The booth did not confirm that recovery choice. Please try again.")
        }
    }

    private func armFinishRequestTimeout(generation: UInt64) {
        finishRequestTimeoutTask?.cancel()
        finishRequestTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.transientRequestGeneration == generation,
                  self.finishRequestPending else { return }
            self.finishRequestTimeoutTask = nil
            self.finishRequestPending = false
            self.setSessionRequestError("The booth did not confirm the next session. Please try again.")
        }
    }

    func customerKeep(photoIndex: Int) {
        guard CustomerDisplayWorkflow.canUseReviewActions(
                  in: stateMachine.phase,
                  reviewMediaReady: isReviewMediaReady
              ),
              !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(.keep(photoIndex: photoIndex), in: stateMachine.phase) else { return }
#if DEBUG
        if demoKioskMode {
            demoAdvance(afterKeeping: photoIndex)
            return
        }
#endif
        guard let context = currentSessionMessageContext else { return }
        let generation = beginTransientRequest()
        reviewDecisionPending = true
        cancelCountdown()
        multipeer.sendControl(.reviewDecision(context: context, action: .keep)) { [weak self] outcome in
            guard let self,
                  self.transientRequestGeneration == generation,
                  outcome != .sent else { return }
            self.reviewDecisionPending = false
            self.setSessionRequestError("The booth did not receive that choice. Please try again.")
        }
        guard reviewDecisionPending else { return }
        armReviewDecisionTimeout(generation: generation)
    }

    func customerRetake(photoIndex: Int) {
        guard CustomerDisplayWorkflow.canUseReviewActions(
                  in: stateMachine.phase,
                  reviewMediaReady: isReviewMediaReady
              ),
              !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(.retake(photoIndex: photoIndex), in: stateMachine.phase) else { return }
#if DEBUG
        if demoKioskMode {
            stateMachine.retakeShot(photoIndex: photoIndex)
            scheduleDemoShot(photoIndex: photoIndex)
            return
        }
#endif
        guard let context = currentSessionMessageContext else { return }
        let generation = beginTransientRequest()
        reviewDecisionPending = true
        cancelCountdown()
        multipeer.sendControl(.reviewDecision(context: context, action: .retake)) { [weak self] outcome in
            guard let self,
                  self.transientRequestGeneration == generation,
                  outcome != .sent else { return }
            self.reviewDecisionPending = false
            self.setSessionRequestError("The booth did not receive that choice. Please try again.")
        }
        guard reviewDecisionPending else { return }
        armReviewDecisionTimeout(generation: generation)
    }

    func customerRetryReceive(photoIndex: Int) {
        sendCaptureRecovery(.retryReceive(photoIndex: photoIndex))
    }

    func customerRetakeFailedCapture(photoIndex: Int) {
        sendCaptureRecovery(.retake(photoIndex: photoIndex))
    }

    func customerContinueAfterCaptureFailure(photoIndex: Int) {
        sendCaptureRecovery(.continueSession(photoIndex: photoIndex))
    }

    func customerUsePreviousCapture(photoIndex: Int) {
        sendCaptureRecovery(.usePrevious(photoIndex: photoIndex))
    }

    private func sendCaptureRecovery(_ action: CaptureRecoveryAction) {
        guard !recoveryActionPending else { return }
        let customerAction: CustomerDisplayAction
        switch action {
        case .retryReceive(let index): customerAction = .retryReceive(photoIndex: index)
        case .retake(let index): customerAction = .retakeFailedCapture(photoIndex: index)
        case .continueSession(let index): customerAction = .continueAfterCaptureFailure(photoIndex: index)
        case .usePrevious(let index): customerAction = .usePreviousCapture(photoIndex: index)
        }
        guard CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else { return }
        guard let context = currentSessionMessageContext else { return }
        let generation = beginTransientRequest()
        recoveryActionPending = true
        multipeer.sendControl(.captureRecoveryAction(context: context, action: action)) { [weak self] outcome in
            guard let self,
                  self.transientRequestGeneration == generation,
                  outcome != .sent else { return }
            self.recoveryActionPending = false
            self.setSessionRequestError("The booth did not receive that recovery choice. Please try again.")
        }
        guard recoveryActionPending else { return }
        armRecoveryActionTimeout(generation: generation)
    }

    func customerDone() {
        guard !finishRequestPending, case .finished = stateMachine.phase,
              let context = currentSessionMessageContext else { return }
        cancelCountdown()
        let generation = beginTransientRequest()
        finishRequestPending = true
        multipeer.sendControl(.customerFinished(context: context)) { [weak self] outcome in
            guard let self,
                  self.transientRequestGeneration == generation,
                  outcome != .sent else { return }
            self.finishRequestPending = false
            self.setSessionRequestError("The booth did not receive the next-session request. Please try again.")
        }
        guard finishRequestPending else { return }
        armFinishRequestTimeout(generation: generation)
    }

#if DEBUG
    func demoPrepareSession(config: EventConfig, presentation: SessionPresentation) {
        eventConfig = config
        sessionPresentation = presentation
        promptImages = [:]
        stateMachine.startSession(config: config, sessionID: presentation.sessionID)
        selectedLanguage = presentation.language
        scheduleDemoShot(photoIndex: 0)
    }

    private func scheduleDemoShot(photoIndex: Int) {
        let descriptor = CountdownDescriptor(
            photoIndex: photoIndex,
            captureAt: Date().addingTimeInterval(TimeInterval(eventConfig.countdownSeconds))
        )
        stateMachine.beginCountdown(photoIndex: photoIndex, captureAt: descriptor.captureAt)
        runCountdown(descriptor)
        Task { @MainActor [weak self] in
            let nanos = UInt64(max(0, descriptor.captureAt.timeIntervalSinceNow) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self,
                  case .countdown(let currentIndex, _) = self.stateMachine.phase,
                  currentIndex == photoIndex else { return }
            guard let sample = FilterSampleRenderer.makeSampleImage(),
                  let filtered = try? await PhotoFilterPipeline().apply(self.eventConfig.selectedFilterID, to: sample),
                  let data = jpegDataForDemo(filtered) else { return }
            self.reviewDecisionPending = false
            self.stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: data)
        }
    }

    private func demoAdvance(afterKeeping photoIndex: Int) {
        stateMachine.keepShot(photoIndex: photoIndex)
        if photoIndex + 1 < eventConfig.photoCount {
            scheduleDemoShot(photoIndex: photoIndex + 1)
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.stateMachine.finishSession(qrPayload: "demo://session/\(UUID().uuidString)")
            }
        }
    }
#endif

}

enum BoothAssetRetryPolicy {
    static let maximumAutomaticRetries = 2
    static let maximumRecoveryGenerations = 2

    static func shouldRetry(after failureCount: Int) -> Bool {
        failureCount < maximumAutomaticRetries
    }
}

enum BoothAssetRecoveryStatus: Equatable {
    case idle
    case restoring
    case connectionRecovered
    case reconnectRequired
    case operatorRecoveryRequired

    func title(for language: CustomerLanguage) -> String {
        switch self {
        case .idle: return ""
        case .restoring: return LocalizedText(
            english: "Restoring photo…",
            thai: "กำลังกู้คืนรูปภาพ…"
        ).value(for: language)
        case .connectionRecovered: return LocalizedText(
            english: "Connection recovered. Retrying image.",
            thai: "เชื่อมต่อแล้ว กำลังลองกู้คืนรูปภาพอีกครั้ง"
        ).value(for: language)
        case .reconnectRequired, .operatorRecoveryRequired: return LocalizedText(
            english: "Photo couldn't be restored.",
            thai: "ไม่สามารถกู้คืนรูปภาพได้"
        ).value(for: language)
        }
    }

    func detail(for language: CustomerLanguage) -> String? {
        switch self {
        case .idle, .restoring, .connectionRecovered:
            return nil
        case .reconnectRequired:
            return LocalizedText(
                english: "Reconnect to retry the image.",
                thai: "เชื่อมต่อใหม่เพื่อลองกู้คืนรูปภาพอีกครั้ง"
            ).value(for: language)
        case .operatorRecoveryRequired:
            return LocalizedText(
                english: "Please ask the operator to restart recovery for this session.",
                thai: "โปรดขอให้เจ้าหน้าที่เริ่มการกู้คืนสำหรับเซสชันนี้อีกครั้ง"
            ).value(for: language)
        }
    }
}

enum BoothAssetRetryGenerationTransition: Equatable {
    case initial
    case advanced
    case duplicate
    case stale
}

struct BoothAssetRetryState: Equatable, Sendable {
    let generation: Int
    let attemptsInGeneration: Int
    let recoveryGenerationsUsed: Int
}

struct BoothAssetRetryTracker: Sendable {
    private(set) var currentGeneration: Int?
    private var states: [BoothAssetReference: BoothAssetRetryState] = [:]

    mutating func activate(
        generation: Int,
        missing: Set<BoothAssetReference>
    ) -> BoothAssetRetryGenerationTransition {
        if let currentGeneration {
            if generation < currentGeneration { return .stale }
            if generation == currentGeneration { return .duplicate }
        }

        let transition: BoothAssetRetryGenerationTransition = currentGeneration == nil
            ? .initial
            : .advanced
        currentGeneration = generation

        for reference in missing {
            guard let previous = states[reference] else { continue }
            let recoveryCount = previous.recoveryGenerationsUsed
            guard recoveryCount < BoothAssetRetryPolicy.maximumRecoveryGenerations else {
                states[reference] = BoothAssetRetryState(
                    generation: generation,
                    attemptsInGeneration: BoothAssetRetryPolicy.maximumAutomaticRetries + 1,
                    recoveryGenerationsUsed: recoveryCount
                )
                continue
            }
            states[reference] = BoothAssetRetryState(
                generation: generation,
                attemptsInGeneration: 0,
                recoveryGenerationsUsed: recoveryCount + 1
            )
        }
        return transition
    }

    func acceptsDisconnect(generation: Int?) -> Bool {
        guard let generation, let currentGeneration else { return true }
        return generation >= currentGeneration
    }

    func canRequest(_ reference: BoothAssetReference) -> Bool {
        guard let state = states[reference] else { return true }
        guard let currentGeneration, state.generation == currentGeneration else { return false }
        return state.attemptsInGeneration <= BoothAssetRetryPolicy.maximumAutomaticRetries
    }

    mutating func recordFailure(
        _ reference: BoothAssetReference,
        generation: Int
    ) -> Bool {
        if currentGeneration == nil { currentGeneration = generation }
        guard currentGeneration == generation else { return false }

        let previous = states[reference] ?? BoothAssetRetryState(
            generation: generation,
            attemptsInGeneration: 0,
            recoveryGenerationsUsed: 0
        )
        guard previous.generation == generation else { return false }
        let attempts = min(
            previous.attemptsInGeneration + 1,
            BoothAssetRetryPolicy.maximumAutomaticRetries + 1
        )
        states[reference] = BoothAssetRetryState(
            generation: generation,
            attemptsInGeneration: attempts,
            recoveryGenerationsUsed: previous.recoveryGenerationsUsed
        )
        return attempts <= BoothAssetRetryPolicy.maximumAutomaticRetries
    }

    mutating func markCompleted(_ reference: BoothAssetReference) {
        states.removeValue(forKey: reference)
    }

    mutating func remove(_ reference: BoothAssetReference) {
        states.removeValue(forKey: reference)
    }

    mutating func retain(expected: Set<BoothAssetReference>) {
        states = states.filter { expected.contains($0.key) }
    }

    mutating func resetForSession() {
        currentGeneration = nil
        states.removeAll()
    }

    func state(for reference: BoothAssetReference) -> BoothAssetRetryState? {
        states[reference]
    }

    func shouldRecycleCurrentGeneration(_ reference: BoothAssetReference) -> Bool {
        guard let currentGeneration,
              let state = states[reference],
              state.generation == currentGeneration,
              state.attemptsInGeneration > BoothAssetRetryPolicy.maximumAutomaticRetries else {
            return false
        }
        return state.recoveryGenerationsUsed < BoothAssetRetryPolicy.maximumRecoveryGenerations
    }
}

struct BoothAssetResponseDeadlineRegistry: Equatable, Sendable {
    private(set) var pending: Set<BoothAssetReference> = []

    mutating func arm(_ references: [BoothAssetReference]) {
        pending.formUnion(references)
    }

    mutating func cancel(_ reference: BoothAssetReference) {
        pending.remove(reference)
    }

    func contains(_ reference: BoothAssetReference) -> Bool {
        pending.contains(reference)
    }

    mutating func reset() {
        pending.removeAll()
    }
}

actor BoothAssetReceivePipeline {
    private var assembler = BoothAssetAssembler()
    private var generation: UInt64 = 0

    func reset(to generation: UInt64) {
        guard generation > self.generation else { return }
        self.generation = generation
        assembler = BoothAssetAssembler()
    }

    func resetCurrent(generation: UInt64) {
        guard generation == self.generation else { return }
        assembler = BoothAssetAssembler()
    }

    func append(
        _ chunk: BoothAssetChunk,
        generation: UInt64
    ) throws -> (BoothAssetReference, Data)? {
        guard generation >= self.generation else { return nil }
        if generation > self.generation {
            self.generation = generation
            assembler = BoothAssetAssembler()
        }
        return try assembler.append(chunk)
    }
}
