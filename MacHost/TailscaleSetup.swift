import Darwin
import Foundation

struct TailscaleSetup {
    let address: String?
    let message: String
    let isInstalled: Bool

    static var applicationPaths: [String] {
        ["/Applications/Tailscale.app", NSHomeDirectory() + "/Applications/Tailscale.app"]
    }

    static var cliPaths: [String] {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"] +
            applicationPaths.map { $0 + "/Contents/MacOS/Tailscale" }
    }

    static func check() async -> TailscaleSetup {
        await Task.detached(priority: .utility) { inspect() }.value
    }

    private static func inspect() -> TailscaleSetup {
        let paths = cliPaths.filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard !paths.isEmpty else {
            return TailscaleSetup(address: nil,
                                  message: "Install Tailscale, sign in, and connect this Mac and your iPhone or iPad to the same Tailscale network.",
                                  isInstalled: applicationPaths.contains { FileManager.default.fileExists(atPath: $0) })
        }
        for path in paths {
            if let address = try? readAddress(using: path) {
                return TailscaleSetup(address: address, message: "Connected · \(address)", isInstalled: true)
            }
        }
        return TailscaleSetup(address: nil,
                              message: "Open Tailscale, sign in, and turn on its connection. Then check setup again.",
                              isInstalled: true)
    }

    /// Accept only Tailscale's CGNAT IPv4 range, never a wildcard or LAN address.
    static func isTailscaleIPv4(_ value: String) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let octets = fields.compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func readAddress(using path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["ip", "-4"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 0.25) != .success {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            throw SetupError.unavailable
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let address = text.split(whereSeparator: \.isNewline).map(String.init).first(where: isTailscaleIPv4) else {
            throw SetupError.unavailable
        }
        return address
    }

    private enum SetupError: Error { case unavailable }
}
