import UIKit

/// Raw-touch trackpad. Deliberately avoids UIGestureRecognizers: they add recognition delays, and
/// we want every touch sample on the wire the instant it arrives.
///
///  1 finger move      → pointer (with smoothed acceleration)
///  1 finger tap       → left click            2 finger tap → right click      3 finger tap → middle
///  2 finger move      → scroll, with trackpad-style phases + inertia
///  press & hold, move → drag (over text: selects by word, like a Mac double-click drag)
///
/// One-handed:
///  edge strip (left/right) vertical swipe → scroll with inertia; flick again to go faster
///  swipe up from the bottom edge          → Mission Control
///  slide along the bottom edge            → Spaces follow your finger; release to finish or snap back
/// Phone flat on a table:
///  3 fingers ← → (interactive) ↑ ↓        → Spaces / Mission Control / App windows
///  4–5 fingers spread                     → Show Desktop
final class TouchpadView: UIView {
    enum Mode { case pointer, stripPending, strip, edge, multi }

    // Output
    var onMove: ((Double, Double, Double, Double) -> Void)?   // dx, dy, leadX, leadY
    var onScroll: ((Double, Double, ScrollPhase, MomentumPhase) -> Void)?
    var onClick: ((MouseButton) -> Void)?
    var onButton: ((MouseButton, Bool) -> Void)?
    var onHoldBegin: (() -> Void)?
    var onSystem: ((SystemAction) -> Void)?
    var onTouchDown: (() -> Void)?
    var onStripActive: ((Bool) -> Void)?
    /// Interactive Space swipe (phase, progress, velocity): +1 progress = one Space to the right.
    var onSpaceSwipe: ((SwipePhase, Double, Double) -> Void)?
    var onSampleDelay: ((Double) -> Void)?
    var onLeadMs: ((Double) -> Void)?

    // Settings
    var sensitivity: CGFloat = 1.6
    var acceleration: CGFloat = 1.0
    var scrollSpeed: CGFloat = 1.0
    var naturalScroll = true
    var predictive = false
    var stripSide: StripSide = .left

    /// The scroll zone is the whole side of the pad: about a third of its width, full height.
    static func stripZoneWidth(for width: CGFloat) -> CGFloat { min(max(width * 0.26, 78), 108) }
    static let edgeHeight: CGFloat = 36
    // Interactive Space swipe: finger travel for one full Space.
    private static let edgeSwipeWidth: CGFloat = 150
    private static let multiSwipeWidth: CGFloat = 220
    private var swiping = false
    private var swipeOrigin: CGFloat = 0
    private var swipeWidth: CGFloat = 150
    private var swipeProgress = 0.0
    private var swipeSamples: [(t: TimeInterval, p: Double)] = []

    private var mode: Mode = .pointer
    private var active: Set<UITouch> = []
    private var startPoint: CGPoint = .zero
    private var gestureStart: TimeInterval = 0
    private var maxTouches = 0
    private var travel: CGFloat = 0
    private var acted = false                  // a system gesture fired: no click on release
    private var verticalFired = false
    private var multiTranslation: CGPoint = .zero
    private var multiStartSpread: CGFloat = 0
    private var smoothedSpeed: CGFloat = 0
    private var hasLead = false
    private var scrolling = false
    private var dragging = false
    private var lastSample: TimeInterval = 0
    private var holdTimer: Timer?

    // Scroll velocity: recent (time, delta) samples → release velocity, like UIScrollView.
    private var scrollSamples: [(t: TimeInterval, d: CGPoint)] = []
    private var lastScrollTime: TimeInterval = 0
    private var momentum: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var momentumStarted = false
    private var carryVelocity: CGPoint = .zero
    private var carryUntil: TimeInterval = 0

    private var refreshLink: CADisplayLink?
    private var refreshUntil: CFTimeInterval = 0
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let tick = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Display rate

    /// ProMotion drops a static screen to low refresh rates, and touch delivery follows the display.
    /// Keep a 120 Hz display link alive while fingers are down so touches arrive every 8 ms.
    private func holdHighRefresh() {
        refreshUntil = CACurrentMediaTime() + 0.6
        guard refreshLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refreshTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        refreshLink = link
    }

