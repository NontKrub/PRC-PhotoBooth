import Foundation
import Network
import Observation
import CoreImage
import CoreGraphics

// iPad-side coordinator — receives messages from Mac, drives local UI state.
@MainActor
@Observable
final class iPadViewModel {
    let multipeer: BoothTransport
    let stateMachine: SessionStateMachine

    var latestPreviewImage: CGImage?
    var eventConfig: EventConfig = EventConfig()
    var experienceCatalog: CustomerExperienceCatalog?
    var experienceAssets: [String: CGImage] = [:]
    var selectedTemplateID: String?
    var selectedFilterID: PhotoFilterID?
    var selectedLanguage: CustomerLanguage = .english
    var sessionPresentation: SessionPresentation?
    var promptImages: [String: CGImage] = [:]
    private(set) var isSessionRequestPending = false
    private(set) var reviewDecisionPending = false
    private(set) var recoveryActionPending = false
    var sessionRequestError: String?
    var stripThumbImage: CGImage?
    var isMirrored = false
    var isBoothPaused = false
    private(set) var previewTransport: PreviewTransport

    // USB preview (over cable)
    private(set) var usbPreviewConnected = false
    private var usbBrowser: NWBrowser?
    private var usbConnection: NWConnection?
    private var usbEndpoints: [NWEndpoint] = []
    private var usbEndpointIndex = 0
    private var usbReconnectTask: Task<Void, Never>?
    private var recvBuf = Data()
    private var pendingPreviewJPEG: Data?
    private var previewDecodeTask: Task<Void, Never>?
    private var sessionRequestTimeoutTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
#if DEBUG
    private(set) var demoKioskMode = false
#endif

