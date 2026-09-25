import Foundation

struct DSLRCaptureAttemptValidator: Sendable {
    static func isNewMediaFile(
        name: String?,
        creationDate: Date?,
        context: DSLRCaptureAttemptContext
    ) -> Bool {
        // File must NOT be in the baseline
        guard let name, !context.baselineFileNames.contains(name) else { return false }
        // Creation date must be compatible (within 60s before capture request)
        let cutoff = context.requestedAt.addingTimeInterval(-60)
        guard let date = creationDate, date >= cutoff else {
            // If no date, we can't prove freshness — reject
            return false
        }
        return true
    }
    
    static func isNewObjectHandle(
        _ handle: UInt32,
        context: DSLRCaptureAttemptContext
    ) -> Bool {
        // Fixed buffer handle 0xFFFFC001 requires separate freshness proof
        guard handle != 0xFFFFC001 else { return false }
        // Handle must NOT be in baseline
        return !context.baselineObjectHandles.contains(handle)
    }
    
    // For the fixed PC buffer handle, we need additional freshness proof
    static func canTrustPCBufferContent(
        objectInMemoryValue: UInt16?,
        shutterWasIssued: Bool
    ) -> Bool {
        // Only trust if we know we issued a shutter AND the camera reports a new object ready
        guard shutterWasIssued else { return false }
        guard let value = objectInMemoryValue, value >= 0x8000 else { return false }
        return true
    }
}
