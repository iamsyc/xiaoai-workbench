import Foundation
import XiaoaiCore

@MainActor enum USBDiagnosticCommand {
    static let usage = "用法：XiaoaiWorkbench --usb-diagnose <新的输出目录>\n等待 USB 最多 120 秒，识别后立即读取环境并备份 system0，不刷写分区或保存启动项。\n"
    static let observeUsage = "用法：XiaoaiWorkbench --usb-observe <新的输出目录>\n被动记录 USB 设备发布、驱动匹配、端口计数和内核日志 120 秒，不打开设备或发送 USB 请求。\n"
    nonisolated static func printLine(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    @discardableResult
    static func run(directory: URL, passive: Bool = false,
                    output: @escaping @Sendable (String) -> Void = printLine) async throws -> BackupArtifact? {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkbenchError("诊断输出目录已存在，请使用新目录。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let journal = USBJournal()
        let log = directory.appendingPathComponent("usb-diagnostics.jsonl")
        let kernel = USBKernelLog(directory: directory, journal: journal)
        let monitor: USBSystemMonitor
        do {
            monitor = try USBSystemMonitor { journal.record($0) }
        } catch {
            await kernel.stop()
            journal.record("usb.system.start_failed")
            try journal.write(to: log)
            throw error
        }
        if passive {
            journal.record("session.begin mode=passive timeout_seconds=120 device_requests=0")
            journal.record("boot.environment.unavailable reason=passive_mode_no_device_requests")
            output("USB 底层被动监听已就绪，持续 120 秒，仅记录系统事件，不发送设备请求。")
            do {
                try await Task.sleep(for: .seconds(120))
                journal.record("session.complete mode=passive")
            } catch {
                journal.record("session.cancelled mode=passive")
            }
            monitor.stop()
            await kernel.stop()
            try journal.write(to: log)
            output("被动诊断已结束：\(directory.path)")
            try Task.checkCancellation()
            return nil
        }
        let workbench = Workbench(paths: AppModel.defaultPaths(), diagnostics: {
            journal.record($0)
            if $0.hasPrefix("usb.device.") || $0.hasPrefix("usb.context.") {
                output($0)
            }
        })
        let result: Result<BackupArtifact, any Error>
        let observationDeadline = ContinuousClock.now.advanced(by: .seconds(120))
        journal.record("session.begin mode=read_only timeout_seconds=120")
        output("正在初始化 USB 持续监听，等待上限 120 秒。")
        do {
            result = .success(try await workbench.detectAndBackup(to: directory.appendingPathComponent("Backup")) { message, fraction in
                if let fraction { output("\(message) \(Int(fraction * 100))%") }
                else { output(message) }
            })
            journal.record("session.complete")
        } catch {
            journal.record("session.failed error_type=\(String(reflecting: type(of: error)))")
            result = .failure(error)
            output("传输失败：\(error.localizedDescription)")
            try? await workbench.observeUSBAfterFailure(until: observationDeadline) { message, _ in output(message) }
        }
        await workbench.disconnect()
        monitor.stop()
        await kernel.stop()
        try journal.write(to: log)
        output("诊断日志：\(log.path)")
        let backup = try result.get()
        output("备份：\(backup.directory.path)")
        output("原版基线匹配：\(backup.isStock)\nSHA-256：\(backup.manifest.systemHash)")
        return backup
    }
}
