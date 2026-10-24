import Testing
import Foundation
@testable import XiaoaiCore

final class MockUSB: USBTransport, @unchecked Sendable {
    var reads: [Data] = []
    var commands: [String] = []
    var writes: [Data] = []
    var controls: [(UInt8, Data)] = []
    var tplStatus = "success"
    var uploadRemaining = 0
    var failIdentify = false
    func control(_ type: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ data: Data) throws -> Data {
        controls.append((request, data))
        if request == 0x20, failIdentify { throw WorkbenchError("Simulated identify failure") }
        if request == 0x34 || request == 0x30 { commands.append(AMLProtocol.status(data)) }
        if request == 0x34, AMLProtocol.status(data).hasPrefix("upload "),
           let hex = AMLProtocol.status(data).split(separator: " ").last {
            uploadRemaining = Int(hex.dropFirst(2), radix: 16) ?? 0
        }
        if request == 0x33 {
            let length = min(65536, uploadRemaining); uploadRemaining -= length
            var header = Data(); header.appendLE(UInt32(0xefe8)); header.appendLE(UInt32(length))
            header.append(Data(count: 8)); return header
        }
        if request == 0x31 {
            var response = Data(tplStatus.utf8)
            response.append(Data(count: 64 - response.count))
            return response
        }
        if request == 0x20 { return Data([0, 7, 0, 16, 0, 0, 0, 0]) }
        return data
    }
    func read(_ count: Int, timeout: UInt32) throws -> Data {
        guard !reads.isEmpty else { throw WorkbenchError("Mock response exhausted") }
        return reads.removeFirst()
    }
    func write(_ data: Data) throws { writes.append(data) }
}

