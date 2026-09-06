import Foundation
import CoreGraphics

/// Suppresses bump detection around user input, so the accelerometer can't be
/// fooled by anything the user physically does to the machine other than a
/// genuine chassis knock.
///
/// The core idea: **a real chassis knock generates no input event.** Typing,
/// moving the cursor, clicking, or tapping *any* trackpad (built-in or external)
/// all emit HID events. We listen for those and suppress detection for a short
/// window around each, so:
///   1. bumps while typing are ignored (keyboard events),
///   2. bumps while moving the cursor are ignored (mouse-moved/dragged events),
///   3. trackpad taps/clicks are ignored (mouse-down/up + moved events) — leaving
///      only true chassis hits, which produce no event.
///
/// Listen-only `CGEventTap`; needs Accessibility or Input Monitoring permission.
/// If the tap can't be created we simply don't suppress.
final class InputSuppressor {
    /// Keystrokes ring the chassis a while, so suppress a touch longer.
    var keyWindow: TimeInterval = 0.5
    /// Pointer activity (move/click/tap). Continuous events refresh this while the
    /// user keeps moving, so detection resumes shortly after they stop.
    var pointerWindow: TimeInterval = 0.3

    private(set) var isActive = false
    private nonisolated(unsafe) var lastKey: TimeInterval = -100
    private nonisolated(unsafe) var lastPointer: TimeInterval = -100

    private var tap: CFMachPort?
    private var thread: Thread?

    func isSuppressed(now: TimeInterval) -> Bool {
        now - lastKey < keyWindow || now - lastPointer < pointerWindow
    }

    func start() {
        guard tap == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "bump.input-suppressor"
        thread = t
        t.start()
    }

    private func run() {
        // Keyboard + every pointer/trackpad event we can observe.
        let types: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]
        var mask: UInt64 = 0
        for t in types { mask |= (1 << UInt64(t.rawValue)) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<InputSuppressor>.fromOpaque(ctx).takeUnretainedValue()
                switch type {
                case .keyDown, .flagsChanged:
                    me.lastKey = ProcessInfo.processInfo.systemUptime
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                default:
                    me.lastPointer = ProcessInfo.processInfo.systemUptime
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            isActive = false
            return
        }
        self.tap = tap
        isActive = true
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }
}
