import Foundation
import XiaoaiCore

struct CLIUsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CLIRequest: Sendable {
    enum Command: String, CaseIterable, Sendable {
        case paths, detect, backup, build, flash, restore, observe, diagnose
        case otaStatus = "ota-status", otaBackup = "ota-backup", otaPackage = "ota-package"
        case otaInstall = "ota-install", otaConfirm = "ota-confirm", otaRollback = "ota-rollback"
        case prepareOriginal = "prepare-original", importOriginal = "import-original"
        case checkBackup = "check-backup", verifySSH = "verify-ssh"
        case verifyBluetooth = "verify-bluetooth"
        case rebootVerify = "reboot-verify", sshCommand = "ssh-command"

        var required: Set<String> {
            switch self {
            case .otaStatus, .otaRollback: ["host"]
            case .otaBackup: ["host", "output"]
            case .otaPackage: ["firmware", "kernel", "output"]
            case .otaInstall: ["host", "package", "backup"]
            case .otaConfirm: ["host", "job"]
            case .backup, .observe, .diagnose: ["output"]
            case .importOriginal: ["file"]
            case .checkBackup, .restore: ["backup"]
            case .flash: ["firmware", "backup"]
            case .verifySSH, .rebootVerify, .sshCommand: ["host"]
            case .verifyBluetooth: ["host", "address"]
            default: []
            }
        }
        var allowed: Set<String> {
            var options = required
            if [.otaStatus, .otaBackup, .otaInstall, .otaConfirm, .otaRollback].contains(self) { options.formUnion(["address", "data-dir"]) }
            if self == .otaPackage { options.formUnion(["data-dir", "tools-dir"]) }
            if [.otaInstall, .otaRollback, .otaConfirm].contains(self) { options.insert("confirm-write") }
            if self == .otaInstall { options.insert("defer-confirm") }
            if [.paths, .prepareOriginal, .importOriginal, .build, .flash, .verifySSH, .verifyBluetooth, .rebootVerify, .sshCommand].contains(self) {
                options.insert("data-dir")
            }
            if [.paths, .build].contains(self) { options.insert("tools-dir") }
            if self == .build { options.insert("original") }
            if self == .sshCommand { options.insert("address") }
            if [.detect, .backup, .flash, .restore].contains(self) { options.insert("timeout") }
            if [.flash, .restore].contains(self) { options.insert("confirm-write") }
            if self == .rebootVerify { options.insert("confirm-reboot") }
            return options
        }
    }
    let command: Command
    let options: [String: String]
    var timeout: Duration { .seconds(Int(options["timeout"] ?? "120")!) }
    func url(_ key: String) -> URL { URL(fileURLWithPath: options[key]!).standardizedFileURL }

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, let command = Command(rawValue: first) else {
            throw CLIUsageError(message: "需要有效子命令，使用 --cli --help 查看。")
        }
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw CLIUsageError(message: "不支持位置参数：\(argument)") }
            let key = String(argument.dropFirst(2))
            guard command.allowed.contains(key), options[key] == nil else {
                throw CLIUsageError(message: "未知、重复或不适用于此命令的参数：\(argument)")
            }
            if ["confirm-write", "confirm-reboot", "defer-confirm"].contains(key) {
                options[key] = "true"
            } else {
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    throw CLIUsageError(message: "参数缺少值：\(argument)")
                }
                options[key] = arguments[index]
            }
            index += 1
        }
        let missing = command.required.subtracting(options.keys).sorted()
        guard missing.isEmpty else { throw CLIUsageError(message: "缺少参数：\(missing.map { "--" + $0 }.joined(separator: ", "))") }
        if let timeout = options["timeout"], !(Int(timeout).map { (1...600).contains($0) } ?? false) {
            throw CLIUsageError(message: "--timeout 必须为 1 至 600 的整数秒数。")
        }
        if let host = options["host"], !Workbench.validIP(host) {
            throw CLIUsageError(message: "--host 必须是有效 IPv4 地址。")
        }
        if let address = options["address"], !BluetoothSSH.validAddress(address) {
            throw CLIUsageError(message: "--address 必须是 XX:XX:XX:XX:XX:XX 格式的蓝牙地址。")
        }
        if [.flash, .restore, .otaInstall, .otaConfirm, .otaRollback].contains(command), options["confirm-write"] == nil {
            throw CLIUsageError(message: "此命令会写入音箱，必须显式提供 --confirm-write。")
        }
        if command == .rebootVerify, options["confirm-reboot"] == nil {
            throw CLIUsageError(message: "此命令会重启音箱，必须显式提供 --confirm-reboot。")
        }
        if let job = options["job"], UUID(uuidString: job) == nil { throw CLIUsageError(message: "--job 必须是有效事务 UUID。") }
        self.command = command; self.options = options
    }
}

