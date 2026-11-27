import UIKit
import SwiftUI

/// The text view that owns the iOS keyboard. It's visible: it shows the Mac's text around the caret,
/// so you can look at the phone instead of the laptop while typing.
final class MirrorTextView: UITextView {
    var onBackspaceAtStart: (() -> Void)?
    override func deleteBackward() {
        if selectedRange.length == 0 && selectedRange.location == 0 { onBackspaceAtStart?() }
        super.deleteBackward()
    }
}

/// Keeps the phone's text view and the Mac's focused field in step.
///
/// The text view is seeded with the Mac's text around the caret (`TextContext`). Every edit on the
/// phone is diffed against a mirror and replayed on the Mac as caret moves + backspaces + typed
/// text, so autocorrect, QuickType, swipe typing and dictation all work. When nothing has been
/// typed for a moment, fresh text from the Mac (autocomplete, a sent message clearing the box…)
/// replaces the mirror.
final class KeyboardController: NSObject, ObservableObject, UITextViewDelegate {
    @Published private(set) var isActive = false
    @Published private(set) var kind: FieldKind = .text
    @Published private(set) var detectedKind: FieldKind = .text
    @Published private(set) var appName = ""
    @Published private(set) var bundleID = ""
    @Published private(set) var isEmpty = true
    @Published private(set) var secureCount = 0
    @Published var mods: Modifiers = []

    let textView = MirrorTextView()
    private let client: RemoteClient
    private var prefs = Prefs.load()

    // What we believe the Mac's field contains, and its selection (character offsets).
    private var mirror: [Character] = []
    private var remoteSelStart = 0
    private var remoteSelLen = 0
    private var suppress = false
    private var lastLocalEdit: CFTimeInterval = 0
    private var contextRequestedAt: CFTimeInterval = 0
    private var focusToken: Int?
    private var dismissedToken: Int?
    private var ignoreInvitesUntil: CFTimeInterval = 0

