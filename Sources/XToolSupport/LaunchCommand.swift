import XCLIUtils
import XUtils
import Foundation
import XKit
import SwiftyMobileDevice
import ArgumentParser

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an installed app"
    )

    @OptionGroup var connectionOptions: ConnectionOptions

    @Argument(
        help: "The app to launch"
    ) var bundleID: String

    @Argument(
        help: .init(
            "Launch arguments to pass to the app",
            valueName: "arg"
        )
    ) var args: [String] = []

    func run() async throws {
        let client = try await connectionOptions.client()
        try Self.launch(bundleID: bundleID, arguments: args, device: client.device)
    }

    static func launch(bundleID: String, arguments args: [String], device: Device) throws {
        let installProxy = try InstallationProxyClient(device: device, label: "xtool-inst")
        let executable: URL
        do {
            executable = try installProxy.executable(forBundleID: bundleID)
        } catch {
            throw Console.Error("Could not find an installed app with bundle ID '\(bundleID)'")
        }

        d.out.print("Launching \(executable.lastPathComponent)...")

        // iOS 17 moved debugserver behind the CoreDevice tunnel, so launch through
        // the CoreDevice app service there instead
        let version = try? LockdownClient(device: device, label: "xtool", performHandshake: true)
            .value(ofType: String.self, forDomain: nil, key: "ProductVersion")
        let major = version?.split(separator: ".").first.flatMap { Int($0) }
        if let major, major >= 17 {
            let pid = try CoreDeviceLauncher(device: device).launch(bundleID: bundleID, arguments: args)
            if let pid { d.out.print("Launched (pid \(pid))") }
            return
        }

        let debugserver: DebugserverClient
        do {
            debugserver = try DebugserverClient(device: device, label: "xtool")
        } catch {
            guard let version else { throw error }
            throw Console.Error("""
            Could not start debugserver on iOS \(version). Make sure Developer Mode is on and the \
            matching developer disk image is mounted.
            """)
        }
        guard try debugserver.launch(executable: executable, arguments: args) == "OK" else {
            throw Console.Error("Launch failed (!OK)")
        }
        guard try debugserver.send(command: "qLaunchSuccess", arguments: []) == Data("OK".utf8) else {
            throw Console.Error("Launch failed (!qLaunchSuccess)")
        }
        try debugserver.send(command: "D", arguments: [])
    }
}
