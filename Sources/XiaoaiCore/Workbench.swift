import Foundation

public typealias Reporter = @Sendable (String, Double?) -> Void

public struct DeviceInfo: Sendable {
    public let protocolVersion: String
    public let environment: EnvironmentSnapshot
}
public struct BackupManifest: Codable, Sendable {
    public let format: Int
    public let createdAt: Date
    public let systemHash: String
    public let logicalHash: String
    public let environment: EnvironmentSnapshot
}
public struct BackupArtifact: Sendable {
    public let directory: URL
    public let manifest: BackupManifest
    public var isStock: Bool { manifest.logicalHash == LX06.originalHash }
}
public struct SSHResult: Sendable {
    public let bootID: String
    public let bootPart: String
    public let output: String
}

struct FlashTransaction {
    let aml: AMLProtocol
    let report: Reporter
    func writeAndVerify(_ image: Data, environment: EnvironmentSnapshot) throws {
        report("正在写入 system0，请保持 USB 和电源连接", 0)
        try aml.writeSystem(image) { report("正在写入 system0，请保持 USB 和电源连接", $0) }
        report("正在读回 system0 并比较 SHA-256", 0)
        let readback = try aml.upload("store system0", count: image.count) {
            report("正在读回 system0 并比较 SHA-256", $0)
        }
        guard sha256(readback) == sha256(image) else {
            throw WorkbenchError("system0 读回校验失败，启动环境未修改。请保持 USB 连接，使用备份恢复。")
        }
        report("分区校验通过，正在保存启动项", nil)
        try aml.bulkCommand("setenv boot_part \(environment.bootPart)")
        if let delay = environment.bootDelay { try aml.bulkCommand("setenv bootdelay \(delay)") }
        else { try aml.bulkCommand("setenv bootdelay") }
        try aml.bulkCommand("saveenv")
        let persisted = try aml.environment()
        guard persisted.bootPart == environment.bootPart, persisted.bootDelay == environment.bootDelay else {
            throw WorkbenchError("系统镜像已校验，但启动环境核对失败。请保持 USB 连接，恢复备份的启动项。")
        }
        report("USB 写入与启动项核对完成。请拔掉 USB 和电源，再重新接通电源，继续 SSH 验证。", 1)
    }
}

