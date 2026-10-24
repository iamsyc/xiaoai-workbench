import Foundation
import IOKit

// IORegistry only: this observer never opens a device or sends USB requests.
struct USBRegistrySnapshot: Codable, Equatable, Sendable {
    let registryID: UInt64
    let parentID: UInt64?
    let kind: String
    let location: String?
    let numbers: [String: UInt64]
    let counters: [String: UInt64]
    let power: [String: UInt64]

    init(registryID: UInt64, parentID: UInt64?, kind: String, properties: [String: Any]) {
        self.registryID = registryID; self.parentID = parentID; self.kind = kind
        location = (properties["locationID"] as? NSNumber).map { String(format: "%08x", $0.uint32Value) }
        // Never serialize whole registry dictionaries: they contain serial numbers.
        func selected(_ source: [String: Any], keys: [String]) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: keys.compactMap { key in
                (source[key] as? NSNumber).map { (key, $0.uint64Value) }
            })
        }
        numbers = selected(properties, keys: ["idVendor", "idProduct", "bcdDevice", "bcdUSB",
            "UsbLinkSpeed", "USBSpeed", "port-status", "kUSBCurrentConfiguration"])
        counters = selected(properties["port-statistics"] as? [String: Any] ?? [:], keys: [
            "kPortStatConnectCount", "kPortStatAddressFailureCount", "kPortStatEnumerationFailureCount",
            "kPortStatOverCurrentCount", "kPortStatRemoteWakeCount", "kPortStatEOF2ViolationCount",
            "kPortStatEOF2ViolationDuringResetCount", "kPortStatEOF2ViolationDuringResumeCount"])
        power = selected(properties["IOPowerManagement"] as? [String: Any] ?? [:], keys: [
            "CurrentPowerState", "DevicePowerState", "DriverPowerState", "ChildrenPowerState"])
    }
}

public final class USBSystemMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.xiaoai.usb-system")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let report: USBDiagnosticReporter
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var timer: DispatchSourceTimer?
    private var previous: [UInt64: USBRegistrySnapshot] = [:]
    private var samples = 0

    public init(report: @escaping USBDiagnosticReporter) throws {
        self.report = report
        queue.setSpecific(key: queueKey, value: true)
        try queue.sync {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                throw WorkbenchError("无法创建 USB 系统通知端口。")
            }
            self.port = port
            let callbacks: [(String, IOServiceMatchingCallback, String)] = [
                (kIOFirstPublishNotification, { user, iterator in
                    guard let user else { return }
                    Unmanaged<USBSystemMonitor>.fromOpaque(user).takeUnretainedValue().drain(iterator, event: "published")
                }, "initial_published"),
                (kIOFirstMatchNotification, { user, iterator in
                    guard let user else { return }
                    Unmanaged<USBSystemMonitor>.fromOpaque(user).takeUnretainedValue().drain(iterator, event: "matched")
                }, "initial_matched"),
                (kIOTerminatedNotification, { user, iterator in
                    guard let user else { return }
                    Unmanaged<USBSystemMonitor>.fromOpaque(user).takeUnretainedValue().drain(iterator, event: "removed")
                }, "initial_terminated")]
            for kind in ["IOUSBHostDevice", "AppleUSBHostPort"] {
                for (notification, callback, initialEvent) in callbacks {
                    var iterator: io_iterator_t = 0
                    let status = IOServiceAddMatchingNotification(port, notification, IOServiceMatching(kind),
                        callback, Unmanaged.passUnretained(self).toOpaque(), &iterator)
                    guard status == KERN_SUCCESS else {
                        closeOnQueue()
                        throw WorkbenchError("USB 系统通知注册失败：\(status)")
                    }
                    iterators.append(iterator)
                    drain(iterator, event: initialEvent)
                }
            }
            sample(event: "baseline")
            IONotificationPortSetDispatchQueue(port, queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.sample(event: "changed") }
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(25))
            self.timer = timer
            timer.resume()
            report("usb.system.ready interval_ms=250 device_requests=0 notifications=publish,match,terminate")
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { closeOnQueue() }
        else { queue.sync { closeOnQueue() } }
    }
    deinit { stop() }

    private func closeOnQueue() {
        guard let port else { return }
        timer?.cancel(); timer = nil
        sample(event: "final", force: true)
        IONotificationPortSetDispatchQueue(port, nil)
        IONotificationPortDestroy(port)
        self.port = nil
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        report("usb.system.closed samples=\(samples)")
    }

    private func snapshot(_ service: io_service_t) -> USBRegistrySnapshot? {
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { return nil }
        var raw: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS, let properties = raw?.takeRetainedValue() as? [String: Any] else {
            report("usb.system.properties_unavailable registry_id=\(registryID) status=\(status)")
            return nil
        }
        var parent: io_registry_entry_t = 0
        var parentID: UInt64?
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(parent, &id) == KERN_SUCCESS { parentID = id }
            IOObjectRelease(parent)
        }
        return USBRegistrySnapshot(registryID: registryID, parentID: parentID,
            kind: IOObjectConformsTo(service, "AppleUSBHostPort") != 0 ? "port" : "device", properties: properties)
    }

    private func emit(_ event: String, _ snapshot: USBRegistrySnapshot) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            report("usb.system.\(event) \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func drain(_ iterator: io_iterator_t, event: String) {
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            // Removal may outlive its properties. Keep the ID even if the snapshot is unavailable.
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            if let state = snapshot(service) { emit(event, state) }
            else { report("usb.system.\(event) registry_id=\(id) properties=unavailable") }
            IOObjectRelease(service)
        }
    }

    private func sample(event: String, force: Bool = false) {
        samples += 1
        var current: [UInt64: USBRegistrySnapshot] = [:]
        for kind in ["AppleUSBHostPort", "IOUSBHostDevice"] {
            var iterator: io_iterator_t = 0
            let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kind), &iterator)
            guard status == KERN_SUCCESS else {
                report("usb.system.scan_failed kind=\(kind) status=\(status)")
                return // A failed scan must not manufacture removal events.
            }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                if let state = snapshot(service) { current[state.registryID] = state }
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
        }
        for state in current.values.sorted(by: { $0.registryID < $1.registryID }) {
            if force || previous[state.registryID] != state { emit(event, state) }
        }
        for id in previous.keys.sorted() where current[id] == nil {
            report("usb.system.absent_at_sample registry_id=\(id)")
        }
        previous = current
        if samples % 40 == 0 { report("usb.system.heartbeat samples=\(samples) entries=\(current.count)") }
    }
}
