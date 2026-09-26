import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

public enum GuestDeliveryInterfaceType: String, Codable, Sendable, Equatable {
    case wifi
    case ethernet
    case other
    case unknown
    case conflicting
}

public enum GuestDeliveryInterfaceSelection: Sendable, Equatable {
    case automatic
    case wifi
    case ethernet
    case interface(name: String)

    public static func forBoothNetwork(
        requested: BoothNetworkPreference,
        effective: BoothEffectiveNetworkTransport
    ) -> GuestDeliveryInterfaceSelection {
        switch effective {
        case .wifi: return .wifi
        case .lan: return .ethernet
        case .unavailable:
            return requested == .lan ? .ethernet : .wifi
        }
    }
}

public struct GuestDeliveryEndpoint: Sendable, Equatable {
    public let interfaceName: String
    public let interfaceIndex: UInt32?
    public let interfaceType: GuestDeliveryInterfaceType
    public let address: String
    public let port: UInt16

    public init(
        interfaceName: String,
        interfaceIndex: UInt32?,
        interfaceType: GuestDeliveryInterfaceType,
        address: String,
        port: UInt16
    ) {
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
        self.interfaceType = interfaceType
        self.address = address
        self.port = port
    }

    public var baseURL: String { "http://\(address):\(port)" }
    public var diagnosticDescription: String {
        let type = switch interfaceType {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .other: "Other"
        case .unknown: "Unknown interface type"
        case .conflicting: "Conflicting interface type"
        }
        return "\(type) · \(interfaceName) · \(address):\(port)"
    }
}

public enum GuestDeliveryResolution: Sendable, Equatable {
    case ready(GuestDeliveryEndpoint)
    case ambiguous(interfaceNames: [String])
    case unavailable

    public var endpoint: GuestDeliveryEndpoint? {
        guard case .ready(let endpoint) = self else { return nil }
        return endpoint
    }
}

public struct NetworkInterfaceSnapshot: Sendable, Equatable {
    public let name: String
    public let flags: UInt32
    public let address: String
    public let family: Int32
    public let interfaceIndex: UInt32?
    public let interfaceType: GuestDeliveryInterfaceType?

    public init(
        name: String,
        flags: UInt32,
        address: String,
        family: Int32 = AF_INET,
        interfaceIndex: UInt32? = nil,
        interfaceType: GuestDeliveryInterfaceType? = nil
    ) {
        self.name = name
        self.flags = flags
        self.address = address
        self.family = family
        self.interfaceIndex = interfaceIndex
        self.interfaceType = interfaceType
    }
}

public enum GuestDeliveryEndpointResolver {
    private static let excludedInterfacePrefixes: [String] = [
        "lo", "bridge", "utun", "ppp", "docker", "vboxnet", "vmnet",
        "veth", "vnic", "awdl", "llw", "anpi", "gif", "stf", "ipsec"
    ]
    private static let configuredDirectEthernetAddresses: Set<String> = ["192.168.4.1", "10.0.0.1"]

