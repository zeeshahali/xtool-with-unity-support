import Foundation

/// The subset of the RemoteXPC object encoding that RSD needs.
///
/// Integers are little-endian. Strings, data and dictionary keys are padded to
/// 4 bytes, relative to where each value starts.
indirect enum XPCObject: Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case date(Int64)
    case data(Data)
    case string(String)
    case uuid(Data)
    case array([XPCObject])
    case dictionary([(String, XPCObject)])

    enum Error: Swift.Error {
        case truncated
        case badMagic
        case unsupportedType(UInt32)
    }

    private enum TypeID: UInt32 {
        case null = 0x1000, bool = 0x2000, int64 = 0x3000, uint64 = 0x4000
        case double = 0x5000, date = 0x7000, data = 0x8000, string = 0x9000
        case uuid = 0xA000, array = 0xE000, dictionary = 0xF000
    }

    subscript(key: String) -> XPCObject? {
        guard case .dictionary(let entries) = self else { return nil }
        return entries.first { $0.0 == key }?.1
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    // MARK: encoding

    func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .null:
            out.appendLE(TypeID.null.rawValue)
        case .bool(let value):
            out.appendLE(TypeID.bool.rawValue)
            out.appendLE(UInt32(value ? 1 : 0))
        case .int64(let value):
            out.appendLE(TypeID.int64.rawValue)
            out.appendLE(UInt64(bitPattern: value))
        case .uint64(let value):
            out.appendLE(TypeID.uint64.rawValue)
            out.appendLE(value)
        case .double(let value):
            out.appendLE(TypeID.double.rawValue)
            out.appendLE(value.bitPattern)
        case .date(let value):
            out.appendLE(TypeID.date.rawValue)
            out.appendLE(UInt64(bitPattern: value))
        case .data(let value):
            out.appendLE(TypeID.data.rawValue)
            out.appendLE(UInt32(value.count))
            out.append(value)
            out.padTo4(count: 4 + value.count)
        case .string(let value):
            let bytes = Data(value.utf8) + [0]
            out.appendLE(TypeID.string.rawValue)
            out.appendLE(UInt32(bytes.count))
            out.append(bytes)
            out.padTo4(count: 4 + bytes.count)
        case .uuid(let value):
            out.appendLE(TypeID.uuid.rawValue)
            out.append(value)
        case .array(let values):
            Self.encodeContainer(.array, count: values.count, into: &out) { body in
                for value in values { value.encode(into: &body) }
            }
        case .dictionary(let entries):
            Self.encodeContainer(.dictionary, count: entries.count, into: &out) { body in
                for (key, value) in entries {
                    let keyBytes = Data(key.utf8) + [0]
                    body.append(keyBytes)
                    body.padTo4(count: keyBytes.count)
                    value.encode(into: &body)
                }
            }
        }
    }

    // containers: type, byte length, element count, elements
    private static func encodeContainer(
        _ type: TypeID, count: Int, into out: inout Data, elements: (inout Data) -> Void
    ) {
        var body = Data()
        body.appendLE(UInt32(count))
        elements(&body)
        out.appendLE(type.rawValue)
        out.appendLE(UInt32(body.count))
        out.append(body)
    }

    // MARK: decoding

    static func decode(_ data: Data) throws -> XPCObject {
        var reader = ByteReader(data)
        return try decode(from: &reader)
    }

    private static func decode(from reader: inout ByteReader) throws -> XPCObject {
        let rawType = try reader.readLE(UInt32.self)
        guard let type = TypeID(rawValue: rawType) else { throw Error.unsupportedType(rawType) }
        switch type {
        case .null:
            return .null
        case .bool:
            return .bool(try reader.readLE(UInt32.self) != 0)
        case .int64:
            return .int64(Int64(bitPattern: try reader.readLE(UInt64.self)))
        case .uint64:
            return .uint64(try reader.readLE(UInt64.self))
        case .double:
            return .double(Double(bitPattern: try reader.readLE(UInt64.self)))
        case .date:
            return .date(Int64(bitPattern: try reader.readLE(UInt64.self)))
        case .data:
            let count = Int(try reader.readLE(UInt32.self))
            let value = try reader.read(count)
            try reader.skip(padding(for: 4 + count))
            return .data(value)
        case .string:
            let count = Int(try reader.readLE(UInt32.self))
            let bytes = try reader.read(count)
            try reader.skip(padding(for: 4 + count))
            return .string(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
        case .uuid:
            return .uuid(try reader.read(16))
        case .array:
            return .array(try decodeContainer(from: &reader) { body in try decode(from: &body) })
        case .dictionary:
            return .dictionary(try decodeContainer(from: &reader) { body in
                let key = try body.readCString()
                try body.skip(padding(for: key.utf8.count + 1))
                return (key, try decode(from: &body))
            })
        }
    }

    private static func decodeContainer<Element>(
        from reader: inout ByteReader, element: (inout ByteReader) throws -> Element
    ) throws -> [Element] {
        var body = ByteReader(try reader.read(Int(try reader.readLE(UInt32.self))))
        let count = try body.readLE(UInt32.self)
        var elements: [Element] = []
        for _ in 0..<count { elements.append(try element(&body)) }
        return elements
    }

    private static func padding(for count: Int) -> Int {
        (4 - count % 4) % 4
    }
}

