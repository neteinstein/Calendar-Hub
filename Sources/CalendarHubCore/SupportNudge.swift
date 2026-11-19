import Foundation

/// When the menu asks, now and then, for a donation. Not before the app has been in use for a
/// while, then no more than once every few months, and never again once the person donates
/// (opens the donate page from anywhere in the app) or says not to ask.
public enum SupportNudge {
    /// How long after Calendar Hub was first run the first ask comes.
    public static let firstAskAfter: TimeInterval = 30 * 24 * 60 * 60
    /// How long "Later" puts it away for.
    public static let askAgainAfter: TimeInterval = 90 * 24 * 60 * 60

    /// - Parameters:
    ///   - firstRun: when this copy first ran (or first ran a version that knows about the ask).
    ///   - lastPutAway: when "Later" was last chosen, if ever.
    ///   - stopped: the person donated or chose not to be asked again.
    public static func isDue(now: Date, firstRun: Date, lastPutAway: Date?, stopped: Bool) -> Bool {
        guard !stopped, now.timeIntervalSince(firstRun) >= firstAskAfter else { return false }
        guard let lastPutAway else { return true }
        return now.timeIntervalSince(lastPutAway) >= askAgainAfter
    }
}
