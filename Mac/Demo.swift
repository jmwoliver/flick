import Foundation

/// Recording mode for demo videos and screenshots, in Debug builds only: launch with FLICK_DEMO=1.
///
/// It keeps anything personal out of a recording. The Mac calls itself "MacBook Pro", the phone's
/// Dock shows a fixed set of Apple apps instead of the user's own, and pairing is stored separately,
/// so the real paired iPhone stays paired. FLICK_DEMO_PIN sets the pairing PIN (default 246810).
enum Demo {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.environment["FLICK_DEMO"] == "1"
    #else
    static let isOn = false
    #endif

    static let macName = "MacBook Pro"
    static var pin: String { ProcessInfo.processInfo.environment["FLICK_DEMO_PIN"] ?? "246810" }
    static let dockApps: [(id: String, name: String)] = [
        ("com.apple.finder", "Finder"), ("com.apple.Safari", "Safari"), ("com.apple.TextEdit", "TextEdit"),
        ("com.apple.calculator", "Calculator"), ("com.apple.Music", "Music"),
    ]
}

/// Where pairing state lives. Demo mode uses its own UserDefaults suite and Keychain accounts.
enum Store {
    static let defaults: UserDefaults = Demo.isOn ? UserDefaults(suiteName: "com.jacobwoliver.flick.mac.demo")! : .standard
    static func key(_ name: String) -> String { Demo.isOn ? "demo.\(name)" : name }
}
