import Foundation

public struct FirmwareArtifact: Codable, Sendable {
    public let file: URL
    public let hash: String
    public let originalHash: String
    public let publicKeyHash: String
    public let changedFiles: [String]
    public let createdAt: Date
}

struct PseudoImage {
    static let marker = Data("\n#\n# START OF DATA - DO NOT MODIFY\n#\n".utf8)
    let lines: [String]
    let payload: Data
    init(data: Data) throws {
        guard let range = data.range(of: Self.marker),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw WorkbenchError("无法解析 SquashFS 伪文件。")
        }
        lines = header.components(separatedBy: "\n")
        payload = Data(data[range.upperBound...])
    }
    func file(_ path: String) throws -> Data {
        guard let line = lines.first(where: { $0.hasPrefix(path + " R ") }) else {
            throw WorkbenchError("固件中缺少普通文件：\(path)")
        }
        let fields = line.split(separator: " ")
        guard fields.count == 9, let length = Int(fields[6]), let offset = Int(fields[7]),
              fields[8] == "0", offset >= 0, length >= 0, offset <= payload.count,
              length <= payload.count - offset else { throw WorkbenchError("文件记录无效：\(path)") }
        return Data(payload[offset..<(offset + length)])
    }
    func text(_ path: String) throws -> String {
        guard let text = String(data: try file(path), encoding: .utf8) else { throw WorkbenchError("文件编码无效：\(path)") }
        return text
    }
    func replacing(_ replacements: [String: Data]) throws -> Data {
        var outputLines: [String] = []
        var output = Data()
        var matched = Set<String>()
        for line in lines {
            var fields = line.split(separator: " ").map(String.init)
            if fields.count > 1, fields[1] == "R" {
                guard fields.count == 9 else { throw WorkbenchError("无法保存固件元数据：\(line)") }
                let path = fields[0]
                let content = try replacements[path] ?? file(path)
                if replacements[path] != nil { matched.insert(path) }
                fields[6] = String(content.count)
                fields[7] = String(output.count)
                output.append(content)
                outputLines.append(fields.joined(separator: " "))
            } else { outputLines.append(line) }
        }
        guard matched == Set(replacements.keys) else { throw WorkbenchError("部分补丁没有匹配到原始文件。") }
        var result = Data(outputLines.joined(separator: "\n").utf8)
        result.append(Self.marker); result.append(output)
        return result
    }
}

