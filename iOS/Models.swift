import UIKit
import SwiftUI

// MARK: - Preferences

enum StripSide: String, CaseIterable, Identifiable {
    case left, right, off
    var id: String { rawValue }
    var title: String { switch self { case .left: "Left"; case .right: "Right"; case .off: "Off" } }
}

struct Prefs {
    var sensitivity: Double
    var acceleration: Double
    var scrollSpeed: Double
    var naturalScroll: Bool
    var autoKeyboard: Bool
    var predictive: Bool
    var stripSide: StripSide

    static func load() -> Prefs {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        return Prefs(sensitivity: dbl("sensitivity", 1.6), acceleration: dbl("acceleration", 1.0),
                     scrollSpeed: dbl("scrollSpeed", 1.0), naturalScroll: bool("naturalScroll", true),
                     autoKeyboard: bool("autoKeyboard", true), predictive: bool("predictive", false),
                     stripSide: StripSide(rawValue: d.string(forKey: "stripSide") ?? "") ?? .left)
    }
}

// MARK: - App icons (cached on disk so the dock is instant on reconnect)

final class IconCache: ObservableObject {
    static let shared = IconCache()
    @Published private(set) var images: [String: UIImage] = [:]
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("icons")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            if let img = UIImage(contentsOfFile: url.path) { images[url.deletingPathExtension().lastPathComponent] = img }
        }
    }

    func has(_ id: String) -> Bool { images[id] != nil }

    func store(_ id: String, png: Data) {
        guard let img = UIImage(data: png) else { return }
        images[id] = img
        try? png.write(to: dir.appendingPathComponent("\(id).png"))
    }
}

// MARK: - Shortcuts

struct Shortcut: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var symbol: String
    /// A character ("c") or "special:<SpecialKey>" ("special:tab").
    var key: String = ""
    var mods: Modifiers = []
    var system: SystemAction? = nil

    var label: String {
        if system != nil { return "" }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        if key.hasPrefix("special:") {
            let k = String(key.dropFirst(8))
            s += ["tab": "⇥", "space": "Space", "returnKey": "↩", "escape": "⎋", "delete": "⌫",
                  "left": "←", "right": "→", "up": "↑", "down": "↓"][k] ?? k
        } else {
            s += key.uppercased()
        }
        return s
    }

    var message: ClientMessage {
        if let system { return .system(system) }
        if key.hasPrefix("special:"), let k = SpecialKey(rawValue: String(key.dropFirst(8))) {
            return .key(k, mods: mods, count: 1)
        }
        return .shortcut(key, mods: mods)
    }
}

struct ShortcutGroup: Identifiable {
    let id: String
    let items: [Shortcut]
}

final class ShortcutStore: ObservableObject {
    @Published var pinned: [String] { didSet { UserDefaults.standard.set(pinned, forKey: "pinnedShortcuts") } }
    @Published var custom: [Shortcut] { didSet { save() } }

