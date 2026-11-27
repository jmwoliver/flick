import SwiftUI
import UIKit

// MARK: - Style

enum Palette {
    static let surfaceTop = Color(white: 0.135)
    static let surfaceBottom = Color(white: 0.085)
    static let hairline = Color.white.opacity(0.07)
    static let chip = Color.white.opacity(0.08)
    static let accent = Color(red: 0.45, green: 0.7, blue: 1)
    static let faint = Color.white.opacity(0.42)
}

extension View {
    /// Liquid Glass on iOS 26+, material before that.
    @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}

// MARK: - Main screen

/// One-handed layout: the trackpad fills the screen; everything you press lives in the bottom
/// thumb zone. Status only appears when something is wrong.
struct ControlView: View {
    @ObservedObject var client: RemoteClient
    @StateObject private var kb: KeyboardController
    @StateObject private var shortcuts = ShortcutStore()
    @State private var showShortcuts = false
    @State private var showSettings = false
    @State private var toast: SystemAction?
    @State private var stripActive = false
    @State private var prefs = Prefs.load()
    @AppStorage("seenHints") private var seenHints = false

    init(client: RemoteClient) {
        self.client = client
        _kb = StateObject(wrappedValue: KeyboardController(client: client))
    }

    var body: some View {
        VStack(spacing: 10) {
            // The live text sits above the trackpad while typing. It always stays in the hierarchy
            // (collapsed when idle) because its text view owns the iOS keyboard.
            EditorCard(kb: kb)
            trackpad
            if kb.isActive {
                AccessoryRow(kb: kb, shortcuts: shortcuts)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                if showShortcuts {
                    ShortcutPanel(store: shortcuts, onRun: run, onSettings: { showSettings = true },
                                  onClose: { withAnimation(.snappy) { showShortcuts = false } })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                DockBar(client: client, showShortcuts: $showShortcuts, onKeyboard: { kb.show() })
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, kb.isActive ? 6 : 0)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings, onDismiss: { prefs = Prefs.load(); kb.reloadPrefs() }) {
            SettingsView().environmentObject(client)
        }
    }

    private func run(_ s: Shortcut) {
        haptic()
        kb.perform(s)
    }

    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [Palette.surfaceTop, Palette.surfaceBottom], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Palette.hairline))

            // Affordances: the scroll strip and the bottom-edge gesture zone.
            if prefs.stripSide != .off {
                // The scroll zone lights up while it's in use.
                GeometryReader { geo in
                    let w = TouchpadView.stripZoneWidth(for: geo.size.width)
                    LinearGradient(colors: [Palette.accent.opacity(0.16), Palette.accent.opacity(0)],
                                   startPoint: prefs.stripSide == .left ? .leading : .trailing,
                                   endPoint: prefs.stripSide == .left ? .trailing : .leading)
                        .frame(width: w)
                        .frame(maxWidth: .infinity, alignment: prefs.stripSide == .left ? .leading : .trailing)
                        .opacity(stripActive ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: stripActive)
                }
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .allowsHitTesting(false)
                HStack {
                    if prefs.stripSide == .right { Spacer() }
                    Capsule().fill(stripActive ? Palette.accent.opacity(0.85) : Color.white.opacity(0.13))
                        .frame(width: stripActive ? 5 : 3, height: stripActive ? 150 : 64)
                        .padding(.horizontal, 9)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stripActive)
                    if prefs.stripSide == .left { Spacer() }
                }
            }
            VStack {
                Spacer()
                Capsule().fill(Color.white.opacity(0.16)).frame(width: 40, height: 4).padding(.bottom, 10)
            }

            if !seenHints { hints }

            TouchSurface(client: client, prefs: prefs,
                         onTouchDown: {
                             if showShortcuts { withAnimation(.snappy) { showShortcuts = false } }
                         },
                         onClick: {
                             kb.trackpadTapped()
                             if !seenHints { withAnimation { seenHints = true } }
                         },
                         onStripActive: { stripActive = $0 },
                         onSystem: { a in
                             client.send(.system(a))
                             withAnimation(.snappy) { toast = a }
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                 if toast == a { withAnimation(.easeOut) { toast = nil } }
                             }
                         })
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

            VStack {
                if let problem = client.problem {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(problem).font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glass(Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .allowsHitTesting(false)

            if let toast {
                Label(toast.title, systemImage: symbol(for: toast))
                    .font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .glass(Capsule())
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var hints: some View {
        VStack(spacing: 14) {
            hintRow("hand.tap", "Tap to click · hold, then move to drag")
            hintRow("hand.point.up.left.and.text", "Two fingers to scroll and right-click")
            hintRow(prefs.stripSide == .right ? "arrow.up.and.down.square" : "arrow.up.and.down.square",
                    "\(prefs.stripSide == .off ? "Edge" : prefs.stripSide.title) side: swipe up / down to scroll")
            hintRow("arrow.up.to.line", "Swipe up from the bottom: Mission Control")
            hintRow("arrow.left.and.right", "Swipe along the bottom: switch Spaces")
        }
        .font(.footnote)
        .foregroundStyle(Palette.faint)
        .padding(.horizontal, 36)
        .allowsHitTesting(false)
    }

    private func hintRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(for a: SystemAction) -> String {
        switch a {
        case .spaceLeft: "arrow.left.square"
        case .spaceRight: "arrow.right.square"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "macwindow.on.rectangle"
        case .showDesktop: "menubar.dock.rectangle"
        case .spotlight: "magnifyingglass"
        }
    }
}

// MARK: - Trackpad bridge

struct TouchSurface: UIViewRepresentable {
    let client: RemoteClient
    let prefs: Prefs
    var onTouchDown: () -> Void
    var onClick: () -> Void
    var onStripActive: (Bool) -> Void
    var onSystem: (SystemAction) -> Void

    func makeUIView(context: Context) -> TouchpadView {
        let pad = TouchpadView()
        pad.onMove = { dx, dy, lx, ly in client.move(dx: dx, dy: dy, leadX: lx, leadY: ly) }
        pad.onScroll = { dx, dy, p, m in client.send(.scroll(dx: dx, dy: dy, phase: p, momentum: m)) }
        pad.onButton = { b, down in client.send(.button(b, down: down)) }
        pad.onHoldBegin = { client.send(.holdBegin) }
        pad.onSpaceSwipe = { phase, p, v in client.send(.spaceSwipe(phase, progress: p, velocity: v)) }
        pad.onSampleDelay = { client.recordTouchDelay($0) }
        pad.onLeadMs = { client.recordLead($0) }
        update(pad)
        return pad
    }

    func updateUIView(_ pad: TouchpadView, context: Context) { update(pad) }

    private func update(_ pad: TouchpadView) {
        pad.sensitivity = prefs.sensitivity
        pad.acceleration = prefs.acceleration
        pad.scrollSpeed = prefs.scrollSpeed
        pad.naturalScroll = prefs.naturalScroll
        pad.predictive = prefs.predictive
        pad.stripSide = prefs.stripSide
        pad.onClick = { b in client.send(.click(b)); onClick() }
        pad.onSystem = onSystem
        pad.onTouchDown = onTouchDown
        pad.onStripActive = onStripActive
    }
}

// MARK: - Dock bar

struct DockBar: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject private var icons = IconCache.shared
    @Binding var showShortcuts: Bool
    var onKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RoundButton(symbol: "keyboard", action: onKeyboard)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(client.dock) { app in
                        AppIconButton(app: app, image: icons.images[app.bundleID], isFront: app.bundleID == client.frontApp) {
                            haptic()
                            client.send(.activateApp(bundleID: app.bundleID))
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                         .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            RoundButton(symbol: "magnifyingglass") { haptic(); client.send(.system(.spotlight)) }
            RoundButton(symbol: "command", active: showShortcuts) {
                haptic()
                withAnimation(.snappy) { showShortcuts.toggle() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(height: 72)
        .glass(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

struct RoundButton: View {
    let symbol: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .foregroundStyle(active ? Color.black : Color.white)
                .background(Circle().fill(active ? Color.white : Palette.chip))
        }
        .buttonStyle(.plain)
    }
}

struct AppIconButton: View {
    let app: DockApp
    let image: UIImage?
    let isFront: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.chip)
                            .overlay(Text(String(app.name.prefix(1))).font(.headline).foregroundStyle(.white))
                    }
                }
                .frame(width: 42, height: 42)
                .scaleEffect(isFront ? 1.06 : 1)
                Circle()
                    .fill(Color.white.opacity(isFront ? 0.95 : (app.running ? 0.45 : 0)))
                    .frame(width: 4, height: 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name)
    }
}

// MARK: - Shortcut tray

struct ShortcutPanel: View {
    @ObservedObject var store: ShortcutStore
    var onRun: (Shortcut) -> Void
    var onSettings: () -> Void
    var onClose: () -> Void
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shortcuts").font(.headline)
                Text("Hold to pin").font(.caption).foregroundStyle(Palette.faint)
                Spacer()
                Button { onSettings() } label: { Image(systemName: "gearshape").frame(width: 36, height: 36) }
                Button { onClose() } label: { Image(systemName: "chevron.down").frame(width: 36, height: 36) }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.pinnedShortcuts.isEmpty { section("Pinned", store.pinnedShortcuts) }
                    ForEach(ShortcutStore.builtIn) { g in section(g.id, g.items) }
                    section("Custom", store.custom, addButton: true)
                }
                .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 6)
            }
        }
        .frame(maxHeight: 330)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .sheet(isPresented: $adding) { CustomShortcutSheet(store: store) }
    }

    private func section(_ title: String, _ items: [Shortcut], addButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Palette.faint).padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                ForEach(items) { s in
                    ShortcutChip(shortcut: s, pinned: store.isPinned(s))
                        .onTapGesture { onRun(s) }
                        .onLongPressGesture(minimumDuration: 0.4) { haptic(.medium); store.togglePin(s) }
                        .contextMenu {
                            if store.custom.contains(s) { Button("Delete", role: .destructive) { store.remove(s) } }
                        }
                }
                if addButton {
                    Button { adding = true } label: {
                        Label("Add", systemImage: "plus").font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 68)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ShortcutChip: View {
    let shortcut: Shortcut
    let pinned: Bool
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: shortcut.symbol).font(.system(size: 15, weight: .medium))
            Text(shortcut.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(shortcut.label.isEmpty ? " " : shortcut.label).font(.system(size: 9).monospaced()).foregroundStyle(Palette.faint)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.chip))
        .overlay(alignment: .topTrailing) {
            if pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Palette.accent).padding(8) }
        }
        .contentShape(Rectangle())
    }
}

