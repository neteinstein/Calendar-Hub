import Foundation

/// The Shortcuts app's command line tool: lists shortcuts and runs one, for turning a Focus on
/// and off during meetings (macOS has no other way for an app to do that).
enum Shortcuts {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Runs `name` without waiting for it. A missing shortcut is only logged.
    static func run(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            AppLog.write("Calendar Hub: the shortcut couldn't run: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        do {
            try process.run()
        } catch {
            AppLog.write("Calendar Hub: couldn't run Shortcuts: \(error)")
        }
    }

    /// The names of the user's shortcuts, sorted. Empty when Shortcuts can't be asked.
    static func list() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = ["list"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let names = (String(data: data, encoding: .utf8) ?? "")
                    .split(whereSeparator: \.isNewline).map(String.init)
                    .filter { !$0.isEmpty }
                continuation.resume(returning: Array(Set(names)).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                })
            }
        }
    }
}
