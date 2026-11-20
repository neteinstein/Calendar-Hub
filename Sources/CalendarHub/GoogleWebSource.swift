import AppKit
import CalendarHubCore
import Foundation
import WebKit

/// Reads a Google Calendar through a built-in browser window, for Google accounts that can't
/// be added to Calendar.app (a work account whose admin turned off third-party access, say).
///
/// The user signs in once in the window. Each sync then downloads, in that signed-in session,
/// the iCalendar export Google Calendar's own Settings › Import & export offers: a zip with an
/// .ics file per calendar the account owns. The account's own calendar (the file named after
/// its address) is read with `ICalendar`. The download goes to a folder only the user can read
/// and is deleted straight after. Nothing is sent anywhere else.
///
/// To Google this is a Safari session, with its own cookie store, like `OutlookWebSource`.
///
/// EXPERIMENTAL: this depends on Google Calendar's export, which Google can change at any time.
/// If a sync can't read it, the copies are left untouched.
@MainActor
final class GoogleWebSource: NSObject, ObservableObject {
    static let calendarURL = URL(string: "https://calendar.google.com/calendar/u/0/r")!
    /// Where Google Calendar's export downloads from, tried in turn.
    static let exportPaths = ["/calendar/exporticalzip", "/calendar/u/0/exporticalzip"]

    @Published private(set) var needsSignIn = false
    /// Called when the window closes, by the user or after signing in.
    var onWindowClosed: (() -> Void)?

    let sourceID: UUID
    private let webView: WKWebView
    private var window: NSWindow?
    private var signingIn = false
    private var closingQuietly = false
    private var isFetching = false
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var closeAfterSignIn: Task<Void, Never>?

