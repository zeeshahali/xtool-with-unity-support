import Foundation
import SwiftyMobileDevice
import libimobiledevice

/// A raw connection to the `CoreDeviceProxy` lockdown service (iOS 17.4+).
///
/// After the `CDTunnel` handshake, this carries raw IPv6 packets between the host
/// and the device's tunnel interface.
final class CoreDeviceProxyConnection {

    static let serviceIdentifier = "com.apple.internal.devicecompute.CoreDeviceProxy"

    enum Error: Swift.Error, LocalizedError {
        case invalidArg
        case muxError
        case sslError
        case startServiceError
        case notEnoughData
        case timeout
        case unknown(Int32)

        init?(_ raw: service_error_t) {
            switch raw {
            case SERVICE_E_SUCCESS: return nil
            case SERVICE_E_INVALID_ARG: self = .invalidArg
            case SERVICE_E_MUX_ERROR: self = .muxError
            case SERVICE_E_SSL_ERROR: self = .sslError
            case SERVICE_E_START_SERVICE_ERROR: self = .startServiceError
            case SERVICE_E_NOT_ENOUGH_DATA: self = .notEnoughData
            case SERVICE_E_TIMEOUT: self = .timeout
            default: self = .unknown(raw.rawValue)
            }
        }

        static func check(_ raw: service_error_t) throws {
            if let error = Error(raw) { throw error }
        }

        var errorDescription: String? {
            "CoreDeviceProxyConnection.Error.\(self)"
        }
    }

    private let raw: service_client_t

    /// Starts the service. `service_client_new` enables SSL itself when the
    /// descriptor asks for it.
    init(device: Device, lockdown: LockdownClient) throws {
        let descriptor = try lockdown.startService(identifier: Self.serviceIdentifier)
        var client: service_client_t?
        try Error.check(service_client_new(device.raw, descriptor.raw, &client))
        guard let client else { throw Error.unknown(0) }
        self.raw = client
    }

    deinit { service_client_free(raw) }

    func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let base = buffer.bindMemory(to: Int8.self).baseAddress
            var offset = 0
            while offset < buffer.count {
                var sent: UInt32 = 0
                try Error.check(service_send(raw, base?.advanced(by: offset), UInt32(buffer.count - offset), &sent))
                offset += Int(sent)
            }
        }
    }

    /// Receives up to `maxLength` bytes. Throws `.timeout` if nothing arrives in time.
    func receive(maxLength: Int, timeout: TimeInterval?) throws -> Data {
        var buffer = [Int8](repeating: 0, count: maxLength)
        var received: UInt32 = 0
        let status = buffer.withUnsafeMutableBufferPointer { ptr in
            if let timeout {
                service_receive_with_timeout(raw, ptr.baseAddress, UInt32(maxLength), &received, UInt32(timeout * 1000))
            } else {
                service_receive(raw, ptr.baseAddress, UInt32(maxLength), &received)
            }
        }
        // a timeout that still delivered bytes is a partial read, not an error
        if status == SERVICE_E_TIMEOUT && received > 0 {
            return Data(bytes: buffer, count: Int(received))
        }
        try Error.check(status)
        return Data(bytes: buffer, count: Int(received))
    }

    func receiveExactly(_ count: Int, timeout: TimeInterval?) throws -> Data {
        var data = Data()
        while data.count < count {
            data += try receive(maxLength: count - data.count, timeout: timeout)
        }
        return data
    }
}
