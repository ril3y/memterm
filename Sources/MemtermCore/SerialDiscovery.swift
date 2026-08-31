import Foundation
import IOKit
import IOKit.serial

// IOKit serial-port discovery (feature/serial stage 1). READ-ONLY: enumerates
// the IORegistry and never open(2)s a device node — connected hardware must
// not be disturbed, and a port is only ever opened behind an explicit user
// gesture (consent invariant).

/// One enumerated port: the callout node plus whatever USB metadata the
/// ancestor chain offers. Every USB field is optional — CH340-class clones
/// ship no vendor name and no serial number, and Bluetooth/debug ports have
/// no USB ancestor at all.
public struct SerialPortInfo: Equatable {
    public let path: String            // /dev/cu.* — the node to open
    public let dialinPath: String?     // /dev/tty.* twin
    public let baseName: String?       // IOTTYBaseName, e.g. "usbserial"
    public let usbProductName: String?
    public let usbVendorName: String?
    public let usbSerialNumber: String?
    public let vendorID: Int?
    public let productID: Int?
    public let locationID: Int?

    public init(path: String, dialinPath: String? = nil, baseName: String? = nil,
                usbProductName: String? = nil, usbVendorName: String? = nil,
                usbSerialNumber: String? = nil, vendorID: Int? = nil,
                productID: Int? = nil, locationID: Int? = nil) {
        self.path = path
        self.dialinPath = dialinPath
        self.baseName = baseName
        self.usbProductName = usbProductName
        self.usbVendorName = usbVendorName
        self.usbSerialNumber = usbSerialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }

    /// Human picker label: product name when the device offers one, else the
    /// /dev basename ("cu.usbserial-11310" beats a blank row).
    public var label: String {
        if let product = usbProductName, !product.isEmpty { return product }
        return (path as NSString).lastPathComponent
    }

    /// Stable identity for reconnect-on-replug, strongest available first:
    /// vid/pid/serial survives /dev renumbering; locationID (physical USB
    /// topology) covers serial-less clones; the path itself is the last
    /// resort for non-USB ports.
    public var stableIdentity: String {
        if let vid = vendorID, let pid = productID,
           let serial = usbSerialNumber, !serial.isEmpty {
            return String(format: "usb:%04x:%04x:%@", vid, pid, serial)
        }
        if let loc = locationID {
            return String(format: "loc:%08x", loc)
        }
        return "path:\(path)"
    }

    public var isUSB: Bool { vendorID != nil || usbProductName != nil }
}

public enum SerialPortDiscovery {

    /// All serial ports currently in the IORegistry, callout-node keyed.
    /// Read-only registry walk; safe to call at any time.
    public static func enumeratePorts() -> [SerialPortInfo] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        (matching as NSMutableDictionary)[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }
        return drain(iterator: iter)
    }

    /// Consumes `iter` (releasing each object) and builds infos. Shared with
    /// the hotplug watcher, whose notification iterators have the same shape.
    static func drain(iterator iter: io_iterator_t) -> [SerialPortInfo] {
        var ports: [SerialPortInfo] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            if let info = info(for: svc) { ports.append(info) }
        }
        return ports
    }

    static func info(for svc: io_object_t) -> SerialPortInfo? {
        guard let callout = prop(svc, kIOCalloutDeviceKey) as? String else { return nil }
        var info = SerialPortInfo(
            path: callout,
            dialinPath: prop(svc, kIODialinDeviceKey) as? String,
            baseName: prop(svc, kIOTTYBaseNameKey) as? String)

        // USB metadata lives on an IOUSBHostInterface ancestor — usually at
        // parent depth 2, but never bound exactly: walk up until a product
        // name appears or ~12 levels are exhausted (non-USB ports have none).
        var cur: io_object_t = svc
        IOObjectRetain(cur)
        var depth = 0
        while depth < 12 {
            var parent: io_object_t = 0
            let pr = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent)
            IOObjectRelease(cur)
            guard pr == KERN_SUCCESS else { return info }
            cur = parent
            depth += 1
            if let product = prop(cur, "USB Product Name") as? String {
                info = SerialPortInfo(
                    path: info.path, dialinPath: info.dialinPath, baseName: info.baseName,
                    usbProductName: product,
                    usbVendorName: prop(cur, "USB Vendor Name") as? String,
                    usbSerialNumber: prop(cur, "USB Serial Number") as? String,
                    vendorID: prop(cur, "idVendor") as? Int,
                    productID: prop(cur, "idProduct") as? Int,
                    locationID: prop(cur, "locationID") as? Int)
                break
            }
        }
        IOObjectRelease(cur)
        return info
    }

    private static func prop(_ svc: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}

