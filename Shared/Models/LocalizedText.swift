import Foundation

public struct LocalizedText: Codable, Sendable, Equatable {
    public var english: String
    public var thai: String

    public init(english: String = "", thai: String = "") {
        self.english = english
        self.thai = thai
    }

    public func value(for language: CustomerLanguage) -> String {
        let requested = language == .english ? english : thai
        let other = language == .english ? thai : english
        if let value = nonEmpty(requested) { return value }
        if let value = nonEmpty(other) { return value }
        return language == .thai ? "ไม่มีชื่อ" : "Untitled"
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
