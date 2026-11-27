import AppKit
import CoreGraphics

/// Turns protocol messages into real HID-level CGEvents. Posting at `.cghidEventTap`
/// means apps can't tell these apart from a physical mouse/keyboard.
/// Thread-safe enough to be driven from the network queue (CGEventPost is thread-safe),
/// which keeps the main thread out of the latency path.
final class InputInjector {
    private let source: CGEventSource?
    private var cursor: CGPoint = .zero
    private var lastPosted: CGPoint?
    private var down: Set<MouseButton> = []
    private var clickCount = 0
    private var lastClick: (time: TimeInterval, pos: CGPoint, button: MouseButton)?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Without this, macOS ignores physical-ish input for 250 ms after a synthetic move.
        source?.localEventsSuppressionInterval = 0
    }

    // MARK: Pointer

    private var lastPostTime: TimeInterval = 0

    private func currentLocation() -> CGPoint {
        // While we're actively streaming, the OS cursor position lags a few events behind
        // what we've posted. Trust our own sub-pixel position then; only resync to the real
        // cursor after a pause, and only if something else (a physical mouse) moved it.
        if lastPosted != nil, ProcessInfo.processInfo.systemUptime - lastPostTime < 0.08 { return cursor }
        let real = CGEvent(source: nil)?.location ?? .zero
        if let last = lastPosted, hypot(real.x - last.x, real.y - last.y) < 1.5 { return cursor }
        cursor = real
        return real
    }

    func move(dx: Double, dy: Double) {
        var p = currentLocation()
        p.x += dx; p.y += dy
        p = clampToDisplays(p, from: cursor)
        cursor = p
        lastPosted = p
        lastPostTime = ProcessInfo.processInfo.systemUptime

        let (type, button): (CGEventType, CGMouseButton) =
            down.contains(.left) ? (.leftMouseDragged, .left) :
            down.contains(.right) ? (.rightMouseDragged, .right) :
            down.contains(.middle) ? (.otherMouseDragged, .center) : (.mouseMoved, .left)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if !down.isEmpty { e.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1))) }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    func button(_ b: MouseButton, isDown: Bool) {
        let p = currentLocation()
        if isDown {
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastClick, last.button == b,
               now - last.time < NSEvent.doubleClickInterval,
               hypot(p.x - last.pos.x, p.y - last.pos.y) < 6 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClick = (now, p, b)
            down.insert(b)
        } else {
            down.remove(b)
        }
        let type: CGEventType
        let cgButton: CGMouseButton
        switch b {
        case .left: type = isDown ? .leftMouseDown : .leftMouseUp; cgButton = .left
        case .right: type = isDown ? .rightMouseDown : .rightMouseUp; cgButton = .right
        case .middle: type = isDown ? .otherMouseDown : .otherMouseUp; cgButton = .center
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        e.post(tap: .cghidEventTap)
    }

    /// Double-click-and-hold: selects the word under the pointer and extends by whole words while
    /// dragging — exactly what macOS does for a double-click drag.
    func wordDragBegin() {
        let p = currentLocation()
        for (type, state) in [(CGEventType.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2)] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(state))
            e.post(tap: .cghidEventTap)
        }
        clickCount = 2
        lastClick = (ProcessInfo.processInfo.systemUptime, p, .left)
        down.insert(.left)
    }

    func click(_ b: MouseButton) {
        button(b, isDown: true)
        button(b, isDown: false)
    }

    func releaseAll() {
        for b in down { button(b, isDown: false) }
    }

    func scroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        e.location = currentLocation()
        e.post(tap: .cghidEventTap)
    }

    private func clampToDisplays(_ p: CGPoint, from previous: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else { return p }
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(p) }) { return p }
        // Outside every screen: clamp to the screen we came from (or the nearest one).
        let home = bounds.first(where: { $0.insetBy(dx: -2, dy: -2).contains(previous) })
            ?? bounds.min(by: { dist($0, p) < dist($1, p) })!
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1),
                       y: min(max(p.y, home.minY), home.maxY - 1))
    }

    private func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    // MARK: Keyboard

    func type(_ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r" { press(SpecialKey.returnKey.keyCode, flags: []); continue }
            if ch == "\t" { press(SpecialKey.tab.keyCode, flags: []); continue }
            let utf16 = Array(String(ch).utf16)
            for isDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                e.flags = []
                utf16.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func key(_ k: SpecialKey, mods: Modifiers, count: Int) {
        for _ in 0..<max(1, min(count, 500)) { press(k.keyCode, flags: mods.cgFlags) }
    }

    func shortcut(_ s: String, mods: Modifiers) {
        guard let ch = s.lowercased().first, let code = KeyCodes.ansi[ch] else {
            type(s); return
        }
        var flags = mods.cgFlags
        if s.first?.isUppercase == true { flags.insert(.maskShift) }
        press(code, flags: flags)
    }

    /// macOS shortcuts for the trackpad's system gestures (all on by default in
    /// System Settings › Keyboard › Keyboard Shortcuts › Mission Control / Spotlight).
    func system(_ a: SystemAction) {
        switch a {
        case .spaceLeft: press(SpecialKey.left.keyCode, flags: .maskControl)
        case .spaceRight: press(SpecialKey.right.keyCode, flags: .maskControl)
        case .missionControl: press(SpecialKey.up.keyCode, flags: .maskControl)
        case .appExpose: press(SpecialKey.down.keyCode, flags: .maskControl)
        case .showDesktop: press(103, flags: [])   // F11
        case .spotlight: press(SpecialKey.space.keyCode, flags: .maskCommand)
        }
    }

    private func press(_ code: CGKeyCode, flags: CGEventFlags) {
        var flags = flags
        // Real keyboards tag navigation and function keys with these flags; some system shortcuts
        // (e.g. ⌃← to switch Spaces) are ignored without them.
        if (123...126).contains(code) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        if [115, 116, 117, 119, 121, 103].contains(code) { flags.insert(.maskSecondaryFn) }
        // Press modifier keys explicitly too; some apps (Electron, games) look at key state, not just flags.
        let modKeys = KeyCodes.modifierKeys(for: flags)
        for m in modKeys { post(m, down: true, flags: flags) }
        post(code, down: true, flags: flags)
        post(code, down: false, flags: flags)
        for m in modKeys.reversed() { post(m, down: false, flags: []) }
    }

    private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

extension Modifiers {
    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.shift) { f.insert(.maskShift) }
        return f
    }
}

extension SpecialKey {
    var keyCode: CGKeyCode {
        switch self {
        case .returnKey: 36
        case .tab: 48
        case .space: 49
        case .delete: 51
        case .escape: 53
        case .forwardDelete: 117
        case .left: 123
        case .right: 124
        case .down: 125
        case .up: 126
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        }
    }
}

enum KeyCodes {
    /// US-ANSI virtual key codes, used for ⌘/⌃/⌥ shortcuts (text itself goes through
    /// keyboardSetUnicodeString, so it's layout-independent).
    static let ansi: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49,
    ]

    static func modifierKeys(for flags: CGEventFlags) -> [CGKeyCode] {
        var keys: [CGKeyCode] = []
        if flags.contains(.maskCommand) { keys.append(55) }
        if flags.contains(.maskShift) { keys.append(56) }
        if flags.contains(.maskAlternate) { keys.append(58) }
        if flags.contains(.maskControl) { keys.append(59) }
        return keys
    }
}
