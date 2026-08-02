import Foundation
import Network

// Streams JPEG preview frames to the iPad over a TCP connection.
// Advertises via Bonjour (_prc-hq._tcp) so the iPad can discover it on any
// interface — including the USB-C virtual ethernet that appears when the iPad
// is plugged in and trusted. USB gives lower latency and higher throughput
// than the MPC unreliable channel used for WiFi preview.
//
// Frame format: [4-byte big-endian length][JPEG bytes]
@MainActor
@Observable
final class USBPreviewServer {
    private(set) var isClientConnected = false
    // Whether the Mac side could start its Bonjour listener.
    private(set) var isSupported = true

    private var listener: NWListener?
    private var connection: NWConnection?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        // Let Network.framework choose an available port. Bonjour advertises the
        // selected port to the iPad, so a fixed port is unnecessary and can
        // collide with a previous app instance or another local service.
        guard let l = try? NWListener(using: params) else {
            isSupported = false
            return
        }
        // A fresh name prevents an iPad from selecting a cached record left by
        // a previous Mac app instance after the listener is restarted.
        let suffix = UUID().uuidString.prefix(8)
        l.service = NWListener.Service(name: "PRC-Booth-HQ-\(suffix)", type: "_prc-hq._tcp")
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in self?.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isSupported = true
                case .failed:
                    self?.isSupported = false
                default:
                    break
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel(); connection?.cancel()
        listener = nil; connection = nil
        isClientConnected = false
    }

    private func accept(_ incoming: NWConnection) {
        connection?.cancel()
        connection = incoming
        incoming.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:    self?.isClientConnected = true
                case .failed, .cancelled:
                    self?.isClientConnected = false
                    self?.connection = nil
                default: break
                }
            }
        }
        incoming.start(queue: .main)
    }

    func send(_ jpegData: Data) {
        guard isClientConnected, let conn = connection else { return }
        var length = UInt32(jpegData.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(jpegData)
        conn.send(content: frame, completion: .idempotent)
    }
}
