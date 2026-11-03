import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A minimal userspace TCP/IPv6 client that runs over a ``CoreDeviceTunnel``.
///
/// The tunnel is a reliable, in-order USB stream, so this skips congestion control
/// and keeps loss recovery to a simple resend of unacknowledged data. It still has
/// to checksum, ACK promptly (the device retransmits otherwise), drop duplicates,
/// and honour the peer's window. Everything is driven synchronously by ``pump``.
final class TunnelNetwork {

    enum Error: Swift.Error, LocalizedError {
        case invalidAddress(String)
        case connectionReset
        case connectionClosed
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .invalidAddress(let address): "Invalid IPv6 address '\(address)'"
            case .connectionReset: "The device reset the connection"
            case .connectionClosed: "The device closed the connection"
            case .timedOut(let what): "Timed out \(what)"
            }
        }
    }

    // the proven-safe segment size across devices; USB CoreDeviceProxy drops
    // host->device packets over 8192 bytes
    static let maxSegmentSize = 1340
    static let receiveWindow: UInt16 = 65535

    let tunnel: CoreDeviceTunnel
    let localAddress: [UInt8]
    let remoteAddress: [UInt8]

    private var connections: [UInt16: TunnelTCPConnection] = [:]
    private var nextPort: UInt16 = .random(in: 49152...60000)

    init(tunnel: CoreDeviceTunnel) throws {
        self.tunnel = tunnel
        localAddress = try Self.parse(tunnel.parameters.clientAddress)
        remoteAddress = try Self.parse(tunnel.parameters.serverAddress)
    }

    private static func parse(_ address: String) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(AF_INET6, address, &bytes) == 1 else { throw Error.invalidAddress(address) }
        return bytes
    }

    func connect(port: UInt16, timeout: TimeInterval = 10) throws -> TunnelTCPConnection {
        let localPort = nextPort
        nextPort = nextPort == 60000 ? 49152 : nextPort + 1
        let connection = TunnelTCPConnection(network: self, localPort: localPort, remotePort: port)
        connections[localPort] = connection
        try connection.open(timeout: timeout)
        return connection
    }

    func remove(_ connection: TunnelTCPConnection) {
        connections[connection.localPort] = nil
    }

    /// Reads one packet from the tunnel and hands it to its connection.
    /// Throws ``CoreDeviceProxyConnection/Error/timeout`` if none arrives in time.
    func pump(timeout: TimeInterval) throws {
        let packet = try tunnel.receivePacket(timeout: timeout)
        guard let segment = TCPSegment(ipv6Packet: packet) else { return }
        connections[segment.destinationPort]?.handle(segment)
    }

    func send(_ segment: TCPSegment) throws {
        try tunnel.send(packet: segment.ipv6Packet(source: localAddress, destination: remoteAddress))
    }
}

final class TunnelTCPConnection {

    private enum State {
        case synSent, established, closed
    }

    let localPort: UInt16
    let remotePort: UInt16
    // strong: the launcher only holds the network until its last direct use;
    // close() breaks the cycle by removing the connection from the network
    private let network: TunnelNetwork

    private var state = State.synSent
    private var sendNext: UInt32 = .random(in: 0...UInt32.max)
    private var sendUnacked: UInt32 = 0
    private var receiveNext: UInt32 = 0
    private var peerWindow = Int(TunnelNetwork.receiveWindow)
    private var unackedData = Data()
    private var received = Data()
    private var peerFinished = false
    private var reset = false

    init(network: TunnelNetwork, localPort: UInt16, remotePort: UInt16) {
        self.network = network
        self.localPort = localPort
        self.remotePort = remotePort
    }

    fileprivate func open(timeout: TimeInterval) throws {
        sendUnacked = sendNext
        let syn = segment(flags: .syn, sequence: sendNext, options: Self.mssOption)
        sendNext &+= 1
        try network.send(syn)
        let deadline = Date().addingTimeInterval(timeout)
        while state == .synSent {
            if reset { throw TunnelNetwork.Error.connectionReset }
            guard Date() < deadline else { throw TunnelNetwork.Error.timedOut("connecting to port \(remotePort)") }
            try pumpIgnoringTimeout(0.5)
        }
    }

    // MSS option: kind 2, length 4
    private static let mssOption: [UInt8] = [
        2, 4, UInt8(TunnelNetwork.maxSegmentSize >> 8), UInt8(TunnelNetwork.maxSegmentSize & 0xFF),
    ]