struct CustomShortcutSheet: View {
    @ObservedObject var store: ShortcutStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var key = ""
    @State private var mods: Modifiers = .command

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Toggle Sidebar)", text: $title)
                TextField("Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Section("Modifiers") {
                    modToggle("⌘ Command", .command)
                    modToggle("⇧ Shift", .shift)
                    modToggle("⌥ Option", .option)
                    modToggle("⌃ Control", .control)
                }
            }
            .navigationTitle("New Shortcut")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let k = String(key.prefix(1)).lowercased()
                        store.add(Shortcut(id: UUID().uuidString, title: title.isEmpty ? k.uppercased() : title,
                                           symbol: "keyboard", key: k, mods: mods))
                        dismiss()
                    }
                    .disabled(key.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func modToggle(_ label: String, _ m: Modifiers) -> some View {
        Toggle(label, isOn: Binding(get: { mods.contains(m) }, set: { if $0 { mods.insert(m) } else { mods.remove(m) } }))
    }
}

// MARK: - Keyboard mode

/// Live view of the Mac's text field. Holds the text view that owns the iOS keyboard, so it stays
/// in the hierarchy (collapsed) even when the keyboard is down.
struct EditorCard: View {
    @ObservedObject var kb: KeyboardController
    @ObservedObject private var icons = IconCache.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if kb.isActive {
                HStack(spacing: 8) {
                    if let img = icons.images[kb.bundleID] {
                        Image(uiImage: img).resizable().frame(width: 18, height: 18)
                    }
                    Text(kb.appName).font(.caption.weight(.semibold)).foregroundStyle(Palette.faint).lineLimit(1)
                    Spacer()
                    Menu {
                        Picker("Field type", selection: Binding(get: { kb.kind }, set: { kb.setOverride($0 == kb.detectedKind ? nil : $0) })) {
                            ForEach(FieldKind.allCases, id: \.self) { k in
                                Text(k == kb.detectedKind ? "\(k.title) (detected)" : k.title).tag(k)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(kb.kind.title)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(kb.isOverridden ? Palette.accent.opacity(0.3) : Palette.chip))
                    }
                    .foregroundStyle(.white)
                }
            }
            MirrorEditor(textView: kb.textView)
                .frame(height: kb.isActive ? 76 : 1)
                .opacity(kb.isActive ? 1 : 0.01)
                .overlay(alignment: .topLeading) {
                    if kb.isActive && kb.kind == .secure {
                        Text(String(repeating: "•", count: kb.secureCount)).font(.title3).padding(.top, 4)
                    } else if kb.isActive && kb.isEmpty {
                        Text("Type into \(kb.appName.isEmpty ? "your Mac" : kb.appName)…")
                            .font(.system(size: 17)).foregroundStyle(Palette.faint).padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, kb.isActive ? 20 : 0)
        .padding(.vertical, kb.isActive ? 16 : 0)
        .background {
            if kb.isActive { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.11)) }
        }
        .frame(height: kb.isActive ? nil : 1)
    }
}

