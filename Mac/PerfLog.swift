import Foundation

/// Appends timestamped lines to ~/Library/Logs/Flick/perf.log. Timings and counts only, never
/// typed text. Rotates to perf.log.1 at 5 MB, so it stays under ~10 MB.
enum PerfLog {
    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Flick")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("perf.log")
    }()
    private static let queue = DispatchQueue(label: "flick.perflog", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
