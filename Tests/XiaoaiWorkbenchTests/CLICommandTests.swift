import Foundation
import Testing
import XiaoaiCore
@testable import XiaoaiWorkbench

struct CLICommandTests {
    @Test(arguments: [
        ["flash", "--firmware", "/missing.json", "--backup", "/missing"],
        ["restore", "--backup", "/missing"],
        ["reboot-verify", "--host", "192.168.1.2"],
        ["ota-install", "--host", "192.168.1.2", "--package", "/tmp/pkg", "--backup", "/tmp/backup"],
        ["ota-confirm", "--host", "192.168.1.2", "--job", "bad", "--confirm-write"],
        ["ota-rollback", "--host", "192.168.1.2"],
        ["ota-status", "--host", "192.168.1.2", "--address", "bad"],
        ["backup"], ["typo"], [],
        ["detect", "--timeout", "0"], ["detect", "--timeout", "601"],
        ["detect", "--timeout", "nan"], ["detect", "--timeout", "1", "--timeout", "2"],
        ["verify-ssh", "--host", "1.2.3.4 -oProxyCommand=evil"],
        ["verify-bluetooth", "--host", "192.168.1.2", "--address", "EC:41:18:6E:AF:06;id"],
        ["verify-bluetooth", "--host", "192.168.1.2"],
        ["paths", "--confirm-write"], ["build", "--original"],
        ["observe", "--output", "/tmp/test", "--timeout", "1"],
        ["restore", "--backup", "/missing", "--confirm-write", "false"]
    ])
    @MainActor func invalidArgumentsNeverReachExecution(arguments: [String]) async throws {
        var executed = false
        let (code, response) = await CLICommand.run(arguments) { _ in
            executed = true
            return CLIData()
        }
        #expect(!executed)
        #expect(code == 64)
        #expect(!response.ok)
        #expect(response.error?.code == "invalid_arguments")
        let encoded = try CLICommand.encoded(response)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["ok"] as? Bool == false)
    }

    @Test(arguments: [
        ["ota-status", "--host", "192.168.1.2"],
        ["ota-backup", "--host", "192.168.1.2", "--output", "/tmp/new"],
        ["ota-package", "--firmware", "/tmp/fw.json", "--kernel", "/tmp/boot.bin", "--output", "/tmp/pkg"],
        ["ota-install", "--host", "192.168.1.2", "--package", "/tmp/pkg", "--backup", "/tmp/backup", "--confirm-write", "--defer-confirm"],
        ["ota-confirm", "--host", "192.168.1.2", "--job", "532ec08f-7cb5-438c-a762-0c3e6a094d01", "--confirm-write", "--address", "EC:41:18:6E:AF:06"],
        ["ota-rollback", "--host", "192.168.1.2", "--confirm-write"],
        ["paths"], ["detect", "--timeout", "25"], ["backup", "--output", "/tmp/new backup"],
        ["check-backup", "--backup", "/tmp/saved"], ["prepare-original"],
        ["import-original", "--file", "/tmp/image"],
        ["build", "--original", "/tmp/image", "--data-dir", "/tmp/data", "--tools-dir", "/tmp/tools"],
        ["flash", "--firmware", "/tmp/firmware.json", "--backup", "/tmp/saved", "--confirm-write"],
        ["restore", "--backup", "/tmp/saved", "--confirm-write"],
        ["verify-ssh", "--host", "192.168.1.2"],
        ["verify-bluetooth", "--host", "192.168.1.2", "--address", "EC:41:18:6E:AF:06"],
        ["reboot-verify", "--host", "192.168.1.2", "--confirm-reboot"],
        ["ssh-command", "--host", "192.168.1.2"],
        ["observe", "--output", "/tmp/log"], ["diagnose", "--output", "/tmp/log"]
    ])
    @MainActor func validCommandsDispatchOnce(arguments: [String]) async {
        var calls = 0
        let (code, response) = await CLICommand.run(arguments) { request in
            calls += 1
            #expect(request.command.rawValue == arguments[0])
            return CLIData(file: "/tmp/result with spaces", requiresPowerCycle: false)
        }
        #expect(calls == 1)
        #expect(code == 0)
        #expect(response.ok)
        #expect(response.data?.file == "/tmp/result with spaces")
        #expect(response.data?.requiresPowerCycle == false)
        #expect(response.error == nil)
    }

    @Test @MainActor func operationalFailureHasDistinctExitCode() async {
        let (code, response) = await CLICommand.run(["detect"]) { _ in
            throw WorkbenchError("simulated failure")
        }
        #expect(code == 1)
        #expect(!response.ok)
        #expect(response.error?.code == "operation_failed")
        #expect(response.error?.message == "simulated failure")
    }

    @Test @MainActor func pathsDoesNotCreateDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (code, response) = await CLICommand.run(["paths", "--data-dir", directory.path])
        #expect(code == 0)
        #expect(response.data?.dataDirectory == directory.path)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test @MainActor func invalidLocalInputFailsBeforeUSBAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Each failure is handled before detect(), so none of these routes may open a device.
        for arguments in [
            ["backup", "--output", directory.path],
            ["flash", "--firmware", "/missing.json", "--backup", directory.path, "--confirm-write"],
            ["restore", "--backup", directory.path, "--confirm-write"]
        ] {
            let (code, response) = await CLICommand.run(arguments)
            #expect(code == 1)
            #expect(response.error?.code == "operation_failed")
        }
    }
}
