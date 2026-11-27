import AppKit
import CoreGraphics

// Instant Space switching by posting a synthetic trackpad "dock swipe" fling.
//
// Ported to Swift from InstantSpaceSwitcher (ISS.c, event_serialize.c) by jurplel —
// https://github.com/jurplel/InstantSpaceSwitcher — MIT License.
//
// Why not ⌃←/⌃→: macOS ignores those shortcuts while a Space slide is animating, so quick
// successive switches get dropped or have to wait out each ~0.7 s animation. A dock-swipe fling is
// what a real trackpad sends; the Dock commits it immediately and accepts the next one right away.
enum SpaceSwitcher {
    // CGEvent fields (undocumented, from ISS.c)
    private static let typeField = CGEventField(rawValue: 55)!
    private static let hidType = CGEventField(rawValue: 110)!
    private static let swipeMask = CGEventField(rawValue: 115)!
    private static let swipeMotion = CGEventField(rawValue: 123)!
    private static let swipeProgress = CGEventField(rawValue: 124)!
    private static let swipePositionX = CGEventField(rawValue: 125)!
    private static let swipePositionY = CGEventField(rawValue: 126)!
    private static let swipeVelocityX = CGEventField(rawValue: 129)!
    private static let swipeVelocityY = CGEventField(rawValue: 130)!
    private static let phaseField = CGEventField(rawValue: 132)!
    private static let phaseAlias = CGEventField(rawValue: 134)!
    private static let zoomDeltaY = CGEventField(rawValue: 138)!
    private static let sourcePIDAlias = CGEventField(rawValue: 169)!

    private static let eventGesture: Int64 = 29
    private static let eventDockControl: Int64 = 30
    private static let hidDockSwipe: Int64 = 23
    private static let motionHorizontal: Int64 = 1
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

    private static let modern = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    private static let modernFling = 9999.0
    private static let legacySpeed = 2000.0

    // Overshoot guard: during a burst the window server still reports an intermediate Space, so
    // keep our own prediction for ~1 s. Swiping past the last Space can wedge the Dock on macOS 27.
    private static var predictedIndex: Int?
    private static var lastGesture: CFTimeInterval = 0

    /// Index we believe the display is on: our own prediction while recent swipes are still
    /// animating (the window server reports the old Space until the slide finishes).
    private static func currentIndex(_ info: SpaceInfo) -> Int {
        (CACurrentMediaTime() - lastGesture < 1.3 ? predictedIndex : nil) ?? info.index
    }

    /// One animated switch (buttons, discrete gestures): a short real swipe released at a
    /// natural speed, so the Dock slides like a trackpad flick. Returns false at the first/last Space.
    @discardableResult
    static func switchSpace(right: Bool) -> Bool {
        guard let info = SpaceInfo.cursorDisplay() else { return fallback(right: right) }
        let current = currentIndex(info)
        if right ? current + 1 >= info.count : current == 0 { return false }
        lastGesture = CACurrentMediaTime()
        predictedIndex = current + (right ? 1 : -1)
        let dir = right ? 1.0 : -1.0
        guard post(.began, progress: 0, velocity: 0, instant: false) else { return fallback(right: right) }
        for i in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.008) {
                _ = post(.changed, progress: dir * 0.07 * Double(i), velocity: 0, instant: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.032) {
            _ = post(.ended, progress: dir * 0.21, velocity: dir * releaseVelocity, instant: false)
        }
        return true
    }

    /// Release speed that commits with a full slide animation (calibrated: ≤50 animates, ≥80 is instant).
    private static let releaseVelocity = 32.0

    // Interactive swipe state
    private static var swipeActive = false
    private static var swipeStarted = false
    private static var canLeft = true, canRight = true
    private static var swipeBase = 0

