import Foundation
import Darwin

struct LocalWebServerConnectionAdmission: Sendable {
    struct Lease: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let clientKey: String?
    }

    struct Snapshot: Sendable, Equatable {
        let activeConnections: Int
        let activeClientCount: Int
        let perClientCounts: [String: Int]
    }

    private let maximumConnections: Int
    private let maximumPerClient: Int
    private var leases: Set<Lease> = []
    private var perClientCounts: [String: Int] = [:]

    init(maximumConnections: Int = 48, maximumPerClient: Int = 8) {
        self.maximumConnections = maximumConnections
        self.maximumPerClient = maximumPerClient
    }

    var snapshot: Snapshot {
        Snapshot(
            activeConnections: leases.count,
            activeClientCount: perClientCounts.count,
            perClientCounts: perClientCounts
        )
    }

    mutating func acquire(clientKey: String?) -> Lease? {
        guard leases.count < maximumConnections else { return nil }
        if let clientKey, perClientCounts[clientKey, default: 0] >= maximumPerClient {
            return nil
        }
        let lease = Lease(id: UUID(), clientKey: clientKey)
        leases.insert(lease)
        if let clientKey {
            perClientCounts[clientKey, default: 0] += 1
        }
        return lease
    }

    mutating func release(_ lease: Lease) {
        guard leases.remove(lease) != nil else { return }
        guard let clientKey = lease.clientKey,
              let count = perClientCounts[clientKey] else { return }
        if count <= 1 {
            perClientCounts.removeValue(forKey: clientKey)
        } else {
            perClientCounts[clientKey] = count - 1
        }
    }
}

enum LocalWebServerClientIdentity {
    static func normalizedHost(_ host: String) -> String {
        let unwrapped = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let address = String(unwrapped.split(separator: "%", maxSplits: 1).first ?? Substring(unwrapped))

        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return "v4:" + bytes.map { String($0) }.joined(separator: ".")
        }

        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return "v4:" + bytes[12..<16].map { String($0) }.joined(separator: ".")
            }
            var normalized = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = withUnsafePointer(to: &ipv6) {
                inet_ntop(AF_INET6, $0, &normalized, socklen_t(normalized.count))
            }
            let addressBytes = normalized.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            return "v6:\(String(decoding: addressBytes, as: UTF8.self).lowercased())"
        }

        return unwrapped.lowercased()
    }
}
