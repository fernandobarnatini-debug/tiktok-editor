import Foundation

/// Persistent debug log for every run. Writes to Documents/retake_debug.log
/// so we can read it from the simulator/device after the run finishes.
/// Serialized through a private queue so concurrent writes from different
/// pipeline stages don't interleave mid-line.
enum DebugLog {
    private static let filename = "retake_debug.log"
    private static let queue = DispatchQueue(label: "DebugLog.serial")

    static func section(_ title: String) {
        append("\n=== \(title) \(Date()) ===")
    }

    static func append(_ line: String) {
        queue.sync {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = docs.appendingPathComponent(filename)
            let text = line.hasSuffix("\n") ? line : line + "\n"
            if FileManager.default.fileExists(atPath: url.path),
               let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? text.data(using: .utf8)?.write(to: url)
            }
        }
    }
}