    fileprivate func handle(_ incoming: TCPSegment) {
        guard incoming.sourcePort == remotePort else { return }
        if incoming.flags.contains(.rst) {
            reset = true
            state = .closed
            return
        }

        if state == .synSent {
            guard incoming.flags.contains([.syn, .ack]), incoming.acknowledgment == sendNext else { return }
            receiveNext = incoming.sequence &+ 1
            sendUnacked = incoming.acknowledgment
            peerWindow = Int(incoming.window)
            state = .established
            try? sendAck()
            return
        }

        if incoming.flags.contains(.ack) {
            let acked = Int(incoming.acknowledgment &- sendUnacked)
            if acked > 0 && acked <= unackedData.count {
                unackedData.removeFirst(acked)
                sendUnacked = incoming.acknowledgment
            }
            peerWindow = Int(incoming.window)
        }

        let payloadLength = incoming.payload.count + (incoming.flags.contains(.fin) ? 1 : 0)
        guard payloadLength > 0 else { return }

        if incoming.sequence == receiveNext {
            received.append(incoming.payload)
            receiveNext &+= UInt32(payloadLength)
            if incoming.flags.contains(.fin) { peerFinished = true }
        }
        // in order, duplicate or out of order: (re)acknowledge what we have so the
        // device resends from receiveNext
        try? sendAck()
    }

    private func segment(
        flags: TCPSegment.Flags,
        sequence: UInt32? = nil,
        options: [UInt8] = [],
        payload: Data = Data()
    ) -> TCPSegment {
        TCPSegment(
            sourcePort: localPort,
            destinationPort: remotePort,
            sequence: sequence ?? sendNext,
            acknowledgment: flags.contains(.ack) ? receiveNext : 0,
            flags: flags,
            window: TunnelNetwork.receiveWindow,
            options: options,
            payload: payload
        )
    }

    private func sendAck() throws {
        try network.send(segment(flags: .ack))
    }

    private func pumpIgnoringTimeout(_ timeout: TimeInterval) throws {
        do {
            try network.pump(timeout: timeout)
        } catch CoreDeviceProxyConnection.Error.timeout {}
    }

    func send(_ data: Data, timeout: TimeInterval = 10) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        var lastProgress = Date()
        while offset < data.count || !unackedData.isEmpty {
            if reset { throw TunnelNetwork.Error.connectionReset }
            guard state == .established else { throw TunnelNetwork.Error.connectionClosed }
            guard Date() < deadline else { throw TunnelNetwork.Error.timedOut("sending to port \(remotePort)") }

            let room = peerWindow - unackedData.count
            if offset < data.count && room > 0 {
                let chunk = data.subdata(in: offset..<min(data.count, offset + min(room, TunnelNetwork.maxSegmentSize)))
                try network.send(segment(flags: [.ack, .psh], payload: chunk))
                sendNext &+= UInt32(chunk.count)
                unackedData.append(chunk)
                offset += chunk.count
                lastProgress = Date()
                continue
            }

            let pending = unackedData.count
            try pumpIgnoringTimeout(0.2)
            if unackedData.count < pending {
                lastProgress = Date()
            } else if Date().timeIntervalSince(lastProgress) > 1 {
                try retransmit()
                lastProgress = Date()
            }
        }
    }

    // resend everything unacknowledged, in segments
    private func retransmit() throws {
        var offset = 0
        while offset < unackedData.count {
            let end = min(unackedData.count, offset + TunnelNetwork.maxSegmentSize)
            let chunk = unackedData.subdata(in: offset..<end)
            try network.send(segment(flags: [.ack, .psh], sequence: sendUnacked &+ UInt32(offset), payload: chunk))
            offset = end
        }
    }

    /// Returns buffered data, waiting up to `timeout` for at least one byte.
    /// Returns empty data once the device has closed its side.
    func receive(timeout: TimeInterval = 10) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while received.isEmpty {
            if reset { throw TunnelNetwork.Error.connectionReset }
            if peerFinished { return Data() }
            guard Date() < deadline else { throw TunnelNetwork.Error.timedOut("waiting for port \(remotePort)") }
            try pumpIgnoringTimeout(min(0.5, max(0.01, deadline.timeIntervalSinceNow)))
        }
        defer { received.removeAll() }
        return received
    }

    func receiveExactly(_ count: Int, timeout: TimeInterval = 10) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while data.count < count {
            if received.isEmpty {
                let chunk = try receive(timeout: max(0.01, deadline.timeIntervalSinceNow))
                if chunk.isEmpty { throw TunnelNetwork.Error.connectionClosed }
                received = chunk
            }
            let take = min(count - data.count, received.count)
            data.append(received.prefix(take))
            received.removeFirst(take)
        }
        return data
    }

    func close() {
        if state == .established {
            try? network.send(segment(flags: [.fin, .ack]))
            sendNext &+= 1
        }
        state = .closed
        network.remove(self)
    }
}

