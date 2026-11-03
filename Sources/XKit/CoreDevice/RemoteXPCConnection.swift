import Foundation

/// A RemoteXPC connection: XPC messages carried in HTTP/2 DATA frames.
///
/// Only the HTTP/2 subset RemoteXPC uses is implemented: SETTINGS, WINDOW_UPDATE,
/// empty HEADERS and DATA on two fixed streams, plus PING and GOAWAY handling.
final class RemoteXPCConnection {

    enum Error: Swift.Error, LocalizedError {
        case goAway
        case unexpectedReply(String)

        var errorDescription: String? {
            switch self {
            case .goAway: "The device closed the RemoteXPC connection"
            case .unexpectedReply(let detail): "Unexpected RemoteXPC reply: \(detail)"
            }
        }
    }

    private enum FrameType: UInt8 {
        case data = 0, headers = 1, settings = 4, ping = 6, goAway = 7, windowUpdate = 8
    }

    private static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    private static let rootChannel: UInt32 = 1
    private static let replyChannel: UInt32 = 3
    private static let initialWindowSize: UInt32 = 16 * 1024 * 1024
    private static let endHeaders: UInt8 = 0x4
    private static let ack: UInt8 = 0x1

    private let tcp: TunnelTCPConnection
    private var rootMessageID: UInt64 = 0
    private var pending: [UInt32: Data] = [:]

    init(tcp: TunnelTCPConnection) throws {
        self.tcp = tcp
        try handshake()
    }

    // Frame order matches devicectl; RSD rejects the connection if the HEADERS for
    // the reply channel arrive after the root channel's DATA (flags 0x0201).
    private func handshake() throws {
        var out = Self.preface
        var settings = Data()
        settings.appendSetting(id: 3, value: 100) // MAX_CONCURRENT_STREAMS
        settings.appendSetting(id: 4, value: Self.initialWindowSize) // INITIAL_WINDOW_SIZE
        out += Self.frame(.settings, stream: 0, payload: settings)
        out += Self.frame(.windowUpdate, stream: 0, payload: Data(bigEndian: Self.initialWindowSize - 65535))
        out += Self.frame(.headers, flags: Self.endHeaders, stream: Self.rootChannel)
        out += Self.frame(.data, stream: Self.rootChannel, payload: XPCWrapper(
            flags: .alwaysSet, messageID: rootMessageID, payload: .dictionary([])
        ).encoded())
        out += Self.frame(.headers, flags: Self.endHeaders, stream: Self.replyChannel)
        out += Self.frame(.data, stream: Self.rootChannel, payload: XPCWrapper(
            flags: Flags(rawValue: 0x0201), messageID: rootMessageID, payload: nil
        ).encoded())
        out += Self.frame(.data, stream: Self.replyChannel, payload: XPCWrapper(
            flags: [.alwaysSet, .initHandshake], messageID: 0, payload: nil
        ).encoded())
        rootMessageID = 1
        try tcp.send(out)
    }

    private typealias Flags = XPCWrapper.Flags

    private static func frame(_ type: FrameType, flags: UInt8 = 0, stream: UInt32, payload: Data = Data()) -> Data {
        var out = Data()
        out.append(contentsOf: [UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)])
        out.append(contentsOf: [type.rawValue, flags])
        out.append(Data(bigEndian: stream & 0x7FFF_FFFF))
        out.append(payload)
        return out
    }

    func send(_ message: XPCObject, wantingReply: Bool = true) throws {
        var flags: Flags = .alwaysSet
        if case .dictionary(let entries) = message, !entries.isEmpty { flags.insert(.dataPresent) }
        if wantingReply { flags.insert(.wantingReply) }
        let wrapper = XPCWrapper(flags: flags, messageID: rootMessageID, payload: message)
        rootMessageID = (rootMessageID + 1) | 1
        try tcp.send(Self.frame(.data, stream: Self.rootChannel, payload: wrapper.encoded()))
    }

    /// Returns the next non-empty dictionary message from the device.
    func receive(timeout: TimeInterval = 10) throws -> XPCObject {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = max(0.01, deadline.timeIntervalSinceNow)
            let header = try tcp.receiveExactly(9, timeout: remaining)
            let length = Int(header[0]) << 16 | Int(header[1]) << 8 | Int(header[2])
            let type = header[3]
            let flags = header[4]
            let stream = (UInt32(header[5]) << 24 | UInt32(header[6]) << 16 | UInt32(header[7]) << 8 | UInt32(header[8]))
                & 0x7FFF_FFFF
            let payload = length > 0 ? try tcp.receiveExactly(length, timeout: remaining) : Data()

            switch FrameType(rawValue: type) {
            case .settings where flags & Self.ack == 0:
                try tcp.send(Self.frame(.settings, flags: Self.ack, stream: 0))
            case .ping where flags & Self.ack == 0:
                try tcp.send(Self.frame(.ping, flags: Self.ack, stream: 0, payload: payload))
            case .goAway:
                throw Error.goAway
            case .data:
                if let message = try appendData(payload, stream: stream) { return message }
            default:
                break
            }
        }
    }

    private func appendData(_ data: Data, stream: UInt32) throws -> XPCObject? {
        var buffer = pending[stream, default: Data()] + data
        defer { pending[stream] = buffer }
        while let (wrapper, used) = try XPCWrapper.parse(buffer) {
            buffer = buffer.subdata(in: used..<buffer.count)
            if let payload = wrapper.payload, case .dictionary(let entries) = payload, !entries.isEmpty {
                return payload
            }
        }
        return nil
    }
}

extension Data {
    fileprivate init(bigEndian value: UInt32) {
        self.init([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    fileprivate mutating func appendSetting(id: UInt16, value: UInt32) {
        append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xFF)])
        append(Data(bigEndian: value))
    }
}