    /// Streams a finger-driven swipe: Spaces slide under the finger, can be reversed mid-way, and
    /// on release either finish (past ~30 % or flicked) or snap back. Never swipes past the
    /// first/last Space (that can wedge the Dock).
    static func interactive(_ phase: SwipePhase, progress: Double, velocity: Double) {
        switch phase {
        case .began:
            let info = SpaceInfo.cursorDisplay()
            swipeBase = info.map(currentIndex) ?? 0
            canRight = info.map { swipeBase + 1 < $0.count } ?? false
            canLeft = info != nil && swipeBase > 0
            swipeActive = true
            swipeStarted = false
            lastGesture = CACurrentMediaTime()
        case .changed:
            guard swipeActive else { return }
            let p = clamp(progress)
            guard p != 0 || swipeStarted else { return }    // don't start the Dock gesture until it can move
            if !swipeStarted { swipeStarted = true; _ = post(.began, progress: 0, velocity: 0, instant: false) }
            _ = post(.changed, progress: p, velocity: 0, instant: false)
            lastGesture = CACurrentMediaTime()
        case .ended, .cancelled:
            guard swipeActive else { return }
            swipeActive = false
            guard swipeStarted else { return }
            let p = clamp(progress)
            let towards = p > 0 ? 1.0 : -1.0
            let flick = velocity * towards                    // + = flicking onward, − = flicking back
            let commit = phase == .ended && p != 0 && flick > -0.8 && (abs(p) > 0.3 || flick > 0.8)
            lastGesture = CACurrentMediaTime()
            if commit {
                let v = towards * min(max(releaseVelocity, 18 + abs(velocity) * 6), 48)   // brisker flick, still animated
                _ = post(.ended, progress: p, velocity: v, instant: false)
                predictedIndex = swipeBase + Int(towards)
            } else {
                _ = post(.cancelled, progress: p, velocity: 0, instant: false)
                predictedIndex = swipeBase
            }
        }
    }

    private static func clamp(_ p: Double) -> Double {
        var p = min(max(p, -1), 1)
        if !canRight { p = min(p, 0) }
        if !canLeft { p = max(p, 0) }
        return p
    }

    private static func fallback(right: Bool) -> Bool {
        // Keyboard shortcut path (needs the default ⌃←/⌃→ shortcuts enabled).
        let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        let code: CGKeyCode = right ? 124 : 123
        for (key, down) in [(CGKeyCode(59), true), (code, true), (code, false), (CGKeyCode(59), false)] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            e?.flags = down || key != 59 ? flags : []
            e?.post(tap: .cghidEventTap)
        }
        return true
    }

    private static var naturalScrolling: Bool {
        var valid: DarwinBoolean = false
        let natural = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication, &valid)
        return !valid.boolValue || natural
    }

    private static func post(_ phase: Phase, right: Bool) -> Bool {
        let p = right ? 0.000016 : -0.000016
        return post(phase, progress: p, velocity: phase == .ended ? (right ? modernFling : -modernFling) : 0, instant: true)
    }

    /// Posts one dock-swipe event. `progress`: cumulative, +1 = a full Space toward the right.
    /// `velocity`: release speed, same sign convention (only meaningful on .ended).
    private static func post(_ phase: Phase, progress: Double, velocity: Double, instant: Bool) -> Bool {
        let right = progress > 0 || (progress == 0 && velocity > 0)
        guard let ev = CGEvent(source: nil) else { return false }
        ev.setIntegerValueField(typeField, value: eventDockControl)
        ev.setIntegerValueField(hidType, value: hidDockSwipe)
        ev.setIntegerValueField(phaseField, value: phase.rawValue)
        ev.setIntegerValueField(swipeMotion, value: motionHorizontal)

        if !modern {
            let v = instant ? (right ? legacySpeed : -legacySpeed) : velocity
            ev.setDoubleValueField(swipeProgress, value: progress)
            ev.setDoubleValueField(swipeVelocityX, value: v)
            ev.setDoubleValueField(swipeVelocityY, value: v)
            ev.post(tap: .cgSessionEventTap)
            return true
        }

        // macOS 27+: right is negative, and the Dock reads the sign through natural scrolling.
        let sign = naturalScrolling ? -1.0 : 1.0
        ev.setDoubleValueField(swipeProgress, value: sign * progress)
        ev.setIntegerValueField(phaseAlias, value: phase.rawValue)
        ev.setDoubleValueField(zoomDeltaY, value: 3.0)
        ev.setDoubleValueField(sourcePIDAlias, value: Double(mach_absolute_time()))
        ev.setDoubleValueField(swipePositionX, value: 0.1)
        if phase == .ended { ev.setDoubleValueField(swipeVelocityX, value: sign * velocity) }   // the release decides it

        guard let augmented = augment(ev), let companion = CGEvent(source: nil) else { return false }
        // The Dock ignores a DockControl event without a companion gesture event.
        companion.setIntegerValueField(typeField, value: eventGesture)
        augmented.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
        return true
    }

    // MARK: macOS 27 IOHID payload (event_serialize.c)

    /// Appends the raw IOHID payload macOS 27 needs to honour a synthetic dock swipe.
    private static func augment(_ ev: CGEvent) -> CGEvent? {
        guard let data = ev.data as Data?, data.count >= 4, Array(data.prefix(4)) == [0, 0, 0, 2] else { return nil }

        let phase = ev.getIntegerValueField(phaseField)
        let velX = ev.getDoubleValueField(swipeVelocityX), velY = ev.getDoubleValueField(swipeVelocityY)
        let includeVelocity = velX != 0 || velY != 0 || phase == 4

        var p = Data()
        func u8(_ v: UInt8) { p.append(v) }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { p.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { p.append(contentsOf: $0) } }
        func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { p.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { p.append(contentsOf: $0) } }
        func fixed(_ v: Double) -> Int32 {
            let f = Int32(clamping: Int64(v * 65536.0))
            return (f == 0 && v != 0) ? (v > 0 ? 1 : -1) : f
        }
        func base(size: UInt32, type: UInt32, options: UInt32, depth: UInt8) {
            u32(size); u32(type); u32(options); u8(depth); u8(0); u8(0); u8(0)
        }

        // IOHIDSystemQueueElementHeader (28 bytes)
        let ts = ev.timestamp != 0 ? ev.timestamp : mach_absolute_time()
        u64(ts); u64(0); u32(0); u32(0); u32(includeVelocity ? 2 : 1)
        // IOHIDFluidTouchGestureData (40 bytes): type 23, flavor 3 = DockPrimary
        base(size: 40, type: 23, options: UInt32((phase & 0xFF) << 24), depth: 0)
        i32(fixed(ev.getDoubleValueField(swipePositionX)))
        i32(fixed(ev.getDoubleValueField(swipePositionY)))
        i32(0)
        u32(UInt32(truncatingIfNeeded: ev.getIntegerValueField(swipeMask)))
        u16(UInt16(truncatingIfNeeded: ev.getIntegerValueField(swipeMotion)))
        u16(3)
        i32(fixed(ev.getDoubleValueField(swipeProgress)))
        // IOHIDVelocityEventData (28 bytes): type 9
        if includeVelocity {
            base(size: 28, type: 9, options: 0, depth: 1)
            i32(fixed(velX)); i32(fixed(velY)); i32(0)
        }

        var out = data
        // Tag: payload length (BE uint16), then field id 4205 (BE uint16).
        out.append(UInt8((p.count >> 8) & 0xFF)); out.append(UInt8(p.count & 0xFF))
        out.append(UInt8((4205 >> 8) & 0xFF)); out.append(UInt8(4205 & 0xFF))
        out.append(p)
        return CGEvent(withDataAllocator: nil, data: out as CFData)
    }
}

