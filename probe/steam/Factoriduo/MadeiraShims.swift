// Stand-ins for the two parts of Madeira that its Steam client calls outside
// probe/steam/Madeira: its log (LogStore) and its settings file (MadeiraConfig).

import Foundation

/// Madeira's LogStore writes to its in-app log. Here every line goes to stderr,
/// which the app's FactorioProbe log already collects, prefixed so it is easy
/// to find. Madeira's Steam code never logs tokens, passwords or account names.
final class LogStore {
    enum Level { case info, success, warning, error }
    static let shared = LogStore()

    func log(_ message: String, level: Level = .info) {
        let mark: String
        switch level {
        case .info: mark = ""
        case .success: mark = "ok "
        case .warning: mark = "warning "
        case .error: mark = "error "
        }
        fputs("FACTORIDUO_STEAM: \(mark)\(message)\n", stderr)
    }
}

/// Madeira keeps settings in madeira.cfg. Here they live in the app's
/// UserDefaults under the same keys ("env.MADEIRA_STEAM_TRACE" and so on).
enum MadeiraConfig {
    private static let defaults = UserDefaults.standard
    private static let prefix = "factoriduo.config."

    static func get(_ key: String) -> String? { defaults.string(forKey: prefix + key) }

    static func set(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}

/// The app's one Steam connection, shared by Steam Cloud saves and the game download.
@MainActor
enum FactoriduoSteam {
    static let session = SteamSession()
    static let fetcher = SteamLibraryFetcher(session: session)
    /// While true, Steam Cloud leaves the connection open when it is done.
    static var downloading = false
}