struct MirrorEditor: UIViewRepresentable {
    let textView: MirrorTextView
    func makeUIView(context: Context) -> MirrorTextView { textView }
    func updateUIView(_ uiView: MirrorTextView, context: Context) {}
}

struct AccessoryRow: View {
    @ObservedObject var kb: KeyboardController
    @ObservedObject var shortcuts: ShortcutStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key(symbol: "keyboard.chevron.compact.down") { kb.hide(byUser: true) }
                divider
                ForEach(shortcuts.pinnedShortcuts) { s in
                    key(text: s.title) { haptic(); kb.perform(s) }
                }
                divider
                modKey("⌘", .command); modKey("⌥", .option); modKey("⌃", .control); modKey("⇧", .shift)
                divider
                key(text: "esc") { kb.press(.escape) }
                key(text: "tab") { kb.press(.tab) }
                key(symbol: "arrow.left") { kb.press(.left) }
                key(symbol: "arrow.up") { kb.press(.up) }
                key(symbol: "arrow.down") { kb.press(.down) }
                key(symbol: "arrow.right") { kb.press(.right) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                     .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .clipShape(Capsule())
        .frame(height: 56)
        .glass(Capsule())
    }

    private var divider: some View { Rectangle().fill(Palette.hairline).frame(width: 1, height: 22) }

    private func key(text: String? = nil, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
                else { Text(text ?? "").font(.subheadline.weight(.medium)) }
            }
            .padding(.horizontal, 18).frame(minWidth: 44, minHeight: 40)
            .background(Capsule().fill(Palette.chip))
        }
        .buttonStyle(.plain)
    }

    private func modKey(_ label: String, _ m: Modifiers) -> some View {
        let on = kb.mods.contains(m)
        return Button { haptic(); kb.toggle(m) } label: {
            Text(label).font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 40)
                .foregroundStyle(on ? Color.black : Color.white)
                .background(Capsule().fill(on ? Palette.accent : Palette.chip))
        }
        .buttonStyle(.plain)
    }
}
