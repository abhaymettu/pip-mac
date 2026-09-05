import Foundation
import IOKit
import IOKit.hid

/// Reads the built-in accelerometer on Apple Silicon MacBooks via the
/// undocumented `AppleSPUHIDDevice` (vendor usage page 0xFF00, usage 3).
///
/// Proven to work **unprivileged** (no root) on M-series MacBooks — see
/// `spike/spike.swift`. Streams ~800 Hz. Each input report is parsed to a 3-axis
/// vector in g; we forward the magnitude to `onSample`.
///
/// Runs its own thread + run loop; `onSample` is invoked on that thread, so keep
/// the handler cheap and marshal to the main actor for UI.
final class SPUAccelerometer {
    static let usagePage = 0xFF00
    static let usage = 3

    /// Called for every sample: (magnitude in g, monotonic time).
    var onSample: ((Double, TimeInterval) -> Void)?

    private(set) var isRunning = false
    private(set) var deviceAvailable = false

    private var manager: IOHIDManager?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    /// True if any Apple Silicon accelerometer device is present on this Mac.
    static func isSupported() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: usagePage,
            kIOHIDDeviceUsageKey: usage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        return (devices?.isEmpty == false)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let t = Thread { [weak self] in self?.runLoopMain() }
        t.name = "bump.accelerometer"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Non-blocking: flip the flag and wake the sensor thread so it tears the HID
    /// manager down on its *own* thread. Closing IOKit HID from another thread
    /// (e.g. the main thread, while toggling input source) hangs the caller —
    /// IOHIDManager is not thread-safe.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    private func runLoopMain() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        runLoop = CFRunLoopGetCurrent()

        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Self.usagePage,
            kIOHIDDeviceUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<SPUAccelerometer>.fromOpaque(ctx).takeUnretainedValue()
            me.attach(device: device, context: ctx)
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

        // Cold-start the sensor (see wakeDriver). Re-assert periodically so it
        // survives stalls / sleep-wake without needing another app (e.g. Knock).
        wakeDriver()
        var ticks = 0
        while isRunning {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, true)
            ticks += 1
            if ticks % 8 == 0 { wakeDriver() }   // ~every 2 s
        }

        // Teardown on this thread (where the manager was opened/scheduled).
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        runLoop = nil
        buffers.forEach { $0.deallocate() }
        buffers.removeAll()
    }

    /// COLD-START the accelerometer. Opening the HID device + registering an input
    /// callback is NOT enough — the AppleSPU accelerometer only begins emitting
    /// reports once a `ReportInterval` is set on its **driver** (`AppleSPUHIDDriver`,
    /// usage 3) IORegistry entry. This is the "driver wake sequence" Knock performs;
    /// without it the sensor stays silent unless some other app has woken it.
    private func wakeDriver() {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDriver"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            let usage = IORegistryEntryCreateCFProperty(svc, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            if usage == Self.usage {
                IORegistryEntrySetCFProperty(svc, "ReportInterval" as CFString, 1000 as CFNumber)
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
    }

    private func attach(device: IOHIDDevice, context: UnsafeMutableRawPointer) {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        deviceAvailable = true

        // CRITICAL: the AppleSPU accelerometer does NOT free-run. Opening + a
        // registered input callback is not enough — the device stays silent until
        // a client requests a report interval (kIOHIDReportIntervalKey, in µs).
        // This is the "wake" Knock performs; without it we only ever saw data when
        // Knock happened to be running. ~1250 µs ≈ 800 Hz.
        IOHIDDeviceSetProperty(device, kIOHIDReportIntervalKey as CFString, 1250 as CFNumber)
        let maxReport = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxReport)
        buffers.append(buffer)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, maxReport, { ctx, result, _, _, _, report, length in
            guard result == kIOReturnSuccess, let ctx else { return }
            let me = Unmanaged<SPUAccelerometer>.fromOpaque(ctx).takeUnretainedValue()
            me.handleReport(report, length)
        }, context)
    }

    private func handleReport(_ report: UnsafePointer<UInt8>, _ length: Int) {
        guard length >= 18 else { return }
        func i32(_ off: Int) -> Int32 {
            Int32(littleEndian: UnsafeRawPointer(report + off).loadUnaligned(as: Int32.self))
        }
        let x = Double(i32(6)) / 65536.0
        let y = Double(i32(10)) / 65536.0
        let z = Double(i32(14)) / 65536.0
        let mag = (x*x + y*y + z*z).squareRoot()
        onSample?(mag, ProcessInfo.processInfo.systemUptime)
    }
}
