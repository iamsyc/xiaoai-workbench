import Foundation
import Testing
@testable import XiaoaiCore

struct OTATests {
    @Test(arguments: ["boot0", "boot1"])
    func parsesBothSlotsAndLastPhase(boot: String) throws {
        let root = boot == "boot0" ? "/dev/mtdblock4" : "/dev/mtdblock5"
        let text = "XW_BOOT=\(boot)\nXW_ROOT=\(root)\nXW_VERSION=1.94.13\nXW_BOOT_ID=532ec08f-7cb5-438c-a762-0c3e6a094d01\nXW_PHASE=idle\nXW_PHASE=trial\n"
        let status = try OTAStatus.parse(text)
        #expect(status.bootPart == boot)
        #expect(status.phase == "trial")
        #expect(throws: (any Error).self) { try OTAStatus.parse(text.replacingOccurrences(of: root, with: "/dev/mtdblock6")) }
        #expect(throws: (any Error).self) { try OTAStatus.parse(text.replacingOccurrences(of: "1.94.13", with: "1.88.221")) }
        #expect(throws: (any Error).self) { try OTAStatus.parse(text.replacingOccurrences(of: "trial", with: "unknown")) }
        let ssh = "XW_UID=0\nXW_MODEL=LX06\nXW_ROM=1.94.13\nXW_BOOT=\(boot)\nXW_BOOT_ID=532ec08f-7cb5-438c-a762-0c3e6a094d01\n"
        #expect(try Workbench.parseSSH(ssh).bootPart == boot)
    }
    @Test func rejectsUnapprovedKernelEvenWithMatchingPackageHashes() throws {
        var kernel = Data("ANDROID!".utf8); kernel.append(Data(count: 6291456 - 8))
        let root = Data(count: 4096)
        let package = OTAPackage(format: 1, model: "LX06", version: "1.94.13", kernelHash: sha256(kernel), rootHash: sha256(root), rootBytes: root.count, publicKeyHash: "test")
        #expect(throws: (any Error).self) { try OTAPackage.validate(package, kernel: kernel, root: root) }
    }
    @Test func deviceAgentIsValidShell() throws {
        _ = try LocalProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-n"], input: Data(OTADeviceAgent.source.utf8))
    }
}
