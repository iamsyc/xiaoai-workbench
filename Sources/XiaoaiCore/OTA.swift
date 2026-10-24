import Foundation

public struct OTAEndpoint: Sendable {
    public let host: String
    public let bluetooth: BluetoothSSH?
    public init(host: String, bluetooth: BluetoothSSH? = nil) throws {
        guard Workbench.validIP(host) else { throw WorkbenchError("请输入有效 IPv4 地址。") }
        self.host = host; self.bluetooth = bluetooth
    }
}
public struct OTAStatus: Codable, Sendable {
    public let bootPart: String
    public let rootDevice: String
    public let bootID: String
    public let phase: String
    public let job: String?
    public let previous: String?
    public let target: String?
    public let rootHash: String?
    static func parse(_ text: String) throws -> Self {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("XW_") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        guard let boot = fields["XW_BOOT"], let root = fields["XW_ROOT"],
              (boot == "boot0" && root == "/dev/mtdblock4") || (boot == "boot1" && root == "/dev/mtdblock5"),
              let id = fields["XW_BOOT_ID"], UUID(uuidString: id) != nil, fields["XW_VERSION"] == LX06.version,
              let phase = fields["XW_PHASE"], ["idle", "writing", "arming", "trial", "committed", "rolled_back", "failed"].contains(phase) else {
            throw WorkbenchError("OTA 设备状态无效或启动分区与挂载根分区不一致。")
        }
        return Self(bootPart: boot, rootDevice: root, bootID: id, phase: phase, job: fields["XW_JOB"],
                    previous: fields["XW_PREVIOUS"], target: fields["XW_TARGET"], rootHash: fields["XW_ROOT_HASH"])
    }
}
public struct OTAPackage: Codable, Sendable {
    public let format: Int
    public let model: String
    public let version: String
    public let kernelHash: String
    public let rootHash: String
    public let rootBytes: Int
    public let publicKeyHash: String
    public static let supportedKernelHash = "f38a880f0c7e7f12bbaced111d5e210d89a38158d1b26e9fb7b5f60f210442d2"
    static func validate(_ package: Self, kernel: Data, root: Data) throws {
        guard package.format == 1, package.model == "LX06", package.version == LX06.version,
              kernel.count == 6291456, kernel.prefix(8) == Data("ANDROID!".utf8),
              package.kernelHash == supportedKernelHash, sha256(kernel) == package.kernelHash,
              root.count == package.rootBytes, root.count <= LX06.systemSize, root.count % 4096 == 0,
              sha256(root) == package.rootHash else { throw WorkbenchError("OTA 包型号、版本、配套内核或镜像校验不符。") }
        _ = try SquashFS.logicalImage(root)
    }
}
struct OTAFileRecord: Codable { let bytes: Int; let sha256: String }
struct OTABackupManifest: Codable {
    let format: Int; let device: OTAStatus; let files: [String: OTAFileRecord]; let systemBytes: Int
    let note: String
}

