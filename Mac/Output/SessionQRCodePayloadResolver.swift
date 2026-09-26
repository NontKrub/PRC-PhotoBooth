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

public struct CloudGuestRoute: Sendable, Equatable {
    /// Canonical route key, beginning with `/` and without a trailing slash.
    public let relativePath: String

    public func guestURL(baseURL: URL) -> URL? {
        URL(string: "\(SessionQRCodePayloadResolver.trimBaseURL(baseURL.absoluteString))\(relativePath)/")
    }

    public func childURL(_ fileName: String, baseURL: URL) -> URL? {
        guard Self.isSafeComponent(fileName),
              let guestURL = guestURL(baseURL: baseURL) else {
            return nil
        }
        return URL(string: guestURL.absoluteString + fileName)
    }

    static func resolve(for manifest: SessionManifest) throws -> CloudGuestRoute {
        if manifest.origin == .soakTest {
            guard let runID = manifest.soakRunID, Self.isSafeComponent(runID) else {
                throw SessionQRCodePayloadError.invalidGuestRoute("Soak run identifier is missing or invalid.")
            }
            guard Self.isSafeComponent(manifest.id) else {
                throw SessionQRCodePayloadError.invalidGuestRoute("Session identifier is invalid.")
            }
            return CloudGuestRoute(relativePath: "/s/soak/\(runID)/\(manifest.id)")
        }
        return try normal(token: manifest.downloadToken)
    }

    static func normal(token: String) throws -> CloudGuestRoute {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SessionQRCodePayloadError.emptyToken }
        guard Self.isSafeComponent(token) else {
            throw SessionQRCodePayloadError.invalidGuestRoute("Download token is invalid.")
        }
        return CloudGuestRoute(relativePath: "/s/\(token)")
    }

    private init(relativePath: String) {
        self.relativePath = relativePath
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !value.isEmpty
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum SessionQRCodePayloadError: LocalizedError, Equatable {
    case emptyToken
    case emptyBaseURL
    case insecurePublicBaseURL
    case localHTTPNotAllowed
    case unroutableLocalBaseURL(String)
    case invalidGuestRoute(String)

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
        case .invalidGuestRoute(let reason):
            return "Guest download route is invalid: \(reason)"
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
        try resolve(
            route: CloudGuestRoute.normal(token: token),
            localBaseURL: localBaseURL,
            publicBaseURL: publicBaseURL,
            cloudUploadEnabled: cloudUploadEnabled,
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        )
    }

    static func resolve(
        manifest: SessionManifest,
        localBaseURL: String,
        publicBaseURL: String?,
        cloudUploadEnabled: Bool,
        allowTrustedLocalHTTP: Bool = false
    ) throws -> String {
        try resolve(
            route: CloudGuestRoute.resolve(for: manifest),
            localBaseURL: localBaseURL,
            publicBaseURL: publicBaseURL,
            cloudUploadEnabled: cloudUploadEnabled,
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        )
    }

    private static func resolve(
        route: CloudGuestRoute,
        localBaseURL: String,
        publicBaseURL: String?,
        cloudUploadEnabled: Bool,
        allowTrustedLocalHTTP: Bool
    ) throws -> String {

        let localBase = trimBaseURL(localBaseURL)
        let hasConfiguredPublicBase = publicBaseURL.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false

        if cloudUploadEnabled && hasConfiguredPublicBase {
            guard let validated = publicBaseURL.flatMap(ValidatedPublicGuestBaseURL.init(string:)) else {
                throw SessionQRCodePayloadError.insecurePublicBaseURL
            }
            guard let guestURL = route.guestURL(baseURL: validated.url) else {
                throw SessionQRCodePayloadError.invalidGuestRoute("Could not construct the public URL.")
            }
            return guestURL.absoluteString
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
        guard let baseURL = URL(string: localBase),
              let guestURL = route.guestURL(baseURL: baseURL) else {
            throw SessionQRCodePayloadError.emptyBaseURL
        }
        return guestURL.absoluteString
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
