import Foundation
import CryptoKit

public struct WorkbenchError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum LX06 {
    public static let version = "1.94.13"
    public static let systemSize = 0x02800000
    public static let originalHash = "317a54909f12b63f22128965bf9005c06435d15f61c4202bb88c4524bf1e2ef4"
    public static let download = URL(string: "https://github.com/idootop/open-xiaoai/releases/download/LX06_1.94.13/LX06_1.94.13.squashfs")!
}

public func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public struct LocalPaths: Sendable {
    public let root: URL
    public let tools: URL
    public var original: URL { root.appendingPathComponent("LX06_1.94.13.squashfs") }
    public var key: URL { root.appendingPathComponent("id_rsa") }
    public var knownHostsOption: String {
        let value = knownHosts.path.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "UserKnownHostsFile=\"" + value + "\""
    }
    public var knownHosts: URL { root.appendingPathComponent("known_hosts") }
    public init(root: URL, tools: URL) { self.root = root; self.tools = tools }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    public func tool(_ name: String) -> URL { tools.appendingPathComponent(name) }
}

public struct ProcessResult: Sendable { public let output: String; public let status: Int32 }

public enum LocalProcess {
    // File-backed output avoids pipe deadlocks on the large SquashFS listing.
    public static func run(_ executable: URL, _ arguments: [String], input: Data? = nil,
                           timeout: TimeInterval = 180) throws -> ProcessResult {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputURL = temp.appendingPathComponent("output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        var inputHandle: FileHandle?
        if let input {
            let inputURL = temp.appendingPathComponent("input")
            try input.write(to: inputURL)
            inputHandle = try FileHandle(forReadingFrom: inputURL)
            process.standardInput = inputHandle
        } else { process.standardInput = FileHandle.nullDevice }
        defer { try? inputHandle?.close() }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw WorkbenchError("操作超时：\(executable.lastPathComponent)")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let result = ProcessResult(output: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                                   status: process.terminationStatus)
        guard result.status == 0 else {
            throw WorkbenchError("\(executable.lastPathComponent) 退出码 \(result.status)\n\(result.output.suffix(3000))")
        }
        return result
    }
}

extension Data {
    func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
    func u64(_ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(self[offset + $1]) << ($1 * 8) }
    }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

public enum SquashFS {
    public static func logicalImage(_ data: Data) throws -> Data {
        guard data.count >= 96, data.prefix(4) == Data("hsqs".utf8), data[28] == 4,
              data.u32(12) == 131072, data[20] == 4 else {
            throw WorkbenchError("镜像必须是 LX06 使用的 SquashFS 4、XZ 压缩、128 KiB 块大小。")
        }
        let length = data.u64(40)
        guard length >= 96, length <= data.count, length < LX06.systemSize else {
            throw WorkbenchError("SquashFS 长度无效或超出 system0 分区。")
        }
        return Data(data.prefix(Int(length)))
    }
}
