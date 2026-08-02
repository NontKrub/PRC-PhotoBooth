import Foundation
import Network
import Observation
import CoreImage
import CoreGraphics

// iPad-side coordinator — receives messages from Mac, drives local UI state.
@MainActor
@Observable
final class iPadViewModel {
    let multipeer: MultipeerService
    let stateMachine: SessionStateMachine

    var latestPreviewImage: CGImage?
    var eventConfig: EventConfig = EventConfig()
    var stripThumbImage: CGImage?
    var isMirrored = false
    private(set) var previewTransport: PreviewTransport

    // USB preview (over cable)
    private(set) var usbPreviewConnected = false
    private var usbBrowser: NWBrowser?
    private var usbConnection: NWConnection?
    private var usbEndpoints: [NWEndpoint] = []
    private var usbEndpointIndex = 0
    private var usbReconnectTask: Task<Void, Never>?
    private var recvBuf = Data()

    init() {
        previewTransport = PreviewTransport(
            rawValue: UserDefaults.standard.string(forKey: "iPadPreviewTransport") ?? ""
        ) ?? .wireless
        multipeer = MultipeerService(role: .iPad)
        stateMachine = SessionStateMachine()
        setupHandlers()
        startUSBPreviewClient()
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

        case .eventConfig(let config):
            eventConfig = config
            stateMachine.config = config

        case .setMirrored(let mirrored):
            isMirrored = mirrored

        case .sessionStart:
            stateMachine.startSession(config: eventConfig)

        case .beginCountdown(let index, let seconds):
            stateMachine.transition(to: .countdown(photoIndex: index, secondsRemaining: seconds))
            runCountdown(photoIndex: index, totalSeconds: seconds)

        case .shotCaptured(let index, let thumbData):
            stateMachine.enterReview(photoIndex: index, thumbnailData: thumbData)

        case .reviewDecision(let action):
            if case .review(let idx) = stateMachine.phase {
                switch action {
                case .keep: stateMachine.keepShot(photoIndex: idx)
                case .retake: stateMachine.retakeShot(photoIndex: idx)
                }
            }

        case .sessionFinished(let qr, let stripData, _):
            if let data = stripData { stripThumbImage = cgImage(from: data) }
            stateMachine.finishSession(qrPayload: qr)

        case .operatorOverride(let action):
            stateMachine.operatorOverride(action)

        default: break
        }
    }

    private func runCountdown(photoIndex: Int, totalSeconds: Int) {
        Task {
            for remaining in stride(from: totalSeconds, through: 1, by: -1) {
                stateMachine.transition(to: .countdown(photoIndex: photoIndex, secondsRemaining: remaining))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updatePreview(_ jpegData: Data) {
        guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return }
        latestPreviewImage = img
    }

    private func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Customer decisions

    func customerTappedStart() {
        multipeer.sendControl(.sessionStart)
        stateMachine.startSession(config: eventConfig)
    }

    func customerKeep(photoIndex: Int) {
        multipeer.sendControl(.reviewDecision(action: .keep))
        stateMachine.keepShot(photoIndex: photoIndex)
    }

    func customerRetake(photoIndex: Int) {
        multipeer.sendControl(.reviewDecision(action: .retake))
        stateMachine.retakeShot(photoIndex: photoIndex)
    }

    func customerDone() {
        stateMachine.reset()
    }

    func selectPreviewTransport(_ transport: PreviewTransport) {
        previewTransport = transport
        UserDefaults.standard.set(transport.rawValue, forKey: "iPadPreviewTransport")
        multipeer.sendControl(.setPreviewTransport(transport: transport))
    }

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
