import Foundation
import USBBridge

protocol USBTransport: AnyObject {
    func control(_ type: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ data: Data) throws -> Data
    func read(_ count: Int, timeout: UInt32) throws -> Data
    func write(_ data: Data) throws
}

struct USBOpenError: LocalizedError {
    let code: Int32
    let message: String
    var errorDescription: String? { message }
}

struct USBStageError: LocalizedError {
    let version: String
    var errorDescription: String? { "设备尚未进入 U-Boot 分区操作阶段，识别码：\(version)" }
}

private final class USBEventSink {
    let report: USBDiagnosticReporter?
    init(_ report: USBDiagnosticReporter?) { self.report = report }
}

final class NativeUSBDiscovery {
    let context: OpaquePointer
    private let sink: USBEventSink
    init(diagnostics: USBDiagnosticReporter?) throws {
        let sink = USBEventSink(diagnostics)
        self.sink = sink
        var error: Int32 = 0
        var stage: UnsafePointer<CChar>?
        diagnostics?("usb.context.begin")
        let callback: xw_event_callback? = diagnostics == nil ? nil : { event, registryID, vendor, product, location, user in
            guard let event, let user else { return }
            let sink = Unmanaged<USBEventSink>.fromOpaque(user).takeUnretainedValue()
            sink.report?(String(format: "usb.device.%@ registry_id=%llu vid=%04x pid=%04x location=%08x",
                                String(cString: event), registryID, vendor, product, location))
        }
        guard let context = xw_context_create(callback, Unmanaged.passUnretained(sink).toOpaque(), &error, &stage) else {
            diagnostics?("usb.context.failed stage=\(stage.map { String(cString: $0) } ?? "unknown") code=\(error)")
            throw WorkbenchError("USB 监听初始化失败：\(String(cString: xw_error(error)))")
        }
        self.context = context
        diagnostics?("usb.context.ready lifetime=detection_and_connection")
    }
    deinit {
        withExtendedLifetime(sink) { xw_context_destroy(context) }
        sink.report?("usb.context.closed")
    }
}

final class NativeUSB: USBTransport {
    private let handle: OpaquePointer
    private let discovery: NativeUSBDiscovery
    private let diagnostics: USBDiagnosticReporter?
    init(discovery: NativeUSBDiscovery, diagnostics: USBDiagnosticReporter? = nil) throws {
        self.discovery = discovery
        self.diagnostics = diagnostics
        let start = DispatchTime.now().uptimeNanoseconds
        diagnostics?("usb.open.begin vid=1b8e pid=c003")
        var error: Int32 = 0
        var stage: UnsafePointer<CChar>?
        guard let handle = xw_open(discovery.context, &error, &stage) else {
            diagnostics?("usb.open.failed stage=\(stage.map { String(cString: $0) } ?? "unknown") code=\(error) name=\(String(cString: xw_error(error))) elapsed_ms=\(usbElapsedMS(since: start))")
            let message: String
            switch error {
            case -4: message = "未检测到 Amlogic USB 设备。请连接主板 Micro USB 数据线，先点击检测，等待出现上电提示后再给音箱断电上电。"
            case -6: message = "USB 设备被占用或连接了多台 Amlogic 设备。请关闭其他刷机工具，只保留一台音箱。"
            case -3: message = "无法访问 USB 设备，请检查 macOS 的配件连接授权。"
            default: message = "USB 连接失败：\(String(cString: xw_error(error)))"
            }
            throw USBOpenError(code: error, message: message)
        }
        self.handle = handle
        diagnostics?("usb.open.ready endpoint_in=\(xw_endpoint_in(handle)) endpoint_out=\(xw_endpoint_out(handle)) elapsed_ms=\(usbElapsedMS(since: start))")
    }
    deinit {
        withExtendedLifetime(discovery) { xw_close(handle) }
        diagnostics?("usb.close.complete")
    }
    private func transfer(_ operation: String, _ body: () -> Int32) throws -> Int32 {
        diagnostics?("\(operation).begin")
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        diagnostics?("\(operation).end result=\(result) error=\(result < 0 ? String(cString: xw_error(result)) : "none") elapsed_ms=\(usbElapsedMS(since: start))")
        guard result >= 0 else { throw usbError(result) }
        return result
    }
    func control(_ type: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ data: Data) throws -> Data {
        var buffer = data
        let result = try transfer("usb.control type=\(type) request=\(request) value=\(value) index=\(index) length=\(data.count) timeout_ms=5000") {
            buffer.withUnsafeMutableBytes {
                xw_control(handle, type, request, value, index, $0.bindMemory(to: UInt8.self).baseAddress,
                           UInt16(data.count), 5000)
            }
        }
        guard result == data.count else { throw WorkbenchError("USB 控制传输不完整：\(result)/\(data.count)") }
        return buffer
    }
    func read(_ count: Int, timeout: UInt32 = 5000) throws -> Data {
        var data = Data(count: count)
        let result = try transfer("usb.bulk_in length=\(count) timeout_ms=\(timeout)") {
            var transferred: Int32 = 0
            let status = data.withUnsafeMutableBytes {
                xw_bulk(handle, xw_endpoint_in(handle), $0.bindMemory(to: UInt8.self).baseAddress, Int32(count), timeout, &transferred)
            }
            diagnostics?("usb.bulk_in.result status=\(status) transferred=\(transferred) requested=\(count)")
            return status < 0 ? status : transferred
        }
        return Data(data.prefix(Int(result)))
    }
    func write(_ data: Data) throws {
        var buffer = data
        let result = try transfer("usb.bulk_out length=\(data.count) timeout_ms=5000") {
            var transferred: Int32 = 0
            let status = buffer.withUnsafeMutableBytes {
                xw_bulk(handle, xw_endpoint_out(handle), $0.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), 5000, &transferred)
            }
            diagnostics?("usb.bulk_out.result status=\(status) transferred=\(transferred) requested=\(data.count)")
            return status < 0 ? status : transferred
        }
        guard result == data.count else { throw WorkbenchError("USB 数据写入不完整：\(result)/\(data.count)") }
    }
    private func usbError(_ code: Int32) -> WorkbenchError {
        WorkbenchError("USB 操作失败：\(String(cString: xw_error(code)))（\(code)）。当前操作已停止。")
    }
}

