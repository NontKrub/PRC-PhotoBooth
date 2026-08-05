import Foundation

enum SessionQRCodePayloadError: Error, Equatable {
    case emptyToken
    case emptyBaseURL
}

struct SessionQRCodePayloadResolver {
    static func resolve(
        token: String,
        localBaseURL: String,
        publicBaseURL: String?,
        cloudUploadEnabled: Bool
    ) throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SessionQRCodePayloadError.emptyToken }

        let localBase = trimBaseURL(localBaseURL)
        let publicBase = publicBaseURL.map(trimBaseURL) ?? ""
        let base = cloudUploadEnabled && !publicBase.isEmpty ? publicBase : localBase
        guard !base.isEmpty else { throw SessionQRCodePayloadError.emptyBaseURL }
        return "\(base)/s/\(token)/"
    }

    private static func trimBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