    public static func isRFC1918PrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return parts[0] == 192 && parts[1] == 168
    }

    public static func isAcceptableInterfaceName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !excludedInterfacePrefixes.contains(where: lower.hasPrefix)
    }

    public static func isGuestRoutable(interface: NetworkInterfaceSnapshot) -> Bool {
        let flags = Int32(interface.flags)
        guard interface.family == AF_INET,
              flags & IFF_UP != 0,
              flags & IFF_RUNNING != 0,
              flags & IFF_LOOPBACK == 0,
              isAcceptableInterfaceName(interface.name),
              isRFC1918PrivateIPv4(interface.address) else { return false }
        return true
    }

    public static func resolve(
        from interfaces: [NetworkInterfaceSnapshot],
        selection: GuestDeliveryInterfaceSelection,
        port: UInt16 = 8585
    ) -> GuestDeliveryResolution {
        let valid = interfaces.filter(isGuestRoutable(interface:))
        let conflictingNames = Array(Set(valid.compactMap {
            $0.interfaceType == .conflicting ? $0.name : nil
        })).sorted()
        guard conflictingNames.isEmpty else {
            return .ambiguous(interfaceNames: conflictingNames)
        }

        let candidates: [NetworkInterfaceSnapshot]
        switch selection {
        case .automatic:
            candidates = valid
        case .wifi:
            candidates = valid.filter { $0.interfaceType == .wifi }
        case .ethernet:
            candidates = valid.filter {
                $0.interfaceType == .ethernet
                    || (($0.interfaceType == nil || $0.interfaceType == .unknown)
                        && configuredDirectEthernetAddresses.contains($0.address))
            }
        case .interface(let name):
            candidates = valid.filter { $0.name == name }
        }

        guard !candidates.isEmpty else { return .unavailable }
        guard candidates.count == 1, let candidate = candidates.first else {
            return .ambiguous(interfaceNames: Array(Set(candidates.map(\.name))).sorted())
        }

        let type: GuestDeliveryInterfaceType
        if let interfaceType = candidate.interfaceType, interfaceType != .unknown {
            type = interfaceType
        } else {
            type = configuredDirectEthernetAddresses.contains(candidate.address) ? .ethernet : .unknown
        }
        return .ready(GuestDeliveryEndpoint(
            interfaceName: candidate.name,
            interfaceIndex: candidate.interfaceIndex,
            interfaceType: type,
            address: candidate.address,
            port: port
        ))
    }

    public static func resolveSystem(
        selection: GuestDeliveryInterfaceSelection,
        port: UInt16 = 8585
    ) -> GuestDeliveryResolution {
        resolve(from: captureSystemInterfaceSnapshots(), selection: selection, port: port)
    }

    public static func resolveBestGuestDeliveryIP(from interfaces: [NetworkInterfaceSnapshot]) -> String? {
        resolve(from: interfaces, selection: .automatic).endpoint?.address
    }

    public static func resolveBestGuestDeliveryIP() -> String? {
        resolveSystem(selection: .automatic).endpoint?.address
    }

    public static func captureSystemInterfaceSnapshots() -> [NetworkInterfaceSnapshot] {
        let pathTypes = GuestDeliveryPathInterfaceTypes.shared.snapshot()
        var snapshots: [NetworkInterfaceSnapshot] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_INET else { continue }
            let name = String(cString: current.pointee.ifa_name)
            let rawInterfaceIndex = name.withCString { if_nametoindex($0) }
            let interfaceIndex = rawInterfaceIndex == 0 ? nil : rawInterfaceIndex
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
            snapshots.append(NetworkInterfaceSnapshot(
                name: name,
                flags: current.pointee.ifa_flags,
                address: ip,
                interfaceIndex: interfaceIndex,
                interfaceType: pathTypes.interfaceType(name: name, index: interfaceIndex)
            ))
        }
        return snapshots
    }
}

struct GuestDeliveryPathInterface: Sendable {
    let name: String
    let index: UInt32?
    let type: GuestDeliveryInterfaceType
}

struct GuestDeliveryPathInterfaceTypeMap: Sendable, Equatable {
    private(set) var byName: [String: GuestDeliveryInterfaceType] = [:]
    private(set) var byIndex: [UInt32: GuestDeliveryInterfaceType] = [:]

    init(interfaces: [GuestDeliveryPathInterface] = []) {
        for interface in interfaces {
            byName[interface.name] = Self.merging(byName[interface.name], interface.type)
            if let index = interface.index {
                byIndex[index] = Self.merging(byIndex[index], interface.type)
            }
        }
    }

    func interfaceType(name: String, index: UInt32?) -> GuestDeliveryInterfaceType? {
        guard let byNameType = byName[name] else { return index.flatMap { byIndex[$0] } }
        guard let index, let byIndexType = byIndex[index] else { return byNameType }
        return Self.merging(byNameType, byIndexType)
    }

    private static func merging(
        _ current: GuestDeliveryInterfaceType?,
        _ incoming: GuestDeliveryInterfaceType
    ) -> GuestDeliveryInterfaceType {
        guard let current else { return incoming }
        if current == incoming { return current }
        if current == .conflicting || incoming == .conflicting { return .conflicting }

        let currentIsGeneric = current == .other || current == .unknown
        let incomingIsGeneric = incoming == .other || incoming == .unknown
        if currentIsGeneric && incomingIsGeneric { return .other }
        if currentIsGeneric { return incoming }
        if incomingIsGeneric { return current }
        return .conflicting
    }
}

final class GuestDeliveryPathInterfaceTypes: @unchecked Sendable {
    static let shared = GuestDeliveryPathInterfaceTypes()

    // NSLock protects replacement and copying of this immutable snapshot.
    private let lock = NSLock()
    private var types = GuestDeliveryPathInterfaceTypeMap()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "PRC-PhotoBooth.GuestDeliveryPath", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let updated = path.availableInterfaces.map { interface in
                let type: GuestDeliveryInterfaceType = switch interface.type {
                case .wifi: .wifi
                case .wiredEthernet: .ethernet
                default: .other
                }
                return GuestDeliveryPathInterface(
                    name: interface.name,
                    index: UInt32(exactly: interface.index),
                    type: type
                )
            }
            guard let self else { return }
            let snapshot = GuestDeliveryPathInterfaceTypeMap(interfaces: updated)
            self.lock.lock()
            self.types = snapshot
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    func snapshot() -> GuestDeliveryPathInterfaceTypeMap {
        lock.lock()
        defer { lock.unlock() }
        return types
    }
}
