import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// An exclusive lock on a file, held for as long as this object lives. The app takes one at
/// launch so only one copy runs: two copies would both sync and could copy events twice. A
/// lock rather than a look at the running apps, because two copies starting together at login
/// can each miss the other. The kernel drops the lock when the process ends, crash or not, so
/// nothing stale is left behind.
public final class InstanceLock {
    public struct Failure: Error, Equatable {
        public var path: String
        public var errno: Int32
    }

    /// The copy holding the lock, as it wrote itself into the lock file.
    public struct Holder: Equatable, Sendable {
        public var pid: Int32
        public var version: String

        public init(pid: Int32, version: String) {
            self.pid = pid
            self.version = version
        }
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Writes who holds the lock into the file, for a later copy to read with `holder(at:)`.
    /// Best effort: a copy that can't be read back is treated like one from before this existed.
    public func record(_ holder: Holder) {
        let text = Array("\(holder.pid) \(holder.version)\n".utf8)
        guard ftruncate(descriptor, 0) == 0 else { return }
        _ = text.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }

    /// Who the lock file says holds it. nil for a file left empty, as copies before 2.0.15
    /// leave it, or one that doesn't read as a holder. The file outlives its holder, so check
    /// the process still runs before believing it.
    public static func holder(at url: URL) -> Holder? {
        guard let data = try? Data(contentsOf: url), data.count <= 256,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = Int32(parts[0]), pid > 0 else { return nil }
        return Holder(pid: pid, version: String(parts[1]))
    }

    /// Whether a copy at `version` starting up takes over from the one holding the lock: only
    /// from an older one, so starting the app twice still leaves the first copy running, and an
    /// old copy started by mistake doesn't end a newer one. A holder that wrote nothing (nil)
    /// is from before 2.0.15, older than any copy that asks.
    public static func replaces(_ holder: Holder?, version: String) -> Bool {
        // Not a copy that can't tell its own version, like a bare binary outside its bundle.
        guard let holder else { return UpdateCheck.isNewer(version, than: "0") }
        return UpdateCheck.isNewer(version, than: holder.version)
    }

    /// Takes the lock on `url`, creating the file and its folder if needed. nil when another
    /// process, or another `InstanceLock` in this one, already holds it. Throws when the file
    /// can't be opened or locked for any other reason.
    public static func acquire(at url: URL) throws -> InstanceLock? {
        let path = url.path
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure(path: path, errno: errno) }

        // Each open() is its own open file description, so this also conflicts with a lock
        // held through another descriptor in this process.
        var result: Int32
        repeat {
            result = flock(descriptor, LOCK_EX | LOCK_NB)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw Failure(path: path, errno: error)
        }
        return InstanceLock(descriptor: descriptor)
    }
}
