import Foundation

struct DSLRCaptureAttemptValidator: Sendable {
    static func authorizes(
        _ candidate: CaptureMediaCandidate,
        context: DSLRCaptureAttemptContext,
        cameraIdentifier: String?
    ) -> Bool {
        guard let expected = context.expectedCameraIdentifier,
              let cameraIdentifier,
              expected == cameraIdentifier,
              context.shutterIssuedAt != nil else { return false }

        switch candidate {
        case .cameraFile(let name, let creationDate):
            guard let name,
                  !name.isEmpty,
                  !context.baselineFileNames.contains(name),
                  let creationDate,
                  let shutterIssuedAt = context.shutterIssuedAt,
                  let normalizedDate = context.normalizedCameraDate(creationDate) else { return false }
            return normalizedDate >= shutterIssuedAt

        case .ptpObjectHandle(let handle):
            guard handle != 0,
                  handle != 0xFFFFFFFF,
                  handle != 0xFFFFC001,
                  context.allowsPTPHandleCandidates,
                  case .success(let baselineHandles) = context.baselineObjectHandles else { return false }
            return !baselineHandles.contains(handle)

        case .sonyPCBuffer(let objectInMemoryValue):
            guard let baseline = context.baselineObjectInMemoryValue,
                  baseline < 0x8000,
                  let objectInMemoryValue,
                  objectInMemoryValue >= 0x8000 else { return false }
            return context.objectInMemoryTransitionObserved
        }
    }

    static func isNewMediaFile(
        name: String?,
        creationDate: Date?,
        context: DSLRCaptureAttemptContext
    ) -> Bool {
        guard let name,
              !name.isEmpty,
              !context.baselineFileNames.contains(name),
              let creationDate,
              let shutterIssuedAt = context.shutterIssuedAt,
              let normalizedDate = context.normalizedCameraDate(creationDate) else { return false }
        return normalizedDate >= shutterIssuedAt
    }

    static func isNewObjectHandle(
        _ handle: UInt32,
        context: DSLRCaptureAttemptContext
    ) -> Bool {
        guard handle != 0,
              handle != 0xFFFFFFFF,
              handle != 0xFFFFC001,
              context.allowsPTPHandleCandidates,
              case .success(let baselineHandles) = context.baselineObjectHandles else { return false }
        return !baselineHandles.contains(handle)
    }
}
