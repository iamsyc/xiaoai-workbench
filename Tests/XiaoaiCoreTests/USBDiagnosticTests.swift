import Foundation
import Testing
@testable import XiaoaiCore

struct USBDiagnosticTests {
    @Test func observationHonorsExpiredDeadlineAndCancellation() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = Workbench(paths: LocalPaths(root: dir, tools: dir)) { _ in
            Issue.record("Observation must not open USB")
            throw WorkbenchError("Unexpected device access")
        }
        try await service.observeUSBAfterFailure(until: ContinuousClock.now - .seconds(1)) { _, _ in
            Issue.record("Expired observation must not start waiting")
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.observeUSBAfterFailure(until: ContinuousClock.now + .seconds(30)) { _, _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test(arguments: [false, true])
    func earlyFailureKeepsObservationWindowWithoutFurtherDeviceRequests(identifyFails: Bool) async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usb = MockUSB()
        usb.failIdentify = identifyFails
        usb.reads = [Data("failed".utf8)]
        let service = Workbench(paths: LocalPaths(root: dir, tools: dir)) { _ in usb }
        await #expect(throws: (any Error).self) {
            try await service.detectAndBackup(to: dir.appendingPathComponent("Backup")) { _, _ in }
        }
        let requests = usb.controls.count
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(40))
        try await service.observeUSBAfterFailure(until: deadline) { _, _ in }
        #expect(ContinuousClock.now >= deadline)
        #expect(usb.controls.count == requests)
        #expect(usb.writes.isEmpty)
    }
    @Test func registryDiagnosticsPreserveUnknownsAndOmitPrivateProperties() throws {
        let properties: [String: Any] = ["locationID": 0x00130000, "idVendor": 0x1b8e,
            "USB Serial Number": "PRIVATE_SERIAL", "UsbDeviceSignature": Data("PRIVATE_SIGNATURE".utf8),
            "port-statistics": ["kPortStatConnectCount": 1, "kPortStatEnumerationFailureCount": 0,
                "kPortStatPowerStateTime": ["kPowerStateOn": "100ms"]],
            "IOPowerManagement": ["CurrentPowerState": 1]]
        let snapshot = USBRegistrySnapshot(registryID: 123, parentID: 100, kind: "port", properties: properties)
        #expect(snapshot.location == "00130000")
        #expect(snapshot.counters["kPortStatConnectCount"] == 1)
        #expect(snapshot.counters["kPortStatEnumerationFailureCount"] == 0)
        #expect(snapshot.counters["kPortStatAddressFailureCount"] == nil)
        #expect(snapshot.numbers["port-status"] == nil)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(json.contains("kPortStatConnectCount"))
        #expect(!json.contains("PRIVATE_"))
        #expect(!json.contains("kPortStatPowerStateTime"))
        var changed = properties
        changed["port-statistics"] = ["kPortStatConnectCount": 2]
        #expect(snapshot != USBRegistrySnapshot(registryID: 123, parentID: 100, kind: "port", properties: changed))
    }
    @Test func bootDiagnosticsUseCurrentEnvironmentAndKeepMissingModeUnknown() throws {
        let snapshot = try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot0\nreboot_mode=cold_boot\nidentifyWaitTime=1000\nwifi_password=PRIVATE_PASSWORD\npreboot=PRIVATE_SCRIPT\n")
        let event = snapshot.bootDiagnosticEvent
        #expect(event.contains("source=current_usb_session reset_register=not_read"))
        #expect(event.contains("\"reboot_mode\":\"cold_boot\""))
        #expect(event.contains("\"identifyWaitTime\":\"1000\""))
        #expect(!event.contains("PRIVATE_"))
        let missing = try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot0\n")
        #expect(!missing.bootDiagnosticEvent.contains("reboot_mode"))
    }
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }
    private func entries(_ journal: USBJournal, in directory: URL) throws -> [[String: Any]] {
        let file = directory.appendingPathComponent("trace.jsonl")
        try journal.write(to: file)
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    @Test func identifiedSessionImmediatelyBacksUpWithoutReopeningOrReidentifying() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var image = Data(count: LX06.systemSize)
        image.replaceSubrange(0..<4, with: Data("hsqs".utf8))
        image[14] = 2; image[20] = 4; image[28] = 4; image[40] = 96
        var environment = Data("board_id=1\nboot_part=boot1\nprivate_value=DO_NOT_LOG_THIS\n\0".utf8)
        environment.append(Data(count: 0x10000 - environment.count))
        let usb = MockUSB()
        usb.reads = [Data("success".utf8), Data("success".utf8), environment, Data("success".utf8)]
        usb.reads += stride(from: 0, to: image.count, by: 0x10000).map { Data(image[$0..<$0 + 0x10000]) }
        let journal = USBJournal()
        let service = Workbench(paths: LocalPaths(root: dir, tools: dir), diagnostics: { journal.record($0) }) { _ in
            journal.record("test.factory.open")
            return usb
        }
        let backup = try await service.detectAndBackup(to: dir.appendingPathComponent("Backup")) { message, _ in
            journal.record("progress: \(message)")
        }
        await service.disconnect()
        #expect(backup.manifest.systemHash == sha256(image))
        #expect(usb.controls.filter { $0.0 == 0x20 }.count == 1)
        #expect(usb.commands == ["env export -t 0x01080000", "upload mem 0x01080000 normal 0x10000", "upload store system0 normal 0x2800000"])
        #expect(usb.writes.isEmpty)
        let rows = try entries(journal, in: dir)
        let events = rows.map { $0["event"] as! String }
        #expect(!events.contains { $0.hasPrefix("progress:") && $0.contains("断电") })
        #expect(events.contains { $0.hasPrefix("progress:") && $0.contains("握手成功") && $0.contains("保持供电") })
        #expect(events.filter { $0 == "test.factory.open" }.count == 1)
        #expect(events.contains { $0.hasPrefix("session.handoff operation=backup") })
        #expect(events.contains { $0.hasPrefix("backup.complete") })
        #expect(!events.joined().contains("DO_NOT_LOG_THIS"))
        let permissions = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("trace.jsonl").path)[.posixPermissions] as! Int
        #expect(permissions == 0o600)
        let elapsed = rows.map { $0["elapsedMS"] as! Double }
        #expect(elapsed == elapsed.sorted())
    }
    @Test func environmentFailureStopsWithoutRetryOrPartitionTransferAndRedactsResponse() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usb = MockUSB(); usb.reads = [Data("DO_NOT_LOG_THIS".utf8)]
        let journal = USBJournal()
        let service = Workbench(paths: LocalPaths(root: dir, tools: dir), diagnostics: { journal.record($0) }) { _ in
            journal.record("test.factory.open")
            return usb
        }
        await #expect(throws: (any Error).self) {
            try await service.detectAndBackup(to: dir.appendingPathComponent("Backup")) { _, _ in }
        }
        await service.disconnect()
        #expect(usb.commands == ["env export -t 0x01080000"])
        #expect(usb.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backup").path))
        let events = try entries(journal, in: dir).map { $0["event"] as! String }
        #expect(events.filter { $0 == "test.factory.open" }.count == 1)
        #expect(events.contains { $0.hasPrefix("detect.failed stage=environment") })
        #expect(events.contains("bulk_command.reply status=unexpected"))
        #expect(!events.joined().contains("DO_NOT_LOG_THIS"))
    }
    @Test func timeoutReportsWaitingOnceAndCreatesNoBackup() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = USBJournal()
        let service = Workbench(paths: LocalPaths(root: dir, tools: dir), diagnostics: { journal.record($0) }) { _ in
            journal.record("test.factory.open")
            throw USBOpenError(code: -4, message: "not connected")
        }
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await service.detectAndBackup(to: dir.appendingPathComponent("Backup"), timeout: .milliseconds(210)) { message, _ in
                journal.record("progress: \(message)")
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backup").path))
        let events = try entries(journal, in: dir).map { $0["event"] as! String }
        #expect(events.filter { $0.hasPrefix("progress: USB 持续监听已就绪") }.count == 1)
        #expect(events.filter { $0.hasPrefix("progress: 正在等待 USB 设备") }.count == 1)
        let firstAttempt = try #require(events.firstIndex(of: "test.factory.open"))
        let powerPrompt = try #require(events.firstIndex { $0.hasPrefix("progress:") && $0.contains("断电") })
        #expect(firstAttempt < powerPrompt)
        #expect(events.contains("detect.timeout"))
    }
}
