import SwiftUI
import ApplicationServices

@main
struct FlickMacApp: App {
    @StateObject private var model = MacModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(model.isConnected ? "MenuBarConnected" : "MenuBarIdle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class MacModel: ObservableObject {
    @Published var state: Server.State = .starting
    @Published var trusted = AXIsProcessTrusted()
    @Published var pin: String
    @Published var focus = FocusInfo(editable: false, secure: false, app: "", role: "", token: 0)
    @Published var paired: Server.PairedDevice?
    @Published var notice: String?
    private let server: Server
    private var trustTimer: Timer?

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    init() {
        // The PIN lives in the Keychain (older builds kept it in UserDefaults).
        let legacy = UserDefaults.standard.string(forKey: "pin")
        UserDefaults.standard.removeObject(forKey: "pin")
        let pin = Keychain.string("pin") ?? legacy ?? MacModel.newPin()
        Keychain.set(pin, "pin")
        self.pin = pin
        server = Server(pin: pin)
        server.onStateChange = { [weak self] s in self?.state = s }
        server.onPairedChange = { [weak self] p in self?.paired = p }
        server.onNotice = { [weak self] n in self?.notice = n }
        paired = server.pairedDevice
        let previousFocus = server.focus.onChange
        server.focus.onChange = { [weak self] info in
            previousFocus?(info)
            DispatchQueue.main.async { self?.focus = info }
        }
        server.start()

        if !trusted {
            // Shows the system prompt that deep-links to Privacy & Security → Accessibility.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            if now != self.trusted {
                self.trusted = now
                if now { self.server.focus.start() }
            }
        }
    }

    static func newPin() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }

    func regeneratePin() {
        pin = MacModel.newPin()
        Keychain.set(pin, "pin")
        server.setPin(pin)
    }

    func disconnect() { server.disconnect() }

    /// Forget the paired phone and its key, and rotate the PIN.
    func unpair() {
        pin = MacModel.newPin()
        Keychain.set(pin, "pin")
        notice = nil
        server.unpair(newPin: pin)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

struct MenuContent: View {
    @ObservedObject var model: MacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Flick").font(.headline)

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.callout)
            }

            if model.paired == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pairing PIN").font(.caption).foregroundStyle(.secondary)
                    Text(model.pin.map(String.init).joined(separator: " "))
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Paired iPhone").font(.caption).foregroundStyle(.secondary)
                if let p = model.paired {
                    HStack {
                        Image(systemName: "iphone")
                        Text(p.name).lineLimit(1)
                        Spacer()
                        if model.isConnected {
                            Button("Disconnect") { model.disconnect() }
                        }
                        Button("Unpair") { model.unpair() }
                    }
                } else {
                    Text("None. The first iPhone to connect with this PIN becomes the paired one. After that, the PIN stops working until you unpair.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if let n = model.notice {
                    Text(n).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility permission is required to move the pointer, type, and detect text fields.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
                }
                .padding(8)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Focus: \(model.focus.app) · \(model.focus.role.isEmpty ? "—" : model.focus.role)\(model.focus.editable ? " ⌨︎" : "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Divider()
            HStack {
                if model.paired == nil { Button("New PIN") { model.regeneratePin() } }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var statusText: String {
        switch model.state {
        case .starting: "Starting…"
        case .listening: "Waiting for iPhone"
        case .connected(let d): "Connected to \(d)"
        case .failed(let e): "Error: \(e)"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .connected: .green
        case .listening: .yellow
        case .starting: .gray
        case .failed: .red
        }
    }
}