// Deliberately expose selected fields only; raw environment and SSH output stay out of stdout.
struct CLIData: Codable, Sendable {
    var dataDirectory: String?
    var toolsDirectory: String?
    var outputDirectory: String?
    var file: String?
    var manifest: String?
    var sha256: String?
    var logicalHash: String?
    var isStock: Bool?
    var boardID: String?
    var bootPart: String?
    var bootDelay: String?
    var protocolVersion: String?
    var bootID: String?
    var sshCommand: String?
    var requiresPowerCycle: Bool?
    var ota: OTAStatus?

    static func backup(_ backup: BackupArtifact) -> Self {
        Self(outputDirectory: backup.directory.path,
             file: backup.directory.appendingPathComponent("system0.bin").path,
             manifest: backup.directory.appendingPathComponent("backup.json").path,
             sha256: backup.manifest.systemHash, logicalHash: backup.manifest.logicalHash,
             isStock: backup.isStock, boardID: backup.manifest.environment.boardID,
             bootPart: backup.manifest.environment.bootPart, bootDelay: backup.manifest.environment.bootDelay)
    }
}

struct CLIResponse: Codable, Sendable {
    struct Failure: Codable, Sendable { let code: String; let message: String }
    var schemaVersion = 1
    let command: String
    let ok: Bool
    let data: CLIData?
    let error: Failure?
}

struct CLIProgress: Encodable {
    let schemaVersion = 1
    let type = "progress"
    let command: String
    let message: String
    let fraction: Double?
}

@MainActor enum CLICommand {
    static let help = """
    用法：XiaoaiWorkbench --cli <命令> [参数]
    paths [--data-dir DIR] [--tools-dir DIR]
    detect [--timeout SECONDS]
    backup --output NEW_DIR [--timeout SECONDS]
    check-backup --backup DIR
    prepare-original [--data-dir DIR]
    import-original --file FILE [--data-dir DIR]
    build [--original FILE] [--data-dir DIR] [--tools-dir DIR]
    flash --firmware FIRMWARE_JSON --backup DIR --confirm-write [--timeout SECONDS] [--data-dir DIR]
    restore --backup DIR --confirm-write [--timeout SECONDS]
    verify-ssh --host IPV4 [--data-dir DIR]
    verify-bluetooth --host KNOWN_IPV4 --address BLUETOOTH_MAC [--data-dir DIR]
    reboot-verify --host IPV4 --confirm-reboot [--data-dir DIR]
    ssh-command --host IPV4 [--address BLUETOOTH_MAC] [--data-dir DIR]
    ota-status --host IPV4 [--address BLUETOOTH_MAC]
    ota-backup --host IPV4 --output NEW_DIR [--address BLUETOOTH_MAC]
    ota-package --firmware FIRMWARE_JSON --kernel BOOT_IMG --output NEW_DIR
    ota-install --host IPV4 --package DIR --backup DIR --confirm-write [--defer-confirm] [--address BLUETOOTH_MAC]
    ota-confirm --host IPV4 --job UUID --confirm-write [--address BLUETOOTH_MAC]
    ota-rollback --host IPV4 --confirm-write [--address BLUETOOTH_MAC]
    observe --output NEW_DIR
    diagnose --output NEW_DIR

    stdout：单个 JSON 结果，schemaVersion=1；stderr：JSONL 进度。
    退出码：0 成功，64 参数错误或缺少确认，1 操作失败。
    --timeout：USB 等待上限，默认 120 秒，范围 1 至 600 秒。
    observe 被动观察 120 秒；diagnose 等待最多 120 秒并备份，失败后继续系统监测到窗口结束。
    每条 USB 命令自行建立会话；需要重新上电时通过进度提示。不会自动刷写或重启。
    帮助使用 --cli --help。无参数启动图形界面。
    """

