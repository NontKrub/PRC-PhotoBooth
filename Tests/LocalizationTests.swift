import Foundation
import Testing

struct LocalizationTests {
    @Test("Thai translations are present for every app catalog entry")
    func thaiTranslationsArePresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for relativePath in ["Mac/Localizable.xcstrings", "iPad/Localizable.xcstrings"] {
            let url = root.appendingPathComponent(relativePath)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let document = try #require(object as? [String: Any])
            let strings = try #require(document["strings"] as? [String: Any])

            for (key, value) in strings {
                let entry = try #require(value as? [String: Any], "Invalid entry for \(key)")
                let localizations = try #require(entry["localizations"] as? [String: Any], "Missing Thai localization for \(relativePath): \(key)")
                let thai = try #require(localizations["th"] as? [String: Any], "Missing Thai localization for \(relativePath): \(key)")
                let stringUnit = try #require(thai["stringUnit"] as? [String: Any], "Missing Thai string unit for \(relativePath): \(key)")
                let translated = try #require(stringUnit["value"] as? String, "Missing Thai value for \(relativePath): \(key)")
                #expect(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty Thai translation for \(relativePath): \(key)")
            }
        }
    }
}