/// Hotplug watcher: paired first-match/terminated IOKit matching
/// notifications delivered on a private queue (the researched mechanism —
/// /dev vnode watching is unreliable for device nodes and polling is
/// unnecessary). Callbacks fire on `callbackQueue`. Watching never opens a
/// device; attach events only feed the picker — auto-open stays forbidden.
public final class SerialHotplugWatcher {

    public var onAttach: (([SerialPortInfo]) -> Void)?
    public var onDetach: (([SerialPortInfo]) -> Void)?

    private let callbackQueue: DispatchQueue
    private let notifyQueue = DispatchQueue(label: "memterm.serial.hotplug")
    private var notifyPort: IONotificationPortRef?
    private var matchIter: io_iterator_t = 0
    private var termIter: io_iterator_t = 0
    private var started = false

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    deinit { stop() }

    /// Registers both notifications and drains their iterators (the drain
    /// both delivers pre-existing devices and ARMS future callbacks).
    /// Returns the ports already present, or nil if registration failed.
    @discardableResult
    public func start() -> [SerialPortInfo]? {
        guard !started else { return nil }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        IONotificationPortSetDispatchQueue(port, notifyQueue)
        notifyPort = port

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Each registration consumes its own matching dict (CF ownership
        // transferred) — one fresh dictionary per registration.
        guard let matchDict = IOServiceMatching(kIOSerialBSDServiceValue) else {
            teardownPort(); return nil
        }
        (matchDict as NSMutableDictionary)[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        let krMatch = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matchDict,
            { refcon, iter in
                guard let refcon else { return }
                let watcher = Unmanaged<SerialHotplugWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.deliver(iterator: iter, attach: true)
            }, refcon, &matchIter)
        guard krMatch == KERN_SUCCESS else { teardownPort(); return nil }

        guard let termDict = IOServiceMatching(kIOSerialBSDServiceValue) else {
            teardownPort(); return nil
        }
        (termDict as NSMutableDictionary)[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        let krTerm = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, termDict,
            { refcon, iter in
                guard let refcon else { return }
                let watcher = Unmanaged<SerialHotplugWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.deliver(iterator: iter, attach: false)
            }, refcon, &termIter)
        guard krTerm == KERN_SUCCESS else { teardownPort(); return nil }

        started = true
        // Initial drains: existing devices out, notifications armed.
        let existing = SerialPortDiscovery.drain(iterator: matchIter)
        _ = SerialPortDiscovery.drain(iterator: termIter)
        return existing
    }

    public func stop() {
        guard started || notifyPort != nil else { return }
        started = false
        teardownPort()
    }

    private func teardownPort() {
        if matchIter != 0 { IOObjectRelease(matchIter); matchIter = 0 }
        if termIter != 0 { IOObjectRelease(termIter); termIter = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func deliver(iterator: io_iterator_t, attach: Bool) {
        let ports = SerialPortDiscovery.drain(iterator: iterator)
        guard !ports.isEmpty else { return }
        callbackQueue.async { [weak self] in
            guard let self else { return }
            (attach ? self.onAttach : self.onDetach)?(ports)
        }
    }
}