struct RootPatch {
    static func replacements(in image: PseudoImage, publicKey: String) throws -> [String: Data] {
        guard publicKey.hasPrefix("ssh-rsa "), publicKey.split(separator: "\n").count == 1 else {
            throw WorkbenchError("需要由本工具生成的 RSA 公钥。")
        }
        let version = try image.text("usr/share/mico/version")
        guard version.contains("option ROM '1.94.13'"), version.contains("option HARDWARE 'LX06'") else {
            throw WorkbenchError("固件型号或版本不符。")
        }
        var ssh = try image.text("etc/init.d/dropbear")
        guard let start = ssh.range(of: "\t[ x\"bluetooth\" =="),
              let end = ssh.range(of: "\t[ -s /data/etc/dropbear/dropbear_rsa_host_key ] || keygen"),
              start.lowerBound < end.lowerBound else { throw WorkbenchError("SSH 启动脚本与基线不符。") }
        ssh.replaceSubrange(start.lowerBound..<end.lowerBound, with: "\tmkdir -p /data/etc/dropbear\n")
        var config = try image.text("etc/config/dropbear")
        config = try replaceOnce(config, "option PasswordAuth '1'", "option PasswordAuth '0'")
        config = try replaceOnce(config, "option RootPasswordAuth '1'", "option RootPasswordAuth '0'")
        var ota = try image.text("bin/ota")
        ota = try replaceOnce(ota, "download_upgrade() {", "download_upgrade() {\n    logger -t ota 'disabled by Xiaoai Workbench'\n    return 1")
        ota = try replaceOnce(ota, "upgrade() {", "upgrade() {\n    logger -t ota 'disabled by Xiaoai Workbench'\n    return 1")
        var flash = try image.text("bin/flash.sh")
        flash = try replaceOnce(flash, "upgrade_param_check() {", "upgrade_param_check() {\n\tklogger 'disabled by Xiaoai Workbench'\n\treturn 1")
        var wireless = try image.text("etc/init.d/wireless")
        wireless = try replaceOnce(wireless, "    trylock \"ota\"", "    echo \"download_fail\"\n    exit 3\n    trylock \"ota\"")
        let rcLocal = try replaceOnce(image.text("etc/rc.local"), "exit 0", """
        # Xiaoai Workbench: device-owned trial deadline for wireless updates.
        if [ -f /data/xiaoai-ota/agent.sh ]; then
            /bin/sh /data/xiaoai-ota/agent.sh boot-watch </dev/null >/tmp/xiaoai-ota-watch.log 2>&1 &
        fi
        # Xiaoai Workbench: authenticated Bluetooth RFCOMM transport to existing SSH.
        (
            count=0
            while [ ! -d /sys/class/bluetooth/hci0 ] && [ "$count" -lt 30 ]; do
                sleep 1
                count=$((count + 1))
            done
            exec /usr/bin/rfcomm -r -A -E watch rfcomm0 23 /bin/sh -c 'exec /usr/bin/nc 127.0.0.1 22 < /dev/rfcomm0 > /dev/rfcomm0'
        ) </dev/null >/tmp/xiaoai-bluetooth-ssh.log 2>&1 &
        exit 0
        """)
        return [
            "etc/init.d/dropbear": Data(ssh.utf8),
            "etc/config/dropbear": Data(config.utf8),
            "etc/dropbear/authorized_keys": Data((publicKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8),
            "bin/ota": Data(ota.utf8), "bin/flash.sh": Data(flash.utf8),
            "etc/init.d/wireless": Data(wireless.utf8),
            "etc/rc.local": Data(rcLocal.utf8)
        ]
    }
    static func replaceOnce(_ text: String, _ old: String, _ new: String) throws -> String {
        // A full-line match prevents upgrade() from matching download_upgrade().
        let lines = text.components(separatedBy: "\n")
        let matches = lines.indices.filter { lines[$0] == old || lines[$0].trimmingCharacters(in: .whitespaces) == old }
        guard matches.count == 1, let index = matches.first else { throw WorkbenchError("补丁匹配数量异常：\(old)") }
        var patched = lines
        let original = patched[index]
        if original == old { patched[index] = new }
        else {
            let prefix = String(original.prefix(while: { $0 == " " || $0 == "\t" }))
            patched[index] = prefix + new
        }
        return patched.joined(separator: "\n")
    }
}

struct FirmwareBuilder {
    let paths: LocalPaths
    func ensureKey() throws -> String {
        try paths.prepare()
        if !FileManager.default.fileExists(atPath: paths.key.path) {
            _ = try LocalProcess.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                ["-q", "-t", "rsa", "-b", "3072", "-N", "", "-C", "xiaoai-workbench", "-f", paths.key.path])
        }
        // Derive from the private key, never trust a stale .pub file.
        return try LocalProcess.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), ["-y", "-f", paths.key.path]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func build(log: (String) -> Void) throws -> FirmwareArtifact {
        try paths.prepare()
        let source = try Data(contentsOf: paths.original, options: .mappedIfSafe)
        guard sha256(source) == LX06.originalHash else { throw WorkbenchError("原版固件 SHA-256 不匹配。") }
        _ = try SquashFS.logicalImage(source)
        let key = try ensureKey()
        let work = paths.root.appendingPathComponent("Builds/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pseudo = work.appendingPathComponent("root.pseudo")
        log("正在读取固件文件及 Linux 权限元数据")
        _ = try LocalProcess.run(paths.tool("unsquashfs"), ["-no-progress", "-pf", pseudo.path, paths.original.path])
        let original = try PseudoImage(data: Data(contentsOf: pseudo, options: .mappedIfSafe))
        let changes = try RootPatch.replacements(in: original, publicKey: key)
        try original.replacing(changes).write(to: pseudo, options: .atomic)
        let empty = work.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let output = work.appendingPathComponent("LX06_1.94.13_root.squashfs")
        log("正在打包最小固件，保留设备节点、链接和原始权限")
        _ = try LocalProcess.run(paths.tool("mksquashfs"), [empty.path, output.path, "-pf", pseudo.path,
            "-comp", "xz", "-b", "131072", "-noappend", "-no-xattrs", "-all-root", "-no-progress", "-processors", "2",
            "-mkfs-time", "1758016585", "-root-time", "1758016585"], timeout: 300)
        let finalData = try Data(contentsOf: output, options: .mappedIfSafe)
        _ = try SquashFS.logicalImage(finalData)
        // Re-read the built image and compare every file and every metadata record.
        let verification = work.appendingPathComponent("verify.pseudo")
        log("正在核对输出镜像的全部文件和元数据")
        _ = try LocalProcess.run(paths.tool("unsquashfs"), ["-no-progress", "-pf", verification.path, output.path])
        let built = try PseudoImage(data: Data(contentsOf: verification, options: .mappedIfSafe))
        try Self.verify(original: original, built: built, changes: changes)
        let artifact = FirmwareArtifact(file: output, hash: sha256(finalData), originalHash: LX06.originalHash,
            publicKeyHash: sha256(Data(key.utf8)), changedFiles: changes.keys.sorted(), createdAt: Date())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifact).write(to: work.appendingPathComponent("firmware.json"), options: .atomic)
        try FileManager.default.removeItem(at: pseudo)
        try FileManager.default.removeItem(at: verification)
        log("固件构建完成，\(changes.count) 个文件发生修改；音频、PAM、shadow 和串口配置已核对保持原样")
        return artifact
    }
    static func verify(original: PseudoImage, built: PseudoImage, changes: [String: Data]) throws {
        func metadata(_ image: PseudoImage) -> [String: String] {
            Dictionary(uniqueKeysWithValues: image.lines.map { line in
                var fields = line.split(separator: " ").map(String.init)
                if fields.count == 9, fields[1] == "R" { fields.removeSubrange(6..<9) }
                return (fields[0], fields.joined(separator: " "))
            })
        }
        guard metadata(original) == metadata(built) else { throw WorkbenchError("输出镜像的 Linux 文件元数据发生非预期变化。") }
        for line in original.lines {
            let fields = line.split(separator: " ")
            if fields.count > 1, fields[1] == "R" {
                let path = String(fields[0])
                guard try built.file(path) == (changes[path] ?? original.file(path)) else {
                    throw WorkbenchError("输出镜像文件核对失败：\(path)")
                }
            }
        }
    }
}
