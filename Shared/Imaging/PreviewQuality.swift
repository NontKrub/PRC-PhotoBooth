import Foundation

public enum PreviewQualityPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case standard
    case high

    public var id: String { rawValue }
}

public struct PreviewQualityProfile: Equatable, Sendable {
    public let maxDimension: Int
    public let jpegQuality: Double
    public let defaultFramesPerSecond: Int
    public let allows60FPS: Bool

    public static let standard = PreviewQualityProfile(
        maxDimension: 1_280,
        jpegQuality: 0.70,
        defaultFramesPerSecond: 30,
        allows60FPS: true
    )
    public static let high = PreviewQualityProfile(
        maxDimension: 1_920,
        jpegQuality: 0.80,
        defaultFramesPerSecond: 30,
        allows60FPS: false
    )
}

public struct PreviewQualityPolicy: Equatable, Sendable {
    public private(set) var preset: PreviewQualityPreset
    public private(set) var resolvedPreset: PreviewQualityPreset

    private var candidate: PreviewQualityPreset?
    private var candidateSince: Date?
    private let hysteresis: TimeInterval

    public init(
        preset: PreviewQualityPreset = .auto,
        hysteresis: TimeInterval = 2
    ) {
        self.preset = preset
        self.resolvedPreset = preset == .high ? .high : .standard
        self.hysteresis = hysteresis
    }

    public mutating func setPreset(_ preset: PreviewQualityPreset) {
        self.preset = preset
        candidate = nil
        candidateSince = nil
        if preset != .auto { resolvedPreset = preset }
    }

    @discardableResult
    public mutating func update(
        effectiveNetwork: BoothEffectiveNetworkTransport,
        now: Date = Date()
    ) -> PreviewQualityProfile {
        let desired: PreviewQualityPreset
        if preset != .auto {
            desired = preset
        } else {
            desired = effectiveNetwork == .lan ? .high : .standard
        }

        if desired != resolvedPreset {
            if candidate != desired {
                candidate = desired
                candidateSince = now
            } else if let candidateSince,
                      now.timeIntervalSince(candidateSince) >= hysteresis {
                resolvedPreset = desired
                candidate = nil
                self.candidateSince = nil
            }
        } else {
            candidate = nil
            candidateSince = nil
        }

        return resolvedPreset == .high ? .high : .standard
    }
}
