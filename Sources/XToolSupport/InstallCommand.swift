import XUtils
import Foundation
import XKit
import SwiftyMobileDevice
import ArgumentParser

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an ipa file to your device"
    )

    @OptionGroup var connectionOptions: ConnectionOptions

    @Argument(
        help: "The path to a custom app/ipa to install"
    ) var path: String

    @Flag(
        name: .shortAndLong,
        help: "Launch the app after installing it"
    ) var launch = false

    func run() async throws {
        let token = try AuthToken.saved()

        let client = try await connectionOptions.client()

        d.out.print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = XToolInstallerDelegate()
        let installer = IntegratedInstaller(
            auth: token.authData(),
            delegate: installDelegate
        )

        // the installer re-signs the app, so this is the bundle ID it ended up with
        let bundleID: String
        do {
            bundleID = try await installer.install(
                app: URL(fileURLWithPath: path),
                udid: client.udid,
                lookupMode: .only(client.connectionType),
                configureDevice: false,
            )
            d.out.print("\nSuccessfully installed!")
        } catch let error as CancellationError {
            throw error
        } catch {
            d.out.print("\nError: \(error)")
            throw ExitCode.failure
        }

        if launch {
            try LaunchCommand.launch(bundleID: bundleID, arguments: [], device: client.device)
        }
    }
}
