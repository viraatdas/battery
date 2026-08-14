import Foundation

/// Where the sampler writes and the UI reads.
///
/// The daemon normally runs as root and owns the system-wide database, but a
/// plain user can run the sampler by hand without installing anything. Both the
/// daemon and the app resolve the path the same way so they always meet at the
/// same file.
public enum DBLocation {
    /// Overrides everything else. Set by tests and by `batteryscoped --db`.
    public static let environmentKey = "BATTERYSCOPE_DB"

    /// System-wide database written by the root LaunchDaemon.
    public static let systemPath = BatteryScopePaths.defaultDBPath

    /// Per-user fallback used when the daemon has never been installed.
    public static var userPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/BatteryScope/batteryscope.db"
    }

    /// Path a reader should open: the system database when it exists, otherwise
    /// the per-user one. Returns nil when neither has been created yet, which
    /// the UI presents as its onboarding state.
    public static func existingPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment[environmentKey], !override.isEmpty {
            return FileManager.default.fileExists(atPath: override) ? override : nil
        }
        for candidate in [systemPath, userPath]
        where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Path a writer should create. Root writes system-wide; anyone else writes
    /// under their own home directory, where no privileges are required.
    public static func writablePath(
        isRoot: Bool = (getuid() == 0),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment[environmentKey], !override.isEmpty {
            return override
        }
        return isRoot ? systemPath : userPath
    }
}
