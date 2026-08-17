import Foundation

public enum GIFQualityPreset: String, Codable, CaseIterable, Sendable, Equatable {
    case compact
    case balanced
    case high

    public var maxDimension: Int {
        switch self {
        case .compact: 320
        case .balanced: 360
        case .high: 480
        }
    }

    public var frameRate: Int {
        switch self {
        case .compact, .balanced: 8
        case .high: 12
        }
    }

    public var frameCount: Int {
        switch self {
        case .compact, .balanced: 40
        case .high: 60
        }
    }

    public var frameDelay: Double { 1.0 / Double(frameRate) }
    public var duration: Double { Double(frameCount) / Double(frameRate) }
}

public enum GIFAvailabilityState: String, Codable, Sendable, Equatable {
    case none
    case preparing
    case ready
    case failed
}