extension SpaceSwitcher {
    /// Debug experiment: a swipe that ramps progress to `maxProgress` over `steps` Changed events
    /// `stepMs` apart, then releases at `velocity`.
    static func experiment(right: Bool, maxProgress: Double, steps: Int, stepMs: Double, velocity: Double) {
        let dir = right ? 1.0 : -1.0
        _ = post(.began, progress: 0, velocity: 0, instant: false)
        for i in 1...max(steps, 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * stepMs / 1000) {
                _ = post(.changed, progress: dir * maxProgress * Double(i) / Double(steps), velocity: 0, instant: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps + 1) * stepMs / 1000) {
            if velocity < 0 { _ = post(.cancelled, progress: dir * maxProgress, velocity: 0, instant: false) }   // negative = cancel test
            else { _ = post(.ended, progress: dir * maxProgress, velocity: dir * velocity, instant: false) }
        }
    }
}

/// Which Space the display under the cursor is showing, and how many it has (SkyLight).
struct SpaceInfo {
    let index: Int
    let count: Int

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias DisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnection: MainConnection? = handle.flatMap { dlsym($0, "SLSMainConnectionID") }
        .map { unsafeBitCast($0, to: MainConnection.self) }
    private static let displaySpaces: DisplaySpaces? = handle.flatMap { dlsym($0, "SLSCopyManagedDisplaySpaces") }
        .map { unsafeBitCast($0, to: DisplaySpaces.self) }

    static func cursorDisplay() -> SpaceInfo? {
        guard let mainConnection, let displaySpaces,
              let list = displaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]], !list.isEmpty else { return nil }
        var uuid: String?
        if let loc = CGEvent(source: nil)?.location {
            var id: CGDirectDisplayID = 0, n: UInt32 = 0
            if CGGetDisplaysWithPoint(loc, 1, &id, &n) == .success, n > 0,
               let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, u) as String
            }
        }
        let display = list.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuid ?? "") == .orderedSame } ?? list[0]
        let ids = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.int64Value }
        guard !ids.isEmpty, let cur = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.int64Value,
              let idx = ids.firstIndex(of: cur) else { return nil }
        return SpaceInfo(index: idx, count: ids.count)
    }
}