public actor Workbench {
    public let paths: LocalPaths
    private var connection: AMLProtocol?
    private let diagnostics: USBDiagnosticReporter?
    private let makeUSB: (@Sendable (USBDiagnosticReporter?) throws -> any USBTransport)?
    public init(paths: LocalPaths, diagnostics: USBDiagnosticReporter? = nil) {
        self.paths = paths; self.diagnostics = diagnostics
        makeUSB = nil
    }
    init(paths: LocalPaths, diagnostics: USBDiagnosticReporter? = nil,
         makeUSB: @escaping @Sendable (USBDiagnosticReporter?) throws -> any USBTransport) {
        self.paths = paths; self.diagnostics = diagnostics; self.makeUSB = makeUSB
    }
    public func disconnect() {
        connection = nil
        diagnostics?("session.released")
    }
    public func observeUSBAfterFailure(until deadline: ContinuousClock.Instant, report: Reporter) async throws {
        // The CLI owns the independent system monitor, even when detection produced no connection.
        guard ContinuousClock.now < deadline else { return }
        diagnostics?("session.observing_after_failure")
        report("传输已停止，继续记录系统 USB 接入和移除，直到本轮观察窗口结束", nil)
        try await Task.sleep(until: deadline, clock: .continuous)
    }
    public func detect(timeout: Duration = .seconds(25), report: Reporter) async throws -> DeviceInfo {
        connection = nil
        let discovery = try makeUSB == nil ? NativeUSBDiscovery(diagnostics: diagnostics) : nil
        // A successful NativeUSB retains discovery through environment reads and backup.
        // Unsuccessful attempts release only their device handle, never this context.
        defer { withExtendedLifetime(discovery) {} }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        diagnostics?("detect.begin timeout=\(timeout)")
        report("USB 持续监听已就绪，正在检查现有连接", nil)
        var lastWaitMessage: String?
        while ContinuousClock.now < deadline {
            var stage = "open"
            do {
                let transport: any USBTransport
                if let makeUSB { transport = try makeUSB(diagnostics) }
                else if let discovery { transport = try NativeUSB(discovery: discovery, diagnostics: diagnostics) }
                else { preconditionFailure("Native USB discovery was not initialized") }
                let aml = AMLProtocol(usb: transport, diagnostics: diagnostics)
                stage = "identify"
                let protocolVersion = try aml.identify().map(String.init).joined(separator: ".")
                diagnostics?("detect.identify.complete; polling stopped; reading environment on same connection")
                report("USB 握手成功，请保持供电和数据线连接，正在读取启动环境", nil)
                stage = "environment"
                let environment = try aml.environment()
                connection = aml
                diagnostics?("detect.complete board_id=\(environment.boardID) boot_part=\(environment.bootPart) bootdelay=\(environment.bootDelay ?? "unset")")
                return DeviceInfo(protocolVersion: protocolVersion, environment: environment)
            } catch let error as USBOpenError where error.code == -4 {
                let message = "正在等待 USB 设备，监听已就绪；请保持数据线连接，现在给音箱断电后重新上电"
                if message != lastWaitMessage { report(message, nil); lastWaitMessage = message }
            } catch is USBStageError {
                let message = "已发现 USB 设备，正在等待 U-Boot 分区操作阶段"
                if message != lastWaitMessage { report(message, nil); lastWaitMessage = message }
            } catch {
                diagnostics?("detect.failed stage=\(stage) error_type=\(String(reflecting: type(of: error)))")
                diagnostics?("boot.environment.unavailable reason=detection_failed stage=\(stage)")
                throw error
            }
            try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(100))), clock: .continuous)
        }
        diagnostics?("detect.timeout")
        diagnostics?("boot.environment.unavailable reason=no_usable_usb_session")
        throw WorkbenchError("等待 USB 连接超时，未确认可用的 U-Boot 设备。请检查主板 Micro USB 数据线，重新点击检测，等待出现上电提示后再给音箱断电上电。")
    }
    private func device() throws -> AMLProtocol {
        guard let connection else { throw WorkbenchError("请先检测 USB 设备。") }
        _ = try connection.identify()
        return connection
    }
    public func prepareOriginal(report: Reporter) async throws {
        try paths.prepare()
        if FileManager.default.fileExists(atPath: paths.original.path),
           sha256(try Data(contentsOf: paths.original, options: .mappedIfSafe)) == LX06.originalHash {
            report("原版固件 SHA-256 已核对", 1); return
        }
        report("正在下载 LX06 1.94.13 原版固件（约 36 MB）", nil)
        let (temp, response) = try await URLSession.shared.download(from: LX06.download)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkbenchError("原版固件下载失败，请检查网络连接。")
        }
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        guard sha256(data) == LX06.originalHash else { throw WorkbenchError("下载镜像 SHA-256 不符，已停止。") }
        try data.write(to: paths.original, options: .atomic)
        report("原版固件下载完成，SHA-256 已核对", 1)
    }
    public func importOriginal(from url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard sha256(data) == LX06.originalHash else { throw WorkbenchError("所选文件与 LX06 1.94.13 原版基线不一致。") }
        try paths.prepare()
        if url.standardizedFileURL != paths.original.standardizedFileURL { try data.write(to: paths.original, options: .atomic) }
    }
    public func buildFirmware(report: Reporter) throws -> FirmwareArtifact {
        try FirmwareBuilder(paths: paths).build { report($0, nil) }
    }
    public func backup(to directory: URL, report: Reporter) throws -> BackupArtifact {
        let aml = try device()
        let environment = try aml.environment()
        return try backup(using: aml, environment: environment, to: directory, report: report)
    }
    public func detectAndBackup(to directory: URL, timeout: Duration = .seconds(120), report: Reporter) async throws -> BackupArtifact {
        let info = try await detect(timeout: timeout, report: report)
        guard let aml = connection else { throw WorkbenchError("USB 会话已关闭。") }
        diagnostics?("session.handoff operation=backup; using identified connection")
        return try backup(using: aml, environment: info.environment, to: directory, report: report)
    }
    private func backup(using aml: AMLProtocol, environment: EnvironmentSnapshot, to directory: URL, report: Reporter) throws -> BackupArtifact {
        diagnostics?("backup.begin bytes=\(LX06.systemSize)")
        report("正在读取 system0（40 MiB），不会写入分区", 0)
        let data = try aml.upload("store system0", count: LX06.systemSize) { report("正在读取 system0（40 MiB）", $0) }
        let logical = try SquashFS.logicalImage(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("system0.bin")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw WorkbenchError("备份目录已存在 system0.bin，请使用新目录。") }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let manifest = BackupManifest(format: 1, createdAt: Date(), systemHash: sha256(data),
            logicalHash: sha256(logical), environment: environment)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestFile = directory.appendingPathComponent("backup.json")
        try encoder.encode(manifest).write(to: manifestFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestFile.path)
        // Validate the files actually written to disk before making the backup usable.
        let saved = try Self.loadBackup(directory)
        diagnostics?("backup.complete bytes=\(data.count) system_sha256=\(saved.manifest.systemHash) logical_sha256=\(saved.manifest.logicalHash) is_stock=\(saved.isStock)")
        report(saved.isStock ? "备份及落盘校验完成，system0 与原版 1.94.13 一致" : "备份完成；system0 与原版基线不同，禁止直接刷入最小固件", 1)
        return saved
    }
    public static func loadBackup(_ directory: URL) throws -> BackupArtifact {
        try readBackup(directory).artifact
    }
    static func readBackup(_ directory: URL) throws -> (artifact: BackupArtifact, image: Data) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: directory.appendingPathComponent("backup.json")))
        guard manifest.format == 1,
              try EnvironmentSnapshot(text: manifest.environment.text) == manifest.environment else {
            throw WorkbenchError("备份环境记录无效。")
        }
        // Keep an owned snapshot so later file replacement or overwrite cannot change validated bytes.
        let data = try Data(contentsOf: directory.appendingPathComponent("system0.bin"))
        guard data.count == LX06.systemSize, sha256(data) == manifest.systemHash,
              sha256(try SquashFS.logicalImage(data)) == manifest.logicalHash else {
            throw WorkbenchError("备份文件损坏或校验不符。")
        }
        return (BackupArtifact(directory: directory, manifest: manifest), data)
    }
    public func openBackup(_ directory: URL) throws -> BackupArtifact { try Self.loadBackup(directory) }
    static func flashEnvironment(from environment: EnvironmentSnapshot) throws -> EnvironmentSnapshot {
        let delay = environment.bootDelay.map { "bootdelay=\($0)\n" } ?? ""
        return try EnvironmentSnapshot(text: "boot_part=boot0\nboard_id=\(environment.boardID)\n" + delay)
    }
    public func flash(_ artifact: FirmwareArtifact, backup: BackupArtifact, report: @escaping Reporter) throws {
        let saved = try Self.loadBackup(backup.directory)
        guard saved.isStock, artifact.originalHash == LX06.originalHash else {
            throw WorkbenchError("仅允许在已备份且核实为原版 1.94.13 的 system0 上操作。")
        }
        let key = try FirmwareBuilder(paths: paths).ensureKey()
        guard sha256(Data(key.utf8)) == artifact.publicKeyHash else { throw WorkbenchError("当前 SSH 密钥与固件不匹配，请重新构建。") }
        let image = try Data(contentsOf: artifact.file, options: .mappedIfSafe)
        _ = try SquashFS.logicalImage(image)
        guard sha256(image) == artifact.hash else { throw WorkbenchError("待刷镜像已改变，请重新构建。") }
        let aml = try device()
        let environment = try aml.environment()
        guard environment.boardID == saved.manifest.environment.boardID,
              environment.bootPart == saved.manifest.environment.bootPart,
              environment.bootDelay == saved.manifest.environment.bootDelay else {
            throw WorkbenchError("设备启动状态已改变，请重新检测并备份。")
        }
        report("正在复核设备 system0 与备份一致", 0)
        let current = try aml.upload("store system0", count: LX06.systemSize) { report("正在复核设备 system0 与备份一致", $0) }
        guard sha256(current) == saved.manifest.systemHash else { throw WorkbenchError("设备 system0 已改变，请重新备份。") }
        let target = try Self.flashEnvironment(from: environment)
        try FlashTransaction(aml: aml, report: report).writeAndVerify(image, environment: target)
    }
    public func restore(_ backup: BackupArtifact, report: @escaping Reporter) throws {
        let (saved, image) = try Self.readBackup(backup.directory)
        let aml = try device()
        let environment = try aml.environment()
        guard environment.boardID == saved.manifest.environment.boardID else { throw WorkbenchError("备份的硬件 board_id 与当前设备不符。") }
        try FlashTransaction(aml: aml, report: report).writeAndVerify(image, environment: saved.manifest.environment)
    }
    public static func validIP(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && (Int($0).map { (0...255).contains($0) } ?? false)
        }
    }
    private func ssh(_ host: String, command: String, bluetooth: BluetoothSSH? = nil) throws -> String {
        guard Self.validIP(host) else { throw WorkbenchError("请输入音箱的 IPv4 地址，例如 192.168.31.227。") }
        guard FileManager.default.fileExists(atPath: paths.key.path) else { throw WorkbenchError("本机尚无专用 SSH 密钥，请先制作固件。") }
        var arguments = [
            "-F", "/dev/null", "-T", "-i", paths.key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(bluetooth == nil ? 5 : 20)", "-o", "ConnectionAttempts=1", "-o", "StrictHostKeyChecking=\(bluetooth == nil ? "accept-new" : "yes")",
            "-o", paths.knownHostsOption, "-o", "HostKeyAlgorithms=+ssh-rsa",
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa"]
        if let bluetooth { arguments += ["-o", "ProxyCommand=\(bluetooth.proxyCommand)"] }
        arguments += ["root@\(host)", command]
        return try LocalProcess.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments, timeout: bluetooth == nil ? 15 : 35).output
    }
    public func verifySSH(host: String, bluetooth: BluetoothSSH? = nil) throws -> SSHResult {
        let output = try ssh(host, command: "printf 'XW_UID=%s\\n' \"$(id -u)\"; printf 'XW_MODEL=%s\\n' \"$(uci -c /usr/share/mico get version.version.HARDWARE)\"; printf 'XW_ROM=%s\\n' \"$(uci -c /usr/share/mico get version.version.ROM)\"; printf 'XW_BOOT=%s\\n' \"$(fw_env -g boot_part)\"; printf 'XW_BOOT_ID=%s\\n' \"$(cat /proc/sys/kernel/random/boot_id)\"", bluetooth: bluetooth)
        return try Self.parseSSH(output)
    }
    static func parseSSH(_ output: String) throws -> SSHResult {
        let lines = output.components(separatedBy: .newlines)
        guard lines.contains("XW_UID=0"), lines.contains("XW_MODEL=LX06"), lines.contains("XW_ROM=1.94.13"),
              (lines.contains("XW_BOOT=boot0") || lines.contains("XW_BOOT=boot1")), let boot = lines.first(where: { $0.hasPrefix("XW_BOOT_ID=") }),
              UUID(uuidString: String(boot.dropFirst(11))) != nil else {
            throw WorkbenchError("SSH 已连接，但 root、型号、版本或启动项核对未通过。\n\(output.prefix(1500))")
        }
        return SSHResult(bootID: String(boot.dropFirst(11)), bootPart: lines.contains("XW_BOOT=boot0") ? "boot0" : "boot1", output: output)
    }
    public func rebootAndVerify(host: String, report: Reporter) async throws -> SSHResult {
        let before = try verifySSH(host: host)
        _ = try ssh(host, command: "trap '' HUP; (sleep 2; reboot) >/dev/null 2>&1 </dev/null &")
        let deadline = Date().addingTimeInterval(120)
        var lastError = "设备尚未完成重启"
        while Date() < deadline {
            try await Task.sleep(for: .seconds(4))
            report("正在等待音箱重启并重新验证 SSH", nil)
            do {
                let after = try verifySSH(host: host)
                if after.bootID != before.bootID { return after }
            } catch { lastError = error.localizedDescription }
        }
        throw WorkbenchError("重启后 SSH 验证超时。\(lastError)")
    }
    public func sshCommand(host: String, bluetooth: BluetoothSSH? = nil) -> String {
        let safeHost = Self.validIP(host) ? host : "音箱IP"
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let proxy = bluetooth.map { " -o StrictHostKeyChecking=yes -o " + quoted("ProxyCommand=" + $0.proxyCommand) } ?? ""
        return "ssh -F /dev/null -i \(quoted(paths.key.path)) -o IdentitiesOnly=yes -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o \(quoted(paths.knownHostsOption))\(proxy) root@\(safeHost)"
    }
}
