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

    /// Seconds between *pressure* readings, which run far more often than the
    /// full tick.
    ///
    /// A stall lasting twenty seconds is a stall someone noticed, and at a
    /// 30-second cadence it is invisible — it can fall entirely between two
    /// samples. Pressure is cheap enough to read this often (a handful of
    /// sysctls) and small enough to store, unlike the process table.
    ///
    /// The two cadences are deliberately different. Detection needs to be fast;
    /// attribution does not, because a process holding 12 GB does not appear
    /// and vanish inside thirty seconds.
    public static let defaultPressureIntervalSeconds: Double = 5

    /// The pressure cadence actually in force: `defaultPressureIntervalSeconds`,
    /// or the tick interval when that is somehow shorter.
    public var pressureIntervalSeconds: Double {
        min(Configuration.defaultPressureIntervalSeconds, intervalSeconds)
    }

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
