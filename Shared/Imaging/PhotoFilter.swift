import Foundation

public enum PhotoFilterID: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case monochrome
    case warm
    case cool
    case highContrast
    case soft
    case vintage

    public var id: String { rawValue }

    public var localizationKey: String {
        switch self {
        case .original: return "filter.original"
        case .monochrome: return "filter.monochrome"
        case .warm: return "filter.warm"
        case .cool: return "filter.cool"
        case .highContrast: return "filter.highContrast"
        case .soft: return "filter.soft"
        case .vintage: return "filter.vintage"
        }
    }
}
