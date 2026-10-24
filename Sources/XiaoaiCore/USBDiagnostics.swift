import Foundation

public typealias USBDiagnosticReporter = @Sendable (String) -> Void

// Capture in memory during USB operations; write once after the session has ended.
public final class USBJournal: @unchecked Sendable {
    private struct Entry: Encodable {
        let timestamp: Date
        let elapsedMS: Double
        let event: String
    }
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var entries: [Entry] = []
    public init() {}
    public func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(timestamp: Date(), elapsedMS: usbElapsedMS(since: started), event: event))
    }
    public func write(to file: URL) throws {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.ISO8601Format(.init(includingFractionalSeconds: true)))
        }
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()
        for entry in snapshot { output.append(try encoder.encode(entry)); output.append(10) }
        try output.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

func usbElapsedMS(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