    /// A tap on the trackpad while typing lowers the keyboard, even if that tap lands on a text
    /// field. The click still happens on the Mac; tapping the field again brings the keyboard back.
    func trackpadTapped() {
        if textView.isFirstResponder {
            ignoreInvitesUntil = CACurrentMediaTime() + 0.7
            hide(byUser: false)
        } else {
            ignoreInvitesUntil = 0
        }
    }
    private var fieldKey = ""
    private var overrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "fieldOverrides") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "fieldOverrides") }
    }

    init(client: RemoteClient) {
        self.client = client
        super.init()
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.tintColor = UIColor(red: 0.45, green: 0.7, blue: 1, alpha: 1)
        textView.font = .systemFont(ofSize: 17)
        textView.keyboardAppearance = .dark
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.smartInsertDeleteType = .no
        textView.onBackspaceAtStart = { [weak self] in
            guard let self else { return }
            self.client.send(.key(.delete, mods: self.consumeMods(), count: 1))
        }
        client.onFocus = { [weak self] in self?.apply(focus: $0) }
        client.onContext = { [weak self] in self?.received(context: $1, token: $0) }
        if let f = client.lastFocus { apply(focus: f) }
    }

    func reloadPrefs() { prefs = Prefs.load() }

    // MARK: Showing / hiding

    func show() {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        client.send(.requestContext)
        contextRequestedAt = CACurrentMediaTime()
    }

    /// `byUser`: stay closed for this field until it's clicked again.
    func hide(byUser: Bool) {
        if byUser { dismissedToken = focusToken }
        textView.resignFirstResponder()
        mods = []
    }

    func textViewDidBeginEditing(_ tv: UITextView) { withAnimation(.snappy(duration: 0.28)) { isActive = true } }
    func textViewDidEndEditing(_ tv: UITextView) { withAnimation(.snappy(duration: 0.28)) { isActive = false } }

    // MARK: Focus & context from the Mac

    private func apply(focus: FocusInfo) {
        if focus.token != focusToken {
            focusToken = focus.token
            dismissedToken = nil
            fieldKey = focus.fieldKey
            appName = focus.app
            bundleID = focus.bundleID
            detectedKind = focus.kind
            applyKind()
            seed(focus.context ?? TextContext(before: "", selected: "", after: ""))
        } else if focus.clicked, let ctx = focus.context, idle {
            seed(ctx)   // clicked elsewhere in the same field: the caret moved
        }
        guard prefs.autoKeyboard else { return }
        if focus.editable {
            // Open only when invited: you clicked inside the field, or a key action put focus there.
            // Apps moving focus on their own (Slack after you click a channel) leave it closed.
            let invited = focus.invite && CACurrentMediaTime() > ignoreInvitesUntil
            if invited { dismissedToken = nil }
            if invited, dismissedToken != focus.token, !textView.isFirstResponder { show() }
        } else if textView.isFirstResponder {
            hide(byUser: false)
        }
    }

    private var idle: Bool {
        textView.markedTextRange == nil && CACurrentMediaTime() - lastLocalEdit > 0.6
    }

    private func received(context ctx: TextContext, token: Int) {
        guard token == focusToken else { return }
        let requested = CACurrentMediaTime() - contextRequestedAt < 1 && lastLocalEdit < contextRequestedAt
        guard idle || requested, textView.markedTextRange == nil else { return }
        if String(mirror) == ctx.before + ctx.selected + ctx.after { return }
        seed(ctx)
    }

    private func seed(_ ctx: TextContext) {
        let full = ctx.before + ctx.selected + ctx.after
        suppress = true
        textView.text = full
        let loc = (ctx.before as NSString).length, len = (ctx.selected as NSString).length
        textView.selectedRange = NSRange(location: loc, length: len)
        suppress = false
        mirror = Array(full)
        remoteSelStart = ctx.before.count
        remoteSelLen = ctx.selected.count
        isEmpty = full.isEmpty
        secureCount = 0
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    // MARK: Field kind → keyboard behaviour

    func setOverride(_ k: FieldKind?) {
        var o = overrides
        o[fieldKey] = k?.rawValue
        overrides = o
        applyKind()
    }

    var isOverridden: Bool { overrides[fieldKey] != nil }

    private func applyKind() {
        let k = overrides[fieldKey].flatMap(FieldKind.init(rawValue:)) ?? detectedKind
        kind = k
        let tv = textView
        let plain = k != .text
        tv.autocapitalizationType = (k == .text) ? .sentences : .none
        tv.autocorrectionType = [.text, .search].contains(k) ? .default : .no
        tv.spellCheckingType = [.text, .search].contains(k) ? .default : .no
        tv.smartQuotesType = plain ? .no : .default
        tv.smartDashesType = plain ? .no : .default
        tv.keyboardType = switch k {
        case .url: .URL
        case .email: .emailAddress
        case .search: .webSearch
        case .number: .numbersAndPunctuation
        case .code, .terminal: .asciiCapable
        default: .default
        }
        tv.returnKeyType = switch k {
        case .url: .go
        case .search: .search
        default: .default
        }
        // Keep passwords out of QuickType learning.
        tv.inlinePredictionType = (k == .secure) ? .no : .default
        tv.textColor = (k == .secure) ? .clear : .white
        if tv.isFirstResponder { tv.reloadInputViews() }
    }

    // MARK: Replaying edits on the Mac

    func textViewDidChange(_ tv: UITextView) { sync() }
    func textViewDidChangeSelection(_ tv: UITextView) { sync() }

    private func selectionInCharacters() -> (start: Int, len: Int) {
        let text = textView.text ?? ""
        let r = textView.selectedRange
        let u = text.utf16
        let s = String.Index(utf16Offset: min(r.location, u.count), in: text)
        let e = String.Index(utf16Offset: min(r.location + r.length, u.count), in: text)
        return (text.distance(from: text.startIndex, to: s), text.distance(from: s, to: e))
    }

    private func sync() {
        guard !suppress, textView.markedTextRange == nil else { return }
        let new = Array(textView.text ?? "")
        let sel = selectionInCharacters()
        let old = mirror

        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        let deleted = old.count - p - s
        let inserted = String(new[p..<(new.count - s)])

        if deleted > 0 || !inserted.isEmpty {
            lastLocalEdit = CACurrentMediaTime()
            if remoteSelLen > 0, p == remoteSelStart, old.count - s == remoteSelStart + remoteSelLen {
                // The edit replaces exactly the Mac's selection: typing (or one delete) does that natively.
                if inserted.isEmpty { client.send(.key(.delete, mods: [], count: 1)) }
                else { client.send(.text(inserted)) }
            } else {
                collapseRemoteSelection()
                moveRemoteCaret(to: old.count - s)
                if deleted > 0 { client.send(.key(.delete, mods: [], count: deleted)) }
                if !inserted.isEmpty { client.send(.text(inserted)) }
            }
            remoteSelStart = p + inserted.count
            remoteSelLen = 0
        }
        mirror = new
        isEmpty = new.isEmpty
        if kind == .secure { secureCount = new.count }

        // Caret moved on the phone (tap in the text, space-bar trackpad…): follow it with arrows.
        if sel.len != remoteSelLen || sel.start != remoteSelStart {
            if !(sel.len > 0 && remoteSelLen == 0 && sel.start + sel.len == remoteSelStart) {
                collapseRemoteSelection()
                moveRemoteCaret(to: sel.start + sel.len)
            }
        }
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    private func collapseRemoteSelection() {
        guard remoteSelLen > 0 else { return }
        client.send(.key(.right, mods: [], count: 1))   // → collapses a selection to its end
        remoteSelStart += remoteSelLen
        remoteSelLen = 0
    }

    private func moveRemoteCaret(to target: Int) {
        let d = target - remoteSelStart
        if d > 0 { client.send(.key(.right, mods: [], count: d)) }
        if d < 0 { client.send(.key(.left, mods: [], count: -d)) }
        remoteSelStart = target
    }

    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            client.send(.key(.returnKey, mods: consumeMods(), count: 1))
            afterNavigation()
            return false
        }
        guard !mods.isEmpty else { return true }
        // With ⌘/⌃/⌥ armed, a keypress is a shortcut, not text.
        if text.isEmpty { client.send(.key(.delete, mods: consumeMods(), count: 1)) }
        else if text == " " { client.send(.key(.space, mods: consumeMods(), count: 1)) }
        else { client.send(.shortcut(text, mods: consumeMods())) }
        afterNavigation()
        return false
    }

    // MARK: Accessory keys

    func consumeMods() -> Modifiers {
        let m = mods
        if !m.isEmpty { mods = [] }
        return m
    }

    func toggle(_ m: Modifiers) {
        if mods.contains(m) { mods.remove(m) } else { mods.insert(m) }
    }

    func press(_ k: SpecialKey) {
        let m = consumeMods()
        if m.isEmpty, k == .left || k == .right {
            // Move the phone's caret; sync() mirrors it to the Mac, so both stay aligned.
            let r = textView.selectedRange
            let len = (textView.text as NSString).length
            let loc = k == .left ? max(0, r.location - (r.length > 0 ? 0 : 1)) : min(len, r.location + max(r.length, 1))
            textView.selectedRange = NSRange(location: loc, length: 0)
            return
        }
        client.send(.key(k, mods: m, count: 1))
        afterNavigation()
    }

    func perform(_ s: Shortcut) {
        client.send(s.message)
        afterNavigation()
    }

    /// The Mac's text/caret may have changed in ways we can't predict: start fresh and ask for it.
    private func afterNavigation() {
        seed(TextContext(before: "", selected: "", after: ""))
        lastLocalEdit = 0
        contextRequestedAt = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.client.send(.requestContext) }
    }
}