    @objc private func refreshTick(_ link: CADisplayLink) {
        if active.isEmpty, momentum == nil, CACurrentMediaTime() > refreshUntil {
            link.invalidate(); refreshLink = nil
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdHighRefresh()
        let now = event?.timestamp ?? CACurrentMediaTime()
        if active.isEmpty, let first = touches.first {
            // Catching a scroll in flight stops it; flicking again soon after adds to it.
            let remaining = stopMomentum()
            carryVelocity = remaining
            carryUntil = now + 0.5
            onTouchDown?()
            let p = first.location(in: self)
            startPoint = p
            acted = false
            verticalFired = false
            let zone = Self.stripZoneWidth(for: bounds.width)
            let inStrip = (stripSide == .left && p.x < zone) || (stripSide == .right && p.x > bounds.width - zone)
            mode = inStrip ? .stripPending : (p.y > bounds.height - Self.edgeHeight ? .edge : .pointer)
            gestureStart = now
            maxTouches = 0
            smoothedSpeed = 0
            travel = 0
            scrolling = false
            scrollSamples.removeAll()
            lastSample = now
            lightHaptic.prepare(); tick.prepare()
        }
        active.formUnion(touches)
        maxTouches = max(maxTouches, active.count)

        if active.count >= 3 {
            if mode == .strip { onStripActive?(false) }
            if scrolling { scrolling = false; onScroll?(0, 0, .ended, .none) }
            if mode != .multi { multiTranslation = .zero; swipeOrigin = 0 }
            mode = .multi
            multiStartSpread = spread()
        } else if active.count == 2, mode != .pointer {
            // A second finger turns strip/edge gestures into normal two-finger scrolling.
            if mode == .strip { onStripActive?(false) }
            if scrolling { scrolling = false; onScroll?(0, 0, .ended, .none) }
            mode = .pointer
        }

        holdTimer?.invalidate()
        if active.count == 1 && !dragging && (mode == .pointer || mode == .stripPending) {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                guard let self, self.active.count == 1, self.travel < 8, !self.scrolling,
                      self.mode == .pointer || self.mode == .stripPending else { return }
                self.mode = .pointer   // holding still in the scroll zone still starts a drag
                self.dragging = true
                self.heavyHaptic.impactOccurred()
                self.onHoldBegin?()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdHighRefresh()
        let now = event?.timestamp ?? CACurrentMediaTime()
        let dt = max(now - lastSample, 1.0 / 240.0)
        lastSample = now

        // Sum coalesced samples (240 Hz on ProMotion) for an accurate delta.
        func delta(_ t: UITouch) -> CGPoint {
            let samples = event?.coalescedTouches(for: t) ?? [t]
            var d = CGPoint.zero
            for s in samples {
                let p = s.location(in: self), q = s.previousLocation(in: self)
                d.x += p.x - q.x; d.y += p.y - q.y
            }
            return d
        }
        if let t = touches.first, let newest = event?.coalescedTouches(for: t)?.last ?? Optional(t) {
            onSampleDelay?((CACurrentMediaTime() - newest.timestamp) * 1000)
        }

        switch mode {
        case .multi:
            holdTimer?.invalidate()
            let moved = touches.filter { active.contains($0) }
            guard !moved.isEmpty else { return }
            var d = moved.reduce(CGPoint.zero) { acc, t in let x = delta(t); return CGPoint(x: acc.x + x.x, y: acc.y + x.y) }
            d.x /= CGFloat(moved.count); d.y /= CGFloat(moved.count)
            multiTranslation.x += d.x; multiTranslation.y += d.y
            travel += hypot(d.x, d.y)
            if active.count >= 4 {
                if !verticalFired, multiStartSpread > 0, spread() / multiStartSpread > 1.4 { verticalFired = true; fire(.showDesktop) }
            } else if active.count == 3 {
                let t = multiTranslation
                if swiping || (!verticalFired && abs(t.x) > 14 && abs(t.x) > abs(t.y)) {
                    swipeUpdate(x: t.x, now: now, width: Self.multiSwipeWidth)
                } else if !verticalFired, abs(t.y) > 60, abs(t.y) > abs(t.x) * 1.3 {
                    verticalFired = true
                    fire(t.y < 0 ? .missionControl : .appExpose)
                }
            }

        case .edge:
            guard active.count == 1, let t = active.first else { return }
            let d = delta(t)
            travel += hypot(d.x, d.y)
            let p = t.location(in: self)
            let tx = p.x - startPoint.x, ty = p.y - startPoint.y
            if swiping {
                swipeUpdate(x: p.x, now: now, width: Self.edgeSwipeWidth)
            } else if !verticalFired, -ty > 40, -ty > abs(tx) {
                verticalFired = true
                fire(.missionControl)
            } else if !verticalFired, abs(tx) > 10, abs(tx) > abs(ty) {
                swipeOrigin = startPoint.x
                swipeUpdate(x: p.x, now: now, width: Self.edgeSwipeWidth)
            }

        case .stripPending:
            guard active.count == 1, let t = active.first else { return }
            let d = delta(t)
            travel += hypot(d.x, d.y)
            let p = t.location(in: self)
            let tx = p.x - startPoint.x, ty = p.y - startPoint.y
            guard hypot(tx, ty) > 8 else { return }
            holdTimer?.invalidate()
            // Only a clearly vertical start is a scroll; anything diagonal is the pointer.
            if abs(ty) > abs(tx) * 1.35 {
                // Clearly vertical: it's a scroll. Include the movement so far so it feels immediate.
                mode = .strip
                tick.selectionChanged()
                onStripActive?(true)
                emitScroll(CGPoint(x: 0, y: ty), dt: dt, now: now, strip: true)
            } else {
                // Sideways out of the edge: it was a pointer move after all.
                mode = .pointer
                pointerMove(CGPoint(x: tx, y: ty), dt: max(dt, 0.03), event: event, touch: t)
            }

        case .strip:
            guard active.count == 1, let t = active.first else { return }
            let d = delta(t)
            travel += hypot(d.x, d.y)
            emitScroll(CGPoint(x: 0, y: d.y), dt: dt, now: now, strip: true)

        case .pointer:
            if active.count == 1, let t = active.first, touches.contains(t) {
                let d = delta(t)
                travel += hypot(d.x, d.y)
                if travel > 8 { holdTimer?.invalidate() }
                guard !scrolling else { return }   // one finger left over from a two-finger scroll
                pointerMove(d, dt: dt, event: event, touch: t)
            } else if active.count == 2 {
                holdTimer?.invalidate()
                let moved = touches.filter { active.contains($0) }
                guard !moved.isEmpty, !dragging else { return }
                var d = moved.reduce(CGPoint.zero) { acc, t in let x = delta(t); return CGPoint(x: acc.x + x.x, y: acc.y + x.y) }
                d.x /= CGFloat(moved.count); d.y /= CGFloat(moved.count)
                travel += hypot(d.x, d.y)
                emitScroll(d, dt: dt, now: now, strip: false)
            }
        }
    }

    private func pointerMove(_ d: CGPoint, dt: TimeInterval, event: UIEvent?, touch t: UITouch) {
        // Smooth velocity (~30 ms) before the acceleration curve, like a real trackpad.
        let speed = hypot(d.x, d.y) / CGFloat(dt)
        smoothedSpeed += (speed - smoothedSpeed) * CGFloat(1 - exp(-dt / 0.03))
        let gain = sensitivity * (1 + acceleration * min(smoothedSpeed / 900, 3))
        var lead = CGPoint.zero
        if predictive, let p = event?.predictedTouches(for: t)?.last {
            let cur = (event?.coalescedTouches(for: t)?.last ?? t)
            let c = cur.location(in: self), f = p.location(in: self)
            lead = CGPoint(x: (f.x - c.x) * gain, y: (f.y - c.y) * gain)
            onLeadMs?((p.timestamp - cur.timestamp) * 1000)
        }
        hasLead = lead != .zero
        onMove?(Double(d.x * gain), Double(d.y * gain), Double(lead.x), Double(lead.y))
    }

    /// Scroll with a speed-sensitive gain. The edge strip gets more gain: a thumb has little travel.
    private func emitScroll(_ d: CGPoint, dt: TimeInterval, now: TimeInterval, strip: Bool) {
        let phase: ScrollPhase
        if !scrolling {
            guard strip || travel > 4 else { return }
            scrolling = true
            holdTimer?.invalidate()
            phase = .began
        } else {
            phase = .changed
        }
        let speed = hypot(d.x, d.y) / CGFloat(dt)
        let gain: CGFloat = strip ? 2.0 * (1 + min(speed / 1100, 1.6)) : 1.4 * (1 + min(speed / 2200, 0.6))
        let sign: CGFloat = naturalScroll ? 1 : -1
        let s = CGPoint(x: d.x * scrollSpeed * sign * gain, y: d.y * scrollSpeed * sign * gain)
        scrollSamples.append((now, s))
        scrollSamples.removeAll { now - $0.t > 0.1 }
        lastScrollTime = now
        onScroll?(Double(s.x), Double(s.y), phase, .none)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        active.subtract(touches)
        guard active.isEmpty else { return }
        holdTimer?.invalidate()
        if hasLead { hasLead = false; onMove?(0, 0, 0, 0) }   // settle exactly where the finger stopped
        let now = event?.timestamp ?? CACurrentMediaTime()
        if mode == .strip { onStripActive?(false) }
        if swiping {
            swiping = false
            onSpaceSwipe?(cancelled ? .cancelled : .ended, swipeProgress, swipeVelocity(now: now))
            return
        }

        if dragging {
            dragging = false
            onButton?(.left, false)
            return
        }
        if scrolling {
            scrolling = false
            onScroll?(0, 0, .ended, .none)
            // Release velocity from the last ~80 ms; a finger that paused before lifting doesn't fling.
            if now - lastScrollTime < 0.05 {
                let recent = scrollSamples.filter { now - $0.t <= 0.08 }
                if let first = recent.first {
                    let span = max(now - first.t, 1.0 / 120)
                    var v = recent.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.d.x, y: $0.y + $1.d.y) }
                    v = CGPoint(x: v.x / CGFloat(span), y: v.y / CGFloat(span))
                    // Flicking again in the same direction while it's still moving adds speed.
                    if now < carryUntil {
                        if v.x * carryVelocity.x > 0 { v.x += carryVelocity.x * 0.75 }
                        if v.y * carryVelocity.y > 0 { v.y += carryVelocity.y * 0.75 }
                    }
                    if hypot(v.x, v.y) > 80 { startMomentum(v) }
                }
            }
            return
        }
        if acted { return }
        guard !cancelled, now - gestureStart < 0.28, travel < 10 else { return }
        switch maxTouches {
        case 1: onClick?(.left); lightHaptic.impactOccurred()
        case 2: onClick?(.right); lightHaptic.impactOccurred(intensity: 0.8)
        default: onClick?(.middle); lightHaptic.impactOccurred()
        }
    }

