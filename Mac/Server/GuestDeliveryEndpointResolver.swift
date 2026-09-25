import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct NetworkInterfaceSnapshot: Sendable, Equatable {
    public let name: String
    public let flags: UInt32
    public let address: String
    public let family: Int32

    public init(name: String, flags: UInt32, address: String, family: Int32 = AF_INET) {
        self.name = name
        self.flags = flags
        self.address = address
        self.family = family
    }
}

public enum GuestDeliveryEndpointResolver {
    /// Interface name prefixes that are never suitable for guest photo delivery
    private static let excludedInterfacePrefixes: [String] = [
        "lo",       // Loopback
        "bridge",   // Bridge interfaces (Thunderbolt bridge, Internet Sharing, etc.)
        "utun",     // VPN / iCloud Private Relay / Tunnels
        "ppp",      // Point-to-Point
        "docker",   // Docker virtual bridge
        "vboxnet",  // VirtualBox host-only
        "vmnet",    // VMware virtual network
        "veth",     // Virtual ethernet
        "vnic",     // Parallels virtual NIC
        "awdl",     // Apple Wireless Direct Link (AirDrop/AirPlay)
        "llw",      // Low latency WLAN
        "anpi",     // Apple internal network
        "gif",      // Generic IP tunnel
        "stf",      // 6to4 tunnel
        "ipsec",    // IPSec tunnel
    ]

    /// Checks if an IPv4 address is an RFC 1918 private address:
    /// - 10.0.0.0/8 (10.0.0.0 - 10.255.255.255)
    /// - 172.16.0.0/12 (172.16.0.0 - 172.31.255.255)
    /// - 192.168.0.0/16 (192.168.0.0 - 192.168.255.255)
    public static func isRFC1918PrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if parts[0] == 10 {
            return true
        }
        if parts[0] == 172 && (16...31).contains(parts[1]) {
            return true
        }
        if parts[0] == 192 && parts[1] == 168 {
            return true
        }
        return false
    }

    /// Evaluates if an interface name is acceptable for guest delivery.
    public static func isAcceptableInterfaceName(_ name: String) -> Bool {
        let lower = name.lowercased()
        for prefix in excludedInterfacePrefixes {
            if lower.hasPrefix(prefix) {
                return false
            }
        }
        return true
    }

    /// Determines if an interface snapshot represents a valid, routable guest delivery candidate.
    public static func isGuestRoutable(interface: NetworkInterfaceSnapshot) -> Bool {
        guard interface.family == AF_INET else { return false }
        let flags = Int32(interface.flags)
        let isUp = (flags & IFF_UP) != 0
        let isRunning = (flags & IFF_RUNNING) != 0
        let isLoopback = (flags & IFF_LOOPBACK) != 0

        guard isUp && isRunning && !isLoopback else { return false }
        guard isAcceptableInterfaceName(interface.name) else { return false }
        guard isRFC1918PrivateIPv4(interface.address) else { return false }

        // Must not be loopback or broadcast / all-zeroes
        if interface.address == "127.0.0.1" || interface.address.hasPrefix("127.") || interface.address == "0.0.0.0" {
            return false
        }

        return true
    }

    /// Priority score for candidate interfaces. Lower score = higher priority.
    /// Prefers physical interfaces (`en*`).
    public static func priorityScore(for name: String) -> Int {
        let lower = name.lowercased()
        if lower.hasPrefix("en") {
            if let index = Int(lower.dropFirst(2)) {
                return index
            }
            return 10
        }
        if lower.hasPrefix("eth") {
            return 20
        }
        return 100
    }

    /// Resolves the best guest delivery IP from a provided list of interface snapshots.
    public static func resolveBestGuestDeliveryIP(from interfaces: [NetworkInterfaceSnapshot]) -> String? {
        let validCandidates = interfaces.filter { isGuestRoutable(interface: $0) }
        guard !validCandidates.isEmpty else { return nil }

        let sorted = validCandidates.sorted { lhs, rhs in
            let scoreL = priorityScore(for: lhs.name)
            let scoreR = priorityScore(for: rhs.name)
            if scoreL != scoreR {
                return scoreL < scoreR
            }
            return lhs.name < rhs.name
        }

        return sorted.first?.address
    }

    /// Queries the live system network interfaces and returns the best routable guest delivery IP.
    public static func resolveBestGuestDeliveryIP() -> String? {
        let snapshots = captureSystemInterfaceSnapshots()
        return resolveBestGuestDeliveryIP(from: snapshots)
    }

    public static func captureSystemInterfaceSnapshots() -> [NetworkInterfaceSnapshot] {
        var snapshots: [NetworkInterfaceSnapshot] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let flags = current.pointee.ifa_flags

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = hostname.withUnsafeBufferPointer { buffer in
                String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
            }
            snapshots.append(NetworkInterfaceSnapshot(name: name, flags: flags, address: ip, family: family))
        }
        return snapshots
    }
}