/// SSH provides authentication and transport for both Wi-Fi and RFCOMM. Device writes outlive this process.
public actor OTAService {
    let paths: LocalPaths
    public init(paths: LocalPaths) { self.paths = paths }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func sshArguments(_ endpoint: OTAEndpoint) throws -> [String] {
        guard FileManager.default.fileExists(atPath: paths.key.path), FileManager.default.fileExists(atPath: paths.knownHosts.path) else {
            throw WorkbenchError("请先完成一次 Wi-Fi root SSH 验证，建立专用密钥与主机密钥记录。")
        }
        var args = ["-F", "/dev/null", "-T", "-i", paths.key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=yes", "-o", paths.knownHostsOption,
                    "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
                    "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
        if let bluetooth = endpoint.bluetooth { args += ["-o", "ProxyCommand=\(bluetooth.proxyCommand)"] }
        return args + ["root@\(endpoint.host)"]
    }
    func ssh(_ endpoint: OTAEndpoint, _ command: String, input: Data? = nil, timeout: TimeInterval = 45,
             report: Reporter? = nil) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("stdout"), err = directory.appendingPathComponent("stderr")
        for file in [out, err] { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        var stdin: FileHandle?
        if let input {
            let file = directory.appendingPathComponent("stdin"); try input.write(to: file)
            stdin = try FileHandle(forReadingFrom: file)
        }
        defer { try? stdin?.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try sshArguments(endpoint) + [command]
        process.standardInput = stdin ?? FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout); var lastReport = Date.distantPast
        while process.isRunning {
            if Date() > deadline {
                process.terminate(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit()
                let detail = String(decoding: (try? Data(contentsOf: err)) ?? Data(), as: UTF8.self)
                throw WorkbenchError("SSH 传输超时。设备端已启动的升级会继续，可重新查询状态。\n\(detail.suffix(1200))")
            }
            if let report, let input, let stdin, Date().timeIntervalSince(lastReport) > 2 {
                report("正在传输升级文件", min(0.99, Double(try stdin.offset()) / Double(max(input.count, 1))))
                lastReport = Date()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: out)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: try Data(contentsOf: err), as: UTF8.self)
            throw WorkbenchError("SSH 退出码 \(process.terminationStatus)\n\(detail.suffix(1600))")
        }
        return data
    }
    func agent(_ endpoint: OTAEndpoint, _ command: String) throws -> String {
        String(decoding: try ssh(endpoint, "sh -s -- " + command, input: Data(OTADeviceAgent.source.utf8)), as: UTF8.self)
    }
    public func status(_ endpoint: OTAEndpoint) throws -> OTAStatus { try .parse(agent(endpoint, "status")) }
    public func backup(_ endpoint: OTAEndpoint, to directory: URL, report: Reporter) throws -> URL {
        let device = try status(endpoint)
        guard !["writing", "arming", "trial"].contains(device.phase) else { throw WorkbenchError("请先结束当前 OTA 事务。") }
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw WorkbenchError("备份目录已存在。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [String: OTAFileRecord] = [:]
        for (index, name) in ["boot0", "boot1", "system0", "system1"].enumerated() {
            let size = index < 2 ? 6291456 : LX06.systemSize
            let command = "dd if=/dev/mtdblock\(index + 2) bs=131072 count=\(size / 131072) 2>/dev/null"
            report("正在备份 \(name)（\(size / 1048576) MiB）", Double(index) / 4)
            let data = try ssh(endpoint, command, timeout: endpoint.bluetooth == nil ? 180 : 1800)
            guard data.count == size else { throw WorkbenchError("\(name) 备份短读，停止。") }
            let hash = sha256(data)
            let remote = String(decoding: try ssh(endpoint, command + " | sha256sum", timeout: 180), as: UTF8.self).split(separator: " ").first
            guard remote == Substring(hash) else { throw WorkbenchError("\(name) 两次读取不一致。") }
            let file = directory.appendingPathComponent(name + ".bin"); try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard sha256(try Data(contentsOf: file)) == hash else { throw WorkbenchError("备份落盘校验失败。") }
            files[name] = OTAFileRecord(bytes: size, sha256: hash)
        }
        let environment = try ssh(endpoint, "dd if=/dev/nand_env bs=65536 count=1 2>/dev/null")
        guard environment.count == 65536 else { throw WorkbenchError("启动环境备份长度异常。") }
        try environment.write(to: directory.appendingPathComponent("nand-env.bin"), options: .atomic)
        files["nand-env"] = OTAFileRecord(bytes: environment.count, sha256: sha256(environment))
        let after = try status(endpoint)
        guard after.bootID == device.bootID, after.bootPart == device.bootPart else { throw WorkbenchError("备份期间设备重启，备份未完成。") }
        let manifest = OTABackupManifest(format: 1, device: device, files: files, systemBytes: LX06.systemSize,
            note: "system0/system1 contain the first 40 MiB logical image area; excludes system1's extra reported 128 KiB tail; not a full raw NAND backup")
        let file = directory.appendingPathComponent("ota-backup.json"); try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
        report("四个系统分区及启动环境备份完成", 1); return file
    }
    public func makePackage(firmware: URL, kernel: URL, output: URL) throws -> OTAPackage {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw WorkbenchError("OTA 包目录已存在。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let artifact = try decoder.decode(FirmwareArtifact.self, from: Data(contentsOf: firmware))
        guard artifact.originalHash == LX06.originalHash, artifact.file.isFileURL else { throw WorkbenchError("OTA 固件来源不匹配。") }
        let root = try Data(contentsOf: artifact.file), boot = try Data(contentsOf: kernel)
        let package = OTAPackage(format: 1, model: "LX06", version: LX06.version, kernelHash: sha256(boot),
                                 rootHash: artifact.hash, rootBytes: root.count, publicKeyHash: artifact.publicKeyHash)
        try OTAPackage.validate(package, kernel: boot, root: root)
        let hook = try LocalProcess.run(paths.tool("unsquashfs"), ["-cat", artifact.file.path, "etc/rc.local"]).output
        guard hook.contains("/data/xiaoai-ota/agent.sh boot-watch") else { throw WorkbenchError("固件缺少 OTA 试启动回退入口，请重新构建。") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try root.write(to: output.appendingPathComponent("root.squashfs"), options: .atomic)
        try boot.write(to: output.appendingPathComponent("boot.img"), options: .atomic)
        try JSONEncoder().encode(package).write(to: output.appendingPathComponent("ota.json"), options: .atomic)
        return package
    }
    func loadPackage(_ directory: URL) throws -> (OTAPackage, Data, Data) {
        let package = try JSONDecoder().decode(OTAPackage.self, from: Data(contentsOf: directory.appendingPathComponent("ota.json")))
        let kernel = try Data(contentsOf: directory.appendingPathComponent("boot.img"))
        let root = try Data(contentsOf: directory.appendingPathComponent("root.squashfs"))
        try OTAPackage.validate(package, kernel: kernel, root: root)
        let publicKey = try LocalProcess.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), ["-y", "-f", paths.key.path]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha256(Data(publicKey.utf8)) == package.publicKeyHash else { throw WorkbenchError("本机密钥与 OTA 固件不匹配。") }
        return (package, kernel, root)
    }
    public func install(_ endpoint: OTAEndpoint, package directory: URL, backup backupDirectory: URL,
                        deferConfirmation: Bool = false, report: @escaping Reporter) async throws -> OTAStatus {
        let (package, kernel, root) = try loadPackage(directory)
        let backup = try JSONDecoder().decode(OTABackupManifest.self, from: Data(contentsOf: backupDirectory.appendingPathComponent("ota-backup.json")))
        for (name, record) in backup.files {
            let data = try Data(contentsOf: backupDirectory.appendingPathComponent(name + ".bin"))
            guard data.count == record.bytes, sha256(data) == record.sha256 else { throw WorkbenchError("OTA 备份已损坏。") }
        }
        guard backup.format == 1, Set(backup.files.keys) == Set(["boot0", "boot1", "system0", "system1", "nand-env"]) else { throw WorkbenchError("OTA 备份不完整。") }
        let before = try status(endpoint)
        guard before.bootPart == backup.device.bootPart, !["writing", "arming", "trial"].contains(before.phase) else { throw WorkbenchError("备份启动槽位不匹配或存在未结束的升级。") }
        report("正在复核当前系统与备份一致", nil)
        let read = "dd if=\(before.rootDevice) bs=131072 count=320 2>/dev/null | sha256sum"
        let hash = String(decoding: try ssh(endpoint, read, timeout: 180), as: UTF8.self).split(separator: " ").first
        guard hash == backup.files[before.bootPart == "boot0" ? "system0" : "system1"].map({ Substring($0.sha256) }) else { throw WorkbenchError("当前系统与备份不一致，请重新备份。") }
        let kernelDevice = before.bootPart == "boot0" ? "/dev/mtdblock2" : "/dev/mtdblock3"
        let kernelHash = String(decoding: try ssh(endpoint, "dd if=\(kernelDevice) bs=131072 count=48 2>/dev/null | sha256sum"), as: UTF8.self).split(separator: " ").first
        guard kernelHash == backup.files[before.bootPart].map({ Substring($0.sha256) }) else { throw WorkbenchError("当前内核与备份不一致，请重新备份。") }
        let job = UUID().uuidString.lowercased()
        // Use the transaction ID as the only remote directory component.
        let destination = "/tmp/xiaoai-ota/" + job
        _ = try ssh(endpoint, "test $(df -k /tmp | awk 'NR==2 {print $4}') -gt 50000 && umask 077 && mkdir -p " + Self.quote(destination))
        report("正在上传内核", 0)
        _ = try ssh(endpoint, "cat > " + Self.quote(destination + "/boot.img"), input: kernel, timeout: endpoint.bluetooth == nil ? 180 : 1800, report: report)
        report("正在上传系统镜像", 0)
        _ = try ssh(endpoint, "cat > " + Self.quote(destination + "/root.squashfs"), input: root, timeout: endpoint.bluetooth == nil ? 180 : 1800, report: report)
        _ = try ssh(endpoint, "cat > " + Self.quote(destination + "/agent.sh"), input: Data(OTADeviceAgent.source.utf8))
        let args = "apply \(job) \(package.rootHash) \(package.rootBytes) \(package.kernelHash)"
        let command = "trap '' HUP; sh " + Self.quote(destination + "/agent.sh") + " " + args + " >" + Self.quote(destination + "/apply.log") + " 2>&1 </dev/null &"
        report("设备端开始写入备用槽位，连接中断可重新查询状态", nil)
        _ = try ssh(endpoint, command)
        return try await waitForTrial(endpoint, job: job, before: before, deferConfirmation: deferConfirmation, report: report)
    }
    func waitForTrial(_ endpoint: OTAEndpoint, job: String, before: OTAStatus, deferConfirmation: Bool, report: @escaping Reporter) async throws -> OTAStatus {
        let deadline = Date().addingTimeInterval(240); var lastError = "等待设备升级"
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            do {
                let state = try status(endpoint)
                if state.job == job {
                    if state.phase == "failed" { throw OTATransactionFailure(message: "设备端升级失败，请核对当前槽位并查看 /tmp/xiaoai-ota/\(job)/apply.log。") }
                    if state.phase == "rolled_back" {
                        _ = try agent(endpoint, "finish-rollback " + Self.quote(job))
                        throw OTATransactionFailure(message: "新系统未完成确认，已回退原槽位。")
                    }
                    if state.phase == "trial", state.bootID != before.bootID, state.bootPart == state.target {
                        report("新槽位已启动，正在核对镜像和服务", nil)
                        if deferConfirmation { return state }
                        return try confirm(endpoint, job: job)
                    }
                    report("OTA 阶段：\(state.phase)", nil)
                }
            } catch let error as OTATransactionFailure { throw error }
            catch { lastError = error.localizedDescription; report("等待设备重新连接：\(lastError)", nil) }
        }
        throw WorkbenchError("OTA 等待超时，设备试启动未确认时将自动回退。\(lastError)")
    }
    public func confirm(_ endpoint: OTAEndpoint, job: String) throws -> OTAStatus {
        guard UUID(uuidString: job) != nil else { throw WorkbenchError("事务 ID 无效。") }
        return try .parse(agent(endpoint, "confirm " + Self.quote(job)))
    }
    public func rollback(_ endpoint: OTAEndpoint, report: @escaping Reporter) async throws -> OTAStatus {
        let before = try status(endpoint)
        guard let job = before.job, let previous = before.previous, UUID(uuidString: job) != nil,
              ["trial", "committed", "rolled_back"].contains(before.phase) else { throw WorkbenchError("没有可回退的 OTA 事务。") }
        if before.phase == "rolled_back" { return try .parse(agent(endpoint, "finish-rollback " + Self.quote(job))) }
        _ = try agent(endpoint, "rollback " + Self.quote(job))
        return try await waitForRollback(endpoint, job: job, previous: previous, beforeBootID: before.bootID, report: report)
    }
    public func waitForRollback(_ endpoint: OTAEndpoint, job: String, previous: String, beforeBootID: String, report: @escaping Reporter) async throws -> OTAStatus {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(4))
            if let state = try? status(endpoint), state.bootID != beforeBootID, state.bootPart == previous, state.job == job, state.phase == "rolled_back" {
                return try .parse(agent(endpoint, "finish-rollback " + Self.quote(job)))
            }
            report("等待原槽位启动并验证", nil)
        }
        throw WorkbenchError("回退验证超时，请通过另一种连接方式查询状态。")
    }
}
struct OTATransactionFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
