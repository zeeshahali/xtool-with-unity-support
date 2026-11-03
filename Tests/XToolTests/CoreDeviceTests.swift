import Foundation
import Testing
@testable import XKit

@Test func xpcDictionaryRoundTrips() throws {
    let object = XPCObject.dictionary([
        ("Services", .dictionary([
            ("com.apple.internal.dt.remote.debugproxy", .dictionary([("Port", .string("60030"))])),
        ])),
        ("Count", .uint64(73)),
        ("Flag", .bool(true)),
        ("Blob", .data(Data([1, 2, 3]))),
        ("List", .array([.int64(-1), .null])),
    ])
    let decoded = try XPCObject.decode(object.encoded())
    #expect(decoded["Services"]?["com.apple.internal.dt.remote.debugproxy"]?["Port"]?.stringValue == "60030")
    guard case .uint64(73)? = decoded["Count"] else { Issue.record("Count"); return }
    guard case .bool(true)? = decoded["Flag"] else { Issue.record("Flag"); return }
    guard case .data(let blob)? = decoded["Blob"] else { Issue.record("Blob"); return }
    #expect(blob == Data([1, 2, 3]))
    guard case .array(let list)? = decoded["List"], list.count == 2 else { Issue.record("List"); return }
}

@Test func xpcStringIsNulTerminatedAndPadded() {
    // type, length (including NUL), "ab\0", one byte of padding
    let encoded = XPCObject.string("ab").encoded()
    #expect([UInt8](encoded) == [0x00, 0x90, 0x00, 0x00, 3, 0, 0, 0, 0x61, 0x62, 0, 0])
}

@Test func xpcWrapperParsesAcrossPartialData() throws {
    let wrapper = XPCWrapper(flags: [.alwaysSet, .dataPresent], messageID: 7, payload: .dictionary([("k", .string("v"))]))
    let data = wrapper.encoded()
    #expect(try XPCWrapper.parse(data.prefix(data.count - 1)) == nil)
    let (parsed, used) = try #require(try XPCWrapper.parse(data + Data([0xFF])))
    #expect(used == data.count)
    #expect(parsed.messageID == 7)
    #expect(parsed.payload?["k"]?.stringValue == "v")
}

@Test func launchRequestUsesTheTypesTheDeviceChecks() throws {
    let request = try XPCObject.decode(
        CoreDeviceLauncher.launchRequest(bundleID: "com.example.game", arguments: ["-a"]).encoded()
    )
    guard case .int64(2)? = request["CoreDevice.CoreDeviceDDIProtocolVersion"] else {
        Issue.record("DDI protocol version must be Int64"); return
    }
    guard case .array(let components)? = request["CoreDevice.coreDeviceVersion"]?["components"],
          case .uint64? = components.first else {
        Issue.record("version components must be UInt64"); return
    }
    #expect(request["CoreDevice.featureIdentifier"]?.stringValue == "com.apple.coredevice.feature.launchapplication")
    let input = request["CoreDevice.input"]
    #expect(input?["applicationSpecifier"]?["bundleIdentifier"]?["_0"]?.stringValue == "com.example.game")
    guard case .data? = input?["options"]?["platformSpecificOptions"] else {
        Issue.record("platformSpecificOptions must be plist Data"); return
    }
}

@Test func tcpSegmentRoundTripsWithValidChecksum() throws {
    let source = [UInt8](repeating: 0, count: 15) + [2]
    let destination = [UInt8](repeating: 0, count: 15) + [1]
    let segment = TCPSegment(
        sourcePort: 50000, destinationPort: 53941, sequence: 0xDEAD_BEEF, acknowledgment: 42,
        flags: [.ack, .psh], window: 65535, payload: Data("hello".utf8)
    )
    let packet = segment.ipv6Packet(source: source, destination: destination)
    let parsed = try #require(TCPSegment(ipv6Packet: packet))
    #expect(parsed.sourcePort == 50000)
    #expect(parsed.destinationPort == 53941)
    #expect(parsed.sequence == 0xDEAD_BEEF)
    #expect(parsed.acknowledgment == 42)
    #expect(parsed.flags == [.ack, .psh])
    #expect(parsed.payload == Data("hello".utf8))

    // summing a segment that includes its own checksum gives zero
    #expect(TCPSegment.checksum([UInt8](packet.dropFirst(40)), source: source, destination: destination) == 0)
}
