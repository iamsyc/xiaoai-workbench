import Foundation
import XiaoaiCore

// Capture kernel evidence independently of the app and libusb event callbacks.
@MainActor final class USBKernelLog {
    private let process = Process()
    private var handles: [FileHandle] = []
    private let journal: USBJournal

    init(directory: URL, journal: USBJournal) {
        self.journal = journal
        do {
            for name in ["kernel-usb.ndjson", "kernel-usb.stderr"] {
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw WorkbenchError("无法创建内核日志文件。")
                }
                handles.append(try FileHandle(forWritingTo: url))
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["stream", "--style", "ndjson", "--level", "debug", "--timeout", "180",
                "--predicate", "process == \"kernel\" AND (subsystem CONTAINS[c] \"usb\" OR eventMessage CONTAINS[c] \"USB\")"]
            process.standardOutput = handles[0]; process.standardError = handles[1]
            try process.run()
            journal.record("usb.kernel.started max_seconds=180 logging_configuration=unchanged")
        } catch {
            journal.record("usb.kernel.unavailable error_type=\(String(reflecting: type(of: error)))")
        }
    }

    func stop() async {
        if process.isRunning { process.interrupt() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if process.isRunning {
            process.terminate()
            journal.record("usb.kernel.stop_timeout bounded_by_stream_timeout=true")
        } else if process.processIdentifier > 0 {
            journal.record("usb.kernel.exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
        }
        for handle in handles { try? handle.close() }
        handles.removeAll()
    }
}
