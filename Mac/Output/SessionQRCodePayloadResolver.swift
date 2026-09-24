import Foundation

public enum GuestDeliveryPolicy: String, Sendable, Equatable {
    case publicHTTPS
    case trustedLocalHTTP
    case unavailable
}

public enum SessionQRCodePayloadError: LocalizedError, Equatable {
    case emptyToken
    case emptyBaseURL
    case insecurePublicBaseURL
    case localHTTPNotAllowed

    public var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "Download token is empty."
        case .emptyBaseURL:
            return "Download base URL is empty."
        case .insecurePublicBaseURL:
            return "Public download base URL must use HTTPS."
        case .localHTTPNotAllowed:
            return "Guest downloads over local HTTP are disabled. Configure HTTPS or enable trusted local HTTP."
        }
    }
}

public struct SessionQRCodePayloadResolver {
    public static func evaluatePolicy(
        publicBaseURL: String?,
        cloudUploadEnabled: Bool,
        allowTrustedLocalHTTP: Bool,
        isRelease: Bool = isReleaseBuild
    ) -> GuestDeliveryPolicy {
        let publicBase = publicBaseURL.map(trimBaseURL) ?? ""
        if cloudUploadEnabled && !publicBase.isEmpty {
            if isRelease {
                if publicBase.lowercased().hasPrefix("https://") {
                    return .publicHTTPS
                } else {
                    return .unavailable
                }
            } else {
                if publicBase.lowercased().hasPrefix("https://") || publicBase.lowercased().hasPrefix("http://") {
                    return .publicHTTPS
                } else {
                    return .unavailable
                }
            }
        }
        if allowTrustedLocalHTTP {
            return .trustedLocalHTTP
        }
        return .unavailable
    }

    public static func resolve(
        token: String,
        localBaseURL: String,
        publicBaseURL: String?,
        cloudUploadEnabled: Bool,
        allowTrustedLocalHTTP: Bool = false,
        isRelease: Bool = isReleaseBuild
    ) throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SessionQRCodePayloadError.emptyToken }

        let localBase = trimBaseURL(localBaseURL)
        let publicBase = publicBaseURL.map(trimBaseURL) ?? ""

        if cloudUploadEnabled && !publicBase.isEmpty {
            if isRelease {
                guard publicBase.lowercased().hasPrefix("https://") else {
                    throw SessionQRCodePayloadError.insecurePublicBaseURL
                }
            } else {
                guard publicBase.lowercased().hasPrefix("https://") || publicBase.lowercased().hasPrefix("http://") else {
                    throw SessionQRCodePayloadError.insecurePublicBaseURL
                }
            }
            return "\(publicBase)/s/\(token)/"
        }

        guard allowTrustedLocalHTTP else {
            throw SessionQRCodePayloadError.localHTTPNotAllowed
        }
        guard !localBase.isEmpty else {
            throw SessionQRCodePayloadError.emptyBaseURL
        }
        return "\(localBase)/s/\(token)/"
    }

    public static func trimBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static var isReleaseBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}
