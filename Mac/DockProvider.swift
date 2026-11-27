import AppKit

/// Mirrors the Mac's Dock for the phone: pinned Dock apps first (in Dock order), then any other
/// running apps. Watches launches/quits/activations and renders icons on request.
final class DockProvider {
    var onChange: (([DockApp], String) -> Void)?
    private(set) var apps: [DockApp] = []
    private(set) var front = ""
    private var observers: [NSObjectProtocol] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var list: [DockApp] = [DockApp(bundleID: "com.apple.finder", name: "Finder", running: true, pinned: true)]
        var seen: Set<String> = ["com.apple.finder"]
        for (id, name) in pinnedApps() where !seen.contains(id) {
            seen.insert(id)
            list.append(DockApp(bundleID: id, name: name, running: runningIDs.contains(id), pinned: true))
        }
        for app in running {
            guard let id = app.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            list.append(DockApp(bundleID: id, name: app.localizedName ?? id, running: true, pinned: false))
        }
        if Demo.isOn {
            list = Demo.dockApps.map { DockApp(bundleID: $0.id, name: $0.name, running: runningIDs.contains($0.id), pinned: true) }
        }
        let f = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard list != apps || f != front else { return }
        apps = list; front = f
        onChange?(list, f)
    }

    /// Pinned apps from the Dock's own preferences, in Dock order.
    private func pinnedApps() -> [(String, String)] {
        guard let tiles = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] else { return [] }
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any] else { return nil }
            var id = data["bundle-identifier"] as? String
            if id == nil, let file = data["file-data"] as? [String: Any], let s = file["_CFURLString"] as? String,
               let url = URL(string: s) ?? Optional(URL(fileURLWithPath: s)) {
                id = Bundle(url: url)?.bundleIdentifier
            }
            guard let id else { return nil }
            let name = data["file-label"] as? String ?? id
            return (id, name)
        }
    }

    /// 120×120 PNG of the app's icon (~10–20 KB).
    func icon(for bundleID: String) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let size = 120
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Activates a running app or launches it.
    func activate(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.unhide()
            app.activate(options: [.activateAllWindows])
            // Apps with no open windows (e.g. after closing the last one) need a reopen to show one.
            if let url = app.bundleURL {
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }
}
