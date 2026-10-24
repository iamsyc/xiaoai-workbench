import Foundation
import Testing
@testable import XiaoaiCore

private final class UploadWireUSB: USBTransport {
    let total: Int
    var offset = 0
    var statusPending = true
    var headerOverride: Data?
    var requests: [(UInt16, UInt16)] = []
    var dataReads = 0
    init(total: Int) { self.total = total }
    func control(_ type: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ data: Data) throws -> Data {
        if request == 0x34 { return data }
        guard type == 0xc0, request == 0x33, data.count == 16 else { throw WorkbenchError("unexpected request") }
        requests.append((value, index))
        var header = Data()
        header.appendLE(UInt32(0xefe8)); header.appendLE(UInt32(min(0x10000, total - offset)))
        header.append(Data(count: 8)) // Reserved fields are not sequence/checksum guarantees.
        return headerOverride ?? header
    }
    func read(_ count: Int, timeout: UInt32) throws -> Data {
        if statusPending { statusPending = false; return Data("success".utf8) }
        dataReads += 1
        let data = Data(repeating: UInt8(truncatingIfNeeded: offset / 0x10000), count: count)
        offset += count
        return data
    }
    func write(_ data: Data) throws { throw WorkbenchError("unexpected write") }
}

struct UploadProtocolTests {
    @Test(arguments: [0x10000, 0x10000 + 123, LX06.systemSize])
    func readMediaUses4096BytePacketsIncludingFinalTail(count: Int) throws {
        let usb = UploadWireUSB(total: count)
        let result = try AMLProtocol(usb: usb).upload("store system0", count: count)
        #expect(result.count == count)
        #expect(usb.requests.count == (count + 65535) / 65536)
        for (block, request) in usb.requests.enumerated() {
            let length = min(65536, count - block * 65536)
            #expect(request.0 == 4096)
            #expect(Int(request.1) == (length + 4095) / 4096)
            #expect(result[block * 65536] == UInt8(truncatingIfNeeded: block))
        }
    }

    @Test(arguments: [0, 1, 65537])
    func invalidAnnouncedLengthStopsBeforeBulk(length: Int) {
        let usb = UploadWireUSB(total: 65536)
        var header = Data(); header.appendLE(UInt32(0xefe8)); header.appendLE(UInt32(length)); header.append(Data(count: 8))
        usb.headerOverride = header
        #expect(throws: (any Error).self) { try AMLProtocol(usb: usb).upload("store system0", count: 65536) }
        #expect(usb.dataReads == 0)
    }

    @Test func shortHeaderStopsBeforeBulk() {
        let usb = UploadWireUSB(total: 65536); usb.headerOverride = Data(count: 7)
        #expect(throws: (any Error).self) { try AMLProtocol(usb: usb).upload("store system0", count: 65536) }
        #expect(usb.dataReads == 0)
    }
}
