import AppKit
import ApplicationServices

/// Detects text inputs with the Accessibility API (what VoiceOver uses), classifies what *kind* of
/// field it is, and reads the text around the caret so the phone can mirror it.
///
///  * AXObserver on the frontmost app for focus changes (instant).
///  * After every injected click, a forced report — so clicking the *same* field reopens the keyboard.
///  * A 0.4 s poll as a safety net, which also picks up text changed on the Mac (tab completion…).
///
/// Electron apps (Slack, Discord, VS Code…) hide their accessibility tree until someone sets
/// `AXManualAccessibility`; Chromium browsers wake up on `AXEnhancedUserInterface`.
final class FocusWatcher {
    var onChange: ((FocusInfo) -> Void)?
    var onContext: ((Int, TextContext) -> Void)?
    private(set) var current = FocusInfo(editable: false, secure: false, app: "", role: "", token: 0)

    private var focused: AXUIElement?
    private var lastClick: (point: CGPoint, time: CFTimeInterval)?
    private var lastKeyAction: CFTimeInterval = 0

    /// Record where the user clicked (global, top-left origin) so we can tell whether a newly
    /// focused field is the thing they clicked on.
    func noteClick(at p: CGPoint) { lastClick = (p, CACurrentMediaTime()) }
    func noteKeyAction() { lastKeyAction = CACurrentMediaTime() }
    private var lastContext: TextContext?
    private var observer: AXObserver?
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var categoryCache: [String: String] = [:]
    private let chromiumBundlePrefixes = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        "com.superlogical.rex", "com.raggesilver.BlackBox", "com.termius-dmg.mac", "app.tabby",
    ]
    static let codeEditors: [String] = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode",
        "com.sublimetext", "com.panic.Nova", "com.jetbrains.", "com.google.android.studio", "com.exafunction.windsurf",
    ]

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attach(to: app)
        }
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.evaluate()
            self?.pollContext()
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        detach()
    }

    /// Call after injecting a click: focus moves a beat after mouse-up. The last check always
    /// reports, flagged `clicked`, even if the same field is still focused.
    func checkAfterClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.evaluate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in self?.evaluate(clicked: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.evaluate() }
    }

    func checkSoon() {
        for delay in [0.04, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.evaluate() }
        }
    }

    /// Reads and reports the text around the caret right now (phone asked, e.g. after Return).
    func sendContextNow() {
        guard current.editable, !current.secure, let el = focused else { return }
        let ctx = current.kind == .terminal ? TextContext(before: "", selected: "", after: "") : readContext(el, kind: current.kind)
        lastContext = ctx
        if let ctx { onContext?(current.token, ctx) }
    }

    private func attach(to app: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        detach()
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let id = app.bundleIdentifier, chromiumBundlePrefixes.contains(where: id.hasPrefix) {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue().evaluate()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        evaluate()
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
    }

    func evaluate(clicked: Bool = false) {
        guard AXIsProcessTrusted() else { return }
        var owner = NSWorkspace.shared.frontmostApplication
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var el: AXUIElement?
        let focusedEl: AXUIElement? = attribute(system, kAXFocusedUIElementAttribute)
        // Attribute the field to the process that owns it. Spotlight, Raycast, Alfred, Notification
        // Center replies… are floating panels that never become the "front app".
        if let e = focusedEl {
            var pid: pid_t = 0
            if AXUIElementGetPid(e, &pid) == .success, pid != 0, let app = NSRunningApplication(processIdentifier: pid) {
                owner = app
            }
        }
        let bundleID = owner?.bundleIdentifier ?? ""
        var info = FocusInfo(editable: false, secure: false, app: owner?.localizedName ?? "", role: "", token: 0)
        if bundleID == "com.apple.Spotlight" { info.app = "Spotlight" }
        info.bundleID = bundleID
        if let e = focusedEl {
            el = e
            let role: String = attribute(e, kAXRoleAttribute) ?? ""
            let subrole: String = attribute(e, kAXSubroleAttribute) ?? ""
            info.role = subrole.isEmpty ? role : "\(role)/\(subrole)"
            info.token = Int(CFHash(e))
            (info.editable, info.secure) = isEditable(e, role: role, subrole: subrole)
            if info.editable {
                let (kind, hintKey) = classify(e, role: role, subrole: subrole, bundleID: bundleID)
                // A field whose hints say "password" is treated as secure even if its role isn't
                // AXSecureTextField, so its text is never read or sent to the phone.
                if kind == .secure { info.secure = true }
                info.kind = info.secure ? .secure : kind
                info.fieldKey = "\(bundleID)|\(info.role)|\(hintKey)"
            }
        }
        let changed = !info.sameField(as: current)
        guard changed || clicked else { return }
        focused = el
        if info.editable, !info.secure, let el {
            // Terminals: the screen already shows the line, and their AX text is unreliable (rows
            // without newlines, streaming output). The phone card shows only what you type.
            info.context = info.kind == .terminal ? TextContext(before: "", selected: "", after: "") : readContext(el, kind: info.kind)
        }
        lastContext = info.context
        info.clicked = clicked
        if info.editable, let el {
            let now = CACurrentMediaTime()
            let clickedInside = lastClick.map { now - $0.time < 0.8 && frame(of: el).insetBy(dx: -6, dy: -6).contains($0.point) } ?? false
            info.invite = clickedInside || now - lastKeyAction < 0.8
        }
        current = info
        onChange?(info)
    }

    /// Text changed on the Mac side (autocomplete, a sent message clearing the box…).
    private func pollContext() {
        guard current.editable, !current.secure, current.kind != .terminal, let el = focused else { return }
        let ctx = readContext(el, kind: current.kind)
        if let ctx, ctx != lastContext {
            lastContext = ctx
            onContext?(current.token, ctx)
        }
    }

    // MARK: Classification

    private func isEditable(_ el: AXUIElement, role: String, subrole: String) -> (Bool, Bool) {
        if subrole == "AXSecureTextField" { return (true, true) }
        if let enabled: Bool = attribute(el, kAXEnabledAttribute), !enabled { return (false, false) }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return (true, false)
        default: break
        }
        if let _: AXUIElement = attribute(el, "AXEditableAncestor") { return (true, false) }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           let _: CFTypeRef = attribute(el, kAXSelectedTextRangeAttribute) {
            return (true, false)
        }
        return (false, false)
    }

    /// Generic, layered field classification:
    ///  1. explicit accessibility semantics (subrole: search / secure)
    ///  2. the field's own words: placeholder, label, description, identifiers ("Address", "URL", "Email"…)
    ///  3. the app: known terminals, code editors, or the app's App Store category (developer tools)
    private func classify(_ el: AXUIElement, role: String, subrole: String, bundleID: String) -> (FieldKind, String) {
        let hintAttrs = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
                         kAXIdentifierAttribute, "AXDOMIdentifier", kAXHelpAttribute, kAXRoleDescriptionAttribute]
        var hints = hintAttrs.compactMap { (a: String) -> String? in attribute(el, a) }
        if let classes: [String] = attribute(el, "AXDOMClassList") { hints += classes }
        let h = hints.joined(separator: " ").lowercased()
        let hintKey = String(h.prefix(80))
        func has(_ words: [String]) -> Bool { words.contains { h.contains($0) } }

        if Self.terminals.contains(bundleID) { return (.terminal, "") }
        // Terminals embedded in other apps (xterm.js in Electron/web apps, VS Code's panel…)
        if has(["xterm", "terminal input", "terminal"]) { return (.terminal, hintKey) }
        if subrole == "AXSearchField" { return (.search, hintKey) }
        if has(["address and search", "address bar", "url", "web address", "smart search field", "location", "omnibox"]) { return (.url, hintKey) }
        if has(["e-mail", "email"]) { return (.email, hintKey) }
        if has(["password", "passcode"]) { return (.secure, hintKey) }
        if has(["phone", "zip", "postal", "amount", "quantity", "verification code", "one-time"]) { return (.number, hintKey) }
        // Prose editors (chat boxes, comments, docs) win over app-level guesses: a developer tool's
        // chat or commit-message box is still prose.
        if has(["prosemirror", "tiptap", "contenteditable", "message", "compose", "prompt", "chat", "reply",
                "comment", "write", "note", "description", "ql-editor", "draft"]) { return (.text, hintKey) }
        if has(["search", "find", "filter", "jump to", "go to"]) { return (.search, hintKey) }
        if has(["monaco", "codemirror", "source editor", "code editor", "console"]) { return (.code, hintKey) }
        if Self.codeEditors.contains(where: bundleID.hasPrefix), role == "AXTextArea" { return (.code, hintKey) }
        return (.text, hintKey)
    }

    private func category(of bundleID: String) -> String {
        if let c = categoryCache[bundleID] { return c }
        var c = ""
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let b = Bundle(url: url), let cat = b.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String {
            c = cat
        }
        categoryCache[bundleID] = c
        return c
    }

    // MARK: Text around the caret

    private func readContext(_ el: AXUIElement, kind: FieldKind) -> TextContext? {
        var total = 0
        if let n: Int = attribute(el, kAXNumberOfCharactersAttribute) { total = n }
        var sel = CFRange(location: total, length: 0)
        if let v: AXValue = attribute(el, kAXSelectedTextRangeAttribute) { AXValueGetValue(v, .cfRange, &sel) }

        if kind == .terminal {
            // A terminal's value is the whole scrollback: show just the current (last non-empty) line.
            let start = max(0, total - 600)
            guard let tail = string(el, CFRange(location: start, length: total - start)) ?? attribute(el, kAXValueAttribute) else { return nil }
            let line = tail.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0) }.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            var trimmed = line
            while trimmed.hasSuffix(" ") && trimmed.count > 1 && trimmed.dropLast().hasSuffix(" ") { trimmed.removeLast() }
            return TextContext(before: trimmed, selected: "", after: "")
        }

        let beforeStart = max(0, sel.location - 400)
        let before = string(el, CFRange(location: beforeStart, length: sel.location - beforeStart))
        let selected = sel.length > 0 ? string(el, CFRange(location: sel.location, length: min(sel.length, 400))) : ""
        let afterStart = sel.location + sel.length
        let after = string(el, CFRange(location: afterStart, length: max(0, min(200, total - afterStart))))
        if let before, let selected, let after {
            return TextContext(before: Self.lastLines(before, 4), selected: selected, after: Self.firstLines(after, 2))
        }
        // No range support (some web content): fall back to the whole value, caret at the end.
        if let value: String = attribute(el, kAXValueAttribute), value.count < 4000 {
            return TextContext(before: Self.lastLines(value, 4), selected: "", after: "")
        }
        return nil
    }

    /// The card on the phone shows the neighbourhood of the caret, never a whole log or document.
    static func lastLines(_ s: String, _ n: Int) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return String(lines.suffix(n).joined(separator: "\n").suffix(300))
    }
    static func firstLines(_ s: String, _ n: Int) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return String(lines.prefix(n).joined(separator: "\n").prefix(150))
    }

    private func frame(of el: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v: AXValue = attribute(el, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &p) }
        if let v: AXValue = attribute(el, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    private func string(_ el: AXUIElement, _ range: CFRange) -> String? {
        if range.length == 0 { return "" }
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success
        else { return nil }
        return out as? String
    }

    private func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        }
        return value as? T
    }
}
