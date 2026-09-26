import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif

@testable import PRC_PhotoBooth_Mac

@Suite("Guest Delivery Endpoint Resolver")
struct GuestDeliveryEndpointResolverTests {
    private let activeFlags: UInt32 = UInt32(IFF_UP | IFF_RUNNING)
    private let downFlags: UInt32 = UInt32(IFF_RUNNING) // missing IFF_UP
    private let loopbackFlags: UInt32 = UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK)

    @Test("loopback interface is rejected")
    func loopbackIsRejected() {
        let lo0 = NetworkInterfaceSnapshot(name: "lo0", flags: loopbackFlags, address: "127.0.0.1")
        #expect(!GuestDeliveryEndpointResolver.isGuestRoutable(interface: lo0))
        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [lo0]) == nil)
    }

    @Test("virtual bridge interfaces are rejected")
    func virtualBridgeIsRejected() {
        let bridge = NetworkInterfaceSnapshot(name: "bridge100", flags: activeFlags, address: "192.168.2.1")
        #expect(!GuestDeliveryEndpointResolver.isGuestRoutable(interface: bridge))
        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [bridge]) == nil)
    }

    @Test("docker and vm interfaces are rejected")
    func dockerAndVMInterfacesAreRejected() {
        let docker = NetworkInterfaceSnapshot(name: "docker0", flags: activeFlags, address: "172.17.0.1")
        let vbox = NetworkInterfaceSnapshot(name: "vboxnet0", flags: activeFlags, address: "192.168.56.1")
        let vmnet = NetworkInterfaceSnapshot(name: "vmnet1", flags: activeFlags, address: "192.168.105.1")
        for iface in [docker, vbox, vmnet] {
            #expect(!GuestDeliveryEndpointResolver.isGuestRoutable(interface: iface))
        }
        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [docker, vbox, vmnet]) == nil)
    }

    @Test("vpn and tunnel interfaces are rejected")
    func vpnAndTunnelInterfacesAreRejected() {
        let utun = NetworkInterfaceSnapshot(name: "utun2", flags: activeFlags, address: "10.8.0.2")
        let ppp = NetworkInterfaceSnapshot(name: "ppp0", flags: activeFlags, address: "10.0.0.1")
        let gif = NetworkInterfaceSnapshot(name: "gif0", flags: activeFlags, address: "192.168.1.1")
        for iface in [utun, ppp, gif] {
            #expect(!GuestDeliveryEndpointResolver.isGuestRoutable(interface: iface))
        }
        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [utun, ppp, gif]) == nil)
    }

    @Test("down or inactive interface is rejected")
    func inactiveInterfaceIsRejected() {
        let down = NetworkInterfaceSnapshot(name: "en0", flags: downFlags, address: "192.168.1.50")
        #expect(!GuestDeliveryEndpointResolver.isGuestRoutable(interface: down))
        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [down]) == nil)
    }

    @Test("non-RFC1918 addresses are rejected")
    func nonRFC1918IsRejected() {
        let publicIP = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "8.8.8.8")
        let invalid172Low = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "172.15.0.1")
        let invalid172High = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "172.32.0.1")
        let zeroes = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "0.0.0.0")

        for iface in [publicIP, invalid172Low, invalid172High, zeroes] {
            #expect(!GuestDeliveryEndpointResolver.isGuestRoutable(interface: iface))
        }
    }

    @Test("valid RFC 1918 interfaces are accepted")
    func validRFC1918IsAccepted() {
        let en0Ten = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "10.0.4.15")
        let en0Seventeen = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "172.20.10.2")
        let en1Nineteen = NetworkInterfaceSnapshot(name: "en1", flags: activeFlags, address: "192.168.1.100")

        #expect(GuestDeliveryEndpointResolver.isGuestRoutable(interface: en0Ten))
        #expect(GuestDeliveryEndpointResolver.isGuestRoutable(interface: en0Seventeen))
        #expect(GuestDeliveryEndpointResolver.isGuestRoutable(interface: en1Nineteen))
    }

    @Test("automatic selection fails closed when physical networks are ambiguous")
    func automaticSelectionFailsClosedWhenAmbiguous() {
        let en1 = NetworkInterfaceSnapshot(name: "en1", flags: activeFlags, address: "192.168.1.100")
        let en0 = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "10.0.0.50")
        let bridge = NetworkInterfaceSnapshot(name: "bridge100", flags: activeFlags, address: "192.168.2.1")
        let lo0 = NetworkInterfaceSnapshot(name: "lo0", flags: loopbackFlags, address: "127.0.0.1")

        let result = GuestDeliveryEndpointResolver.resolve(from: [bridge, en1, lo0, en0], selection: .automatic)
        #expect(result == .ambiguous(interfaceNames: ["en0", "en1"]))
        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [bridge, en1, lo0, en0]) == nil)
    }

    @Test("selected Ethernet chooses direct Ethernet even when Wi-Fi is also active")
    func selectedEthernetWinsOverWiFi() throws {
        let wifi = NetworkInterfaceSnapshot(
            name: "en0", flags: activeFlags, address: "10.10.0.5",
            interfaceIndex: 4, interfaceType: .wifi
        )
        let ethernet = NetworkInterfaceSnapshot(
            name: "en5", flags: activeFlags, address: "192.168.4.1",
            interfaceIndex: 9, interfaceType: .ethernet
        )

        let endpoint = try #require(GuestDeliveryEndpointResolver.resolve(
            from: [wifi, ethernet], selection: .ethernet
        ).endpoint)
        #expect(endpoint.address == "192.168.4.1")
        #expect(endpoint.interfaceName == "en5")
        #expect(endpoint.interfaceIndex == 9)
        #expect(endpoint.interfaceType == .ethernet)
        #expect(endpoint.port == 8585)
    }

    @Test("selected Wi-Fi chooses the active Wi-Fi interface when Ethernet is also active")
    func selectedWiFiWinsOverEthernet() throws {
        let wifi = NetworkInterfaceSnapshot(
            name: "en0", flags: activeFlags, address: "10.10.0.5", interfaceType: .wifi
        )
        let ethernet = NetworkInterfaceSnapshot(
            name: "en5", flags: activeFlags, address: "192.168.4.1", interfaceType: .ethernet
        )

        let endpoint = try #require(GuestDeliveryEndpointResolver.resolve(
            from: [wifi, ethernet], selection: .wifi
        ).endpoint)
        #expect(endpoint.address == "10.10.0.5")
        #expect(endpoint.interfaceName == "en0")
        #expect(endpoint.interfaceType == .wifi)
    }

    @Test("duplicate path entries with the same type merge without trapping")
    func duplicatePathEntriesMergeSameType() {
        let map = GuestDeliveryPathInterfaceTypeMap(interfaces: [
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi),
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi)
        ])
        #expect(map.interfaceType(name: "en0", index: 4) == .wifi)
    }

    @Test("generic and concrete path types merge in either order")
    func genericAndConcretePathTypesMergeDeterministically() {
        let otherThenWiFi = GuestDeliveryPathInterfaceTypeMap(interfaces: [
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .other),
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi)
        ])
        let wifiThenOther = GuestDeliveryPathInterfaceTypeMap(interfaces: [
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi),
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .other)
        ])

        #expect(otherThenWiFi.interfaceType(name: "en0", index: 4) == .wifi)
        #expect(wifiThenOther.interfaceType(name: "en0", index: 4) == .wifi)
    }

    @Test("conflicting concrete path types fail guest delivery closed")
    func conflictingConcretePathTypesAreAmbiguous() {
        let map = GuestDeliveryPathInterfaceTypeMap(interfaces: [
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi),
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .ethernet)
        ])
        let type = map.interfaceType(name: "en0", index: 4)
        let en0 = NetworkInterfaceSnapshot(
            name: "en0", flags: activeFlags, address: "10.10.0.5", interfaceType: type
        )

        #expect(type == .conflicting)
        #expect(GuestDeliveryEndpointResolver.resolve(from: [en0], selection: .automatic)
            == .ambiguous(interfaceNames: ["en0"]))
        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [en0]) == nil)
    }

    @Test("separate interfaces retain their own classifications")
    func multiplePathInterfacesKeepIndependentTypes() {
        let map = GuestDeliveryPathInterfaceTypeMap(interfaces: [
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi),
            GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi),
            GuestDeliveryPathInterface(name: "en5", index: 9, type: .ethernet)
        ])

        #expect(map.interfaceType(name: "en0", index: 4) == .wifi)
        #expect(map.interfaceType(name: "en5", index: 9) == .ethernet)
    }

    @Test("replacing path snapshots clears stale and conflicting classifications")
    func repeatedPathUpdatesReplaceTheCache() {
        let wifi = GuestDeliveryPathInterface(name: "en0", index: 4, type: .wifi)
        let ethernet = GuestDeliveryPathInterface(name: "en0", index: 4, type: .ethernet)

        var map = GuestDeliveryPathInterfaceTypeMap(interfaces: [wifi])
        #expect(map.interfaceType(name: "en0", index: 4) == .wifi)
        map = GuestDeliveryPathInterfaceTypeMap(interfaces: [wifi, wifi])
        #expect(map.interfaceType(name: "en0", index: 4) == .wifi)
        map = GuestDeliveryPathInterfaceTypeMap(interfaces: [wifi, ethernet])
        #expect(map.interfaceType(name: "en0", index: 4) == .conflicting)
        map = GuestDeliveryPathInterfaceTypeMap(interfaces: [ethernet])
        #expect(map.interfaceType(name: "en0", index: 4) == .ethernet)
        map = GuestDeliveryPathInterfaceTypeMap(interfaces: [wifi])
        #expect(map.interfaceType(name: "en0", index: 4) == .wifi)
    }

    @Test("known Wi-Fi at a configured direct-LAN address is never selected as Ethernet")
    func knownWiFiCannotBeReclassifiedByAddress() {
        let wifi = NetworkInterfaceSnapshot(
            name: "en0", flags: activeFlags, address: "10.0.0.1", interfaceType: .wifi
        )

        #expect(GuestDeliveryEndpointResolver.resolve(from: [wifi], selection: .ethernet) == .unavailable)
        #expect(GuestDeliveryEndpointResolver.resolve(from: [wifi], selection: .wifi).endpoint?.interfaceType == .wifi)
    }

    @Test("configured direct-LAN address selects only an unclassified interface")
    func directLANAddressFallbackRequiresUnknownInterfaceType() throws {
        let unknown = NetworkInterfaceSnapshot(
            name: "en5", flags: activeFlags, address: "192.168.4.1", interfaceType: .unknown
        )
        let endpoint = try #require(GuestDeliveryEndpointResolver.resolve(
            from: [unknown], selection: .ethernet
        ).endpoint)
        #expect(endpoint.interfaceType == .ethernet)
    }

    @Test("multiple matching interfaces remain ambiguous")
    func matchingInterfacesRemainAmbiguous() {
        let first = NetworkInterfaceSnapshot(
            name: "en0", flags: activeFlags, address: "10.10.0.5", interfaceType: .wifi
        )
        let second = NetworkInterfaceSnapshot(
            name: "en1", flags: activeFlags, address: "10.10.0.6", interfaceType: .wifi
        )
        #expect(GuestDeliveryEndpointResolver.resolve(from: [first, second], selection: .wifi)
            == .ambiguous(interfaceNames: ["en0", "en1"]))
    }

    @Test("guest endpoint reports unavailable for filtered virtual interfaces")
    func virtualOnlyEndpointIsUnavailable() {
        let vm = NetworkInterfaceSnapshot(name: "vmnet1", flags: activeFlags, address: "192.168.56.1")
        #expect(GuestDeliveryEndpointResolver.resolve(from: [vm], selection: .ethernet) == .unavailable)
    }

    @Test("booth network preference maps to effective guest interface")
    func boothNetworkPreferenceMapsToEffectiveGuestInterface() {
        #expect(GuestDeliveryInterfaceSelection.forBoothNetwork(requested: .lan, effective: .unavailable) == .ethernet)
        #expect(GuestDeliveryInterfaceSelection.forBoothNetwork(requested: .wifi, effective: .lan) == .ethernet)
        #expect(GuestDeliveryInterfaceSelection.forBoothNetwork(requested: .lan, effective: .wifi) == .wifi)
    }

    @Test("returns nil when no routable interface exists")
    func returnsNilWhenNoRoutableInterfaceExists() {
        let bridge = NetworkInterfaceSnapshot(name: "bridge100", flags: activeFlags, address: "192.168.2.1")
        let lo0 = NetworkInterfaceSnapshot(name: "lo0", flags: loopbackFlags, address: "127.0.0.1")
        let utun = NetworkInterfaceSnapshot(name: "utun0", flags: activeFlags, address: "10.2.0.1")

        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [bridge, lo0, utun]) == nil)
    }
}