    static let builtIn: [ShortcutGroup] = [
        ShortcutGroup(id: "Edit", items: [
            Shortcut(id: "copy", title: "Copy", symbol: "doc.on.doc", key: "c", mods: .command),
            Shortcut(id: "paste", title: "Paste", symbol: "doc.on.clipboard", key: "v", mods: .command),
            Shortcut(id: "cut", title: "Cut", symbol: "scissors", key: "x", mods: .command),
            Shortcut(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", key: "z", mods: .command),
            Shortcut(id: "redo", title: "Redo", symbol: "arrow.uturn.forward", key: "z", mods: [.command, .shift]),
            Shortcut(id: "selectAll", title: "Select All", symbol: "selection.pin.in.out", key: "a", mods: .command),
        ]),
        ShortcutGroup(id: "Find", items: [
            Shortcut(id: "find", title: "Find", symbol: "magnifyingglass", key: "f", mods: .command),
            Shortcut(id: "ctrlF", title: "Ctrl-F", symbol: "text.magnifyingglass", key: "f", mods: .control),
            Shortcut(id: "findNext", title: "Find Next", symbol: "chevron.down", key: "g", mods: .command),
            Shortcut(id: "address", title: "Address Bar", symbol: "link", key: "l", mods: .command),
        ]),
        ShortcutGroup(id: "Tabs & Windows", items: [
            Shortcut(id: "newTab", title: "New Tab", symbol: "plus.square.on.square", key: "t", mods: .command),
            Shortcut(id: "closeTab", title: "Close", symbol: "xmark.square", key: "w", mods: .command),
            Shortcut(id: "reopenTab", title: "Reopen Tab", symbol: "arrow.counterclockwise.square", key: "t", mods: [.command, .shift]),
            Shortcut(id: "reload", title: "Reload", symbol: "arrow.clockwise", key: "r", mods: .command),
            Shortcut(id: "back", title: "Back", symbol: "chevron.left", key: "[", mods: .command),
            Shortcut(id: "forward", title: "Forward", symbol: "chevron.right", key: "]", mods: .command),
            Shortcut(id: "switchApp", title: "Last App", symbol: "square.stack.3d.up", key: "special:tab", mods: .command),
            Shortcut(id: "nextWindow", title: "Next Window", symbol: "macwindow.on.rectangle", key: "`", mods: .command),
            Shortcut(id: "save", title: "Save", symbol: "square.and.arrow.down", key: "s", mods: .command),
            Shortcut(id: "quit", title: "Quit App", symbol: "power", key: "q", mods: .command),
        ]),
        ShortcutGroup(id: "Terminal", items: [
            Shortcut(id: "ctrlC", title: "Interrupt", symbol: "stop.circle", key: "c", mods: .control),
            Shortcut(id: "ctrlD", title: "EOF", symbol: "eject", key: "d", mods: .control),
            Shortcut(id: "ctrlR", title: "History", symbol: "clock.arrow.circlepath", key: "r", mods: .control),
            Shortcut(id: "clear", title: "Clear", symbol: "clear", key: "k", mods: .command),
        ]),
        ShortcutGroup(id: "System", items: [
            Shortcut(id: "spotlight", title: "Spotlight", symbol: "magnifyingglass.circle", system: .spotlight),
            Shortcut(id: "mission", title: "Mission Control", symbol: "rectangle.3.group", system: .missionControl),
            Shortcut(id: "desktop", title: "Show Desktop", symbol: "menubar.dock.rectangle", system: .showDesktop),
            Shortcut(id: "screenshot", title: "Screenshot", symbol: "camera.viewfinder", key: "4", mods: [.command, .shift]),
            Shortcut(id: "emoji", title: "Emoji", symbol: "face.smiling", key: "special:space", mods: [.command, .control]),
        ]),
    ]

    init() {
        pinned = UserDefaults.standard.stringArray(forKey: "pinnedShortcuts") ?? ["copy", "paste", "undo", "find", "selectAll"]
        if let data = UserDefaults.standard.data(forKey: "customShortcuts"),
           let list = try? JSONDecoder().decode([Shortcut].self, from: data) { custom = list } else { custom = [] }
    }

    var all: [Shortcut] { Self.builtIn.flatMap(\.items) + custom }
    var pinnedShortcuts: [Shortcut] { pinned.compactMap { id in all.first { $0.id == id } } }

    func isPinned(_ s: Shortcut) -> Bool { pinned.contains(s.id) }
    func togglePin(_ s: Shortcut) {
        if let i = pinned.firstIndex(of: s.id) { pinned.remove(at: i) } else { pinned.append(s.id) }
    }
    func add(_ s: Shortcut) { custom.append(s); pinned.append(s.id) }
    func remove(_ s: Shortcut) { custom.removeAll { $0.id == s.id }; pinned.removeAll { $0 == s.id } }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: "customShortcuts") }
    }
}