struct AMLProtocol {
    let usb: any USBTransport
    var diagnostics: USBDiagnosticReporter? = nil
    func identify() throws -> [UInt8] {
        diagnostics?("identify.begin")
        let reply = try usb.control(0xc0, 0x20, 0, 0, Data(count: 8))
        diagnostics?("identify.reply bytes=\(reply.count) version=\(reply.map(String.init).joined(separator: "."))")
        guard reply.count == 8, reply[3] == 0x10 else {
            throw USBStageError(version: reply.map(String.init).joined(separator: "."))
        }
        return Array(reply)
    }
    static func commandData(_ command: String) throws -> Data {
        guard command.utf8.count < 127, !command.contains("\0") else { throw WorkbenchError("USB 命令长度无效。") }
        return Data((command + "\0").utf8)
    }
    static func status(_ data: Data) -> String { String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self) }
    func bulkCommand(_ command: String) throws {
        diagnostics?("bulk_command.begin command=\(command)")
        _ = try usb.control(0x40, 0x34, 0, 2, Self.commandData(command))
        let deadline = Date().addingTimeInterval(120)
        while true {
            let reply = Self.status(try usb.read(512, timeout: 5000))
            // Log only recognized status tokens; unexpected responses can contain device data.
            diagnostics?("bulk_command.reply status=\(reply == "success" ? "success" : reply.hasPrefix("Continue:34") ? "Continue:34" : "unexpected")")
            if reply == "success" { return }
            guard reply.hasPrefix("Continue:34"), Date() < deadline else {
                throw WorkbenchError("设备拒绝命令 \(command)：\(reply.prefix(200))")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
    func tplCommand(_ command: String) throws {
        diagnostics?("tpl_command.begin command=\(command)")
        _ = try usb.control(0x40, 0x30, 0, 1, Self.commandData(command))
        let reply = Self.status(try usb.control(0xc0, 0x31, 0, 0, Data(count: 64)))
        guard reply == "success" else { throw WorkbenchError("设备拒绝传输准备：\(reply)") }
    }
    func upload(_ source: String, count: Int, progress: (Double) -> Void = { _ in }) throws -> Data {
        guard count > 0, count <= LX06.systemSize else { throw WorkbenchError("读取长度无效。") }
        diagnostics?("upload.begin source=\(source) bytes=\(count)")
        try bulkCommand("upload \(source) normal 0x\(String(count, radix: 16))")
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let length = min(0x10000, count - result.count)
            let offset = result.count
            diagnostics?("upload.block.begin offset=\(offset) length=\(length) packet_size=4096")
            do {
                // READ_MEDIA wValue is the packet size, not the 64 KiB transfer length.
                let header = try usb.control(0xc0, 0x33, 4096,
                                             UInt16((length + 4095) / 4096), Data(count: 16))
                guard header.count == 16 else { throw WorkbenchError("读取传输头不完整：\(header.count)/16") }
                let announced = Int(header.u32(4))
                diagnostics?("upload.block.header offset=\(offset) marker=\(header.u32(0)) announced_length=\(announced) expected_length=\(length)")
                guard announced == length else {
                    throw WorkbenchError("设备声明读取长度 \(announced)，预期 \(length)，偏移 \(offset)。已停止读取。")
                }
                let block = try usb.read(length, timeout: 10000)
                guard block.count == length else { throw WorkbenchError("读取不完整：\(block.count)/\(length)，备份不可用。") }
                result.append(block)
            } catch {
                diagnostics?("upload.failed source=\(source) offset=\(offset) completed_bytes=\(result.count) total_bytes=\(count) error_type=\(String(reflecting: type(of: error)))")
                throw error
            }
            if result.count % 0x100000 == 0 || result.count == count { progress(Double(result.count) / Double(count)) }
        }
        diagnostics?("upload.complete bytes=\(result.count)")
        return result
    }
    static func checksum(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0
        for offset in stride(from: 0, to: data.count, by: 4) {
            var word: UInt32 = 0
            for i in 0..<min(4, data.count - offset) { word |= UInt32(data[offset + i]) << (8 * i) }
            checksum &+= word
        }
        return checksum
    }
    static func writeHeader(_ data: Data, sequence: UInt32) -> Data {
        var header = Data()
        header.appendLE(UInt32(0)); header.appendLE(UInt32(data.count)); header.appendLE(sequence)
        header.appendLE(checksum(data)); header.appendLE(UInt16(0x00ef)); header.appendLE(UInt16(512))
        header.append(Data(count: 32 - header.count))
        return header
    }
    func writeSystem(_ image: Data, progress: (Double) -> Void = { _ in }) throws {
        guard !image.isEmpty, image.count <= LX06.systemSize else { throw WorkbenchError("写入镜像长度无效。") }
        try tplCommand("download store system0 normal 0x\(String(image.count, radix: 16))")
        var offset = 0
        var sequence: UInt32 = 0
        while offset < image.count {
            let end = min(offset + 0x10000, image.count)
            let block = Data(image[offset..<end])
            _ = try usb.control(0x40, 0x32, 1, 0xffff, Self.writeHeader(block, sequence: sequence))
            try usb.write(block)
            let deadline = Date().addingTimeInterval(30)
            while true {
                let ack = Self.status(try usb.read(512, timeout: 5000))
                if ack.hasPrefix("OK!!") { break }
                guard ack.hasPrefix("Continue:32"), Date() < deadline else {
                    throw WorkbenchError("分区写入未获确认（块 \(sequence)）：\(ack.prefix(100))。启动项未切换。")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            offset = end; sequence += 1
            if offset % 0x100000 == 0 || offset == image.count { progress(Double(offset) / Double(image.count)) }
        }
        try bulkCommand("download get_status")
    }
    func environment() throws -> EnvironmentSnapshot {
        // U-Boot exports into RAM only. No persistent environment write occurs here.
        try bulkCommand("env export -t 0x01080000")
        let raw = try upload("mem 0x01080000", count: 0x10000)
        let text = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        let snapshot = try EnvironmentSnapshot(text: text)
        diagnostics?(snapshot.bootDiagnosticEvent)
        return snapshot
    }
}

public struct EnvironmentSnapshot: Codable, Equatable, Sendable {
    public let bootPart: String
    public let bootDelay: String?
    public let boardID: String
    public let text: String
    var bootDiagnosticEvent: String {
        let allowed = Set(["reboot_mode", "boot_part", "bootdelay", "board_id", "identifyWaitTime", "upgrade_step", "firstboot"])
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, allowed.contains(String(pair[0])) { fields[String(pair[0])] = String(pair[1]) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(fields)) ?? Data("{}".utf8)
        return "boot.environment source=current_usb_session reset_register=not_read fields=\(String(decoding: payload, as: UTF8.self))"
    }
    public init(text: String) throws {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        guard let boot = values["boot_part"], ["boot0", "boot1"].contains(boot),
              let board = values["board_id"], ["1", "3", "4", "5", "6", "10"].contains(board) else {
            throw WorkbenchError("无法确认 LX06 的 board_id 和 boot_part，当前仅允许检测，停止分区操作。")
        }
        if let delay = values["bootdelay"], Int(delay) == nil { throw WorkbenchError("bootdelay 格式无效。") }
        bootPart = boot; boardID = board; bootDelay = values["bootdelay"]; self.text = text
    }
}
