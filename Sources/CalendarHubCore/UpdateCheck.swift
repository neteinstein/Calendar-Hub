import Foundation

/// Works out whether a newer version of the app is published on GitHub. Pure parsing and
/// comparison, no networking, so it can be unit tested.
public enum UpdateCheck {
    /// The newest published version and where to read about it.
    public struct Latest: Hashable, Sendable {
        public var version: String
        public var url: URL?

        public init(version: String, url: URL? = nil) {
            self.version = version
            self.url = url
        }
    }

    /// True when `candidate` is a higher version than `current`. Versions are dotted numbers
    /// ("0.1.0"); a leading "v" and anything after a dash or plus ("0.2.0-beta") are ignored,
    /// and missing components count as zero, so "1.2" equals "1.2.0" and "1.10" beats "1.9".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(of: candidate)
        let b = components(of: current)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func components(of version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        text = text.components(separatedBy: CharacterSet(charactersIn: "-+")).first ?? text
        return text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// Reads the newest release from GitHub's `GET /repos/…/releases/latest` response.
    public static func latest(fromReleaseJSON data: Data) -> Latest? {
        struct Release: Decodable {
            let tag_name: String
            let html_url: String?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.tag_name.isEmpty
        else { return nil }
        return Latest(version: release.tag_name, url: release.html_url.flatMap(URL.init(string:)))
    }

    /// Reads the version from an app Info.plist. The one on the repo's main branch says what
    /// the newest source build would be, which covers the time before releases are published.
    public static func version(fromInfoPlist data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    /// Reads `version "2.0.1"` from a Homebrew formula: the version `brew upgrade` installs.
    /// The tap is updated after main, so for a Homebrew install it's the version that counts.
    public static func version(fromFormula text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.trimmingCharacters(in: .whitespaces)
            guard words.hasPrefix("version \""), let end = words.dropFirst(9).firstIndex(of: "\"") else { continue }
            let version = String(words[words.index(words.startIndex, offsetBy: 9)..<end])
            return version.isEmpty ? nil : version
        }
        return nil
    }

    /// Checks run once a day.
    public static let interval: TimeInterval = 24 * 3600

    /// True when the last check that got an answer is a day old, or there's none yet. One dated
    /// in the future counts too, so a clock that was set back can't stop the checks.
    public static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        let age = now.timeIntervalSince(lastChecked)
        return age >= interval || age < 0
    }

    /// How this copy was installed: where its updates come from, and how to run one.
    public enum Installation: Equatable, Sendable {
        case homebrew(Homebrew)
        /// Built from source. `clone` is the clone it was built in, when the app is still in
        /// that clone's `build` folder; nil when it was moved, so the update can't run by itself.
        case source(clone: URL?)

        public var homebrew: Homebrew? {
            if case .homebrew(let homebrew) = self { return homebrew }
            return nil
        }
    }

    public struct Homebrew: Equatable, Sendable {
        /// Homebrew's prefix: /opt/homebrew, or /usr/local on Intel.
        public var prefix: URL
        /// The account that owns Homebrew when it isn't the one running the app: Homebrew
        /// installed from a separate admin account. Only that account can run `brew upgrade`.
        public var owner: String?
        /// The launchd job's label when `brew services` started the app.
        public var serviceLabel: String?

        public init(prefix: URL, owner: String? = nil, serviceLabel: String? = nil) {
            self.prefix = prefix
            self.owner = owner
            self.serviceLabel = serviceLabel
        }
    }

    /// Homebrew's prefix for a bundle Homebrew installed, given its path with symlinks resolved
    /// (`<prefix>/Cellar/calendar-hub/<version>/Calendar Hub.app`); nil for any other bundle.
    public static func homebrewPrefix(forResolvedBundle bundle: URL) -> URL? {
        ApplicationsLink.homebrewOptBundle(forResolvedBundle: bundle)?
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The clone a source build may sit in: `<clone>/build/Calendar Hub.app`. Only the
    /// layout; the caller checks that it really is a clone.
    public static func sourceClone(forResolvedBundle bundle: URL) -> URL? {
        let folder = bundle.standardizedFileURL.deletingLastPathComponent()
        guard bundle.pathExtension == "app", folder.lastPathComponent == "build" else { return nil }
        return folder.deletingLastPathComponent()
    }

    /// A shell script that updates the app and starts the new version, for Terminal to run so
    /// that its output, any password prompt and any error are in front of the user. It stops at
    /// the first failure and leaves the running copy alone. nil when the update can't run by
    /// itself: a source build that isn't in its clone any more.
    public static func updateScript(for installation: Installation) -> String? {
        var lines = [
            "#!/bin/bash",
            "# Updates Calendar Hub and starts the new version. Written by the app for Terminal to run.",
            "set -euo pipefail",
        ]
        switch installation {
        case .homebrew(let homebrew):
            let brew = quoted(homebrew.prefix.appendingPathComponent("bin/brew").path)
            let upgrade = "\(brew) update && \(brew) upgrade calendar-hub"
            if let owner = homebrew.owner {
                lines += [
                    "echo \(quoted("Homebrew belongs to “\(owner)”, so the upgrade runs as that account: enter its password."))",
                    "su - \(quoted(owner)) -c \(quoted(upgrade))",
                ]
            } else {
                lines += [brew + " update", brew + " upgrade calendar-hub"]
            }
            if let label = homebrew.serviceLabel {
                // Restarts the job brew services started, from this account, the one logged in.
                lines.append("launchctl kickstart -k \"gui/$(id -u)/\"\(quoted(label))")
            } else {
                lines += restart(quoted(homebrew.prefix.appendingPathComponent("opt/calendar-hub/Calendar Hub.app").path))
            }
        case .source(let clone?):
            lines += [
                "cd \(quoted(clone.path))",
                "git pull --ff-only",
                "scripts/build-app.sh",
            ] + restart(quoted("build/Calendar Hub.app"))
        case .source(nil):
            return nil
        }
        lines += ["echo", "echo \(quoted("Calendar Hub is up to date and running. You can close this window."))"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quits the old copy and opens `app`. The pause lets the old copy quit first, since only
    /// one copy runs at a time; it may be gone already, if `brew upgrade` removed it.
    private static func restart(_ app: String) -> [String] {
        ["pkill -x CalendarHub || true", "sleep 1", "open \(app)"]
    }

    /// `text` in single quotes for the shell, with any single quote in it kept.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
