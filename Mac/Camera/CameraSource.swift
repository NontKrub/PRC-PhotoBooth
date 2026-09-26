import Foundation
import CoreGraphics
import AVFoundation

struct CaptureAttempt: Sendable, Equatable {
    let id: UUID
    let startedAt: Date

    init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
    }
}

struct DSLRCaptureAttemptContext: Sendable {
    let id: UUID
    let requestedAt: Date
    let baselineFileNames: Set<String>
    let baselineObjectHandles: PTPHandleBaselineResult
    let expectedCameraIdentifier: String?
    let allowsPTPHandleCandidates: Bool
    let shutterIssuedAt: Date?
    let shutterCommandGeneration: UInt64?
    let baselineObjectInMemoryValue: UInt16?
    let objectInMemoryTransitionObserved: Bool

    init(
        id: UUID,
        requestedAt: Date,
        baselineFileNames: Set<String>,
        baselineObjectHandles: PTPHandleBaselineResult,
        expectedCameraIdentifier: String?,
        allowsPTPHandleCandidates: Bool = true,
        shutterIssuedAt: Date? = nil,
        shutterCommandGeneration: UInt64? = nil,
        baselineObjectInMemoryValue: UInt16? = nil,
        objectInMemoryTransitionObserved: Bool = false
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.baselineFileNames = baselineFileNames
        self.baselineObjectHandles = baselineObjectHandles
        self.expectedCameraIdentifier = expectedCameraIdentifier
        self.allowsPTPHandleCandidates = allowsPTPHandleCandidates
        self.shutterIssuedAt = shutterIssuedAt
        self.shutterCommandGeneration = shutterCommandGeneration
        self.baselineObjectInMemoryValue = baselineObjectInMemoryValue
        self.objectInMemoryTransitionObserved = objectInMemoryTransitionObserved
    }

    func recordingShutterIssued(at date: Date, generation: UInt64) -> Self {
        Self(
            id: id,
            requestedAt: requestedAt,
            baselineFileNames: baselineFileNames,
            baselineObjectHandles: baselineObjectHandles,
            expectedCameraIdentifier: expectedCameraIdentifier,
            allowsPTPHandleCandidates: allowsPTPHandleCandidates,
            shutterIssuedAt: date,
            shutterCommandGeneration: generation,
            baselineObjectInMemoryValue: baselineObjectInMemoryValue,
            objectInMemoryTransitionObserved: objectInMemoryTransitionObserved
        )
    }

    func recordingObjectInMemoryBaseline(_ value: UInt16?) -> Self {
        Self(
            id: id,
            requestedAt: requestedAt,
            baselineFileNames: baselineFileNames,
            baselineObjectHandles: baselineObjectHandles,
            expectedCameraIdentifier: expectedCameraIdentifier,
            allowsPTPHandleCandidates: allowsPTPHandleCandidates,
            shutterIssuedAt: shutterIssuedAt,
            shutterCommandGeneration: shutterCommandGeneration,
            baselineObjectInMemoryValue: value,
            objectInMemoryTransitionObserved: objectInMemoryTransitionObserved
        )
    }

    func recordingObjectInMemoryValue(_ value: UInt16?) -> Self {
        let baselineWasEmpty = baselineObjectInMemoryValue.map { $0 < 0x8000 } ?? false
        let transitionObserved = objectInMemoryTransitionObserved
            || (shutterIssuedAt != nil && baselineWasEmpty && (value.map { $0 >= 0x8000 } ?? false))
        return Self(
            id: id,
            requestedAt: requestedAt,
            baselineFileNames: baselineFileNames,
            baselineObjectHandles: baselineObjectHandles,
            expectedCameraIdentifier: expectedCameraIdentifier,
            allowsPTPHandleCandidates: allowsPTPHandleCandidates,
            shutterIssuedAt: shutterIssuedAt,
            shutterCommandGeneration: shutterCommandGeneration,
            baselineObjectInMemoryValue: baselineObjectInMemoryValue,
            objectInMemoryTransitionObserved: transitionObserved
        )
    }