    nonisolated static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }
    nonisolated static func progress(_ command: String) -> Reporter {
        { message, fraction in
            // All event fields are strings or finite fractions supplied by our own core.
            if let data = try? encoded(CLIProgress(command: command, message: message, fraction: fraction)) {
                FileHandle.standardError.write(data)
            }
        }
    }

    static func run(_ arguments: [String],
                    execute: (CLIRequest) async throws -> CLIData = execute) async -> (Int32, CLIResponse) {
        do {
            let request = try CLIRequest(arguments)
            let data = try await execute(request)
            return (0, CLIResponse(command: request.command.rawValue, ok: true, data: data, error: nil))
        } catch {
            let usage = error is CLIUsageError
            return (usage ? 64 : 1, CLIResponse(command: arguments.first ?? "", ok: false, data: nil,
                error: .init(code: usage ? "invalid_arguments" : "operation_failed", message: error.localizedDescription)))
        }
    }

    static func execute(_ request: CLIRequest) async throws -> CLIData {
        let defaults = AppModel.defaultPaths()
        let paths = LocalPaths(root: request.options["data-dir"].map { URL(fileURLWithPath: $0).standardizedFileURL } ?? defaults.root,
                               tools: request.options["tools-dir"].map { URL(fileURLWithPath: $0).standardizedFileURL } ?? defaults.tools)
        let service = Workbench(paths: paths)
        let report = progress(request.command.rawValue)
        switch request.command {
        case .otaPackage:
            let package = try await OTAService(paths: paths).makePackage(firmware: request.url("firmware"), kernel: request.url("kernel"), output: request.url("output"))
            return CLIData(outputDirectory: request.url("output").path, manifest: request.url("output").appendingPathComponent("ota.json").path, sha256: package.rootHash)
        case .otaStatus, .otaBackup, .otaInstall, .otaConfirm, .otaRollback:
            let endpoint = try OTAEndpoint(host: request.options["host"]!, bluetooth: bluetooth(request))
            let ota = OTAService(paths: paths)
            switch request.command {
            case .otaBackup:
                let file = try await ota.backup(endpoint, to: request.url("output"), report: report)
                return CLIData(outputDirectory: request.url("output").path, manifest: file.path)
            case .otaInstall:
                return CLIData(ota: try await ota.install(endpoint, package: request.url("package"), backup: request.url("backup"), deferConfirmation: request.options["defer-confirm"] != nil, report: report))
            case .otaConfirm: return CLIData(ota: try await ota.confirm(endpoint, job: request.options["job"]!))
            case .otaRollback: return CLIData(ota: try await ota.rollback(endpoint, report: report))
            default: return CLIData(ota: try await ota.status(endpoint))
            }
        case .paths:
            return CLIData(dataDirectory: paths.root.path, toolsDirectory: paths.tools.path)
        case .detect:
            let info = try await service.detect(timeout: request.timeout, report: report)
            await service.disconnect()
            return CLIData(boardID: info.environment.boardID, bootPart: info.environment.bootPart,
                           bootDelay: info.environment.bootDelay, protocolVersion: info.protocolVersion)
        case .backup:
            let destination = request.url("output")
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw WorkbenchError("备份输出目录已存在，请使用新目录。") }
            let backup = try await service.detectAndBackup(to: destination, timeout: request.timeout, report: report)
            await service.disconnect()
            return .backup(backup)
        case .checkBackup:
            return .backup(try Workbench.loadBackup(request.url("backup")))
        case .prepareOriginal:
            try await service.prepareOriginal(report: report)
            return CLIData(file: paths.original.path, sha256: LX06.originalHash)
        case .importOriginal:
            try await service.importOriginal(from: request.url("file"))
            return CLIData(file: paths.original.path, sha256: LX06.originalHash)
        case .build:
            if request.options["original"] != nil { try await service.importOriginal(from: request.url("original")) }
            else { try await service.prepareOriginal(report: report) }
            let artifact = try await service.buildFirmware(report: report)
            return CLIData(file: artifact.file.path,
                           manifest: artifact.file.deletingLastPathComponent().appendingPathComponent("firmware.json").path,
                           sha256: artifact.hash)
        case .flash:
            let backup = try Workbench.loadBackup(request.url("backup"))
            guard backup.isStock else { throw WorkbenchError("首次刷入需要原版 1.94.13 备份。") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let artifact = try decoder.decode(FirmwareArtifact.self, from: Data(contentsOf: request.url("firmware")))
            guard artifact.file.isFileURL, artifact.originalHash == LX06.originalHash,
                  sha256(try Data(contentsOf: artifact.file)) == artifact.hash else {
                throw WorkbenchError("固件清单或文件校验失败。")
            }
            _ = try await service.detect(timeout: request.timeout, report: report)
            try await service.flash(artifact, backup: backup, report: report)
            await service.disconnect()
            return CLIData(sha256: artifact.hash, bootPart: "boot0", requiresPowerCycle: true)
        case .restore:
            let backup = try Workbench.loadBackup(request.url("backup"))
            _ = try await service.detect(timeout: request.timeout, report: report)
            try await service.restore(backup, report: report)
            await service.disconnect()
            return CLIData(sha256: backup.manifest.systemHash, bootPart: backup.manifest.environment.bootPart,
                           bootDelay: backup.manifest.environment.bootDelay, requiresPowerCycle: true)
        case .verifySSH, .rebootVerify:
            let host = request.options["host"]!
            let result = try await (request.command == .verifySSH
                ? service.verifySSH(host: host) : service.rebootAndVerify(host: host, report: report))
            return CLIData(bootID: result.bootID)
        case .verifyBluetooth:
            let result = try await service.verifySSH(host: request.options["host"]!, bluetooth: bluetooth(request))
            return CLIData(bootID: result.bootID)
        case .sshCommand:
            return CLIData(sshCommand: try await service.sshCommand(host: request.options["host"]!, bluetooth: bluetooth(request)))
        case .observe, .diagnose:
            let directory = request.url("output")
            let backup = try await USBDiagnosticCommand.run(directory: directory, passive: request.command == .observe) {
                report($0, nil)
            }
            var result = backup.map { CLIData.backup($0) } ?? CLIData()
            result.outputDirectory = directory.path
            return result
        }
    }
    static func bluetooth(_ request: CLIRequest) throws -> BluetoothSSH? {
        guard let address = request.options["address"] else { return nil }
        let executable = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("XiaoaiBluetoothProxy")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkbenchError("缺少蓝牙代理，请使用完整打包应用。")
        }
        return try BluetoothSSH(executable: executable, address: address)
    }
}