    init(sourceID: UUID) {
        self.sourceID = sourceID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: sourceID)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        webView.customUserAgent = OutlookWebSource.safariUserAgent()
        super.init()
        urlObservation = webView.observe(\.url) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.urlChanged(webView.url) }
        }
        loadingObservation = webView.observe(\.isLoading) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.urlChanged(webView.url) }
        }
    }

    func tearDown() {
        onWindowClosed = nil
        urlObservation = nil
        loadingObservation = nil
        closeAfterSignIn?.cancel()
        window?.close()
        window = nil
        webView.stopLoading()
    }

    // MARK: - Sign-in window

    func showWindow(title: String) {
        let window = self.window ?? makeWindow()
        window.title = "Google Calendar – \(title)"
        signingIn = Self.isSignInPage(webView.url)
        if webView.url == nil { webView.load(URLRequest(url: Self.calendarURL)) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        self.window = window
        return window
    }

    func closeWindow() {
        guard let window, window.isVisible else { return }
        closingQuietly = true
        window.close()
        closingQuietly = false
    }

    /// Closes the window once a sign-in in it has come back to Google Calendar and stayed there.
    private func urlChanged(_ url: URL?) {
        guard window?.isVisible == true, let url else { return }
        if Self.isSignInPage(url) {
            signingIn = true
            closeAfterSignIn?.cancel()
            closeAfterSignIn = nil
        } else if signingIn, Self.isCalendarHost(url), !webView.isLoading, closeAfterSignIn == nil {
            closeAfterSignIn = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.closeAfterSignIn = nil
                guard self.signingIn, self.window?.isVisible == true, !self.webView.isLoading,
                      let url = self.webView.url, Self.isCalendarHost(url) else { return }
                self.signingIn = false
                AppLog.write("Calendar Hub: signed in to Google Calendar, closing its window")
                self.window?.close()
            }
        }
    }

    static func isSignInPage(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
    }

    static func isCalendarHost(_ url: URL) -> Bool {
        url.host?.lowercased() == "calendar.google.com"
    }

    // MARK: - Fetching

    func fetch(from start: Date, to end: Date) async -> SourceFetchResult {
        guard !isFetching else { return .failure("Already reading Google Calendar") }
        if window?.isVisible == true {
            return .failure("Google Calendar window is open. Close it after signing in to sync.")
        }
        isFetching = true
        defer { isFetching = false }
        let result = await read(from: start, to: end)
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
            modifiedSince: .distantPast)
        return result
    }

    private func read(from start: Date, to end: Date) async -> SourceFetchResult {
        guard await load(Self.calendarURL) else { return .failure("Google Calendar didn't load") }
        if Self.isSignInPage(webView.url) || webView.url.map(Self.isCalendarHost) != true {
            needsSignIn = true
            AppLog.write("Calendar Hub: signed out of Google Calendar")
            return .failure("Signed out of Google Calendar. Open its window to sign in again.")
        }
        needsSignIn = false
        var zip: Data?
        var lastError = "no export"
        for path in Self.exportPaths {
            switch await download(path) {
            case .success(let data): zip = data
            case .failure(let error): lastError = error.message
            }
            if zip != nil { break }
        }
        guard let zip else {
            AppLog.write("Calendar Hub: Google Calendar's export couldn't be downloaded: \(lastError)")
            return .failure("Google Calendar's export couldn't be downloaded (\(lastError))")
        }
        let files: [(name: String, text: String)]
        do {
            files = try Self.unzip(zip)
        } catch {
            return .failure("Google Calendar's export couldn't be opened: \(error.localizedDescription)")
        }
        guard let own = Self.ownCalendar(in: files) else {
            return .failure("Google Calendar's export has no calendar of the account's own")
        }
        let account = own.name.hasSuffix(".ics") ? String(own.name.dropLast(4)) : own.name
        let events = ICalendar.sourceEvents(ICalendar.events(in: own.text), account: account, from: start, to: end)
        AppLog.write("Calendar Hub: Google Calendar \(events.count) meetings from \(files.count) calendar files")
        return .success(events)
    }

    /// The account's own calendar among the export's files: the one named after an address that
    /// isn't a group, holiday or other shared calendar.
    static func ownCalendar(in files: [(name: String, text: String)]) -> (name: String, text: String)? {
        let personal = files.filter { file in
            let name = file.name.lowercased()
            return name.hasSuffix(".ics") && name.contains("@") && !name.contains("calendar.google.com")
                && !name.contains("#")
        }
        return personal.max { $0.text.count < $1.text.count } ?? files.first { $0.name.lowercased().hasSuffix(".ics") }
    }

    private struct DownloadError: Error { let message: String }

    /// Downloads `path` in the signed-in page, so it's sent with the session's cookies.
    private func download(_ path: String) async -> Result<Data, DownloadError> {
        let script = """
        const response = await fetch(path, { credentials: 'include' });
        if (!response.ok) return 'error:' + response.status;
        const type = response.headers.get('content-type') || '';
        if (type.includes('text/html')) return 'error:html';
        const bytes = new Uint8Array(await response.arrayBuffer());
        let binary = '';
        for (let i = 0; i < bytes.length; i += 32768) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
        }
        return btoa(binary);
        """
        do {
            let value = try await webView.callAsyncJavaScript(script, arguments: ["path": path], in: nil, contentWorld: .defaultClient)
            guard let text = value as? String else { return .failure(DownloadError(message: "no answer")) }
            if text.hasPrefix("error:") { return .failure(DownloadError(message: String(text.dropFirst(6)))) }
            guard let data = Data(base64Encoded: text) else { return .failure(DownloadError(message: "unreadable")) }
            return .success(data)
        } catch {
            return .failure(DownloadError(message: error.localizedDescription))
        }
    }

    /// Loads `url` and waits for it to finish, up to a minute. False if it never did.
    private func load(_ url: URL) async -> Bool {
        webView.load(URLRequest(url: url))
        let deadline = ContinuousClock.now + .seconds(60)
        try? await Task.sleep(for: .milliseconds(500))
        while webView.isLoading {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// The files in a zip, read with `ditto` into a folder only the user can read, then deleted.
    static func unzip(_ data: Data) throws -> [(name: String, text: String)] {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("calendarhub-google-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("export.zip")
        try data.write(to: zip)
        let out = folder.appendingPathComponent("files")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, out.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var files: [(name: String, text: String)] = []
        let walker = fileManager.enumerator(at: out, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "ics", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files.append((url.lastPathComponent, text))
        }
        return files
    }
}

extension GoogleWebSource: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            signingIn = false
            closeAfterSignIn?.cancel()
            closeAfterSignIn = nil
            if closingQuietly { return }
            DispatchQueue.main.async { [weak self] in self?.onWindowClosed?() }
        }
    }
}
