import Foundation
import SwiftyMobileDevice

/// Launches apps on iOS 17.4+ through the CoreDevice app service, which is what
/// Xcode and `devicectl` use.
///
/// Opens a `CoreDeviceProxy` tunnel over USB, finds the app service through
/// Remote Service Discovery, and sends it a `launchapplication` request.
public struct CoreDeviceLauncher {

    public enum Error: Swift.Error, LocalizedError {
        case tunnelUnavailable(Swift.Error)
        case appServiceUnavailable
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .tunnelUnavailable(let underlying):
                """
                Could not open a CoreDevice tunnel to the device (\(underlying.localizedDescription)). \
                Launching on iOS 17 needs iOS 17.4 or later, over USB.
                """
            case .appServiceUnavailable:
                """
                The device doesn't offer the CoreDevice app service. Make sure Developer Mode is on \
                and the personalized developer disk image is mounted.
                """
            case .launchFailed(let message):
                "Could not launch the app: \(message)"
            }
        }
    }

    static let appService = "com.apple.coredevice.appservice"
    static let launchFeature = "com.apple.coredevice.feature.launchapplication"

    private let device: Device

    public init(device: Device) {
        self.device = device
    }

    /// - Returns: the launched process's ID, if the device reported one
    @discardableResult
    public func launch(bundleID: String, arguments: [String]) throws -> Int64? {
        let tunnel: CoreDeviceTunnel
        do {
            let lockdown = try LockdownClient(device: device, label: "xtool", performHandshake: true)
            tunnel = try CoreDeviceTunnel(device: device, lockdown: lockdown)
        } catch {
            throw Error.tunnelUnavailable(error)
        }
        let network = try TunnelNetwork(tunnel: tunnel)

        let rsdConnection = try network.connect(port: tunnel.parameters.serverRSDPort)
        defer { rsdConnection.close() }
        let peerInfo = try RemoteXPCConnection(tcp: rsdConnection).receive()
        guard let port = peerInfo["Services"]?[Self.appService]?["Port"]?.stringValue.flatMap(UInt16.init)
        else { throw Error.appServiceUnavailable }

        let appConnection = try network.connect(port: port)
        defer { appConnection.close() }
        let appService = try RemoteXPCConnection(tcp: appConnection)
        try appService.send(Self.launchRequest(bundleID: bundleID, arguments: arguments))
        let response = try appService.receive(timeout: 30)

        guard let output = response["CoreDevice.output"] else {
            throw Error.launchFailed(Self.errorMessage(in: response))
        }
        if case .int64(let pid)? = output["processToken"]?["processIdentifier"] { return pid }
        return nil
    }

    // The device checks field types, so the Int64/UInt64 split here is deliberate.
    static func launchRequest(bundleID: String, arguments: [String]) throws -> XPCObject {
        let version = "629.3"
        let components = version.split(separator: ".").compactMap { UInt64($0) }
        let emptyPlist = try PropertyListSerialization.data(
            fromPropertyList: [String: Any](), format: .xml, options: 0
        )
        let input = XPCObject.dictionary([
            ("applicationSpecifier", .dictionary([
                ("bundleIdentifier", .dictionary([("_0", .string(bundleID))])),
            ])),
            ("options", .dictionary([
                ("arguments", .array(arguments.map { .string($0) })),
                ("environmentVariables", .dictionary([])),
                ("standardIOUsesPseudoterminals", .bool(true)),
                ("startStopped", .bool(false)),
                ("terminateExisting", .bool(true)),
                ("user", .dictionary([("shortName", .string("mobile"))])),
                ("platformSpecificOptions", .data(emptyPlist)),
            ])),
            ("standardIOIdentifiers", .dictionary([])),
        ])
        return .dictionary([
            ("CoreDevice.CoreDeviceDDIProtocolVersion", .int64(2)),
            ("CoreDevice.coreDeviceVersion", .dictionary([
                ("components", .array(components.map { .uint64($0) })),
                ("originalComponentsCount", .int64(Int64(components.count))),
                ("stringValue", .string(version)),
            ])),
            ("CoreDevice.deviceIdentifier", .string(UUID().uuidString.lowercased())),
            ("CoreDevice.input", input),
            ("CoreDevice.invocationIdentifier", .string(UUID().uuidString.lowercased())),
            ("CoreDevice.featureIdentifier", .string(launchFeature)),
            ("CoreDevice.action", .dictionary([])),
        ])
    }

    // failures carry CoreDevice.error { code, userInfo { NSLocalizedDescription } }
    private static func errorMessage(in response: XPCObject) -> String {
        let error = response["CoreDevice.error"]
        if let description = error?["userInfo"]?["NSLocalizedDescription"]?.stringValue {
            return description
        }
        return "unexpected response from the device: \(response)"
    }
}
