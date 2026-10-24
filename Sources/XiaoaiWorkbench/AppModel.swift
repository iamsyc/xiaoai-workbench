import AppKit
import Foundation
import Observation
import XiaoaiCore

@MainActor @Observable
final class AppModel {
    var busy = false
    var writingDevice = false
    var status = "连接音箱，或先制作最小固件"
    var progress: Double?
    var error: String?
    var device: DeviceInfo?
    var backup: BackupArtifact?
    var firmware: FirmwareArtifact?
    var verified = false
    var rebootVerified = false
    var verifiedBootPart = ""
    var host = ""
    var otaBluetooth = false
    var bluetoothAddress = ""
    var otaBackupURL: URL?
    var otaPackageURL: URL?
    var otaState: OTAStatus?
    let otaService: OTAService
    var logs: [String] = []
    var selected = Section.device
    let paths: LocalPaths
    let service: Workbench
    private let logURL: URL

    enum Section: String, CaseIterable, Identifiable {
        case device = "设备与备份", firmware = "最小固件", verify = "SSH 验证", ota = "无线升级", logs = "执行记录"
        var id: Self { self }
        var icon: String {
            switch self {
            case .device: "hifispeaker"
            case .firmware: "shippingbox"
            case .verify: "terminal"
            case .logs: "text.alignleft"
            case .ota: "wifi"
            }
        }
    }