    init() {
        previewTransport = PreviewTransport(
            rawValue: UserDefaults.standard.string(forKey: "iPadPreviewTransport") ?? ""
        ) ?? .wireless
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
        setupHandlers()
        multipeer.start()
        startUSBPreviewClient()
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
            self?.updatePreview(jpegData)
        }
    }

    private func handleMessage(_ msg: Message) {
        switch msg {
        case .hello(let role) where role == .mac:
            multipeer.sendControl(.hello(role: .iPad))
            multipeer.sendControl(.setPreviewTransport(transport: previewTransport))

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

        case .sessionStart:
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
            stateMachine.transition(to: .selectingExperience)

        case .sessionPrepared(let config, let presentation):
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

        case .beginCountdown(let index, let seconds):
            recoveryActionPending = false
            reviewDecisionPending = false
            stateMachine.transition(to: .countdown(photoIndex: index, secondsRemaining: seconds))
            runCountdown(photoIndex: index, totalSeconds: seconds)

        case .shotCaptured(let index, let thumbData):
            cancelCountdown()
            recoveryActionPending = false
            reviewDecisionPending = false
            stateMachine.enterReview(photoIndex: index, thumbnailData: thumbData)

        case .captureRecovery(let index, let failure):
            cancelCountdown()
            recoveryActionPending = false
            reviewDecisionPending = false
            stateMachine.transition(to: .captureRecovery(photoIndex: index, failure: failure))

        case .reviewDecision(let action):
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

        case .sessionFinished(let qr, let stripData, _):
            cancelCountdown()
            recoveryActionPending = false
            reviewDecisionPending = false
            if let data = stripData { stripThumbImage = Self.cgImage(from: data) }
            stateMachine.finishSession(qrPayload: qr)

        case .operatorOverride(let action):
            if case .cancelSession = action { cancelCountdown() }
            stateMachine.operatorOverride(action)

        default: break
        }
    }

    private func applySessionSync(_ snapshot: SessionSyncSnapshot) {
        cancelCountdown()
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
        stateMachine.startSession(config: snapshot.config, sessionID: sessionID)
        switch snapshot.phase {
        case .review(let index):
            if let data = snapshot.reviewThumbnailData {
                stateMachine.enterReview(photoIndex: index, thumbnailData: data)
            } else {
                stateMachine.transition(to: snapshot.phase)
            }
        case .finished:
            if let data = snapshot.stripThumbnailData { stripThumbImage = Self.cgImage(from: data) }
            stateMachine.transition(to: snapshot.phase)
        case .countdown(let index, let seconds):
            stateMachine.transition(to: snapshot.phase)
            runCountdown(photoIndex: index, totalSeconds: seconds)
        default:
            stateMachine.transition(to: snapshot.phase)
        }
    }

    private func runCountdown(photoIndex: Int, totalSeconds: Int) {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: totalSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                stateMachine.transition(to: .countdown(photoIndex: photoIndex, secondsRemaining: remaining))
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self.countdownTask = nil
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func updatePreview(_ jpegData: Data) {
        pendingPreviewJPEG = jpegData
        guard previewDecodeTask == nil else { return }

        previewDecodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let jpeg = self.pendingPreviewJPEG {
                self.pendingPreviewJPEG = nil
                let image = await Task.detached(priority: .userInitiated) {
                    Self.cgImage(from: jpeg)
                }.value
                guard !Task.isCancelled else { return }
                self.latestPreviewImage = image
            }
            self.previewDecodeTask = nil
        }
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
            multipeer.sendControl(.sessionStart)
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
        stateMachine.transition(to: .selectingExperience)
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
            customerLanguage: selectedLanguage
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
        reviewDecisionPending = true
        cancelCountdown()
        multipeer.sendControl(.reviewDecision(action: .keep))
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
        reviewDecisionPending = true
        cancelCountdown()
        multipeer.sendControl(.reviewDecision(action: .retake))
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
        recoveryActionPending = true
        multipeer.sendControl(.captureRecoveryAction(action: action))
    }

    func customerDone() {
        guard CustomerDisplayWorkflow.canApply(.back, in: stateMachine.phase) else { return }
        cancelCountdown()
        recoveryActionPending = false
        reviewDecisionPending = false
        stateMachine.reset()
    }

    func selectPreviewTransport(_ transport: PreviewTransport) {
        previewTransport = transport
        UserDefaults.standard.set(transport.rawValue, forKey: "iPadPreviewTransport")
        multipeer.sendControl(.setPreviewTransport(transport: transport))
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.stateMachine.phase == .countdown(photoIndex: photoIndex, secondsRemaining: self.eventConfig.countdownSeconds)
                || self.stateMachine.phase == .readyToStart else { return }
            guard let sample = FilterSampleRenderer.makeSampleImage(),
                  let filtered = try? await PhotoFilterPipeline().apply(self.eventConfig.selectedFilterID, to: sample),
                  let data = jpegDataForDemo(filtered) else { return }
            self.reviewDecisionPending = false
            self.stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: data)
        }
        stateMachine.beginCountdown(photoIndex: photoIndex)
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

    // MARK: - USB preview client

    private func startUSBPreviewClient() {
        let browser = NWBrowser(for: .bonjour(type: "_prc-hq._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.usbEndpoints = results.map(\.endpoint)
                self.usbEndpointIndex = 0
                guard self.usbConnection == nil else { return }
                self.connectUSB(to: endpoint)
            }
        }
        browser.start(queue: .main)
        usbBrowser = browser
    }

    private func connectUSB(to endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.usbPreviewConnected = true
                    self.receiveUSBFrame()
                case .failed, .cancelled:
                    self.usbPreviewConnected = false
                    self.usbConnection = nil
                    self.recvBuf = Data()
                    self.scheduleUSBReconnect()
                default: break
                }
            }
        }
        conn.start(queue: .main)
        usbConnection = conn
    }

    private func scheduleUSBReconnect() {
        guard usbReconnectTask == nil else { return }
        usbReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.usbReconnectTask = nil
            guard let self, self.usbConnection == nil, let endpoint = self.nextUSBEndpoint() else { return }
            self.connectUSB(to: endpoint)
        }
    }

    private func nextUSBEndpoint() -> NWEndpoint? {
        guard !usbEndpoints.isEmpty else { return nil }
        defer { usbEndpointIndex = (usbEndpointIndex + 1) % usbEndpoints.count }
        return usbEndpoints[usbEndpointIndex]
    }

    private func receiveUSBFrame() {
        usbConnection?.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, let data, error == nil else { return }
                // ponytail: O(n) removeFirst; acceptable for ≤30fps preview frames
                self.recvBuf.append(data)
                while self.recvBuf.count >= 4 {
                    let frameLen = self.recvBuf.prefix(4).withUnsafeBytes {
                        Int(UInt32(bigEndian: $0.load(as: UInt32.self)))
                    }
                    guard self.recvBuf.count >= 4 + frameLen else { break }
                    let jpeg = self.recvBuf.subdata(in: 4..<(4 + frameLen))
                    self.recvBuf.removeFirst(4 + frameLen)
                    self.updatePreview(jpeg)
                }
                self.receiveUSBFrame()
            }
        }
    }
}