/// A RemoteXPC message frame: a fixed header followed by an optional XPC object.
struct XPCWrapper {
    struct Flags: OptionSet {
        let rawValue: UInt32
        static let alwaysSet = Flags(rawValue: 0x0000_0001)
        static let dataPresent = Flags(rawValue: 0x0000_0100)
        static let wantingReply = Flags(rawValue: 0x0001_0000)
        static let reply = Flags(rawValue: 0x0002_0000)
        static let initHandshake = Flags(rawValue: 0x0040_0000)
    }

    static let magic: UInt32 = 0x29B0_0B92
    static let payloadMagic: UInt32 = 0x4213_3742
    static let payloadVersion: UInt32 = 5
    static let headerSize = 24

    var flags: Flags
    var messageID: UInt64
    var payload: XPCObject?

    func encoded() -> Data {
        var body = Data()
        if let payload {
            body.appendLE(Self.payloadMagic)
            body.appendLE(Self.payloadVersion)
            body.append(payload.encoded())
        }
        var out = Data()
        out.appendLE(Self.magic)
        out.appendLE(flags.rawValue)
        out.appendLE(UInt64(body.count))
        out.appendLE(messageID)
        out.append(body)
        return out
    }

    /// Parses one frame from the start of `data`. Returns nil if more bytes are needed,
    /// otherwise the frame and how many bytes it used.
    static func parse(_ data: Data) throws -> (XPCWrapper, Int)? {
        guard data.count >= headerSize else { return nil }
        var reader = ByteReader(data)
        guard try reader.readLE(UInt32.self) == magic else { throw XPCObject.Error.badMagic }
        let flags = Flags(rawValue: try reader.readLE(UInt32.self))
        let size = Int(try reader.readLE(UInt64.self))
        let messageID = try reader.readLE(UInt64.self)
        guard data.count >= headerSize + size else { return nil }

        var payload: XPCObject?
        if size >= 8 {
            var body = ByteReader(try reader.read(size))
            if try body.readLE(UInt32.self) == payloadMagic {
                _ = try body.readLE(UInt32.self)
                payload = try? XPCObject.decode(body.remaining)
            }
        }
        return (XPCWrapper(flags: flags, messageID: messageID, payload: payload), headerSize + size)
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        self.offset = 0
    }

    var remaining: Data { data.subdata(in: offset..<data.count) }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw XPCObject.Error.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func skip(_ count: Int) throws {
        _ = try read(count)
    }

    mutating func readLE<T: FixedWidthInteger>(_: T.Type) throws -> T {
        try read(MemoryLayout<T>.size).reversed().reduce(T.zero) { $0 << 8 | T($1) }
    }

    mutating func readCString() throws -> String {
        guard let end = data[offset...].firstIndex(of: 0) else { throw XPCObject.Error.truncated }
        let string = String(decoding: data[offset..<end], as: UTF8.self)
        offset = end + 1
        return string
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func padTo4(count: Int) {
        append(contentsOf: [UInt8](repeating: 0, count: (4 - count % 4) % 4))
    }
}
