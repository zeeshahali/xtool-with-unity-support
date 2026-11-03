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

        let installProxy = try InstallationProxyClient(device: client.device, label: "xtool-inst")
        let executable: URL
        do {
            executable = try installProxy.executable(forBundleID: bundleID)
        } catch {
            throw Console.Error("Could not find an installed app with bundle ID '\(bundleID)'")
        }

        d.out.print("Launching \(executable.lastPathComponent)...")

        let debugserver: DebugserverClient
        do {
            debugserver = try DebugserverClient(device: client.device, label: "xtool")
        } catch {
            throw debugserverUnavailableError(device: client.device, underlying: error)
        }
        guard try debugserver.launch(executable: executable, arguments: args) == "OK" else {
            throw Console.Error("Launch failed (!OK)")
        }
        guard try debugserver.send(command: "qLaunchSuccess", arguments: []) == Data("OK".utf8) else {
            throw Console.Error("Launch failed (!qLaunchSuccess)")
        }
        try debugserver.send(command: "D", arguments: [])
    }

    // iOS 17 moved debugserver behind the CoreDevice tunnel, so it's no longer
    // reachable as a lockdown service, even with a developer disk image mounted.
    private func debugserverUnavailableError(device: Device, underlying: Swift.Error) -> Swift.Error {
        let version = try? LockdownClient(device: device, label: "xtool", performHandshake: true)
            .value(ofType: String.self, forDomain: nil, key: "ProductVersion")
        guard let version, let major = version.split(separator: ".").first.flatMap({ Int($0) }) else {
            return underlying
        }
        if major >= 17 {
            return Console.Error("""
            Could not launch the app: xtool can't start apps on iOS 17 or later (this device runs \
            iOS \(version)). Open the app from the Home Screen instead.
            """)
        }
        return Console.Error("""
        Could not start debugserver on iOS \(version). Make sure Developer Mode is on and the \
        matching developer disk image is mounted.
        """)
    }
}
