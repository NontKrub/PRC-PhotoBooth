import Foundation
import Combine
import CoreImage
import CoreGraphics

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
    private var countdownTask: Task<Void, Never>?
    private var sessionMessageGate = SessionMessageGate()
#if DEBUG
    @Published private(set) var demoKioskMode = false
#endif

    private var observationCancellables = Set<AnyCancellable>()

    var networkTransport: NetworkBoothTransport? { multipeer as? NetworkBoothTransport }
    var connectionStatus: BoothConnectionStatus { multipeer.connectionStatus }
    var canChangeConnection: Bool { stateMachine.phase == .idle }
    var isConnectionReady: Bool {
        guard case .connected = connectionStatus.state else { return false }
        guard networkTransport != nil else { return true }
        return connectionStatus.isPeerAuthenticated && connectionStatus.isPreviewChannelConnected
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
            isSessionRequestPending = false
            reviewDecisionPending = false
            recoveryActionPending = false
            sessionRequestTimeoutTask?.cancel()
            stateMachine.startSession(config: eventConfig)

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
            isSessionRequestPending = false
            reviewDecisionPending = false
            recoveryActionPending = false
            sessionRequestTimeoutTask?.cancel()
            eventConfig = config
            stateMachine.startSession(config: config, sessionID: presentation.sessionID)
            sessionPresentation = presentation
            selectedLanguage = presentation.language
            promptImages = presentation.prompts.reduce(into: [String: CGImage]()) { result, prompt in
                if let data = prompt.imageData, let image = Self.cgImage(from: data) {
                    result[prompt.promptID] = image
                }
            }

        case .beginCountdown(let context, let descriptor):
            guard accept(context, message: "beginCountdown") else { break }
            recoveryActionPending = false
            reviewDecisionPending = false
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

        case .captureRecovery(let context, let index, let failure):
            guard accept(context, message: "captureRecovery") else { break }
            cancelCountdown()
            recoveryActionPending = false
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
            switch action {
            case .keep: stateMachine.keepShot(photoIndex: idx)
            case .retake: stateMachine.retakeShot(photoIndex: idx)
            }

        case .sessionFinished(let context, let qr, let stripData, _):
            guard accept(context, message: "sessionFinished") else { break }
            cancelCountdown()
            recoveryActionPending = false
            reviewDecisionPending = false
            if let data = stripData { stripThumbImage = Self.cgImage(from: data) }
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

    private func applySessionSync(_ snapshot: SessionSyncSnapshot) {
        cancelCountdown()
        sessionMessageGate.synchronize(sessionID: snapshot.sessionID, sequence: snapshot.sequence)
        eventConfig = snapshot.config
        stateMachine.config = snapshot.config
        selectedLanguage = snapshot.presentation?.language ?? snapshot.config.customerLanguage
        sessionPresentation = snapshot.presentation
        promptImages = snapshot.presentation?.prompts.reduce(into: [String: CGImage]()) { result, prompt in
            if let data = prompt.imageData, let image = Self.cgImage(from: data) {
                result[prompt.promptID] = image
            }
        } ?? [:]
        isMirrored = snapshot.isMirrored
        isBoothPaused = snapshot.isBoothPaused
        recoveryActionPending = false
        reviewDecisionPending = false
        guard let sessionID = snapshot.sessionID else {
            stateMachine.reset()
            return
        }
        var keptShots = snapshot.keptShots
        var reviewImageData: Data?
        if case .review(let index) = snapshot.phase,
           let data = snapshot.reviewThumbnailData {
            reviewImageData = data
            keptShots[index] = ReviewImageEncoder.thumbnailData(from: data) ?? data
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
        if case .finished = snapshot.phase,
           let data = snapshot.stripThumbnailData {
            stripThumbImage = Self.cgImage(from: data)
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
            multipeer.sendControl(.sessionStart(context: nil))
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
        multipeer.sendControl(.customerSessionRequest(selection: selection))
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
        multipeer.sendControl(.reviewDecision(context: context, action: .keep))
        stateMachine.keepShot(photoIndex: photoIndex)
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
        multipeer.sendControl(.reviewDecision(context: context, action: .retake))
        stateMachine.retakeShot(photoIndex: photoIndex)
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
        multipeer.sendControl(.captureRecoveryAction(context: context, action: action))
    }

    func customerDone() {
        guard CustomerDisplayWorkflow.canApply(.back, in: stateMachine.phase) else { return }
        cancelCountdown()
        recoveryActionPending = false
        reviewDecisionPending = false
        stateMachine.reset()
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
