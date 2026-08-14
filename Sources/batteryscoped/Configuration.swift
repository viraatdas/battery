import BatteryCore
import Foundation

/// Command-line configuration for `batteryscoped`.
public struct Configuration: Equatable {
    /// Seconds between ticks.
    public var intervalSeconds: Double
    /// SQLite database the sampler writes to.
    public var databasePath: String
    /// Take exactly one sample and exit.
    public var runOnce: Bool
    /// Print usage and exit.
    public var showHelp: Bool

    public static let defaultIntervalSeconds: Double = 30
    /// Samples older than this are dropped once an hour.
    public static let retentionDays = 30

    public init(
        intervalSeconds: Double = Configuration.defaultIntervalSeconds,
        databasePath: String = DBLocation.writablePath(),
        runOnce: Bool = false,
        showHelp: Bool = false
    ) {
        self.intervalSeconds = intervalSeconds
        self.databasePath = databasePath
        self.runOnce = runOnce
        self.showHelp = showHelp
    }

    public enum ParseError: Error, CustomStringConvertible {
        case missingValue(flag: String)
        case invalidInterval(String)
        case unknownFlag(String)

        public var description: String {
            switch self {
            case .missingValue(let flag):
                return "\(flag) requires a value"
            case .invalidInterval(let value):
                return "--interval expects a positive number of seconds, got '\(value)'"
            case .unknownFlag(let flag):
                return "unknown option '\(flag)'"
            }
        }
    }

    /// Parses argv (without the executable name).
    public static func parse(
        arguments: [String],
        defaultDatabasePath: String = DBLocation.writablePath()
    ) throws -> Configuration {
        var configuration = Configuration(databasePath: defaultDatabasePath)
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--interval", "-i":
                guard let value = arguments[safe: index + 1] else {
                    throw ParseError.missingValue(flag: argument)
                }
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
                    throw ParseError.invalidInterval(value)
                }
                configuration.intervalSeconds = seconds
                index += 2
            case "--db", "--database":
                guard let value = arguments[safe: index + 1], !value.isEmpty else {
                    throw ParseError.missingValue(flag: argument)
                }
                configuration.databasePath = value
                index += 2
            case "--once":
                configuration.runOnce = true
                index += 1
            case "--help", "-h":
                configuration.showHelp = true
                index += 1
            default:
                throw ParseError.unknownFlag(argument)
            }
        }
        return configuration
    }

    public static func usage(defaultDatabasePath: String = DBLocation.writablePath()) -> String {
        """
        batteryscoped — BatteryScope sampling daemon

        Usage:
            batteryscoped [--interval <seconds>] [--db <path>] [--once]

        Options:
            --interval <seconds>  Seconds between samples (default: \(Int(defaultIntervalSeconds))).
            --db <path>           Database path (default: \(defaultDatabasePath)).
            --once                Take exactly one sample, then exit.
            -h, --help            Show this help.

        Battery samples need no privileges. Per-process energy comes from
        powermetrics, which requires root: install the daemon with
        `sudo ./Scripts/install-daemon.sh` to collect it.
        """
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
