import Foundation

public enum GuestDeliveryPolicy: String, Sendable, Equatable {
    case publicHTTPS
    case trustedLocalHTTP
    case unavailable

    public func permitsLocalGuestHTTP(allowTrustedLocalHTTP: Bool) -> Bool {
        allowTrustedLocalHTTP && self != .unavailable
    }
}

public struct ValidatedPublicGuestBaseURL: Sendable, Equatable {
    public let url: URL
    public let canonicalString: String

    public init?(string: String) {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.contains("\\"),
              var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            return nil
        }
        components.scheme = "https"
        guard let parsedURL = components.url else { return nil }
        let canonicalString = SessionQRCodePayloadResolver.trimBaseURL(parsedURL.absoluteString)
        guard let url = URL(string: canonicalString) else { return nil }
        self.url = url
        self.canonicalString = canonicalString
    }
}

public enum SessionQRCodePayloadError: LocalizedError, Equatable {
    case emptyToken
    case emptyBaseURL
    case insecurePublicBaseURL
    case localHTTPNotAllowed
    case unroutableLocalBaseURL(String)

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
        case .unroutableLocalBaseURL(let reason):
            return "Guest downloads over local HTTP are unavailable: \(reason)."
        }
    }
}

public struct SessionQRCodePayloadResolver {
    public static func isRoutableLocalBase(_ baseURL: String) -> Bool {
        let trimmed = trimBaseURL(baseURL)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" || host.hasPrefix("127.") {
            return false
        }
        return true
    }

    public static func evaluatePolicy(
        publicBaseURL: String?,
        cloudUploadEnabled: Bool,
        allowTrustedLocalHTTP: Bool,
        localBaseURL: String? = nil,
        isRelease: Bool = isReleaseBuild
    ) -> GuestDeliveryPolicy {
        let hasConfiguredPublicBase = publicBaseURL.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        if cloudUploadEnabled && hasConfiguredPublicBase {
            return ValidatedPublicGuestBaseURL(string: publicBaseURL ?? "") == nil ? .unavailable : .publicHTTPS
        }
        if allowTrustedLocalHTTP {
            if let localBaseURL {
                guard isRoutableLocalBase(localBaseURL) else {
                    return .unavailable
                }
            }
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
        let hasConfiguredPublicBase = publicBaseURL.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false

        if cloudUploadEnabled && hasConfiguredPublicBase {
            guard let validated = publicBaseURL.flatMap(ValidatedPublicGuestBaseURL.init(string:)) else {
                throw SessionQRCodePayloadError.insecurePublicBaseURL
            }
            return "\(validated.canonicalString)/s/\(token)/"
        }

        guard allowTrustedLocalHTTP else {
            throw SessionQRCodePayloadError.localHTTPNotAllowed
        }
        guard !localBase.isEmpty else {
            throw SessionQRCodePayloadError.emptyBaseURL
        }
        guard isRoutableLocalBase(localBase) else {
            throw SessionQRCodePayloadError.unroutableLocalBaseURL("Localhost and loopback addresses cannot be reached by guests.")
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
