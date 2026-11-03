import Foundation
import SwiftyMobileDevice

/// The device end of an iOS 17+ CoreDevice tunnel, reached over USB through
/// the `CoreDeviceProxy` lockdown service.
///
/// Once established, the tunnel carries raw IPv6 packets with no extra framing.
final class CoreDeviceTunnel {

    struct Parameters: Sendable {
        var clientAddress: String
        var serverAddress: String
        var serverRSDPort: UInt16
        var mtu: Int
    }

    enum Error: Swift.Error, LocalizedError {
        case badHandshake(String)

        var errorDescription: String? {
            switch self {
            case .badHandshake(let reason):
                "CoreDevice tunnel handshake failed: \(reason)"
            }
        }
    }

    private static let magic = Data("CDTunnel".utf8)
    private static let requestedMTU = 16000
    private static let ipv6HeaderSize = 40

    let connection: CoreDeviceProxyConnection
    let parameters: Parameters

    init(device: Device, lockdown: LockdownClient) throws {
        connection = try CoreDeviceProxyConnection(device: device, lockdown: lockdown)
        parameters = try Self.handshake(over: connection)
    }

    // CDTunnel packet: "CDTunnel" + big-endian UInt16 length + JSON body
    private static func handshake(over connection: CoreDeviceProxyConnection) throws -> Parameters {
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "clientHandshakeRequest",
            "mtu": requestedMTU,
        ])
        var request = magic
        request.append(contentsOf: [UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
        request.append(body)
        try connection.sendAll(request)

        let header = try connection.receiveExactly(magic.count + 2, timeout: 10)
        guard header.prefix(magic.count) == magic else {
            throw Error.badHandshake("unexpected response magic")
        }
        let length = Int(header[header.startIndex + magic.count]) << 8
            | Int(header[header.startIndex + magic.count + 1])
        let responseBody = try connection.receiveExactly(length, timeout: 10)

        guard let response = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let client = response["clientParameters"] as? [String: Any],
              let clientAddress = client["address"] as? String,
              let serverAddress = response["serverAddress"] as? String,
              let rsdPort = (response["serverRSDPort"] as? NSNumber)?.uint16Value
        else {
            throw Error.badHandshake(String(decoding: responseBody, as: UTF8.self))
        }
        let mtu = (client["mtu"] as? NSNumber)?.intValue ?? 1500
        return Parameters(
            clientAddress: clientAddress,
            serverAddress: serverAddress,
            serverRSDPort: rsdPort,
            mtu: mtu
        )
    }

    func send(packet: Data) throws {
        try connection.sendAll(packet)
    }

    /// Reads one IPv6 packet, delimited by the payload length in its header.
    func receivePacket(timeout: TimeInterval? = nil) throws -> Data {
        let header = try connection.receiveExactly(Self.ipv6HeaderSize, timeout: timeout)
        let payloadLength = Int(header[header.startIndex + 4]) << 8 | Int(header[header.startIndex + 5])
        return header + (try connection.receiveExactly(payloadLength, timeout: timeout))
    }
}
