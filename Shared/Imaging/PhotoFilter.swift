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

    public func displayName(for language: CustomerLanguage) -> String {
        switch self {
        case .original: return language == .thai ? "ต้นฉบับ" : "Original"
        case .monochrome: return language == .thai ? "ขาวดำ" : "Monochrome"
        case .warm: return language == .thai ? "โทนอุ่น" : "Warm"
        case .cool: return language == .thai ? "โทนเย็น" : "Cool"
        case .highContrast: return language == .thai ? "คอนทราสต์สูง" : "High Contrast"
        case .soft: return language == .thai ? "นุ่มนวล" : "Soft"
        case .vintage: return language == .thai ? "วินเทจ" : "Vintage"
        }
    }
}