struct TCPSegment {

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let fin = Flags(rawValue: 0x01)
        static let syn = Flags(rawValue: 0x02)
        static let rst = Flags(rawValue: 0x04)
        static let psh = Flags(rawValue: 0x08)
        static let ack = Flags(rawValue: 0x10)
    }

    static let tcpProtocol: UInt8 = 6

    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequence: UInt32
    var acknowledgment: UInt32
    var flags: Flags
    var window: UInt16
    var options: [UInt8] = []
    var payload: Data

    init(
        sourcePort: UInt16, destinationPort: UInt16, sequence: UInt32, acknowledgment: UInt32,
        flags: Flags, window: UInt16, options: [UInt8] = [], payload: Data = Data()
    ) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.sequence = sequence
        self.acknowledgment = acknowledgment
        self.flags = flags
        self.window = window
        self.options = options
        self.payload = payload
    }

    /// Parses a TCP segment out of an IPv6 packet. Returns nil for anything else
    /// (including packets with extension headers, which the tunnel doesn't send).
    init?(ipv6Packet packet: Data) {
        let bytes = [UInt8](packet)
        guard bytes.count >= 60, bytes[0] >> 4 == 6, bytes[6] == Self.tcpProtocol else { return nil }
        let tcp = Array(bytes[40...])
        let headerLength = Int(tcp[12] >> 4) * 4
        guard headerLength >= 20, tcp.count >= headerLength else { return nil }
        sourcePort = UInt16(tcp[0]) << 8 | UInt16(tcp[1])
        destinationPort = UInt16(tcp[2]) << 8 | UInt16(tcp[3])
        sequence = tcp[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        acknowledgment = tcp[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
        flags = Flags(rawValue: tcp[13] & 0x3F)
        window = UInt16(tcp[14]) << 8 | UInt16(tcp[15])
        options = Array(tcp[20..<headerLength])
        payload = Data(tcp[headerLength...])
    }

    func ipv6Packet(source: [UInt8], destination: [UInt8]) -> Data {
        var paddedOptions = options
        while paddedOptions.count % 4 != 0 { paddedOptions.append(0) }
        let headerLength = 20 + paddedOptions.count

        var tcp: [UInt8] = []
        tcp.reserveCapacity(headerLength + payload.count)
        tcp += [UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF)]
        tcp += [UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF)]
        tcp += Self.bigEndian(sequence)
        tcp += Self.bigEndian(acknowledgment)
        tcp += [UInt8(headerLength / 4) << 4, flags.rawValue]
        tcp += [UInt8(window >> 8), UInt8(window & 0xFF)]
        tcp += [0, 0, 0, 0] // checksum, urgent pointer
        tcp += paddedOptions
        tcp += payload

        let checksum = Self.checksum(tcp, source: source, destination: destination)
        tcp[16] = UInt8(checksum >> 8)
        tcp[17] = UInt8(checksum & 0xFF)

        var packet: [UInt8] = [0x60, 0, 0, 0]
        packet += [UInt8(tcp.count >> 8), UInt8(tcp.count & 0xFF), Self.tcpProtocol, 64]
        packet += source
        packet += destination
        packet += tcp
        return Data(packet)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    // one's-complement sum over the IPv6 pseudo-header and the segment
    static func checksum(_ tcp: [UInt8], source: [UInt8], destination: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        func add(_ bytes: [UInt8]) {
            var index = 0
            while index + 1 < bytes.count {
                sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
                index += 2
            }
            if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
        }
        add(source)
        add(destination)
        add(bigEndian(UInt32(tcp.count)))
        add([0, 0, 0, tcpProtocol])
        add(tcp)
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return ~UInt16(sum)
    }
}