    // MARK: Interactive Space swipe

    /// Like a trackpad: content follows the finger, so moving left reveals the next Space.
    private func swipeUpdate(x: CGFloat, now: TimeInterval, width: CGFloat) {
        holdTimer?.invalidate()
        if !swiping {
            swiping = true
            acted = true
            swipeWidth = width
            swipeProgress = 0
            swipeSamples.removeAll()
            onSpaceSwipe?(.began, 0, 0)
        }
        var p = Double(-(x - swipeOrigin) / swipeWidth)
        if abs(p) >= 1 {
            // A full Space: finish this one and keep going from here into the next.
            onSpaceSwipe?(.ended, p > 0 ? 1 : -1, swipeVelocity(now: now))
            heavyHaptic.impactOccurred()
            swipeOrigin = x
            swipeSamples.removeAll()
            onSpaceSwipe?(.began, 0, 0)
            p = 0
        }
        if (abs(swipeProgress) < 0.3) != (abs(p) < 0.3) { tick.selectionChanged() }   // point of no return
        swipeProgress = p
        swipeSamples.append((now, p))
        swipeSamples.removeAll { now - $0.t > 0.1 }
        onSpaceSwipe?(.changed, p, 0)
    }

    /// Progress per second over the last ~80 ms.
    private func swipeVelocity(now: TimeInterval) -> Double {
        let recent = swipeSamples.filter { now - $0.t <= 0.08 }
        guard let first = recent.first, let last = recent.last, last.t > first.t, now - last.t < 0.05 else { return 0 }
        return (last.p - first.p) / (last.t - first.t)
    }