struct CoreTests {
    @Test(arguments: [nil, "0", "1", "7"] as [String?])
    func flashPreservesBootDelayWhileSelectingBoot0(delay: String?) throws {
        let delayLine = delay.map { "bootdelay=\($0)\n" } ?? ""
        let original = try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot1\n" + delayLine)
        let target = try Workbench.flashEnvironment(from: original)
        #expect(target.bootPart == "boot0")
        #expect(target.bootDelay == delay)
        #expect(target.boardID == original.boardID)

        var memory = Data(("board_id=1\nboot_part=boot0\n" + delayLine + "\0").utf8)
        memory.append(Data(count: 0x10000 - memory.count))
        let usb = MockUSB()
        usb.reads = [Data("OK!!".utf8), Data("success".utf8), Data("success".utf8), Data([1, 2, 3]),
                     Data("success".utf8), Data("success".utf8), Data("success".utf8),
                     Data("success".utf8), Data("success".utf8), memory]
        try FlashTransaction(aml: AMLProtocol(usb: usb), report: { _, _ in })
            .writeAndVerify(Data([1, 2, 3]), environment: target)
        #expect(usb.commands.filter { $0.hasPrefix("setenv bootdelay") } ==
                [delay.map { "setenv bootdelay \($0)" } ?? "setenv bootdelay"])
    }
    @Test func testUnknownBoardAndBootAreRejected() throws {
        #expect(throws: (any Error).self) { try EnvironmentSnapshot(text: "board_id=12\nboot_part=boot0\n") }
        #expect(throws: (any Error).self) { try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot2\n") }
        #expect(throws: (any Error).self) { try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot0\nbootdelay=1;reset\n") }
        let valid = try EnvironmentSnapshot(text: "board_id=10\nboot_part=boot1\nbootdelay=3\n")
        #expect((valid.bootPart) == ("boot1"))
    }
    @Test func testChecksumIncludesTailAndWraparound() {
        #expect((AMLProtocol.checksum(Data([0xff, 0xff, 0xff, 0xff, 1]))) == (0))
        #expect((AMLProtocol.checksum(Data([1, 2, 3]))) == (0x030201))
        let header = AMLProtocol.writeHeader(Data([1, 2, 3]), sequence: 7)
        #expect((header.count) == (32))
        #expect((header.u32(4)) == (3))
        #expect((header.u32(8)) == (7))
        #expect((header.u32(12)) == (0x030201))
        #expect((Array(header[16..<20])) == ([0xef, 0, 0, 2]))
    }
    @Test func testCommandBoundaries() {
        #expect(throws: Never.self) { try AMLProtocol.commandData(String(repeating: "a", count: 126)) }
        #expect(throws: (any Error).self) { try AMLProtocol.commandData(String(repeating: "a", count: 127)) }
        #expect(throws: (any Error).self) { try AMLProtocol.commandData("a\0b") }
    }
    @Test func testWriteFailureDoesNotAdvanceSequenceOrSendFinalStatus() {
        let usb = MockUSB(); usb.reads = [Data("FAIL:32".utf8)]
        #expect(throws: (any Error).self) { try AMLProtocol(usb: usb).writeSystem(Data([1, 2, 3])) }
        #expect((usb.writes.count) == (1))
        #expect(!(usb.commands.contains("download get_status")))
    }
    @Test func testTPLFailureDoesNotWrite() {
        let usb = MockUSB(); usb.tplStatus = "failed"
        #expect(throws: (any Error).self) { try AMLProtocol(usb: usb).writeSystem(Data([1])) }
        #expect(usb.writes.isEmpty)
    }
    @Test func testShortReadIsRejected() {
        let usb = MockUSB(); usb.reads = [Data("success".utf8), Data([1, 2])]
        #expect(throws: (any Error).self) { try AMLProtocol(usb: usb).upload("store system0", count: 3) }
    }
    @Test func testReadbackMismatchNeverChangesBootEnvironment() throws {
        let usb = MockUSB()
        usb.reads = [Data("OK!!".utf8), Data("success".utf8), Data("success".utf8), Data([4, 5, 6])]
        let env = try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot0\nbootdelay=15\n")
        #expect(throws: (any Error).self) { try FlashTransaction(aml: AMLProtocol(usb: usb), report: { _, _ in })
            .writeAndVerify(Data([1, 2, 3]), environment: env) }
        #expect(!(usb.commands.contains(where: { $0.hasPrefix("setenv") || $0 == "saveenv" })))
    }
    @Test func testSuccessfulWritePersistsEnvironmentAfterReadback() throws {
        let usb = MockUSB()
        var memory = Data("board_id=1\nboot_part=boot0\nbootdelay=15\n\0".utf8)
        memory.append(Data(count: 0x10000 - memory.count))
        usb.reads = [Data("OK!!".utf8), Data("success".utf8), Data("success".utf8), Data([1, 2, 3]),
                     Data("success".utf8), Data("success".utf8), Data("success".utf8),
                     Data("success".utf8), Data("success".utf8), memory]
        let env = try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot0\nbootdelay=15\n")
        try FlashTransaction(aml: AMLProtocol(usb: usb), report: { _, _ in })
            .writeAndVerify(Data([1, 2, 3]), environment: env)
        #expect((Array(usb.commands.prefix(6))) == (["download store system0 normal 0x3", "download get_status",
            "upload store system0 normal 0x3", "setenv boot_part boot0", "setenv bootdelay 15", "saveenv"]))
    }
    @Test func testPseudoReconstructionPreservesUntouchedDataAndLinks() throws {
        var bytes = Data("/ D 1 755 0 0\na R 1 640 0 0 3 0 0\nb R 1 755 0 0 2 3 0\nlink S 1 777 0 0 /b".utf8)
        bytes.append(PseudoImage.marker); bytes.append(Data([1, 2, 3, 4, 5]))
        let original = try PseudoImage(data: bytes)
        let changes = ["a": Data([6, 7, 8, 9])]
        let built = try PseudoImage(data: original.replacing(changes))
        #expect((try built.file("b")) == (Data([4, 5])))
        #expect((try built.file("a")) == (Data([6, 7, 8, 9])))
        #expect(built.lines.contains("link S 1 777 0 0 /b"))
        try FirmwareBuilder.verify(original: original, built: built, changes: changes)
    }
    @Test func testPatchMatchingCannotTouchDownloadUpgradeByMistake() throws {
        let text = "download_upgrade() {\n}\nupgrade() {\n}\n"
        let patched = try RootPatch.replaceOnce(text, "upgrade() {", "upgrade() {\nreturn 1")
        #expect(patched.hasPrefix("download_upgrade() {\n}"))
        #expect(throws: (any Error).self) { try RootPatch.replaceOnce("upgrade() {\nupgrade() {", "upgrade() {", "x") }
    }
    @Test func testMalformedOrOversizedSquashFSRejected() {
        #expect(throws: (any Error).self) { try SquashFS.logicalImage(Data(count: 100)) }
        var bytes = Data("hsqs".utf8); bytes.append(Data(count: 92))
        bytes[12] = 0; bytes[13] = 0; bytes[14] = 2; bytes[20] = 4; bytes[28] = 4
        #expect(throws: (any Error).self) { try SquashFS.logicalImage(bytes) }
    }
    @Test func testSSHVerificationRequiresAllMarkers() throws {
        let text = "XW_UID=0\nXW_MODEL=LX06\nXW_ROM=1.94.13\nXW_BOOT=boot0\nXW_BOOT_ID=532ec08f-7cb5-438c-a762-0c3e6a094d01\n"
        #expect(throws: Never.self) { try Workbench.parseSSH(text) }
        #expect(throws: (any Error).self) { try Workbench.parseSSH(text.replacingOccurrences(of: "XW_UID=0", with: "XW_UID=1000")) }
        #expect(throws: (any Error).self) { try Workbench.parseSSH(text.replacingOccurrences(of: "1.94.13", with: "1.88.197")) }
        #expect(!(Workbench.validIP("1.2.3.4 -oProxyCommand=evil")))
        #expect(!(Workbench.validIP("256.2.3.4")))
        #expect(Workbench.validIP("192.168.31.227"))
    }
    @Test func testProcessPreservesLiteralArgumentsAndNonzeroStatus() throws {
        let literal = "a b; $(touch SHOULD_NOT_EXIST)"
        let result = try LocalProcess.run(URL(fileURLWithPath: "/bin/echo"), [literal])
        #expect((result.output) == (literal + "\n"))
        #expect(throws: (any Error).self) { try LocalProcess.run(URL(fileURLWithPath: "/usr/bin/false"), []) }
    }
    @Test func testCorruptBackupRejectedBeforeUse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot1\n")
        let manifest = BackupManifest(format: 1, createdAt: Date(), systemHash: "wrong", logicalHash: "wrong", environment: environment)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("backup.json"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("system0.bin"))
        #expect(throws: (any Error).self) { try Workbench.loadBackup(dir) }
    }

    @Test(arguments: ["replace", "overwrite", "remove"])
    func testValidatedBackupRetainsBytesAfterFileChanges(change: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        var image = Data(count: LX06.systemSize)
        image.replaceSubrange(0..<4, with: Data("hsqs".utf8))
        image[14] = 2; image[20] = 4; image[28] = 4; image[40] = 96
        let environment = try EnvironmentSnapshot(text: "board_id=1\nboot_part=boot1\n")
        let manifest = BackupManifest(format: 1, createdAt: Date(), systemHash: sha256(image),
            logicalHash: sha256(try SquashFS.logicalImage(image)), environment: environment)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("backup.json"))
        let file = dir.appendingPathComponent("system0.bin")
        try image.write(to: file)

        let snapshot = try Workbench.readBackup(dir)
        switch change {
        case "replace": try Data(repeating: 0xff, count: LX06.systemSize).write(to: file, options: .atomic)
        case "overwrite":
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data([0xff]))
            try handle.synchronize()
        default: try FileManager.default.removeItem(at: file)
        }

        #expect(snapshot.image.count == LX06.systemSize)
        #expect(sha256(snapshot.image) == manifest.systemHash)
        #expect(snapshot.artifact.manifest.environment == environment)
        #expect(throws: (any Error).self) { try Workbench.loadBackup(dir) }
    }
}
