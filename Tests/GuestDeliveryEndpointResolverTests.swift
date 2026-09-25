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

    @Test("prefers primary physical interface en0 over others")
    func prefersPrimaryPhysicalInterface() {
        let en1 = NetworkInterfaceSnapshot(name: "en1", flags: activeFlags, address: "192.168.1.100")
        let en0 = NetworkInterfaceSnapshot(name: "en0", flags: activeFlags, address: "10.0.0.50")
        let bridge = NetworkInterfaceSnapshot(name: "bridge100", flags: activeFlags, address: "192.168.2.1")
        let lo0 = NetworkInterfaceSnapshot(name: "lo0", flags: loopbackFlags, address: "127.0.0.1")

        let best = GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [bridge, en1, lo0, en0])
        #expect(best == "10.0.0.50")
    }

    @Test("returns nil when no routable interface exists")
    func returnsNilWhenNoRoutableInterfaceExists() {
        let bridge = NetworkInterfaceSnapshot(name: "bridge100", flags: activeFlags, address: "192.168.2.1")
        let lo0 = NetworkInterfaceSnapshot(name: "lo0", flags: loopbackFlags, address: "127.0.0.1")
        let utun = NetworkInterfaceSnapshot(name: "utun0", flags: activeFlags, address: "10.2.0.1")

        #expect(GuestDeliveryEndpointResolver.resolveBestGuestDeliveryIP(from: [bridge, lo0, utun]) == nil)
    }
}
