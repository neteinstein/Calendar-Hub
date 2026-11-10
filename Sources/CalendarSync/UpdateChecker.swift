import AppKit
import CalendarSyncCore
import Combine
import Foundation

/// Checks GitHub for a newer version once a day, and on demand. A Homebrew install compares
/// with the version the tap serves, which is what `brew upgrade` installs; a source build with
/// the newest release when one is published, otherwise the version on the main branch (what a
/// fresh source build would be).
@MainActor
final class UpdateChecker: ObservableObject {
    static let repoPage = URL(string: "https://github.com/neteinstein/Calendar-Sync")!
    /// Where About's Donate button and the menu's heart lead.
    static let donatePage = URL(string: "https://www.pedrovicente.pt/donate")!
    private static let releaseAPI = URL(string: "https://api.github.com/repos/neteinstein/Calendar-Sync/releases/latest")!
    private static let mainInfoPlist = URL(string: "https://raw.githubusercontent.com/neteinstein/Calendar-Sync/main/Support/Info.plist")!
    private static let tapFormula = URL(string: "https://raw.githubusercontent.com/neteinstein/homebrew-tap/main/Formula/calendar-sync.rb")!

    /// How this copy was installed: where its updates come from, and how to run one.
    static let installation = detectInstallation()

    /// Set when a version newer than the running one is published.
    @Published private(set) var available: UpdateCheck.Latest?
    @Published private(set) var isChecking = false
    /// When a check last reached GitHub. Kept across launches, so checks stay a day apart.
    @Published private(set) var lastChecked: Date?
    /// The last check couldn't reach GitHub (offline, GitHub down). What an earlier check
    /// found is kept.
    @Published private(set) var lastCheckFailed = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private let defaults: UserDefaults
    private var timer: Timer?

    private enum Keys {
        static let lastChecked = "updateCheck.lastChecked"
        static let latestVersion = "updateCheck.latestVersion"
        static let latestURL = "updateCheck.latestURL"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        // What the last check found, until the next one: once the app is updated, it's no
        // longer newer.
        if let version = defaults.string(forKey: Keys.latestVersion), UpdateCheck.isNewer(version, than: currentVersion) {
            available = UpdateCheck.Latest(version: version, url: defaults.url(forKey: Keys.latestURL))
        }
        // Ticks every hour and checks once the last check is a day old, so the day counts across
        // sleep and relaunches, and a check that failed is tried again within the hour.
        // Scheduled on the main run loop, so the block runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.checkIfDue() }
            }
        }
        timer?.tolerance = 600
        Task { await checkIfDue() }
    }

    func checkIfDue() async {
        guard UpdateCheck.isDue(lastChecked: lastChecked, now: Date()) else { return }
        await check()
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard let latest = await fetchLatest() else {
            lastCheckFailed = true
            return
        }
        let now = Date()
        lastCheckFailed = false
        lastChecked = now
        available = UpdateCheck.isNewer(latest.version, than: currentVersion) ? latest : nil
        defaults.set(now, forKey: Keys.lastChecked)
        defaults.set(latest.version, forKey: Keys.latestVersion)
        defaults.set(latest.url, forKey: Keys.latestURL)
    }

    private func fetchLatest() async -> UpdateCheck.Latest? {
        if Self.installation.homebrew != nil {
            // main can be ahead of the tap for a while; brew upgrade only gets what the tap serves.
            guard let data = await fetch(Self.tapFormula),
                  let version = UpdateCheck.version(fromFormula: String(decoding: data, as: UTF8.self))
            else { return nil }
            return UpdateCheck.Latest(version: version, url: Self.repoPage)
        }
        if let data = await fetch(Self.releaseAPI), let release = UpdateCheck.latest(fromReleaseJSON: data) {
            return release
        }
        // No release published (or no reply): the version on main is the newest source build.
        if let data = await fetch(Self.mainInfoPlist), let version = UpdateCheck.version(fromInfoPlist: data) {
            return UpdateCheck.Latest(version: version, url: Self.repoPage)
        }
        return nil
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // MARK: - Updating

    /// The update can run by itself, in Terminal. Not for a source build moved out of its clone.
    static var canUpdateInTerminal: Bool { UpdateCheck.updateScript(for: installation) != nil }

    /// What `updateInTerminal` does, to ask before it runs.
    static var updateSummary: String {
        let steps: String
        switch installation {
        case .homebrew(let homebrew):
            let upgrade = "Terminal opens and runs “brew update” and “brew upgrade calendar-sync”"
            steps = (homebrew.owner.map { upgrade + " as “\($0)”, the account that owns Homebrew, so it asks for that account's password." }
                     ?? upgrade + ".")
                + " Homebrew builds the new version on your Mac, which takes a minute or two, then Calendar Sync restarts."
        case .source(let clone):
            steps = "Terminal opens, pulls the new version into \(clone?.path ?? "the clone"), rebuilds the app and restarts it."
        }
        return steps + " Your settings are kept. The new build is ad-hoc signed, so macOS asks for calendar access again."
    }

    /// Writes the update script to a temporary `.command` file and opens it in Terminal, where
    /// the user sees it run, types a password if Homebrew belongs to another account, and sees
    /// what went wrong if it fails. The script restarts the app when it's done.
    static func updateInTerminal() async throws {
        guard let script = UpdateCheck.updateScript(for: installation) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Update Calendar Sync.command")
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Terminal isn't installed."])
        }
        try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func detectInstallation() -> UpdateCheck.Installation {
        // `brew services` starts the app through the opt symlink, which the bundle path keeps.
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        if let prefix = UpdateCheck.homebrewPrefix(forResolvedBundle: bundle) {
            let cellar = prefix.appendingPathComponent("Cellar").path
            let owner = (try? fileManager.attributesOfItem(atPath: cellar))?[.ownerAccountName] as? String
            // launchd sets XPC_SERVICE_NAME to the job's label: sh.brew.calendar-sync under
            // `brew services` (homebrew.mxcl.calendar-sync in older Homebrew).
            let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"].flatMap { $0.hasSuffix(".calendar-sync") ? $0 : nil }
            return .homebrew(.init(prefix: prefix, owner: owner == NSUserName() ? nil : owner, serviceLabel: label))
        }
        let clone = UpdateCheck.sourceClone(forResolvedBundle: bundle).flatMap { clone in
            fileManager.isExecutableFile(atPath: clone.appendingPathComponent("scripts/build-app.sh").path)
                && fileManager.fileExists(atPath: clone.appendingPathComponent(".git").path) ? clone : nil
        }
        return .source(clone: clone)
    }
}
