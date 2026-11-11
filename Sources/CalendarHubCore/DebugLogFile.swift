import Foundation

/// The debug log on disk, so it outlives the app: a crash, or a quit at launch before Settings
/// can be opened, still leaves its lines behind. Each line is written and flushed as it is
/// logged. When the file grows past `maxBytes` it becomes `<name>.old.log` and a new one starts,
/// so the two together never take more than about twice that.
public final class DebugLogFile: @unchecked Sendable {
    public let url: URL
    public let maxBytes: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0

    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = max(1, maxBytes)
    }

    deinit { try? handle?.close() }

    /// The file the log moves to when it is full.
    public var oldURL: URL {
        url.deletingPathExtension().appendingPathExtension("old").appendingPathExtension(url.pathExtension)
    }

    /// Appends `line` and a newline. Errors are dropped: logging never stops the app.
    public func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        if size + data.count > maxBytes, size > 0 { rotate() }
        guard let handle = openHandle() else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            closeHandle()
        }
    }

    /// The log's text, older file first: what the app logged, across launches, up to the last line.
    public func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        let parts = [oldURL, url].compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        return parts.joined().trimmingCharacters(in: .newlines)
    }

    /// Deletes both files.
    public func remove() {
        lock.lock()
        defer { lock.unlock() }
        closeHandle()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: oldURL)
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        size = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        return opened
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        size = 0
    }

    private func rotate() {
        closeHandle()
        let manager = FileManager.default
        try? manager.removeItem(at: oldURL)
        try? manager.moveItem(at: url, to: oldURL)
    }
}