    var canRecover: Bool {
        shutterIssuedAt != nil && expectedCameraIdentifier != nil
    }

    func disablingPTPHandleCandidates() -> Self {
        Self(
            id: id,
            requestedAt: requestedAt,
            baselineFileNames: baselineFileNames,
            baselineObjectHandles: baselineObjectHandles,
            expectedCameraIdentifier: expectedCameraIdentifier,
            allowsPTPHandleCandidates: false,
            shutterIssuedAt: shutterIssuedAt,
            shutterCommandGeneration: shutterCommandGeneration,
            baselineObjectInMemoryValue: baselineObjectInMemoryValue,
            objectInMemoryTransitionObserved: objectInMemoryTransitionObserved
        )
    }
}

enum PTPHandleBaselineResult: Sendable, Equatable {
    case success(Set<UInt32>)
    case unavailable(String)
}

enum CaptureMediaCandidate: Sendable, Equatable {
    case cameraFile(name: String?, creationDate: Date?)
    case ptpObjectHandle(UInt32)
    case sonyPCBuffer(objectInMemoryValue: UInt16?)
}

struct DSLRCaptureAttemptContextStore: Sendable {
    enum Operation: Sendable, Equatable {
        case capture
        case recovery
    }

    private(set) var active: DSLRCaptureAttemptContext?
    private(set) var recoverable: DSLRCaptureAttemptContext?
    private(set) var operation: Operation?
    private var ptpHandleQuarantine: Set<String> = []

    mutating func beginCapture(_ context: DSLRCaptureAttemptContext) {
        if let cameraIdentifier = context.expectedCameraIdentifier,
           ptpHandleQuarantine.contains(cameraIdentifier) {
            active = context.disablingPTPHandleCandidates()
        } else {
            active = context
        }
        recoverable = nil
        operation = .capture
    }

    mutating func beginRecovery(cameraIdentifier: String?) -> DSLRCaptureAttemptContext? {
        guard let recoverable,
              let cameraIdentifier,
              recoverable.expectedCameraIdentifier == cameraIdentifier,
              recoverable.canRecover else { return nil }
        active = recoverable
        operation = .recovery
        return recoverable
    }

    mutating func updateActive(_ context: DSLRCaptureAttemptContext) {
        guard active?.id == context.id else { return }
        active = context
        if operation == .recovery { recoverable = context }
    }

    mutating func finish(succeeded: Bool) {
        guard let context = active else {
            operation = nil
            return
        }
        switch operation {
        case .capture:
            recoverable = !succeeded && context.canRecover ? context : nil
            if !succeeded,
               context.canRecover,
               let cameraIdentifier = context.expectedCameraIdentifier {
                ptpHandleQuarantine.insert(cameraIdentifier)
            }
        case .recovery:
            if succeeded { recoverable = nil }
        case nil:
            break
        }
        active = nil
        operation = nil
    }

    mutating func invalidate() {
        active = nil
        recoverable = nil
        operation = nil
    }
}

struct CaptureAttemptGate {
    private(set) var activeAttemptID: UUID?

    mutating func begin(_ attempt: CaptureAttempt) {
        activeAttemptID = attempt.id
    }

    func isCurrent(_ attemptID: UUID) -> Bool {
        activeAttemptID == attemptID
    }

    mutating func finish(_ attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
    }
}

// Protocol every camera backend must satisfy.
@MainActor
protocol CameraSource: AnyObject {
    var isRunning: Bool { get }
    var availableDevices: [CameraDeviceInfo] { get }
    var selectedDeviceID: String? { get set }

    // Callbacks set by CaptureService
    var onPreviewFrame: ((CVPixelBuffer) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start() throws
    func stop()
    func captureStill() async throws -> CGImage
}

struct CameraDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String          // unique device identifier
    let name: String
    let kind: Kind

    enum Kind: Sendable { case builtIn, usb, dslr, continuityCamera }
}
