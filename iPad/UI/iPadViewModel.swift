import Foundation
import Combine
import CoreImage
import CoreGraphics
import SwiftUI

// iPad-side coordinator — receives messages from Mac, drives local UI state.
@MainActor
final class iPadViewModel: ObservableObject {
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
    private var countdownTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var sessionMessageGate = SessionMessageGate()
    private var assetAssembler = BoothAssetAssembler()
    private var receivedAssets: [String: Data] = [:]
    private var reviewAssetIndices: [String: Int] = [:]
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
        guard isBoothSessionActive, !isConnectionReady else { return false }
#if DEBUG
        if demoKioskMode { return false }
#endif
        return true
    }
    var isConnectionReady: Bool {
        guard case .connected = connectionStatus.state else { return false }
        guard networkTransport != nil else { return true }
        let isFresh = connectionStatus.lastControlActivityAt.map {
            Date().timeIntervalSince($0) < 10
        } ?? false
        return connectionStatus.isPeerAuthenticated
            && connectionStatus.isPreviewChannelConnected
            && isFresh
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
            latestPreviewImage = nil
            pendingPreviewJPEG = nil
            lastPreviewFrameAt = nil
        }
        guard phase == .active, !isConnectionReady, connectionRecoveryTask == nil else { return }
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
        case .hello(let role) where role == .mac:
            multipeer.sendControl(.hello(role: .iPad))

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
            isSessionRequestPending = false
            reviewDecisionPending = false
            recoveryActionPending = false
            finishRequestPending = false
            sessionRequestTimeoutTask?.cancel()
            stateMachine.startSession(config: eventConfig, sessionID: context.sessionID)

        case .sessionRequestRejected(let reason):
            cancelCountdown()
            isSessionRequestPending = false
            reviewDecisionPending = false
            recoveryActionPending = false
            sessionRequestTimeoutTask?.cancel()
            sessionRequestError = reason
            stateMachine.beginSelectingExperience()

        case .sessionPrepared(let config, let presentation, let context):
            guard acceptSessionChange(context, message: "sessionPrepared") else { break }
            cancelCountdown()
            clearSessionMedia()
            isSessionRequestPending = false
            reviewDecisionPending = false
            recoveryActionPending = false
            finishRequestPending = false
            sessionRequestTimeoutTask?.cancel()
            eventConfig = config
            stateMachine.startSession(config: config, sessionID: presentation.sessionID)
            sessionPresentation = presentation
            selectedLanguage = presentation.language
            installPresentationImages(presentation)

        case .beginCountdown(let context, let descriptor):
            guard accept(context, message: "beginCountdown") else { break }
            recoveryActionPending = false
            reviewDecisionPending = false
            recoveryActionTimeoutTask?.cancel()
            reviewDecisionTimeoutTask?.cancel()
            stateMachine.applyAuthoritativePhase(
                .countdown(photoIndex: descriptor.photoIndex, secondsRemaining: max(0, Int(ceil(descriptor.captureAt.timeIntervalSinceNow)))),
                countdownDeadline: descriptor.captureAt
            )
            runCountdown(descriptor)

        case .shotCaptured(let context, let index, let thumbData):
            guard accept(context, message: "shotCaptured") else { break }
            cancelCountdown()
            recoveryActionPending = false
            reviewDecisionPending = false
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
            recoveryActionPending = false
            reviewDecisionPending = false
            reviewAssetIndices[asset.assetID] = index
            stateMachine.applyAuthoritativePhase(.captured(photoIndex: index))
            if let data = receivedAssets[asset.assetID] {
                installReviewAsset(asset, photoIndex: index, data: data)
            }

        case .captureRecovery(let context, let index, let failure):
            guard accept(context, message: "captureRecovery") else { break }
            cancelCountdown()
            recoveryActionPending = false
            recoveryActionTimeoutTask?.cancel()
            reviewDecisionPending = false
            stateMachine.applyAuthoritativePhase(.captureRecovery(photoIndex: index, failure: failure))

        case .reviewDecision(let context, let action):
            guard accept(context, message: "reviewDecision") else { break }
            guard case .review(let idx) = stateMachine.phase else { break }
            let customerAction: CustomerDisplayAction = action == .keep
                ? .keep(photoIndex: idx)
                : .retake(photoIndex: idx)
            guard CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else { break }
            reviewDecisionPending = false
            reviewDecisionTimeoutTask?.cancel()
            switch action {
            case .keep: stateMachine.keepShot(photoIndex: idx)
            case .retake: stateMachine.retakeShot(photoIndex: idx)
            }

        case .sessionFinished(let context, let qr, let stripData, _):
            guard accept(context, message: "sessionFinished") else { break }
            cancelCountdown()
            recoveryActionPending = false
            reviewDecisionPending = false
            finishRequestPending = false
            finishRequestTimeoutTask?.cancel()
            stripThumbImage = stripData.flatMap(Self.cgImage(from:))
            stateMachine.applyAuthoritativePhase(.finished(qrPayload: qr))

        case .sessionFinishedAssets(let context, let qr, let stripAsset, _):
            guard accept(context, message: "sessionFinishedAssets") else { break }
            cancelCountdown()
            recoveryActionPending = false
            reviewDecisionPending = false
            finishRequestPending = false
            finishRequestTimeoutTask?.cancel()
            stripThumbImage = nil
            if let stripAsset, let data = receivedAssets[stripAsset.assetID] {
                stripThumbImage = Self.cgImage(from: data)
            }
            stateMachine.applyAuthoritativePhase(.finished(qrPayload: qr))

        case .operatorOverride(let context, let action):
            if let context {
                guard accept(context, message: "operatorOverride") else { break }
            } else if !stateMachine.currentSessionID.isEmpty {
                break
            }
            if case .cancelSession = action { cancelCountdown() }
            stateMachine.operatorOverride(action)

        default: break
        }
    }

    private func clearSessionMedia() {
        previewDecodeTask?.cancel()
        pendingPreviewJPEG = nil
        lastPreviewFrameAt = nil
        latestPreviewImage = nil
        sessionPresentation = nil
        promptImages = [:]
        stripThumbImage = nil
        receivedAssets = [:]
        reviewAssetIndices = [:]
        assetAssembler = BoothAssetAssembler()
        reviewDecisionTimeoutTask?.cancel()
        recoveryActionTimeoutTask?.cancel()
    }

    private func installPresentationImages(_ presentation: SessionPresentation) {
        promptImages = presentation.prompts.reduce(into: [String: CGImage]()) { result, prompt in
            if let data = prompt.imageData, let image = Self.cgImage(from: data) {
                result[prompt.promptID] = image
            }
            if let asset = prompt.imageAsset,
               let data = receivedAssets[asset.assetID],
               let image = Self.cgImage(from: data) {
                result[prompt.promptID] = image
            }
        }
    }

    private func handleAssetChunk(_ chunk: BoothAssetChunk) {
        let activeSessionID = sessionMessageGate.currentSessionID
        guard chunk.metadata.sessionID == nil || chunk.metadata.sessionID == activeSessionID else { return }
        do {
            guard let (reference, data) = try assetAssembler.append(chunk) else { return }
            receivedAssets[reference.assetID] = data
            switch reference.kind {
            case .templatePreview:
                if let image = Self.cgImage(from: data) { experienceAssets[reference.assetID] = image }
            case .promptImage:
                if let presentation = sessionPresentation { installPresentationImages(presentation) }
            case .reviewImage:
                if let index = reviewAssetIndices[reference.assetID] {
                    installReviewAsset(reference, photoIndex: index, data: data)
                }
            case .stripThumbnail:
                guard reference.sessionID == activeSessionID,
                      case .finished = stateMachine.phase else { break }
                stripThumbImage = Self.cgImage(from: data)
            case .gifThumbnail:
                break
            }
        } catch {
            receivedAssets.removeValue(forKey: chunk.metadata.assetID)
            sessionRequestError = "An asset could not be received. Please reconnect."
        }
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
        if let presentation = snapshot.presentation { installPresentationImages(presentation) }
        isMirrored = snapshot.isMirrored
        isBoothPaused = snapshot.isBoothPaused
        recoveryActionPending = false
        reviewDecisionPending = false
        finishRequestPending = false
        finishRequestTimeoutTask?.cancel()
        guard let sessionID = snapshot.sessionID else {
            stateMachine.reset()
            return
        }
        var keptShots = snapshot.keptShots
        var reviewImageData: Data?
        if case .review(let index) = snapshot.phase {
            if let reviewAsset = snapshot.reviewAsset {
                reviewAssetIndices[reviewAsset.assetID] = index
                if let data = receivedAssets[reviewAsset.assetID] {
                    reviewImageData = data
                    keptShots[index] = ReviewImageEncoder.thumbnailData(from: data) ?? data
                }
            } else if let data = snapshot.reviewThumbnailData {
                reviewImageData = data
                keptShots[index] = ReviewImageEncoder.thumbnailData(from: data) ?? data
            }
        }
        for (index, reference) in snapshot.keptShotAssets {
            if let data = receivedAssets[reference.assetID] {
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
               let data = receivedAssets[stripAsset.assetID] {
                stripThumbImage = Self.cgImage(from: data)
            } else if let data = snapshot.stripThumbnailData {
                stripThumbImage = Self.cgImage(from: data)
            }
        }
        if let presentation = snapshot.presentation { installPresentationImages(presentation) }
        if let reviewAsset = snapshot.reviewAsset,
           let index = reviewAssetIndices[reviewAsset.assetID],
           let data = receivedAssets[reviewAsset.assetID] {
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
        sessionRequestError = nil
        if requiresExperienceSelection {
            beginExperienceSelection()
        } else {
            applyCatalogDefaults(preserveLanguage: false)
            stateMachine.startSession(config: eventConfig)
        }
    }

    func customerTappedStart() {
        guard !isSessionRequestPending,
              CustomerDisplayWorkflow.canApply(.start, in: stateMachine.phase) else { return }
#if DEBUG
        if demoKioskMode {
            DemoKioskDriver.startSession(on: self)
            return
        }
#endif
        guard let catalog = experienceCatalog else {
            isSessionRequestPending = true
            multipeer.sendControl(.sessionStart(context: nil)) { [weak self] outcome in
                guard let self, outcome != .sent else { return }
                self.isSessionRequestPending = false
                self.sessionRequestError = "The booth is not connected. Please try again."
            }
            armSessionRequestTimeout()
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
        isSessionRequestPending = true
        sessionRequestError = nil
        multipeer.sendControl(.customerSessionRequest(selection: selection)) { [weak self] outcome in
            guard let self, outcome != .sent else { return }
            self.isSessionRequestPending = false
            self.sessionRequestError = "The booth is not connected. Please try again."
        }
        armSessionRequestTimeout()
    }

    private func armSessionRequestTimeout() {
        sessionRequestTimeoutTask?.cancel()
        sessionRequestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.isSessionRequestPending else { return }
            self.isSessionRequestPending = false
            self.sessionRequestError = LocalizedText(
                english: "The operator did not respond. Please try again.",
                thai: "ผู้ควบคุมไม่ตอบสนอง กรุณาลองอีกครั้ง"
            ).value(for: self.selectedLanguage)
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
        stateMachine.startSession(config: eventConfig)
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

    func customerKeep(photoIndex: Int) {
        guard !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(.keep(photoIndex: photoIndex), in: stateMachine.phase) else { return }
#if DEBUG
        if demoKioskMode {
            demoAdvance(afterKeeping: photoIndex)
            return
        }
#endif
        guard let context = currentSessionMessageContext else { return }
        reviewDecisionPending = true
        cancelCountdown()
        multipeer.sendControl(.reviewDecision(context: context, action: .keep)) { [weak self] outcome in
            guard let self, outcome != .sent else { return }
            self.reviewDecisionPending = false
            self.sessionRequestError = "The booth did not receive that choice. Please try again."
        }
        guard reviewDecisionPending else { return }
        reviewDecisionTimeoutTask?.cancel()
        reviewDecisionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.reviewDecisionPending else { return }
            self.reviewDecisionPending = false
            self.sessionRequestError = "The booth did not confirm that choice. Please try again."
        }
    }

    func customerRetake(photoIndex: Int) {
        guard !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(.retake(photoIndex: photoIndex), in: stateMachine.phase) else { return }
#if DEBUG
        if demoKioskMode {
            stateMachine.retakeShot(photoIndex: photoIndex)
            scheduleDemoShot(photoIndex: photoIndex)
            return
        }
#endif
        guard let context = currentSessionMessageContext else { return }
        reviewDecisionPending = true
        cancelCountdown()
        multipeer.sendControl(.reviewDecision(context: context, action: .retake)) { [weak self] outcome in
            guard let self, outcome != .sent else { return }
            self.reviewDecisionPending = false
            self.sessionRequestError = "The booth did not receive that choice. Please try again."
        }
        guard reviewDecisionPending else { return }
        reviewDecisionTimeoutTask?.cancel()
        reviewDecisionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.reviewDecisionPending else { return }
            self.reviewDecisionPending = false
            self.sessionRequestError = "The booth did not confirm that choice. Please try again."
        }
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
        recoveryActionPending = true
        multipeer.sendControl(.captureRecoveryAction(context: context, action: action)) { [weak self] outcome in
            guard let self, outcome != .sent else { return }
            self.recoveryActionPending = false
            self.sessionRequestError = "The booth did not receive that recovery choice. Please try again."
        }
        guard recoveryActionPending else { return }
        recoveryActionTimeoutTask?.cancel()
        recoveryActionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.recoveryActionPending else { return }
            self.recoveryActionPending = false
            self.sessionRequestError = "The booth did not confirm that recovery choice. Please try again."
        }
    }

    func customerDone() {
        guard !finishRequestPending, case .finished = stateMachine.phase,
              let context = currentSessionMessageContext else { return }
        cancelCountdown()
        finishRequestPending = true
        sessionRequestError = nil
        multipeer.sendControl(.customerFinished(context: context)) { [weak self] outcome in
            guard let self, outcome != .sent else { return }
            self.finishRequestPending = false
            self.sessionRequestError = "The booth did not receive the next-session request. Please try again."
        }
        guard finishRequestPending else { return }
        finishRequestTimeoutTask?.cancel()
        finishRequestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.finishRequestPending else { return }
            self.finishRequestPending = false
            self.sessionRequestError = "The booth did not confirm the next session. Please try again."
        }
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