    init(paths: LocalPaths = AppModel.defaultPaths()) {
        self.paths = paths
        service = Workbench(paths: paths)
        otaService = OTAService(paths: paths)
        logURL = paths.root.appendingPathComponent("session-\(UUID().uuidString).log")
        do { try paths.prepare() } catch { self.error = error.localizedDescription }
        append("小爱工作台 0.2.0 · LX06 / 1.94.13 · 本机运行")
    }
    static func defaultPaths() -> LocalPaths {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XiaoaiWorkbench")
        let tools = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.resourceURL!.appendingPathComponent("Tools") : URL(fileURLWithPath: "/opt/homebrew/bin")
        return LocalPaths(root: root, tools: tools)
    }
    var reporter: Reporter {
        { [weak self] message, fraction in
            Task { @MainActor [weak self] in
                guard let self, self.busy else { return }
                if self.status != message { self.append(message) }
                self.status = message
                self.progress = fraction
            }
        }
    }
    func append(_ message: String) {
        let entry = "[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)"
        logs.append(entry)
        do {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((entry + "\n").utf8))
        } catch { self.error = "执行记录保存失败：\(error.localizedDescription)" }
    }
    func perform(_ title: String, writingDevice: Bool = false, network: Bool = false, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; progress = nil; status = title; append(title)
        self.writingDevice = writingDevice
        Task {
            defer { busy = false; self.writingDevice = false; progress = nil }
            do {
                if network {
                    guard FileManager.default.fileExists(atPath: paths.key.path) else { throw WorkbenchError("本机尚无专用 SSH 密钥，请先制作固件。") }
                    try await LocalNetworkConnection().check(host: host)
                }
                try await operation()
            }
            catch {
                self.error = error.localizedDescription
                status = "操作已停止"
                append("失败：\(error.localizedDescription)")
            }
        }
    }
    func detect() {
        device = nil
        perform("正在识别 USB 设备和启动环境") {
            self.device = try await self.service.detect(report: self.reporter)
            self.status = "已连接 LX06，启动项 \(self.device!.environment.bootPart)"
            self.append(self.status)
        }
    }
    func createBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "保存备份到此文件夹"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let destination = directory.appendingPathComponent("LX06-Backup-\(UUID().uuidString.prefix(8))")
        perform("准备备份 system0 与启动环境") {
            self.backup = try await self.service.backup(to: destination, report: self.reporter)
            self.status = self.backup?.isStock == true ? "原始系统备份及落盘校验完成" : "备份完成，system0 与原版基线不同"
            self.append(self.status)
        }
    }
    func openBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "选择备份文件夹"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        perform("正在核对备份文件") {
            self.backup = try await self.service.openBackup(directory)
            self.status = "备份文件及环境记录已核对"
            self.append(self.status)
        }
    }
    func build() {
        perform("准备原版固件") {
            try await self.service.prepareOriginal(report: self.reporter)
            self.firmware = try await self.service.buildFirmware(report: self.reporter)
            self.status = "最小固件已生成，全部文件核对通过"
            self.append("固件 SHA-256：\(self.firmware!.hash)")
        }
    }
    func importOriginal() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "导入原版镜像"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        perform("正在核对原版镜像") {
            try await self.service.importOriginal(from: file)
            self.status = "原版 LX06 1.94.13 已导入，SHA-256 匹配"
            self.append(self.status)
        }
    }
    func flash() {
        guard let firmware, let backup else { return }
        verified = false; rebootVerified = false
        perform("准备刷入最小固件", writingDevice: true) {
            try await self.service.flash(firmware, backup: backup, report: self.reporter)
            self.device = nil
            self.status = "USB 写入与启动项核对完成。请拔掉 USB 和电源，再重新上电，继续 SSH 验证。"
            self.append(self.status)
            self.selected = .verify
        }
    }
    func restore() {
        guard let backup else { return }
        verified = false; rebootVerified = false
        perform("准备从备份恢复 system0 和原启动项", writingDevice: true) {
            try await self.service.restore(backup, report: self.reporter)
            self.device = nil
            self.status = "system0 与原启动项已恢复并核对。请拔掉 USB 和电源，再重新上电。"
            self.append(self.status)
        }
    }
    func verify(reboot: Bool = false) {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        verified = false; rebootVerified = false
        perform(reboot ? "正在重启音箱并复验" : "正在通过 SSH 验证 root", network: true) {
            let result = try await (reboot
                ? self.service.rebootAndVerify(host: address, report: self.reporter)
                : self.service.verifySSH(host: address))
            self.verified = true
            self.verifiedBootPart = result.bootPart
            self.rebootVerified = reboot
            self.status = reboot ? "重启后 root SSH 验证通过" : "root SSH、LX06、1.94.13 和 \(result.bootPart) 均已核对"
            self.append(self.status)
            self.append(result.output)
        }
    }
    var otaConnectionValid: Bool {
        Workbench.validIP(host) && (!otaBluetooth || BluetoothSSH.validAddress(bluetoothAddress))
    }
    func otaEndpoint() throws -> OTAEndpoint {
        let proxy = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("XiaoaiBluetoothProxy")
        return try OTAEndpoint(host: host, bluetooth: otaBluetooth ? BluetoothSSH(executable: proxy, address: bluetoothAddress) : nil)
    }
    func otaCheck() {
        otaState = nil
        perform("正在查询无线升级状态", network: !otaBluetooth) {
            self.otaState = try await self.otaService.status(self.otaEndpoint())
            self.status = "\(self.otaState!.bootPart) · \(self.otaState!.phase)"
            self.append(self.status)
        }
    }
    func chooseOTADirectory(package: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = package ? "选择 OTA 包" : "选择 OTA 备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if package { otaPackageURL = url } else { otaBackupURL = url }
    }
    func otaBackup() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "选择备份保存位置"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("LX06-OTA-Backup-" + UUID().uuidString.prefix(8))
        perform("准备无线备份两个启动槽位", network: !otaBluetooth) {
            _ = try await self.otaService.backup(self.otaEndpoint(), to: destination, report: self.reporter)
            self.otaBackupURL = destination
            self.status = "无线备份及两次读取校验完成"
            self.append(self.status)
        }
    }
    func otaBuildPackage() {
        guard let firmware, let backup = otaBackupURL else { return }
        let destination = paths.root.appendingPathComponent("OTAPackages").appendingPathComponent(UUID().uuidString)
        perform("正在制作无线升级包") {
            let manifest = firmware.file.deletingLastPathComponent().appendingPathComponent("firmware.json")
            // The package builder verifies the exact supported kernel hash regardless of slot.
            let kernel = backup.appendingPathComponent("boot0.bin")
            _ = try await self.otaService.makePackage(firmware: manifest, kernel: kernel, output: destination)
            self.otaPackageURL = destination
            self.status = "OTA 包已生成，内核与系统镜像核对通过"
            self.append(self.status)
        }
    }
    func otaInstall() {
        guard let package = otaPackageURL, let backup = otaBackupURL else { return }
        otaState = nil; verified = false; rebootVerified = false
        perform("准备写入备用槽位并验证试启动", writingDevice: true, network: !otaBluetooth) {
            self.otaState = try await self.otaService.install(self.otaEndpoint(), package: package, backup: backup, report: self.reporter)
            self.status = "升级已确认 · \(self.otaState!.bootPart)"
            self.append(self.status)
        }
    }
    func otaRollback() {
        verified = false; rebootVerified = false
        perform("准备回退原槽位", writingDevice: true, network: !otaBluetooth) {
            self.otaState = try await self.otaService.rollback(self.otaEndpoint(), report: self.reporter)
            self.status = "回退已验证 · \(self.otaState!.bootPart)"
            self.append(self.status)
        }
    }
    func otaConfirm() {
        guard let job = otaState?.job else { return }
        perform("正在核对试启动镜像与服务", writingDevice: true, network: !otaBluetooth) {
            self.otaState = try await self.otaService.confirm(self.otaEndpoint(), job: job)
            self.status = "升级已确认 · \(self.otaState!.bootPart)"
            self.append(self.status)
        }
    }
    func copySSH() {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let command = await service.sshCommand(host: host)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
    func show(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Xiaoai-Workbench.log"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do { try logs.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}