    private func fire(_ a: SystemAction) {
        acted = true
        holdTimer?.invalidate()
        heavyHaptic.impactOccurred()
        onSystem?(a)
    }

    /// Mean distance of the fingers from their centroid.
    private func spread() -> CGFloat {
        let pts = active.map { $0.location(in: self) }
        guard pts.count > 1 else { return 0 }
        let c = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        return pts.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / CGFloat(pts.count)
    }

    // MARK: Inertia (UIScrollView "normal" deceleration: velocity × 0.998 per ms)

    private func startMomentum(_ v: CGPoint) {
        momentumVelocity = v
        momentumStarted = false
        holdHighRefresh()
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        let decay = pow(0.998, dt * 1000)
        momentumVelocity = CGPoint(x: momentumVelocity.x * decay, y: momentumVelocity.y * decay)
        refreshUntil = CACurrentMediaTime() + 0.2
        if hypot(momentumVelocity.x, momentumVelocity.y) < 14 { stopMomentum(); return }
        onScroll?(Double(momentumVelocity.x * dt), Double(momentumVelocity.y * dt), .none, momentumStarted ? .continue : .begin)
        momentumStarted = true
    }

    /// Stops any inertia and returns the velocity it still had.
    @discardableResult
    private func stopMomentum() -> CGPoint {
        guard let link = momentum else { return .zero }
        link.invalidate()
        momentum = nil
        if momentumStarted { onScroll?(0, 0, .none, .end) }
        momentumStarted = false
        let v = momentumVelocity
        momentumVelocity = .zero
        return v
    }
}
