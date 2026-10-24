import Foundation

/// RFCOMM carries the existing SSH byte stream; host keys and root authentication remain SSH's responsibility.
public struct BluetoothSSH: Sendable {
    public let executable: URL
    public let address: String
    public static func validAddress(_ address: String) -> Bool {
        address.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil
            && address.utf8.count == 17
    }
    public init(executable: URL, address: String) throws {
        guard executable.isFileURL, Self.validAddress(address) else { throw WorkbenchError("蓝牙代理路径或地址无效。") }
        self.executable = executable; self.address = address.uppercased()
    }
    public var proxyCommand: String {
        // OpenSSH expands percent tokens before the shell evaluates ProxyCommand.
        let path = executable.path.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "'", with: "'\\''")
        return "'\(path)' \(address)"
    }
}
